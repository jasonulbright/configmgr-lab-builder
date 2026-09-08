function Add-CMRoleReportingServicePoint {
    <#
    .SYNOPSIS
        Add the Reporting Services Point role to a site system.

    .DESCRIPTION
        Calls Add-CMRoleSiteSystem first (idempotent prerequisite), then
        registers -UserName as a CM Account (idempotent -- Add-CMReportingServicePoint
        rejects any -UserName that isn't already a registered CM Account,
        confirmed live: "User account '...' was not found at site '...'"),
        then adds the RSP role via Add-CMReportingServicePoint.

        Requires SQL Server Reporting Services already installed and
        configured (report server initialized) on the target server --
        see Install-LabSsrs / Set-LabSsrsConfiguration. This function
        only creates the CM-side role pointing at that report server;
        it does not touch SSRS itself.

        Idempotent: short-circuits when Get-CMReportingServicePoint
        returns a matching entry on the target server.

        CM cmdlets run on the SITE SERVER; -ComputerName is the
        site server.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER RspServerFqdn
        FQDN of the server that will host the RSP role.

    .PARAMETER UserName
        Reporting services point account, domain\sam format. This
        account connects Reporting Services to the site database; CM
        grants it site-database read rights automatically. Registered
        as a CM Account (New-CMAccount) if not already present.

    .PARAMETER Password
        Password for -UserName. Only used to register the CM Account
        when it doesn't already exist; never logged.

    .PARAMETER DatabaseServerName
        FQDN of the server hosting the CM site database.

    .PARAMETER DatabaseName
        CM site database name. Default 'CM_<SiteCode>'.

    .PARAMETER ReportServerInstance
        SSRS instance name on the target server, as discovered by
        Set-LabSsrsConfiguration.

    .PARAMETER FolderName
        Report folder name created on the report server. Default
        'ConfigMgr Reports'.

    .EXAMPLE
        Add-CMRoleReportingServicePoint -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -RspServerFqdn 'CM01.contoso.com' `
            -UserName 'CONTOSO\svc-CMReporting' -Password $cfg.ServiceAccounts.Reporting.Password `
            -DatabaseServerName 'CM01.contoso.com' -ReportServerInstance 'SSRS'
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
        [string]$RspServerFqdn,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Password,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DatabaseServerName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ReportServerInstance,

        [Parameter()]
        [string]$DatabaseName = "CM_$SiteCode",

        [Parameter()]
        [string]$FolderName = 'ConfigMgr Reports'
    )

    # Prerequisite: site system. Idempotent.
    Add-CMRoleSiteSystem -ComputerName $ComputerName -DomainCredential $DomainCredential `
        -SiteCode $SiteCode -SiteSystemServerFqdn $RspServerFqdn | Out-Null

    Write-LabLog "[$ComputerName] Adding RSP role to $RspServerFqdn" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Add RSP role on $RspServerFqdn" -ScriptBlock {
            param($SiteCode, $Fqdn, $UserName, $AcctPassword, $DbServer, $DbName, $RsInstance, $Folder)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMReportingServicePoint -SiteSystemServerName $Fqdn -SiteCode $SiteCode -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; ServerFqdn = $Fqdn }
            }

            if (-not (Get-CMAccount -UserName $UserName -SiteCode $SiteCode -ErrorAction SilentlyContinue)) {
                $secure = ConvertTo-SecureString -String $AcctPassword -AsPlainText -Force
                New-CMAccount -UserName $UserName -Password $secure -SiteCode $SiteCode -ErrorAction Stop | Out-Null
            }

            $params = @{
                SiteCode             = $SiteCode
                SiteSystemServerName = $Fqdn
                UserName             = $UserName
                DatabaseServerName   = $DbServer
                DatabaseName         = $DbName
                ReportServerInstance = $RsInstance
                FolderName           = $Folder
                ErrorAction          = 'Stop'
            }

            Add-CMReportingServicePoint @params | Out-Null
            return [pscustomobject]@{ Status = 'Created'; ServerFqdn = $Fqdn }
        } -ArgumentList $SiteCode, $RspServerFqdn, $UserName, $Password, $DatabaseServerName, $DatabaseName, $ReportServerInstance, $FolderName

    Write-LabLog "[$ComputerName] RSP $RspServerFqdn $($result.Status)" -Status OK
    return $result
}
