function Add-CMRoleDistributionPoint {
    <#
    .SYNOPSIS
        Add the Distribution Point role to a site system.

    .DESCRIPTION
        Calls Add-CMRoleSiteSystem first (idempotent prerequisite),
        then adds the DP role via Add-CMDistributionPoint.

        For default 3-VM topology, the unattend INI already wires the
        site server as the implicit DP at install time, so this
        function is normally NOT called for the site server itself.
        It exists for distributed-role topologies (S15+) where DP
        lives on a different VM, or for multi-DP topologies (additional
        DPs serving regional content).

        Idempotent: short-circuits when Get-CMDistributionPoint returns
        a matching entry on the target server.

        CM cmdlets run on the SITE SERVER; -ComputerName is the
        site server.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER DpServerFqdn
        FQDN of the server that will host the DP role.

    .PARAMETER InstallInternetEnabledDp
        When $true, the DP advertises an internet-facing role.
        Default $false (homelab is internal-only).

    .PARAMETER MinimumFreeSpaceMB
        Minimum free space CM is allowed to leave on the DP content
        drive. Default 500 -- MECM's own product default for the DP
        role, so it is guaranteed accepted by Add-CMDistributionPoint
        on every supported build.

    .EXAMPLE
        Add-CMRoleDistributionPoint -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -DpServerFqdn 'DP01.contoso.com'
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
        [string]$DpServerFqdn,

        [Parameter()]
        [bool]$InstallInternetEnabledDp = $false,

        [Parameter()]
        # 100000 is the real Add-CMDistributionPoint maximum (verified
        # against CM 2509: "The 1048576 argument is greater than the
        # maximum allowed range of 100000"). Reject here, not 30 minutes
        # into a deploy on the remote side.
        [ValidateRange(0, 100000)]
        [int]$MinimumFreeSpaceMB = 500
    )

    # Prerequisite: site system. Idempotent.
    Add-CMRoleSiteSystem -ComputerName $ComputerName -DomainCredential $DomainCredential `
        -SiteCode $SiteCode -SiteSystemServerFqdn $DpServerFqdn | Out-Null

    Write-LabLog "[$ComputerName] Adding DP role to $DpServerFqdn" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Add DP role on $DpServerFqdn" -ScriptBlock {
            param($SiteCode, $Fqdn, $Internet, $MinFreeMB)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMDistributionPoint -SiteSystemServerName $Fqdn -SiteCode $SiteCode -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; ServerFqdn = $Fqdn }
            }

            $params = @{
                SiteCode                 = $SiteCode
                SiteSystemServerName     = $Fqdn
                MinimumFreeSpaceMB       = $MinFreeMB
                InstallInternetEnabledDistributionPoint = $Internet
                ErrorAction              = 'Stop'
            }

            Add-CMDistributionPoint @params | Out-Null
            return [pscustomobject]@{ Status = 'Created'; ServerFqdn = $Fqdn }
        } -ArgumentList $SiteCode, $DpServerFqdn, $InstallInternetEnabledDp, $MinimumFreeSpaceMB

    Write-LabLog "[$ComputerName] DP $DpServerFqdn $($result.Status)" -Status OK
    return $result
}
