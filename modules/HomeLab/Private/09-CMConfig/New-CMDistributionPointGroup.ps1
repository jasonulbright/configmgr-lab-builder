function New-CMDistributionPointGroup {
    <#
    .SYNOPSIS
        Idempotently create a CM distribution point group and add the
        primary DP to it.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 9 (lines 1176-1194). 'All DPs'
        is the canonical homelab DP-group name (per
        reference_mecm_homelab_bible.md); content distribution targets
        this group instead of individual DPs.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER Name
        DP-group display name. Default 'All DPs'.

    .EXAMPLE
        New-CMDistributionPointGroup -ComputerName CM01 -DomainCredential $cred -SiteCode MCM
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidateLength(3,3)]
        [string]$SiteCode,

        [Parameter()]
        [string]$Name = 'All DPs'
    )

    Write-LabLog "[$ComputerName] Configuring DP group '$Name'" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Configure DP group $Name" -ScriptBlock {
            param($SiteCode, $Name)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $g = Get-CMDistributionPointGroup -Name $Name -ErrorAction SilentlyContinue
            if (-not $g) {
                $g = New-CMDistributionPointGroup -Name $Name -ErrorAction Stop
                $action = 'Created'
            } else {
                $action = 'AlreadyExists'
            }

            $dpAdded = $false
            $dp = Get-CMDistributionPoint -SiteCode $SiteCode -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($dp) {
                try {
                    Add-CMDistributionPointToGroup `
                        -DistributionPointGroupName $Name `
                        -DistributionPointName ($dp.NetworkOSPath.TrimStart('\\')) `
                        -ErrorAction Stop
                    $dpAdded = $true
                } catch {
                    # already-attached throws -- treat as no-op
                    $dpAdded = $false
                }
            }

            return [pscustomobject]@{
                GroupName = $Name
                Action    = $action
                DPAdded   = $dpAdded
                DPName    = if ($dp) { $dp.NetworkOSPath.TrimStart('\\') } else { $null }
            }
        } -ArgumentList $SiteCode, $Name

    Write-LabLog "[$ComputerName] DP group '$Name' $($result.Action); DP attached: $($result.DPAdded)" -Status OK
    return $result
}
