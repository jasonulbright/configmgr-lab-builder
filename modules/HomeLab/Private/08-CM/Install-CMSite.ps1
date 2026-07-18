function Install-CMSite {
    <#
    .SYNOPSIS
        Run unattended Configuration Manager 2509 primary-site setup on
        a domain-joined VM.

    .DESCRIPTION
        The orchestrator. Replaces AL's `Install-CMSite.ps1` (507 lines
        of which ~80% was logging plumbing) with the actual install
        workflow:

          1. Idempotency probe: query SMS_Site in
             ROOT\SMS\site_<SiteCode>. If a site already answers, return
             'AlreadyInstalled' without doing anything else.
          2. Push the CM 2509 source tree from the host to
             C:\Install\CM\ on the VM (Copy-LabFile -Recurse). Skipped
             if -CMSourcePath is not supplied AND C:\Install\CM exists
             on the VM (caller pre-staged).
          3. Push the CM-PreReqs offline cache (optional). When
             present, the generated INI sets PrerequisiteComp=1; when
             absent, setup.exe downloads its own.
          4. Build ConfigurationFile-CM.ini via New-CMUnattendIni and
             push to C:\Install\.
          5. Place NO_SMS_ON_DRIVE.SMS on every fixed drive on the VM
             EXCEPT C: -- prevents CM from picking the SQL data /
             tempdb / backup drives as content stores.
          6. Run setup.exe /script C:\Install\ConfigurationFile-CM.ini
             /noUserInput synchronously inside the VM. Setup typically
             runs 30-60 minutes; the pooled session keeps WinRM open.
             If exit code is non-zero AND Test-CMSetupLog says Failure,
             throw with the log error context.
          7. Test-CMSetupLog to confirm "successfully installed" before
             reporting Installed.

        Returns [pscustomobject]:
          Status        - 'AlreadyInstalled' / 'Installed'
          SiteCode
          ExitCode
          SetupLogPath  - 'C:\ConfigMgrSetup.log' (always)
          Duration      - TimeSpan, only set when actually installed

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER SiteName
        Display name.

    .PARAMETER CMServerFqdn
        FQDN of the site server. Defaults to "$ComputerName.$($DomainCredential.UserName.Split('\')[0]).local"
        which is wrong; pass it explicitly.

    .PARAMETER SQLServerFqdn
        FQDN of the SQL host. Default: $CMServerFqdn (co-located).

    .PARAMETER CMSourcePath
        Path on the HOST to the extracted CM 2509 baseline. The folder
        must contain SMSSETUP\BIN\X64\setup.exe. If omitted, the
        function assumes the source is already at C:\Install\CM\ on
        the VM (use this when running from inside the lab or when the
        source was pre-pushed).

    .PARAMETER CMPreReqsPath
        Optional path on the HOST to the offline prereqs cache. When
        present, pushed to C:\Install\CM-PreReqs and PrerequisiteComp=1.

    .PARAMETER Branch
        CB (Current Branch, default) or TP (Technical Preview).

    .PARAMETER ProductID
        Default 'EVAL'.

    .PARAMETER SetupTimeoutMinutes
        Hard ceiling for the setup.exe call. Default 90.

    .PARAMETER PostInstallReadyTimeoutMinutes
        After setup.exe exits cleanly, how long to wait for SMS_EXECUTIVE
        + the CM provider via Wait-CMReady. Default 12 (matches AL).

    .EXAMPLE
        Install-CMSite `
            -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -SiteName 'Home Lab Primary Site' `
            -CMServerFqdn 'CM01.contoso.com' `
            -CMSourcePath 'C:\LabSources\SoftwarePackages\CM' `
            -SetupTimeoutMinutes 90
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
        [string]$SiteName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CMServerFqdn,

        [Parameter()]
        [string]$SQLServerFqdn,

        [Parameter()]
        [string]$CMSourcePath,

        [Parameter()]
        [string]$CMPreReqsPath,

        [Parameter()]
        [ValidateSet('CB','TP')]
        [string]$Branch = 'CB',

        [Parameter()]
        [string]$ProductID = 'EVAL',

        [Parameter()]
        [ValidateRange(15, 240)]
        [int]$SetupTimeoutMinutes = 90,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$PostInstallReadyTimeoutMinutes = 12
    )

    if (-not $SQLServerFqdn) { $SQLServerFqdn = $CMServerFqdn }

    if ($CMSourcePath -and -not (Test-Path -Path $CMSourcePath -PathType Container)) {
        throw "Install-CMSite: CMSourcePath not found: $CMSourcePath"
    }
    if ($CMPreReqsPath -and -not (Test-Path -Path $CMPreReqsPath -PathType Container)) {
        throw "Install-CMSite: CMPreReqsPath not found: $CMPreReqsPath"
    }

    # 1. Idempotency. Probing the WMI namespace from the VM is robust
    # even when SMS_EXECUTIVE is starting up: a missing namespace
    # throws ObjectNotFound and we treat that as "not installed".
    Write-LabLog "[$ComputerName] Probing for existing CM site $SiteCode" -Status RUN
    $existing = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            param($Site)
            try {
                $cm = Get-CimInstance -Namespace "ROOT\SMS\site_$Site" -ClassName SMS_Site -ErrorAction Stop |
                    Where-Object { $_.SiteCode -eq $Site } | Select-Object -First 1
                if ($cm) { return [pscustomobject]@{ Installed = $true; Version = $cm.Version } }
            } catch { }
            return [pscustomobject]@{ Installed = $false }
        } -ArgumentList $SiteCode

    if ($existing.Installed) {
        Write-LabLog "[$ComputerName] CM site $SiteCode already installed (v$($existing.Version))" -Status SKIP
        return [pscustomobject]@{
            Status       = 'AlreadyInstalled'
            SiteCode     = $SiteCode
            Version      = $existing.Version
            ExitCode     = $null
            SetupLogPath = 'C:\ConfigMgrSetup.log'
        }
    }

    # 2. Push CM source if a host path was supplied. Uses the same
    # stage-rename pattern as Install-HomeLab's pre-schema push to dodge
    # the Copy-Item -Recurse nested-folder bug and to handle nested
    # source layouts (e.g. ConfigMgr_2509 inside the supplied folder).
    if ($CMSourcePath) {
        $hasSource = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
            Test-Path 'C:\Install\CM\SMSSETUP\BIN\X64\setup.exe'
        }
        if (-not $hasSource) {
            $effectiveSrc = $CMSourcePath
            if (-not (Test-Path (Join-Path $CMSourcePath 'SMSSETUP'))) {
                $kids = @(Get-ChildItem -Path $CMSourcePath -Directory)
                $nested = $kids | Where-Object { Test-Path (Join-Path $_.FullName 'SMSSETUP') } | Select-Object -First 1
                if ($nested) { $effectiveSrc = $nested.FullName }
            }
            Write-LabLog "[$ComputerName] Pushing CM source from $effectiveSrc (this may take 5-30 min)" -Status RUN
            Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
                if (-not (Test-Path 'C:\Install')) { New-Item -Path 'C:\Install' -ItemType Directory -Force | Out-Null }
                if (Test-Path 'C:\Install\CM')         { Remove-Item 'C:\Install\CM'         -Recurse -Force -ErrorAction SilentlyContinue }
                if (Test-Path 'C:\Install\__cmstage')  { Remove-Item 'C:\Install\__cmstage'  -Recurse -Force -ErrorAction SilentlyContinue }
            } | Out-Null
            Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                         -Path $effectiveSrc -Destination 'C:\Install\__cmstage' -Recurse `
                         -Activity 'Push CM 2509 source'
            Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
                $stage = 'C:\Install\__cmstage'
                $dirs = @(Get-ChildItem $stage -Directory)
                if ($dirs.Count -ne 1) {
                    throw "Push CM source: expected exactly 1 staged child folder, got $($dirs.Count)"
                }
                Move-Item $dirs[0].FullName 'C:\Install\CM' -Force
                Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
            } | Out-Null
        }
        # Validate the final layout regardless of skip vs push.
        $ok = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
            Test-Path 'C:\Install\CM\SMSSETUP\BIN\X64\setup.exe'
        }
        if (-not $ok) {
            throw "Install-CMSite: setup.exe still missing at C:\Install\CM\SMSSETUP\BIN\X64\setup.exe after push"
        }
    } else {
        $hasSource = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
            Test-Path 'C:\Install\CM\SMSSETUP\BIN\X64\setup.exe'
        }
        if (-not $hasSource) {
            throw "Install-CMSite: -CMSourcePath not given and C:\Install\CM\SMSSETUP\BIN\X64\setup.exe missing on $ComputerName."
        }
    }

    # 3. Push prereqs offline cache (optional). Same stage-rename pattern
    # as the CM source push -- Copy-LabFile pre-creates the destination,
    # which makes Copy-Item -Recurse nest the source folder one layer
    # deeper than CM setup expects. Sentinel is "any file directly under
    # the prereq root" so an accidentally-nested layout is detected as
    # "needs re-push" rather than "looks fine."
    $prereqHasFiles = $false
    if ($CMPreReqsPath) {
        $alreadyPushed = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
            $root = 'C:\Install\CM-PreReqs'
            (Test-Path $root) -and ((Get-ChildItem $root -File -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null)
        }
        if (-not $alreadyPushed) {
            Write-LabLog "[$ComputerName] Pushing CM prereqs cache" -Status RUN
            Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
                if (Test-Path 'C:\Install\CM-PreReqs')   { Remove-Item 'C:\Install\CM-PreReqs'   -Recurse -Force -ErrorAction SilentlyContinue }
                if (Test-Path 'C:\Install\__prereqstage') { Remove-Item 'C:\Install\__prereqstage' -Recurse -Force -ErrorAction SilentlyContinue }
                if (-not (Test-Path 'C:\Install')) { New-Item -Path 'C:\Install' -ItemType Directory -Force | Out-Null }
            } | Out-Null
            Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                         -Path $CMPreReqsPath -Destination 'C:\Install\__prereqstage' -Recurse `
                         -Activity 'Push CM prereqs'
            Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
                $stage = 'C:\Install\__prereqstage'
                $dirs = @(Get-ChildItem $stage -Directory)
                if ($dirs.Count -ne 1) {
                    throw "Push CM prereqs: expected exactly 1 staged child folder, got $($dirs.Count)"
                }
                Move-Item $dirs[0].FullName 'C:\Install\CM-PreReqs' -Force
                Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
            } | Out-Null
            $hasFiles = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
                (Get-ChildItem 'C:\Install\CM-PreReqs' -File -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null
            }
            if (-not $hasFiles) {
                throw "Push CM prereqs: C:\Install\CM-PreReqs is empty after stage-rename"
            }
        }
        $prereqHasFiles = $true
    }

    # 4. Build + push the unattend INI.
    $hostIni = Join-Path $env:TEMP ('homelab-cm-config-{0}.ini' -f $ComputerName)
    $iniPath = New-CMUnattendIni `
        -CMServerFqdn $CMServerFqdn `
        -SQLServerFqdn $SQLServerFqdn `
        -SiteCode $SiteCode -SiteName $SiteName `
        -Branch $Branch -ProductID $ProductID `
        -PrerequisitePathHasFiles $prereqHasFiles `
        -OutputPath $hostIni

    Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                 -Path $iniPath -Destination 'C:\Install\ConfigurationFile-CM.ini' `
                 -Activity 'Push CM unattend INI'

    # 5. NO_SMS_ON_DRIVE.SMS on every fixed drive except C: (the SMS
    # install root). This prevents CM from claiming the SQL data /
    # backup / tempdb drives as content stores.
    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Place NO_SMS_ON_DRIVE.SMS markers' -ScriptBlock {
            $fixed = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
                Where-Object { $_.DeviceID -ne 'C:' }
            foreach ($d in $fixed) {
                $marker = Join-Path "$($d.DeviceID)\" 'NO_SMS_ON_DRIVE.SMS'
                if (-not (Test-Path $marker)) {
                    Set-Content -Path $marker -Value '' -Force
                }
            }
        } | Out-Null

    # 6. setup.exe /script. Synchronous Start-Process inside the
    # pooled session. This blocks for 30-60 min; PSSessions keep
    # WinRM open for the duration.
    Write-LabLog "[$ComputerName] Running CM 2509 setup.exe (timeout ${SetupTimeoutMinutes}m)" -Status RUN
    $setupStart = Get-Date

    # CM setup.exe must run with an interactive token (DPAPI / domain
    # ops). Run via scheduled task with explicit domain creds. Same
    # pattern as Install-LabSqlServer.
    $setupResult = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            param($IniPath, $DomUser, $DomPass, $TimeoutMinutes)
            $exe = 'C:\Install\CM\SMSSETUP\BIN\X64\setup.exe'
            if (-not (Test-Path $exe)) {
                throw "setup.exe missing at $exe"
            }
            $stdout = 'C:\Install\cm-setup-stdout.log'
            $cmdFile = 'C:\Install\run-cm-setup.cmd'
            $cmdBody = @"
@echo off
"$exe" /script "$IniPath" /noUserInput > "$stdout" 2>&1
exit /b %ERRORLEVEL%
"@
            Set-Content -Path $cmdFile -Value $cmdBody -Encoding ASCII

            $taskName = 'HomeLab-CmSetup'
            $action = New-ScheduledTaskAction -Execute $cmdFile
            $execLimit = New-TimeSpan -Minutes $TimeoutMinutes
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit $execLimit
            Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User $DomUser -Password $DomPass -RunLevel Highest -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName

            $startDeadline = (Get-Date).AddSeconds(60)
            $started = $false
            while ((Get-Date) -lt $startDeadline) {
                if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') { $started = $true; break }
                Start-Sleep -Seconds 2
            }
            if (-not $started) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; throw "CM setup task did not start within 60s" }

            $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
            $exit = $null
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 30
                if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') {
                    $exit = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
                    break
                }
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            if ($null -eq $exit) { throw "CM setup did not complete within ${TimeoutMinutes}m" }
            return [pscustomobject]@{ ExitCode = $exit }
        } -ArgumentList 'C:\Install\ConfigurationFile-CM.ini', $DomainCredential.UserName,
                        ([System.Net.NetworkCredential]::new('', $DomainCredential.Password).Password),
                        $SetupTimeoutMinutes

    $duration = (Get-Date) - $setupStart
    Write-LabLog "[$ComputerName] setup.exe exit $($setupResult.ExitCode) after $([math]::Round($duration.TotalMinutes, 1))m" -Status INFO

    # 7. Verify via the log. setup.exe exit code alone is unreliable.
    $logCheck = Test-CMSetupLog -ComputerName $ComputerName -DomainCredential $DomainCredential
    if ($logCheck.Status -eq 'Failure') {
        $msg = "Install-CMSite: ConfigMgrSetup.log shows Failure on $ComputerName.`nMatch: $($logCheck.MatchLine)`n--- error context ---`n$($logCheck.ErrorContext)"
        throw $msg
    }
    if ($logCheck.Status -ne 'Success') {
        # InProgress after setup.exe exited is NORMAL on CM 2509:
        # setup.exe hands off to an async bootstrap that finishes after
        # the process exits. Observed on 3 of 3 verified installs
        # (2026-07-16/17), recovered by the Wait-CMReady gate below
        # every time -- INFO, not WARN.
        Write-LabLog "[$ComputerName] setup.exe exited but log shows $($logCheck.Status); waiting for SMS_EXECUTIVE (normal 2509 async handoff)" -Status INFO
    }

    Remove-Item -Path $hostIni -Force -ErrorAction SilentlyContinue

    # 8. SMS_EXECUTIVE + CM provider gate.
    $ready = Wait-CMReady -ComputerName $ComputerName -DomainCredential $DomainCredential `
        -SiteCode $SiteCode -TimeoutSeconds ($PostInstallReadyTimeoutMinutes * 60)
    if (-not $ready) {
        throw "Install-CMSite: SMS_EXECUTIVE / CM provider did not come ready within ${PostInstallReadyTimeoutMinutes}m"
    }

    Write-LabLog "[$ComputerName] CM site $SiteCode installed and ready" -Status OK
    return [pscustomobject]@{
        Status       = 'Installed'
        SiteCode     = $SiteCode
        ExitCode     = $setupResult.ExitCode
        SetupLogPath = 'C:\ConfigMgrSetup.log'
        Duration     = $duration
    }
}
