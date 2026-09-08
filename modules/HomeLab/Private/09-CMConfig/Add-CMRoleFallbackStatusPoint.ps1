function Add-CMRoleFallbackStatusPoint {
    <#
    .SYNOPSIS
        Add the Fallback Status Point role to a site system.

    .DESCRIPTION
        Calls Add-CMRoleSiteSystem first (idempotent prerequisite),
        then adds the FSP role via Add-CMFallbackStatusPoint.

        Idempotent: short-circuits when Get-CMFallbackStatusPoint
        returns a matching entry on the target server.

        CM cmdlets run on the SITE SERVER; -ComputerName is the
        site server.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER FspServerFqdn
        FQDN of the server that will host the FSP role.

    .EXAMPLE
        Add-CMRoleFallbackStatusPoint -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -FspServerFqdn 'FSP01.contoso.com'
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
        [string]$FspServerFqdn
    )

    # Prerequisite: site system. Idempotent.
    Add-CMRoleSiteSystem -ComputerName $ComputerName -DomainCredential $DomainCredential `
        -SiteCode $SiteCode -SiteSystemServerFqdn $FspServerFqdn | Out-Null

    Write-LabLog "[$ComputerName] Adding FSP role to $FspServerFqdn" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Add FSP role on $FspServerFqdn" -ScriptBlock {
            param($SiteCode, $Fqdn)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMFallbackStatusPoint -SiteSystemServerName $Fqdn -SiteCode $SiteCode -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; ServerFqdn = $Fqdn }
            }

            $params = @{
                SiteCode             = $SiteCode
                SiteSystemServerName = $Fqdn
                ErrorAction          = 'Stop'
            }

            Add-CMFallbackStatusPoint @params | Out-Null
            return [pscustomobject]@{ Status = 'Created'; ServerFqdn = $Fqdn }
        } -ArgumentList $SiteCode, $FspServerFqdn

    Write-LabLog "[$ComputerName] FSP $FspServerFqdn $($result.Status)" -Status OK
    return $result
}
