function Install-LabWsusConsole {
    <#
    .SYNOPSIS
        Install the WSUS administration console and API on a lab VM, so
        the VM can publish updates to the WSUS server.

    .DESCRIPTION
        A tool that publishes local or third-party updates uses the WSUS
        administration API (Microsoft.UpdateServices.Administration.dll).
        The API comes with the WSUS console. The site server gets it from
        the WSUS role (Install-LabWsus, -IncludeManagementTools). Other VMs
        need it added:
          - Windows Server: Install-WindowsFeature UpdateServices-UI
            (Learn: troubleshoot-software-update-synchronization,
            "Verify prerequisites").
          - Windows client: the RSAT capability Rsat.WSUS.Tools~~~~0.0.1.0
            (Learn: install-remote-server-administration-tools). It installs
            in a scheduled task as SYSTEM.

        Windows 11 22H2 and later ask a WSUS server for Features on Demand
        through on-premises UUP (Learn: fod-and-lang-packs). A software
        update point holds the metadata and not the files, so each file URL
        answers HTTP 404 and the install ends with 0x80d02002. UseWUServer = 0
        alone does not change the source, because Windows Update reads a
        cached copy of the policy (UpdatePolicy\GPCache). For the length of
        the install the client script saves the policy key and the cache,
        removes the WSUS source values and the cache, and puts both keys back,
        also after a failure. A run that finds saved keys restores them first.

        Idempotent: returns 'AlreadyInstalled' when the API assembly is
        already registered. Throws when the assembly is missing after the
        install.

    .PARAMETER ComputerName
        VM that receives the console.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER TimeoutMinutes
        Time limit of the client install. The task limit is 20 minutes longer,
        so that the policy restore runs after a timeout.

    .EXAMPLE
        Install-LabWsusConsole -ComputerName CLIENT01 -DomainCredential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter()]
        [ValidateRange(5, 240)]
        [int]$TimeoutMinutes = 40
    )

    Write-LabLog "[$ComputerName] Installing the WSUS administration console" -Status RUN

    # Runs on a client VM as SYSTEM. Passed as text and written to a file there.
    $clientInstall = {
        param([int]$LimitMinutes)
        $ErrorActionPreference = 'Stop'
        $api = Join-Path $env:windir 'Microsoft.NET\assembly\GAC_MSIL\Microsoft.UpdateServices.Administration'
        $name = 'Rsat.WSUS.Tools~~~~0.0.1.0'
        $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $cache = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\GPCache'
        $store = Join-Path $env:ProgramData 'HomeLab\wsus-console-policy'
        $saved = [ordered]@{ $policy = (Join-Path $store 'policy.reg'); $cache = (Join-Path $store 'policy-cache.reg') }

        function Restore-UpdatePolicy {
            if (-not (Test-Path (Join-Path $store 'complete'))) { return }
            foreach ($service in 'usosvc', 'wuauserv') { Stop-Service $service -Force -ErrorAction SilentlyContinue }
            foreach ($key in $saved.Keys) {
                if (-not (Test-Path $saved[$key])) {
                    # A cache that did not exist before the install holds the values of the install.
                    if ($key -eq $cache -and (Test-Path $key)) { Remove-Item $key -Recurse -Force }
                    continue
                }
                # The key is replaced, not merged, so that a value from the install does not stay.
                if (Test-Path $key) { Remove-Item $key -Recurse -Force }
                # reg.exe writes its success text to the error stream, so the stream is not redirected.
                $run = Start-Process reg.exe -ArgumentList 'import', ('"{0}"' -f $saved[$key]) -Wait -PassThru -WindowStyle Hidden
                if ($run.ExitCode -ne 0) { throw "$key was not restored from $($saved[$key])." }
            }
            Remove-Item $store -Recurse -Force
            foreach ($service in 'usosvc', 'wuauserv') { Start-Service $service -ErrorAction SilentlyContinue }
            'The Windows Update policy is restored.'
        }

        # Before the installed check: a run that was ended can leave the policy changed with the console installed.
        Restore-UpdatePolicy
        if (Test-Path -Path $api) { 'STATUS:AlreadyInstalled'; return }
        try {
            $server = (Get-ItemProperty -Path $policy -Name WUServer -ErrorAction SilentlyContinue).WUServer
            if ($server) {
                if (Test-Path $store) { Remove-Item $store -Recurse -Force }
                $null = New-Item -ItemType Directory -Force $store
                foreach ($key in $saved.Keys) {
                    if (-not (Test-Path $key)) { continue }
                    $null = & reg.exe export ($key -replace '^HKLM:', 'HKLM') $saved[$key] /y
                    if ($LASTEXITCODE -ne 0) { throw "$key was not saved, so nothing is changed." }
                }
                $null = New-Item -ItemType File (Join-Path $store 'complete')
                foreach ($service in 'usosvc', 'wuauserv') { Stop-Service $service -Force -ErrorAction SilentlyContinue }
                foreach ($value in 'WUServer', 'WUStatusServer', 'UpdateServiceUrlAlternate', 'FillEmptyContentUrls') {
                    Remove-ItemProperty -Path $policy -Name $value -ErrorAction SilentlyContinue
                }
                if (Test-Path "$policy\AU") { Set-ItemProperty -Path "$policy\AU" -Name UseWUServer -Value 0 }
                if (Test-Path $cache) { Remove-Item $cache -Recurse -Force }
                foreach ($service in 'usosvc', 'wuauserv') { Start-Service $service -ErrorAction SilentlyContinue }
                Start-Sleep -Seconds 15
            }
            # The limit is inside the script, because the end of a task runs no finally block. No Stop-Job on a
            # timeout: it waits for a job in a servicing call, and the restore must not wait.
            $job = Start-Job { param($n) (Add-WindowsCapability -Online -Name $n).RestartNeeded } -ArgumentList $name
            if (-not (Wait-Job $job -Timeout ($LimitMinutes * 60))) { throw "The install did not end in $LimitMinutes minutes." }
            if (Receive-Job $job) { 'The WSUS console install asks for a restart.' }
        } finally {
            Restore-UpdatePolicy
        }
    }

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Install the WSUS administration console' -ScriptBlock {
            param($ClientInstallText, $TimeoutMinutes)
            $ErrorActionPreference = 'Stop'
            $gac = Join-Path $env:windir 'Microsoft.NET\assembly\GAC_MSIL\Microsoft.UpdateServices.Administration'

            $isServer = ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1)
            $status = 'Installed'
            if ($isServer) {
                if (Test-Path -Path $gac) {
                    return [pscustomobject]@{ Status = 'AlreadyInstalled' }
                }
                $feat = Install-WindowsFeature -Name UpdateServices-UI -ErrorAction Stop
                if (-not $feat.Success) { throw "Install-WindowsFeature UpdateServices-UI failed: $($feat | Out-String)" }
            } else {
                $folder = Join-Path $env:ProgramData 'HomeLab\wsus-console-run'
                $null = New-Item -ItemType Directory -Path $folder -Force
                $script = Join-Path $folder 'install.ps1'
                $log = Join-Path $folder 'install.log'
                Set-Content -Path $script -Value $ClientInstallText -Encoding UTF8
                $task = 'HomeLab-WsusConsole'
                $command = "try { & '$script' -LimitMinutes $TimeoutMinutes *>&1 | Out-File '$log' -Encoding utf8 } catch { `$_ | Out-File '$log' -Encoding utf8 -Append; exit 1 }"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes ($TimeoutMinutes + 20))
                $null = Register-ScheduledTask -TaskName $task -Action $action -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force
                try {
                    $started = Get-Date
                    Start-ScheduledTask -TaskName $task
                    do {
                        Start-Sleep -Seconds 10
                        $state = (Get-ScheduledTask -TaskName $task).State
                        $info = Get-ScheduledTaskInfo -TaskName $task
                    } while (($state -eq 'Running' -or $info.LastRunTime -lt $started.AddSeconds(-5)) -and
                        (Get-Date) -lt $started.AddMinutes($TimeoutMinutes + 21))
                    $text = if (Test-Path -Path $log) { Get-Content -Path $log -Raw } else { '' }
                    if ($state -eq 'Running' -or $info.LastTaskResult -ne 0) {
                        throw "The WSUS console install failed (task state $state, result $($info.LastTaskResult)): $text"
                    }
                    if ($text -match 'STATUS:AlreadyInstalled') { $status = 'AlreadyInstalled' }
                } finally {
                    Unregister-ScheduledTask -TaskName $task -Confirm:$false
                    Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            if (-not (Test-Path -Path $gac)) {
                throw 'The WSUS administration API (Microsoft.UpdateServices.Administration) is missing after the install'
            }
            [pscustomobject]@{ Status = $status }
        } -ArgumentList $clientInstall.ToString(), $TimeoutMinutes
    Write-LabLog "[$ComputerName] WSUS console: $($result.Status)" -Status OK
    return $result
}
