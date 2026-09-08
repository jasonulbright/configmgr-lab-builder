function Add-CMRoleServiceConnectionPoint {
    <#
    .SYNOPSIS
        Add the Service Connection Point role to a site system.

    .DESCRIPTION
        Calls Add-CMRoleSiteSystem first (idempotent prerequisite),
        then adds the SCP role via Add-CMServiceConnectionPoint.

        A hierarchy supports only one service connection point, and
        it must be installed at the top-tier site.

        Idempotent: short-circuits when Get-CMServiceConnectionPoint
        returns a matching entry on the target server.

        CM cmdlets run on the SITE SERVER; -ComputerName is the
        site server.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER ScpServerFqdn
        FQDN of the server that will host the SCP role.

    .PARAMETER Mode
        Online or Offline. Default Online.

    .EXAMPLE
        Add-CMRoleServiceConnectionPoint -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -ScpServerFqdn 'CM01.contoso.com'
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
        [string]$ScpServerFqdn,

        [Parameter()]
        [ValidateSet('Online','Offline')]
        [string]$Mode = 'Online'
    )

    # Prerequisite: site system. Idempotent.
    Add-CMRoleSiteSystem -ComputerName $ComputerName -DomainCredential $DomainCredential `
        -SiteCode $SiteCode -SiteSystemServerFqdn $ScpServerFqdn | Out-Null

    Write-LabLog "[$ComputerName] Adding SCP role to $ScpServerFqdn" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Add SCP role on $ScpServerFqdn" -ScriptBlock {
            param($SiteCode, $Fqdn, $Mode)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMServiceConnectionPoint -SiteSystemServerName $Fqdn -SiteCode $SiteCode -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; ServerFqdn = $Fqdn }
            }

            $params = @{
                SiteCode             = $SiteCode
                SiteSystemServerName = $Fqdn
                Mode                 = $Mode
                ErrorAction          = 'Stop'
            }

            Add-CMServiceConnectionPoint @params | Out-Null
            return [pscustomobject]@{ Status = 'Created'; ServerFqdn = $Fqdn }
        } -ArgumentList $SiteCode, $ScpServerFqdn, $Mode

    Write-LabLog "[$ComputerName] SCP $ScpServerFqdn $($result.Status)" -Status OK
    return $result
}
