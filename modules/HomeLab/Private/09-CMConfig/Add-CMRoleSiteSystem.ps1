function Add-CMRoleSiteSystem {
    <#
    .SYNOPSIS
        Add a server to the CM site as a site system.

    .DESCRIPTION
        A site system is a server that can host one or more CM site
        roles (MP, DP, SUP, SMP, FSP, etc.). Adding a server as a
        site system is the prerequisite for assigning any role to it.

        For the default 3-VM topology where every CM role lives on
        the site server, this function is a no-op (the site server
        is implicitly its own site system after Install-CMSite). The
        helper exists for distributed-role topologies (S15+) where
        MP / DP / SUP land on separate VMs.

        Idempotent: short-circuits when Get-CMSiteSystemServer
        returns a matching entry.

        The CM cmdlets must run against the SITE SERVER (not the
        target site system VM); they reach the site database via
        the CM provider on the site server. -ComputerName is the
        site server.

    .PARAMETER ComputerName
        DNS / short name of the CM site server (where the CM provider
        runs and the cmdlets execute).

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER SiteSystemServerFqdn
        FQDN of the server to add as a site system. Must be
        domain-joined and reachable from the site server.

    .PARAMETER AccountName
        Optional account to use for the site system (e.g.
        contoso\svc-CMSiteSystem). Default: site server's computer
        account (uses the local-system context).

    .EXAMPLE
        Add-CMRoleSiteSystem -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -SiteSystemServerFqdn 'DP01.contoso.com'
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
        [string]$SiteSystemServerFqdn,

        [Parameter()]
        [string]$AccountName
    )

    Write-LabLog "[$ComputerName] Adding site system $SiteSystemServerFqdn (site $SiteCode)" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Add site system $SiteSystemServerFqdn" -ScriptBlock {
            param($SiteCode, $Fqdn, $Account)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMSiteSystemServer -SiteSystemServerName $Fqdn -SiteCode $SiteCode -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; ServerFqdn = $Fqdn }
            }

            $params = @{
                SiteSystemServerName = $Fqdn
                SiteCode             = $SiteCode
                ErrorAction          = 'Stop'
            }
            if ($Account) { $params['AccountName'] = $Account }

            New-CMSiteSystemServer @params | Out-Null
            return [pscustomobject]@{ Status = 'Created'; ServerFqdn = $Fqdn }
        } -ArgumentList $SiteCode, $SiteSystemServerFqdn, $AccountName

    Write-LabLog "[$ComputerName] Site system $SiteSystemServerFqdn $($result.Status)" -Status OK
    return $result
}
