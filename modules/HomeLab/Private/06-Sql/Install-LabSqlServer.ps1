function Install-LabSqlServer {
    <#
    .SYNOPSIS
        Run unattended SQL Server 2022 setup on a domain-joined VM.

    .DESCRIPTION
        Steps:
          1. Generate ConfigurationFile.ini on the host
             (New-LabSqlConfigIni)
          2. Copy-LabFile the INI into the VM at C:\Install\sql-config.ini
          3. Add-VMDvdDrive on the host to attach the SQL 2022 ISO to
             the VM as a virtual DVD (zero-copy ISO mount)
          4. Inside the VM: identify the new DVD drive letter, invoke
             setup.exe /CONFIGURATIONFILE=C:\Install\sql-config.ini
             /IACCEPTSQLSERVERLICENSETERMS=True (also passed via INI but
             setup.exe wants it on the cmdline too in some builds)
          5. Wait for setup completion. Exit code 0 = success;
             3010 = success-reboot-required (also success).
          6. Tail the latest Setup Bootstrap\Log\<timestamp>\Summary.txt
             for diagnostics on failure
          7. Remove-VMDvdDrive

        Idempotent: queries the VM for the SQL service before doing
        anything; if MSSQL$<InstanceName> (or MSSQLSERVER for default
        instance) is Running, returns 'AlreadyInstalled' immediately.

        Requires elevation on the host (Add-VMDvdDrive).

    .PARAMETER ComputerName
        DNS / short name of the target VM.

    .PARAMETER DomainCredential
        Domain admin credential for the inside-VM execution.

    .PARAMETER IsoPath
        Absolute path to the SQL 2022 ISO ON THE HOST.

    .PARAMETER InstanceName
        SQL instance name. Default 'MSSQLSERVER'.

    .PARAMETER SaPassword
        sa login password.

    .PARAMETER SqlSysAdminAccounts
        Array of accounts added to sysadmin at install time. Must
        include the CM site server's computer account so CM setup can
        create CM_<SiteCode>.

    .PARAMETER Collation
        SQL collation. Default 'SQL_Latin1_General_CP1_CI_AS' (CM req).

    .PARAMETER ConfigOverrides
        Optional hashtable of [OPTIONS] keys/values to merge over the
        generated config (escape hatch for tuning specific keys
        without growing this function's parameter list).

    .PARAMETER SetupTimeoutMinutes
        Hard ceiling for setup.exe. Default 60 (typical install: 15-25
        min on a hot host).

    .EXAMPLE
        Install-LabSqlServer `
            -ComputerName CM01 -DomainCredential $cred `
            -IsoPath C:\LabSources\ISOs\SQLServer2022-x64-ENU.iso `
            -SaPassword 'P@ssw0rd!' `
            -SqlSysAdminAccounts @('BUILTIN\Administrators','CONTOSO\Domain Admins','CONTOSO\CM01$')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IsoPath,

        [Parameter()]
        [string]$InstanceName = 'MSSQLSERVER',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SaPassword,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SqlSysAdminAccounts,

        [Parameter()]
        [string]$Collation = 'SQL_Latin1_General_CP1_CI_AS',

        [Parameter()]
        [hashtable]$ConfigOverrides,

        [Parameter()]
        [ValidateRange(10, 240)]
        [int]$SetupTimeoutMinutes = 60
    )

    if (-not (Test-Path -Path $IsoPath -PathType Leaf)) {
        throw "Install-LabSqlServer: ISO not found: $IsoPath"
    }

    # Idempotency: ask the VM if SQL is already up. (Querying the VM via
    # WinRM does not need local admin; the elevation check is gated to
    # the actual Add-VMDvdDrive path below.)
    $svcName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
    $existing = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            param($svc)
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($s) {
                [pscustomobject]@{ Installed = $true; Status = [string]$s.Status }
            } else {
                [pscustomobject]@{ Installed = $false; Status = 'NotPresent' }
            }
        } -ArgumentList $svcName

    if ($existing.Installed) {
        Write-LabLog "[$ComputerName] SQL instance '$InstanceName' already installed (Status=$($existing.Status))" -Status SKIP
        return [pscustomobject]@{ Status = 'AlreadyInstalled'; Instance = $InstanceName }
    }

    # Elevation is required from this point on (Add-VMDvdDrive).
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Install-LabSqlServer: process must be elevated; Add-VMDvdDrive requires admin'
    }

    # 1. Build the INI on the host.
    $hostIni = Join-Path $env:TEMP ('homelab-sql-config-{0}.ini' -f $ComputerName)
    $iniParams = @{
        SaPassword          = $SaPassword
        SqlSysAdminAccounts = $SqlSysAdminAccounts
        InstanceName        = $InstanceName
        Collation           = $Collation
        OutputPath          = $hostIni
    }
    $null = New-LabSqlConfigIni @iniParams

    if ($ConfigOverrides) {
        # Merge overrides via Read | mutate | Write so the final on-disk INI
        # is byte-deterministic with our writer.
        $cfg = Read-LabIni -Path $hostIni
        if (-not $cfg.Contains('OPTIONS')) {
            $cfg['OPTIONS'] = [ordered]@{}
        }
        foreach ($kvp in $ConfigOverrides.GetEnumerator()) {
            $cfg['OPTIONS'][$kvp.Key] = [string]$kvp.Value
        }
        Write-LabIni -Data $cfg -Path $hostIni -Encoding ASCII
    }

    # 2. Push the INI to the VM.
    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
        if (-not (Test-Path 'C:\Install')) { New-Item -Path 'C:\Install' -ItemType Directory -Force | Out-Null }
    } | Out-Null

    Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                 -Path $hostIni -Destination 'C:\Install\sql-config.ini' `
                 -Activity 'Push SQL config INI to VM'

    # 3. Attach the ISO as a DVD drive (Hyper-V zero-copy).
    Write-LabLog "[$ComputerName] Attaching SQL 2022 ISO as virtual DVD" -Status RUN
    $existingDvd = Get-VMDvdDrive -VMName $ComputerName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $IsoPath }
    if (-not $existingDvd) {
        Add-VMDvdDrive -VMName $ComputerName -Path $IsoPath -ErrorAction Stop
    }

    try {
        # 4 + 5. Run setup.exe from the freshly-mounted DVD inside the VM.
        Write-LabLog "[$ComputerName] Running SQL 2022 setup.exe (timeout ${SetupTimeoutMinutes}m)" -Status RUN
        $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
            -Activity 'Run SQL 2022 setup.exe' -ScriptBlock {
                param($IniPath, $TimeoutSeconds)

                # Find the DVD with setup.exe at the root.
                $dvd = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=5' |
                    Where-Object { $_.DeviceID -and (Test-Path (Join-Path "$($_.DeviceID)\" 'setup.exe')) } |
                    Select-Object -First 1
                if (-not $dvd) {
                    throw 'No DVD drive with setup.exe at the root found inside the VM.'
                }

                $setup = Join-Path "$($dvd.DeviceID)\" 'setup.exe'

                # SQL setup uses DPAPI to encrypt SAPWD. DPAPI fails inside
                # a network-logon session (which is what WinRM gives us)
                # because it cannot reach the user profile keys without
                # credential delegation. Run setup via a SYSTEM-owned
                # scheduled task to dodge the network-logon constraint.
                # Wrap in a .cmd file because Scheduled Task argument
                # quoting with multiple quoted args is unreliable.
                $taskName = 'HomeLab-SqlSetup'
                $cmdFile  = 'C:\Install\run-sql-setup.cmd'
                $stdout   = 'C:\Install\sql-setup-stdout.log'
                $cmdBody = @"
@echo off
"$setup" /CONFIGURATIONFILE="$IniPath" /IACCEPTSQLSERVERLICENSETERMS > "$stdout" 2>&1
exit /b %ERRORLEVEL%
"@
                Set-Content -Path $cmdFile -Value $cmdBody -Encoding ASCII
                $action   = New-ScheduledTaskAction -Execute $cmdFile
                $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
                Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
                Start-ScheduledTask -TaskName $taskName

                # Wait up to 60s for the task to transition to Running. A
                # freshly-registered task reports LastTaskResult=267011
                # (TASK_HAS_NOT_RUN) before the scheduler picks it up;
                # don't mistake that for completion.
                $startDeadline = (Get-Date).AddSeconds(60)
                $started = $false
                while ((Get-Date) -lt $startDeadline) {
                    if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') { $started = $true; break }
                    Start-Sleep -Seconds 2
                }
                if (-not $started) {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
                    throw "SQL setup scheduled task did not transition to Running within 60s"
                }

                $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                $exit = $null
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 10
                    if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') {
                        $exit = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
                        break
                    }
                }
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
                if ($null -eq $exit) {
                    throw "SQL setup scheduled task did not complete within ${TimeoutSeconds}s"
                }

                # Tail the most recent Summary.txt regardless of exit code; on
                # success we want to log the path, on failure we want the body.
                $summary = Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1

                $summaryText = if ($summary) { Get-Content -Path $summary.FullName -Raw } else { $null }

                [pscustomobject]@{
                    ExitCode    = $exit
                    SummaryPath = if ($summary) { $summary.FullName } else { $null }
                    SummaryText = $summaryText
                }
            } -ArgumentList 'C:\Install\sql-config.ini', ($SetupTimeoutMinutes * 60)

        if ($result.ExitCode -notin 0, 3010) {
            $msg = "Install-LabSqlServer: setup.exe returned $($result.ExitCode) on $ComputerName."
            if ($result.SummaryPath) {
                $msg += " Summary log: $($result.SummaryPath)`n--- Summary.txt ---`n$($result.SummaryText)"
            }
            throw $msg
        }

        Write-LabLog "[$ComputerName] SQL setup OK (exit $($result.ExitCode))" -Status OK

        return [pscustomobject]@{
            Status      = if ($result.ExitCode -eq 3010) { 'InstalledRebootRequired' } else { 'Installed' }
            Instance    = $InstanceName
            ExitCode    = $result.ExitCode
            SummaryPath = $result.SummaryPath
        }
    } finally {
        Get-VMDvdDrive -VMName $ComputerName -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $IsoPath } |
            Remove-VMDvdDrive -ErrorAction SilentlyContinue
        Remove-Item -Path $hostIni -Force -ErrorAction SilentlyContinue
    }
}
