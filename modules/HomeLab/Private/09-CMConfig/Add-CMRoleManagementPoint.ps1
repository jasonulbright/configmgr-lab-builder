function Add-CMRoleManagementPoint {
    <#
    .SYNOPSIS
        Add the Management Point role to a site system.

    .DESCRIPTION
        Calls Add-CMRoleSiteSystem first (idempotent prerequisite),
        then adds the MP role via Add-CMManagementPoint.

        For default 3-VM topology, the unattend INI already wires the
        site server as the implicit MP at install time, so this
        function is normally NOT called for the site server itself.
        It exists for distributed-role topologies (S15+) where MP
        lives on a different VM, or for adding additional MPs in a
        multi-MP topology.

        Idempotent: short-circuits when Get-CMManagementPoint returns
        a matching entry on the target server.

        CM cmdlets run on the SITE SERVER; -ComputerName is the
        site server.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER MpServerFqdn
        FQDN of the server that will host the MP role.

    .PARAMETER UseHttps
        When $true, MP advertises HTTPS. Default $false (homelab
        defaults to HTTP for simplicity; PKI / HTTPS is out of scope
        for the baseline).

    .EXAMPLE
        Add-CMRoleManagementPoint -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -MpServerFqdn 'MP01.contoso.com'
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
        [string]$MpServerFqdn,

        [Parameter()]
        [bool]$UseHttps = $false
    )

    # Prerequisite: site system. Idempotent.
    Add-CMRoleSiteSystem -ComputerName $ComputerName -DomainCredential $DomainCredential `
        -SiteCode $SiteCode -SiteSystemServerFqdn $MpServerFqdn | Out-Null

    Write-LabLog "[$ComputerName] Adding MP role to $MpServerFqdn" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Add MP role on $MpServerFqdn" -ScriptBlock {
            param($SiteCode, $Fqdn, $UseHttps)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMManagementPoint -SiteSystemServerName $Fqdn -SiteCode $SiteCode -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; ServerFqdn = $Fqdn }
            }

            $params = @{
                SiteCode             = $SiteCode
                SiteSystemServerName = $Fqdn
                ErrorAction          = 'Stop'
            }
            if ($UseHttps) {
                $params['CommunicationType'] = 'Https'
            } else {
                $params['CommunicationType'] = 'Http'
            }

            Add-CMManagementPoint @params | Out-Null
            return [pscustomobject]@{ Status = 'Created'; ServerFqdn = $Fqdn }
        } -ArgumentList $SiteCode, $MpServerFqdn, $UseHttps

    Write-LabLog "[$ComputerName] MP $MpServerFqdn $($result.Status)" -Status OK
    return $result
}
