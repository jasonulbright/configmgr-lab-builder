function New-LabSqlConfigIni {
    <#
    .SYNOPSIS
        Generate the ConfigurationFile.ini that drives unattended SQL
        Server 2022 setup.

    .DESCRIPTION
        Builds the INI passed to setup.exe via /CONFIGURATIONFILE=. The
        homelab needs a tightly-scoped CM-friendly install:
          - SQLENGINE feature only (no SSAS, IS, RS -- CM doesn't need
            them for the homelab path; Reporting Services is optional
            and adds Server 2025 / SSRS-on-Server-Core compatibility risk)
          - Default instance MSSQLSERVER on TCP 1433
          - Mixed-mode authentication, sa password set
          - Collation SQL_Latin1_General_CP1_CI_AS (the only collation
            CM 2509 supports for the site database)
          - SQLSYSADMINACCOUNTS pre-populated with the domain Admins
            group AND the CM site server's computer account, so CM
            setup can create CM_<SiteCode> at install time without an
            extra ALTER SERVER ROLE step
          - UPDATEENABLED=False (offline, no PSGallery / WU lookups)
          - IACCEPTSQLSERVERLICENSETERMS=True (eval terms accepted)

        Returns the full path of the written INI file. Output is ASCII
        (setup.exe rejects UTF-8 with BOM; ASCII is the documented
        encoding).

        Built atop Write-LabIni so the byte-deterministic test from
        Tests/Unit/Ini.Tests.ps1 covers the formatting plumbing.

    .PARAMETER InstanceName
        SQL instance name. Default 'MSSQLSERVER' (the default instance).

    .PARAMETER SaPassword
        Password for the 'sa' login.

    .PARAMETER SqlSysAdminAccounts
        Array of principals added to the sysadmin role at install time.
        Lab default: BUILTIN\Administrators + CONTOSO\Domain Admins +
        CONTOSO\CM01$. Supply explicitly so the domain prefix is right.

    .PARAMETER Collation
        Default 'SQL_Latin1_General_CP1_CI_AS' (CM 2509 requirement).

    .PARAMETER InstallSqlDataDir
        Default C:\Program Files\Microsoft SQL Server\.

    .PARAMETER SqlUserDbDir
        User database default folder. Default 'D:\SQLData' to keep CM
        DB off C:\.

    .PARAMETER SqlUserDbLogDir
        User log default folder. Default 'E:\SQLLogs'.

    .PARAMETER SqlTempDbDir
        TempDB folder. Default 'D:\SQLTempDb'.

    .PARAMETER SqlBackupDir
        Backup folder. Default 'D:\SQLBackup'.

    .PARAMETER OutputPath
        Path for the INI file. Default
        '$env:TEMP\HomeLab-SqlConfigurationFile.ini'.

    .PARAMETER SqlSvcAccount
        Service account for the SQL Engine service. Default
        'NT Service\MSSQLSERVER' (built-in virtual account).

    .EXAMPLE
        New-LabSqlConfigIni `
            -SaPassword 'P@ssw0rd!' `
            -SqlSysAdminAccounts @('BUILTIN\Administrators', 'CONTOSO\Domain Admins', 'CONTOSO\CM01$') `
            -OutputPath C:\Temp\sql-config.ini
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName = 'MSSQLSERVER',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SaPassword,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SqlSysAdminAccounts,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Collation = 'SQL_Latin1_General_CP1_CI_AS',

        [Parameter()]
        [string]$InstallSqlDataDir = 'C:\Program Files\Microsoft SQL Server',

        [Parameter()]
        [string]$SqlUserDbDir = 'C:\SQLData',

        [Parameter()]
        [string]$SqlUserDbLogDir = 'C:\SQLLogs',

        [Parameter()]
        [string]$SqlTempDbDir = 'C:\SQLTempDb',

        [Parameter()]
        [string]$SqlBackupDir = 'C:\SQLBackup',

        [Parameter()]
        [string]$SqlSvcAccount = 'NT AUTHORITY\NetworkService',

        [Parameter()]
        [string]$OutputPath
    )

    if (-not $OutputPath) {
        $OutputPath = Join-Path $env:TEMP 'HomeLab-SqlConfigurationFile.ini'
    }

    # SQL setup.exe wants quoted paths. Wrap-with-quotes only at emit time.
    $accountsLine = ($SqlSysAdminAccounts | ForEach-Object { '"' + $_ + '"' }) -join ' '

    $cfg = [ordered]@{
        OPTIONS = [ordered]@{
            ACTION                          = 'Install'
            QUIET                           = 'True'
            UPDATEENABLED                   = 'False'
            ENU                             = 'True'
            HELP                            = 'False'
            INDICATEPROGRESS                = 'False'
            FEATURES                        = 'SQLENGINE'
            INSTANCENAME                    = $InstanceName
            INSTANCEID                      = $InstanceName
            INSTALLSHAREDDIR                = '"C:\Program Files\Microsoft SQL Server"'
            INSTALLSHAREDWOWDIR             = '"C:\Program Files (x86)\Microsoft SQL Server"'
            INSTANCEDIR                     = '"' + $InstallSqlDataDir + '"'
            AGTSVCSTARTUPTYPE               = 'Automatic'
            AGTSVCACCOUNT                   = '"NT AUTHORITY\NetworkService"'
            SQLSVCSTARTUPTYPE               = 'Automatic'
            FILESTREAMLEVEL                 = '0'
            ENABLERANU                      = 'False'
            SQLCOLLATION                    = $Collation
            SQLSVCACCOUNT                   = '"' + $SqlSvcAccount + '"'
            SQLSVCINSTANTFILEINIT           = 'True'
            SQLSYSADMINACCOUNTS             = $accountsLine
            SECURITYMODE                    = 'SQL'
            SAPWD                           = '"' + $SaPassword + '"'
            INSTALLSQLDATADIR               = '"' + $InstallSqlDataDir + '"'
            SQLUSERDBDIR                    = '"' + $SqlUserDbDir + '"'
            SQLUSERDBLOGDIR                 = '"' + $SqlUserDbLogDir + '"'
            SQLTEMPDBDIR                    = '"' + $SqlTempDbDir + '"'
            SQLTEMPDBLOGDIR                 = '"' + $SqlUserDbLogDir + '"'
            SQLBACKUPDIR                    = '"' + $SqlBackupDir + '"'
            ADDCURRENTUSERASSQLADMIN        = 'False'
            TCPENABLED                      = '1'
            NPENABLED                       = '0'
            BROWSERSVCSTARTUPTYPE           = 'Automatic'
            IACCEPTSQLSERVERLICENSETERMS    = 'True'
        }
    }

    Write-LabIni -Data $cfg -Path $OutputPath -Encoding ASCII
    return (Resolve-Path $OutputPath).Path
}
