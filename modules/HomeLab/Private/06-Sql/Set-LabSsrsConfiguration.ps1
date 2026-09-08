function Set-LabSsrsConfiguration {
    <#
    .SYNOPSIS
        Configure a previously-installed SSRS report server: create its
        catalog database, wire the connection, set the service account,
        reserve the web service and web portal URLs, and initialize it.

    .DESCRIPTION
        Equivalent of running Report Server Configuration Manager by hand
        after Install-LabSsrs has put the binaries down. There is no
        command-line tool for this in current Microsoft docs; it is done
        through the Reporting Services WMI provider
        (MSReportServer_ConfigurationSetting).

        Two separate databases are involved. This function only ever
        touches #1:
          1. The SSRS catalog database (ReportServer + ReportServerTempDB,
             or whatever -DatabaseName resolves to) -- created and wired up
             here.
          2. The ConfigMgr site database (CM_<SiteCode>) -- untouched by
             this function. A separate Add-CMReportingServicePoint wrapper
             points the RSP role at the report server this function
             produces; it does not create or reference the SSRS catalog DB.

        Steps:
          1. Discover the report server instance's WMI namespace
             (root\Microsoft\SqlServer\ReportServer\RS_<Instance>\v<N>\Admin)
             by enumerating __NAMESPACE children -- the instance name and
             provider version are never hardcoded, since a fresh install's
             defaults are not guaranteed
          2. Read IsInitialized off MSReportServer_ConfigurationSetting; if
             already true, short-circuit (idempotent)
          3. GenerateDatabaseCreationScript for the catalog DB, run it
             (Invoke-Sqlcmd if present in the remote session, else raw
             ADO.NET against a Windows-trusted connection -- the caller's
             -DomainCredential is expected to already be a SQL sysadmin,
             the same assumption Install-LabSqlServer.ps1 documents for its
             -SqlSysAdminAccounts)
          4. GenerateDatabaseRightsScript for -ServiceAccountCredential on
             that DB, run it the same way
          5. SetDatabaseConnection to point the report server at the new DB
             using Windows credentials (-ServiceAccountCredential)
          6. SetWindowsServiceIdentity so the SQLServerReportingServices
             service runs as -ServiceAccountCredential
          7. SetVirtualDirectory + ReserveURL for both the web service and
             web portal applications at http://+:80 (SetVirtualDirectory
             must run first -- ReserveURL does not resolve to a browsable
             path otherwise)
          8. Restart the service. Required here, before initializing --
             SetWindowsServiceIdentity (step 6) does not take effect for
             the already-running process until restarted, and calling
             InitializeReportServer beforehand fails with
             rsServerConfigurationError even though every prior step
             reported success (confirmed live)
          9. Re-check IsInitialized (the restart alone often flips it);
             call InitializeReportServer only if still needed, then
             report final state

    .PARAMETER ComputerName
        DNS / short name of the target VM.

    .PARAMETER DomainCredential
        Domain admin credential for the inside-VM execution. Must already
        be a SQL sysadmin on the target instance (e.g. the lab Admin
        credential) -- this function creates the catalog database with it
        and does not add any new SQL login.

    .PARAMETER ServiceAccountCredential
        Credential for the SSRS service account (e.g. svc-CMReporting).
        Resolve this at the call site, not here.

    .PARAMETER DatabaseName
        SSRS catalog database name. Default 'ReportServer'.

    .PARAMETER SqlServerInstance
        SQL Server instance hosting the catalog database. Default
        'localhost' -- this lab's default topology co-locates SSRS and SQL
        on the same VM.

    .EXAMPLE
        $svc = Get-LabCredential -Identity Reporting
        Set-LabSsrsConfiguration -ComputerName CM01 -DomainCredential $cred `
            -ServiceAccountCredential $svc
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
        [System.Management.Automation.PSCredential]$ServiceAccountCredential,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$DatabaseName = 'ReportServer',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SqlServerInstance = 'localhost'
    )

    # Discovery + idempotency check in one round trip. CIM calls below run
    # locally on the target VM (no -ComputerName/-Credential) because this
    # scriptblock already executes inside the authenticated WinRM session --
    # a second CIM hop from this workstation would hit the same
    # non-domain-joined Kerberos double-hop failure Invoke-LabCommand exists
    # to avoid.
    $discovery = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Discover SSRS report server state' -ScriptBlock {
            $rsNamespaces = Get-CimInstance -Namespace 'root\Microsoft\SqlServer\ReportServer' -ClassName __NAMESPACE -ErrorAction Stop |
                Where-Object { $_.Name -like 'RS_*' }
            if (-not $rsNamespaces) {
                throw 'Set-LabSsrsConfiguration: no RS_* namespace under root\Microsoft\SqlServer\ReportServer -- run Install-LabSsrs first'
            }
            $rsBase = "root\Microsoft\SqlServer\ReportServer\$(($rsNamespaces | Select-Object -First 1).Name)"

            $versionNamespaces = Get-CimInstance -Namespace $rsBase -ClassName __NAMESPACE -ErrorAction Stop |
                Where-Object { $_.Name -like 'v*' } | Sort-Object Name -Descending
            if (-not $versionNamespaces) {
                throw "Set-LabSsrsConfiguration: no version namespace under $rsBase"
            }
            $adminNamespace = "$rsBase\$(($versionNamespaces | Select-Object -First 1).Name)\Admin"

            $cs = Get-CimInstance -Namespace $adminNamespace -ClassName MSReportServer_ConfigurationSetting -ErrorAction Stop |
                Select-Object -First 1
            if (-not $cs) {
                throw "Set-LabSsrsConfiguration: no MSReportServer_ConfigurationSetting instance in $adminNamespace"
            }

            [pscustomobject]@{
                AdminNamespace = $adminNamespace
                IsInitialized  = [bool]$cs.IsInitialized
                InstanceName   = [string]$cs.InstanceName
                DatabaseName   = [string]$cs.DatabaseName
                WebServiceVDir = [string]$cs.VirtualDirectoryReportServer
                PortalVDir     = [string]$cs.VirtualDirectoryReportManager
            }
        }

    if ($discovery.IsInitialized) {
        Write-LabLog "[$ComputerName] SSRS report server already initialized (instance $($discovery.InstanceName))" -Status SKIP
        $webVDir = if ($discovery.WebServiceVDir) { $discovery.WebServiceVDir } else { 'ReportServer' }
        $portalVDir = if ($discovery.PortalVDir) { $discovery.PortalVDir } else { 'Reports' }
        return [pscustomobject]@{
            Status                   = 'AlreadyConfigured'
            ReportServerInstanceName = $discovery.InstanceName
            DatabaseName             = $discovery.DatabaseName
            WebServiceUrl            = "http://$ComputerName/$webVDir"
            PortalUrl                = "http://$ComputerName/$portalVDir"
        }
    }

    Write-LabLog "[$ComputerName] Configuring SSRS report server (DB=$DatabaseName on $SqlServerInstance)" -Status RUN

    $configured = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Create catalog DB, wire connection, reserve URLs, initialize' -ScriptBlock {
            param($AdminNamespace, $DatabaseName, $SqlServerInstance, [System.Management.Automation.PSCredential]$ServiceAccountCredential, $Lcid)

            $svcUserName = $ServiceAccountCredential.UserName
            $svcPassword = $ServiceAccountCredential.GetNetworkCredential().Password

            $cs = Get-CimInstance -Namespace $AdminNamespace -ClassName MSReportServer_ConfigurationSetting -ErrorAction Stop |
                Select-Object -First 1
            if (-not $cs) {
                throw "Set-LabSsrsConfiguration: no MSReportServer_ConfigurationSetting instance found in $AdminNamespace"
            }

            # CIM surfaces each WMI [out] parameter as a property on the
            # result plus its own ReturnValue. The RS WMI provider's
            # documented success signal is the named HRESULT/out param, not
            # ReturnValue, but a nonzero ReturnValue is treated as failure
            # too since an out param can be unpopulated when the call never
            # really ran.
            function Test-RsResult {
                param($Result, [string]$MethodName)
                # The RS WMI provider's documented success signal is each
                # method's own HRESULT/out-param, not CIM's generic
                # ReturnValue -- and ReturnValue's TYPE varies per method
                # (int for some, bool for others: GenerateDatabaseCreationScript
                # returns bool True on success, and comparing that to 0 with
                # -ne coerces 0 to $false and misreads success as failure).
                # When HRESULT is present,
                # it alone is authoritative. Only fall back to ReturnValue
                # when a method has no HRESULT out-param at all.
                $hasHresult = $Result.PSObject.Properties['HRESULT']
                $failed = $false
                if ($hasHresult) {
                    $failed = ($Result.HRESULT -ne 0)
                } elseif ($Result.ReturnValue -is [bool]) {
                    $failed = (-not $Result.ReturnValue)
                } else {
                    $failed = ($Result.ReturnValue -ne 0)
                }
                if ($failed) {
                    $hresult = if ($hasHresult) { $Result.HRESULT } else { $null }
                    $extra = ''
                    if ($Result.PSObject.Properties['Error'] -and $Result.Error) { $extra = " Error: $($Result.Error)" }
                    elseif ($Result.PSObject.Properties['ExtendedErrors'] -and $Result.ExtendedErrors) { $extra = " ExtendedErrors: $($Result.ExtendedErrors -join '; ')" }
                    throw "Set-LabSsrsConfiguration: $MethodName failed (ReturnValue=$($Result.ReturnValue), HRESULT=$hresult).$extra"
                }
            }

            function Invoke-RsDbScript {
                param([string]$Script, [string]$SqlServerInstance)
                if (Get-Command -Name Invoke-Sqlcmd -ErrorAction SilentlyContinue) {
                    Invoke-Sqlcmd -ServerInstance $SqlServerInstance -Database 'master' -Query $Script -QueryTimeout 120 -ErrorAction Stop
                    return
                }
                # No Invoke-Sqlcmd in this session: fall back to ADO.NET. GO
                # is a batch separator recognized by sqlcmd/SSMS, not valid
                # T-SQL, so SqlCommand needs the script pre-split on it.
                $batches = $Script -split '(?im)^\s*GO\s*$' | Where-Object { $_.Trim() }
                $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$SqlServerInstance;Database=master;Integrated Security=True;Connection Timeout=30")
                try {
                    $conn.Open()
                    foreach ($batch in $batches) {
                        $cmd = $conn.CreateCommand()
                        $cmd.CommandTimeout = 120
                        $cmd.CommandText = $batch
                        $null = $cmd.ExecuteNonQuery()
                    }
                } finally {
                    $conn.Close()
                }
            }

            function Test-RsDatabaseExists {
                param([string]$DatabaseName, [string]$SqlServerInstance)
                if (Get-Command -Name Invoke-Sqlcmd -ErrorAction SilentlyContinue) {
                    $row = Invoke-Sqlcmd -ServerInstance $SqlServerInstance -Database 'master' `
                        -Query "SELECT 1 AS Present FROM sys.databases WHERE name = '$DatabaseName'" -QueryTimeout 30 -ErrorAction Stop
                    return [bool]$row
                }
                $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$SqlServerInstance;Database=master;Integrated Security=True;Connection Timeout=30")
                try {
                    $conn.Open()
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM sys.databases WHERE name = '$DatabaseName'"
                    return ([int]$cmd.ExecuteScalar() -gt 0)
                } finally {
                    $conn.Close()
                }
            }

            # 1. Catalog database creation script -- skipped only when BOTH
            # the catalog DB and its companion TempDB already exist (e.g.
            # resuming after an earlier partial failure downstream of
            # creation). GenerateDatabaseCreationScript creates both as one
            # script and SSRS does not recreate a missing TempDB on its
            # own, so checking only the primary database would leave a
            # half-created pair undetected.
            #
            # GenerateDatabaseCreationScript does not check for an existing
            # database before generating its CREATE DATABASE script, so
            # there is no confirmed-safe way to re-run it against a
            # database that already exists. A mismatched pair
            # (exactly one of the two present) means a prior run failed
            # mid-script in a state this function cannot safely resolve
            # automatically -- re-running could error on the CREATE
            # DATABASE for the half that already exists, or silently do
            # nothing useful. Fail clearly and point at manual cleanup
            # instead of guessing.
            $tempDbName = "${DatabaseName}TempDB"
            $catalogExists = Test-RsDatabaseExists -DatabaseName $DatabaseName -SqlServerInstance $SqlServerInstance
            $tempDbExists = Test-RsDatabaseExists -DatabaseName $tempDbName -SqlServerInstance $SqlServerInstance
            if ($catalogExists -and $tempDbExists) {
                Write-Verbose "Set-LabSsrsConfiguration: '$DatabaseName' and '$tempDbName' already exist, skipping creation"
            } elseif ($catalogExists -or $tempDbExists) {
                $present = if ($catalogExists) { $DatabaseName } else { $tempDbName }
                $missing = if ($catalogExists) { $tempDbName } else { $DatabaseName }
                throw "Set-LabSsrsConfiguration: '$present' exists but '$missing' does not -- SSRS catalog database pair is in an inconsistent state (likely a prior run failed mid-script). Not safe to auto-repair; drop '$present' manually on $SqlServerInstance and re-run, or restore both from backup."
            } else {
                $dbScript = Invoke-CimMethod -InputObject $cs -MethodName GenerateDatabaseCreationScript -Arguments @{
                    DatabaseName     = $DatabaseName
                    Lcid             = $Lcid
                    IsSharePointMode = $false
                } -ErrorAction Stop
                Test-RsResult -Result $dbScript -MethodName 'GenerateDatabaseCreationScript'
                Invoke-RsDbScript -Script $dbScript.Script -SqlServerInstance $SqlServerInstance
            }

            # 2. Grant the service account rights on the new catalog DB
            # (+ tempdb/msdb, per GenerateDatabaseRightsScript's own docs).
            $isRemoteDb = $SqlServerInstance -notin @('localhost', '.', '(local)', $env:COMPUTERNAME)
            $rightsScript = Invoke-CimMethod -InputObject $cs -MethodName GenerateDatabaseRightsScript -Arguments @{
                UserName      = $svcUserName
                DatabaseName  = $DatabaseName
                IsRemote      = $isRemoteDb
                IsWindowsUser = $true
            } -ErrorAction Stop
            Test-RsResult -Result $rightsScript -MethodName 'GenerateDatabaseRightsScript'
            Invoke-RsDbScript -Script $rightsScript.Script -SqlServerInstance $SqlServerInstance

            # 3. Point the report server at the new DB as the service
            # account. CredentialsType: 0 = Windows, 1 = SQL Server,
            # 2 = Windows Service -- undocumented in the type itself.
            $connResult = Invoke-CimMethod -InputObject $cs -MethodName SetDatabaseConnection -Arguments @{
                Server          = $SqlServerInstance
                DatabaseName    = $DatabaseName
                CredentialsType = 0
                UserName        = $svcUserName
                Password        = $svcPassword
            } -ErrorAction Stop
            Test-RsResult -Result $connResult -MethodName 'SetDatabaseConnection'

            # 4. Run the Windows service as the same account.
            $idResult = Invoke-CimMethod -InputObject $cs -MethodName SetWindowsServiceIdentity -Arguments @{
                UseBuiltInAccount = $false
                Account           = $svcUserName
                Password          = $svcPassword
            } -ErrorAction Stop
            Test-RsResult -Result $idResult -MethodName 'SetWindowsServiceIdentity'

            # 5. Virtual directories, then URL reservations. ReserveURL
            # needs VirtualDirectory already set for the application or the
            # reservation does not resolve to a browsable path.
            $webServiceVDir = 'ReportServer'
            $portalVDir = 'Reports'

            $vd1 = Invoke-CimMethod -InputObject $cs -MethodName SetVirtualDirectory -Arguments @{
                Application = 'ReportServerWebService'; VirtualDirectory = $webServiceVDir; Lcid = $Lcid
            } -ErrorAction Stop
            Test-RsResult -Result $vd1 -MethodName 'SetVirtualDirectory(ReportServerWebService)'

            $vd2 = Invoke-CimMethod -InputObject $cs -MethodName SetVirtualDirectory -Arguments @{
                Application = 'ReportServerWebApp'; VirtualDirectory = $portalVDir; Lcid = $Lcid
            } -ErrorAction Stop
            Test-RsResult -Result $vd2 -MethodName 'SetVirtualDirectory(ReportServerWebApp)'

            $url1 = Invoke-CimMethod -InputObject $cs -MethodName ReserveURL -Arguments @{
                Application = 'ReportServerWebService'; UrlString = 'http://+:80'; Lcid = $Lcid
            } -ErrorAction Stop
            Test-RsResult -Result $url1 -MethodName 'ReserveURL(ReportServerWebService)'

            $url2 = Invoke-CimMethod -InputObject $cs -MethodName ReserveURL -Arguments @{
                Application = 'ReportServerWebApp'; UrlString = 'http://+:80'; Lcid = $Lcid
            } -ErrorAction Stop
            Test-RsResult -Result $url2 -MethodName 'ReserveURL(ReportServerWebApp)'

            # 6. Restart BEFORE initializing. SetWindowsServiceIdentity only
            # takes effect for the currently-running process after a
            # restart -- confirmed live: calling InitializeReportServer
            # before this restart fails with rsServerConfigurationError
            # (HRESULT=-2146233088) even though the DB connection and
            # service identity were both already set successfully. The
            # restart alone is often enough for IsInitialized to flip true;
            # InitializeReportServer below is called anyway for certainty.
            Restart-Service -Name 'SQLServerReportingServices' -Force -ErrorAction Stop
            Start-Sleep -Seconds 8

            # 7. Initialize. Re-fetch the instance first -- InstallationID
            # is only meaningful once a database connection exists, and the
            # restart invalidates the earlier CIM instance reference.
            $cs = Get-CimInstance -Namespace $AdminNamespace -ClassName MSReportServer_ConfigurationSetting -ErrorAction Stop |
                Select-Object -First 1
            if (-not $cs.IsInitialized) {
                $initResult = Invoke-CimMethod -InputObject $cs -MethodName InitializeReportServer -Arguments @{
                    InstallationID = $cs.InstallationID
                } -ErrorAction Stop
                Test-RsResult -Result $initResult -MethodName 'InitializeReportServer'
            }

            $final = Get-CimInstance -Namespace $AdminNamespace -ClassName MSReportServer_ConfigurationSetting -ErrorAction Stop |
                Select-Object -First 1

            [pscustomobject]@{
                IsInitialized  = [bool]$final.IsInitialized
                InstanceName   = [string]$final.InstanceName
                DatabaseName   = [string]$final.DatabaseName
                WebServiceVDir = $webServiceVDir
                PortalVDir     = $portalVDir
            }
        } -ArgumentList $discovery.AdminNamespace, $DatabaseName, $SqlServerInstance, $ServiceAccountCredential, 1033

    if (-not $configured.IsInitialized) {
        throw "Set-LabSsrsConfiguration: report server on $ComputerName did not reach IsInitialized=true after configuration"
    }

    Write-LabLog "[$ComputerName] SSRS report server configured and initialized (instance $($configured.InstanceName))" -Status OK

    return [pscustomobject]@{
        Status                   = 'Configured'
        ReportServerInstanceName = $configured.InstanceName
        DatabaseName             = $configured.DatabaseName
        WebServiceUrl            = "http://$ComputerName/$($configured.WebServiceVDir)"
        PortalUrl                = "http://$ComputerName/$($configured.PortalVDir)"
    }
}
