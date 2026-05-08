function New-CMBoundaryGroup {
    <#
    .SYNOPSIS
        Idempotently create a CM boundary group, add a boundary to it,
        and attach the site system server.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 9 (lines 1146-1173). Three
        independently-idempotent actions:

          1. Get-or-create the boundary group with the given Name
          2. Add-CMBoundaryToGroup (no-op if already present)
          3. Set-CMBoundaryGroup -AddSiteSystemServerName <CM01.contoso.com>
             so clients in this boundary find this MP/DP

        BoundaryId is required; pair with New-CMBoundary upstream.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER Name
        Boundary-group display name.

    .PARAMETER BoundaryId
        BoundaryID returned from New-CMBoundary.

    .PARAMETER SiteSystemServerFqdn
        FQDN of the MP/DP server (e.g. CM01.contoso.com).

    .EXAMPLE
        $b = New-CMBoundary -... -Subnet '192.168.50.0/24'
        New-CMBoundaryGroup -... -Name 'HomeLab Boundary Group' `
            -BoundaryId $b.BoundaryId -SiteSystemServerFqdn 'CM01.contoso.com'
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

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$BoundaryId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteSystemServerFqdn
    )

    Write-LabLog "[$ComputerName] Configuring boundary group '$Name'" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Configure BG $Name" -ScriptBlock {
            param($SiteCode, $Name, $BoundaryId, $SiteSystemFqdn)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $bg = Get-CMBoundaryGroup -Name $Name -ErrorAction SilentlyContinue
            if (-not $bg) {
                $bg = New-CMBoundaryGroup -Name $Name -ErrorAction Stop
                $bgAction = 'Created'
            } else {
                $bgAction = 'AlreadyExists'
            }

            $boundaryAdded = $true
            try {
                Add-CMBoundaryToGroup -BoundaryId $BoundaryId -BoundaryGroupId $bg.GroupID -ErrorAction Stop
            } catch {
                # CM throws on already-attached; treat as no-op.
                $boundaryAdded = $false
            }

            $siteSystemAdded = $true
            try {
                Set-CMBoundaryGroup -Id $bg.GroupID -AddSiteSystemServerName $SiteSystemFqdn -ErrorAction Stop
            } catch {
                $siteSystemAdded = $false
            }

            return [pscustomobject]@{
                GroupId          = $bg.GroupID
                Name             = $Name
                Action           = $bgAction
                BoundaryAdded    = $boundaryAdded
                SiteSystemAdded  = $siteSystemAdded
            }
        } -ArgumentList $SiteCode, $Name, $BoundaryId, $SiteSystemServerFqdn

    Write-LabLog "[$ComputerName] BG '$Name' $($result.Action) (id $($result.GroupId))" -Status OK
    return $result
}
