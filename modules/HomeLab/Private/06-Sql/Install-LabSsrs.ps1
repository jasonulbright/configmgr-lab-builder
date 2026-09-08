function Install-LabSsrs {
    <#
    .SYNOPSIS
        Install the SQL Server Reporting Services (SSRS) binaries on a
        domain-joined VM. Files only -- no report server configuration.

    .DESCRIPTION
        Steps:
          1. Copy-LabFile the standalone SQLServerReportingServices.exe
             installer into the VM at C:\Install\SQLServerReportingServices.exe
          2. Run it once with /? and log whatever it prints, so the switches
             actually supported by the staged build are captured for
             verification alongside the flags this function hardcodes below
          3. Run it unattended:
             /quiet IAcceptLicenseTerms=<True> Edition=<Edition> InstallFolder=<InstallFolder>

             This is a WixStdBA-based bootstrapper (confirmed by reading its
             own extracted BootstrapperApplicationData.xml): IAcceptLicenseTerms,
             Edition, InstallFolder and PID are WixStdbaOverridableVariable
             entries, which WixStdBA takes as bare NAME=VALUE properties on
             the command line -- NOT /NAME:VALUE switches. /IAcceptLicenseTerms
             and /Edition:X (this repo's SQL-setup-style guess, and the
             generic WiX Burn /install verb) all fail instantly with exit 87
             against this specific bundle; empirically confirmed live against
             CM01 that /install and /norestart are ALSO rejected by this
             bundle's bootstrapper application, so this function deliberately
             does not pass them -- only /quiet plus the three properties.
          4. Wait for setup completion. Exit code 0 = success; 3010 =
             success-reboot-required (also success)
          5. On a non-success exit code, best-effort locate and tail the
             bootstrapper's own log under %TEMP% or
             <InstallFolder>\Setup Bootstrap\Log

        Idempotent: queries the VM for the SQLServerReportingServices
        service before doing anything; if present, returns 'AlreadyInstalled'
        immediately.

        Installs binaries only. Creating the report server catalog
        database and initializing the report server is
        Set-LabSsrsConfiguration's job, run afterward.

    .PARAMETER ComputerName
        DNS / short name of the target VM.

    .PARAMETER DomainCredential
        Domain admin credential for the inside-VM execution.

    .PARAMETER InstallerPath
        Absolute path to SQLServerReportingServices.exe ON THE HOST. The
        installer is expected to already be staged there (no download).

    .PARAMETER InstallFolder
        Report server install location. Default matches the Reporting
        Services installer's own documented default.

    .PARAMETER Edition
        Edition token passed to /Edition:. Default 'Eval' -- this lab
        always installs Eval editions, matching Install-LabSqlServer.ps1's
        SQL Server install.

    .PARAMETER SetupTimeoutMinutes
        Hard ceiling for setup.exe. Default 30.

    .EXAMPLE
        Install-LabSsrs -ComputerName CM01 -DomainCredential $cred
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$InstallerPath = 'C:\LabSources\SoftwarePackages\SQL2022\SQLServerReportingServices.exe',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$InstallFolder = 'C:\Program Files\Microsoft SQL Server Reporting Services',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Edition = 'Eval',

        [Parameter()]
        [ValidateRange(5, 180)]
        [int]$SetupTimeoutMinutes = 30
    )

    if (-not (Test-Path -Path $InstallerPath -PathType Leaf)) {
        throw "Install-LabSsrs: installer not found: $InstallerPath"
    }

    # Idempotency: ask the VM if SSRS is already installed.
    $existing = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            $s = Get-Service -Name 'SQLServerReportingServices' -ErrorAction SilentlyContinue
            if ($s) {
                [pscustomobject]@{ Installed = $true; Status = [string]$s.Status }
            } else {
                [pscustomobject]@{ Installed = $false; Status = 'NotPresent' }
            }
        }

    if ($existing.Installed) {
        Write-LabLog "[$ComputerName] SSRS already installed (Status=$($existing.Status))" -Status SKIP
        return [pscustomobject]@{ Status = 'AlreadyInstalled'; ExitCode = $null; InstallFolder = $InstallFolder }
    }

    Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                 -Path $InstallerPath -Destination 'C:\Install\SQLServerReportingServices.exe' `
                 -Activity 'Push SSRS installer to VM'

    # No Microsoft Learn page documents this bootstrapper's own command-line
    # switches -- only the interactive wizard is documented. Capture /?
    # output as a best-effort cross-check for the hardcoded flags below. /?
    # may show a modal dialog instead of writing console text since this is
    # fundamentally a GUI installer; cap the wait so a diagnostic step can
    # never hang unattended setup.
    $helpInfo = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Capture SSRS setup /? output' -ScriptBlock {
            param($ExePath)

            $stdout = 'C:\Install\ssrs-help-stdout.log'
            $stderr = 'C:\Install\ssrs-help-stderr.log'
            Remove-Item -Path $stdout, $stderr -ErrorAction SilentlyContinue

            $proc = Start-Process -FilePath $ExePath -ArgumentList '/?' -PassThru `
                -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden
            $exited = $proc.WaitForExit(15000)
            if (-not $exited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }

            $text = ''
            foreach ($f in $stdout, $stderr) {
                if (Test-Path -Path $f) { $text += (Get-Content -Path $f -Raw -ErrorAction SilentlyContinue) }
            }
            [pscustomobject]@{ Exited = $exited; Output = $text }
        } -ArgumentList 'C:\Install\SQLServerReportingServices.exe'

    if ($helpInfo.Exited -and $helpInfo.Output) {
        Write-LabLog "[$ComputerName] SQLServerReportingServices.exe /? output:`n$($helpInfo.Output)" -Status INFO
    } else {
        Write-LabLog "[$ComputerName] SQLServerReportingServices.exe /? produced no captured console output (likely a GUI dialog, killed after 15s); proceeding with /Quiet /IAcceptLicenseTerms /Edition /InstallFolder" -Status INFO
    }

    Write-LabLog "[$ComputerName] Running SSRS setup.exe (timeout ${SetupTimeoutMinutes}m)" -Status RUN

    $installResult = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Run SSRS setup.exe' -ScriptBlock {
            param($ExePath, $Edition, $InstallFolder, $TimeoutSeconds)

            # WixStdBA overridable variables are bare NAME=VALUE properties,
            # not /NAME:VALUE switches -- see the function-level .DESCRIPTION
            # for how this was confirmed. /install and /norestart are
            # deliberately omitted: this bundle's bootstrapper application
            # rejects both (exit 87) even though they're standard Burn
            # engine verbs elsewhere.
            #
            # Start-Process -ArgumentList does NOT quote array elements
            # containing spaces -- confirmed empirically: an unquoted
            # 'InstallFolder=C:\Program Files\...' value is torn apart into
            # one bare token per space (7 separate args from 2 real ones).
            # Every value that can contain a space gets its own embedded
            # quotes here rather than relying on Start-Process to add them.
            $argList = @(
                '/quiet'
                'IAcceptLicenseTerms=True'
                "Edition=`"$Edition`""
                "InstallFolder=`"$InstallFolder`""
            )

            # No -Wait: WaitForExit(timeout) gives an escape hatch a bare
            # -Wait would not, in case /Quiet turns out to be the wrong
            # switch and the bootstrapper tries to render UI in a session
            # with no desktop. $TimeoutSeconds here is already in seconds --
            # the caller converts from -SetupTimeoutMinutes before passing
            # it (see -ArgumentList below); do not multiply by 60 again.
            $proc = Start-Process -FilePath $ExePath -ArgumentList $argList -PassThru -WindowStyle Hidden
            $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
            if (-not $exited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                throw "Install-LabSsrs: setup.exe did not exit within $TimeoutSeconds seconds"
            }
            $exitCode = $proc.ExitCode

            $logPath = $null
            $logText = $null
            if ($exitCode -notin 0, 3010) {
                # Best effort: no confirmed single log location/name for this
                # bootstrapper; scan the commonly seen patterns and take the
                # newest match.
                $candidates = New-Object System.Collections.Generic.List[System.IO.FileSystemInfo]
                foreach ($pattern in '*ReportingServices*.log', '*SSRS*.log') {
                    Get-ChildItem -Path $env:TEMP -Filter $pattern -ErrorAction SilentlyContinue |
                        ForEach-Object { $candidates.Add($_) }
                }
                $bootstrapLog = Join-Path $InstallFolder 'Setup Bootstrap\Log'
                if (Test-Path -Path $bootstrapLog) {
                    Get-ChildItem -Path $bootstrapLog -Include '*.log', 'Summary.txt' -Recurse -ErrorAction SilentlyContinue |
                        ForEach-Object { $candidates.Add($_) }
                }
                $best = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($best) {
                    $logPath = $best.FullName
                    $logText = Get-Content -Path $logPath -Raw -ErrorAction SilentlyContinue
                }
            }

            [pscustomobject]@{ ExitCode = $exitCode; LogPath = $logPath; LogText = $logText }
        } -ArgumentList 'C:\Install\SQLServerReportingServices.exe', $Edition, $InstallFolder, ($SetupTimeoutMinutes * 60)

    if ($installResult.ExitCode -notin 0, 3010) {
        $msg = "Install-LabSsrs: setup.exe returned $($installResult.ExitCode) on $ComputerName."
        if ($installResult.LogPath) {
            $msg += " Setup log: $($installResult.LogPath)`n--- log ---`n$($installResult.LogText)"
        } else {
            $msg += ' No setup log could be located for diagnostics.'
        }
        throw $msg
    }

    Write-LabLog "[$ComputerName] SSRS setup OK (exit $($installResult.ExitCode))" -Status OK

    return [pscustomobject]@{
        Status        = if ($installResult.ExitCode -eq 3010) { 'InstalledRebootRequired' } else { 'Installed' }
        ExitCode      = $installResult.ExitCode
        InstallFolder = $InstallFolder
    }
}
