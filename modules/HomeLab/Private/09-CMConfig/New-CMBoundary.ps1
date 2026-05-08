function New-CMBoundary {
    <#
    .SYNOPSIS
        Idempotently create an IP-subnet boundary in CM.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 9 (lines 1134-1143).

        Boundary type is fixed at IPSubnet for the homelab; CM also
        supports IPRange / ADSite / IPv6Prefix but the lab only uses
        the lab-internal subnet (192.168.50.0/24 by default).

        Returns the boundary id + display name regardless of whether
        the boundary was created or already existed.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER Subnet
        CIDR like '192.168.50.0/24'. Used both as the boundary value
        AND the display name.

    .EXAMPLE
        New-CMBoundary -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -Subnet '192.168.50.0/24'
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
        [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
        [string]$Subnet
    )

    Write-LabLog "[$ComputerName] Creating CM IPSubnet boundary $Subnet" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Create boundary $Subnet" -ScriptBlock {
            param($SiteCode, $Subnet)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $b = Get-CMBoundary -BoundaryName $Subnet -ErrorAction SilentlyContinue
            if (-not $b) {
                $b = New-CMBoundary -DisplayName $Subnet -Type IPSubnet -Value $Subnet -ErrorAction Stop
                $action = 'Created'
            } else {
                $action = 'AlreadyExists'
            }

            return [pscustomobject]@{
                BoundaryId   = $b.BoundaryID
                DisplayName  = $b.DisplayName
                Action       = $action
            }
        } -ArgumentList $SiteCode, $Subnet

    Write-LabLog "[$ComputerName] Boundary $Subnet $($result.Action) (id $($result.BoundaryId))" -Status OK
    return $result
}
