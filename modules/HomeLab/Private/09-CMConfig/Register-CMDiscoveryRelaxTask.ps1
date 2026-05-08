function Register-CMDiscoveryRelaxTask {
    <#
    .SYNOPSIS
        Schedule a one-shot relax of AD discovery delta cadence on CM01,
        N hours after deploy completes. Self-deleting.

    .DESCRIPTION
        The engine sets AD System / User Discovery delta cadence to 3
        minutes so newly-built lab VMs become CM resources (and trigger
        client push) within minutes. That cadence is wasteful long-term:
        the discovery thread, AD traversal, and SQL writes all spin
        every 3 minutes for a 3-VM lab that almost never changes.

        This helper registers a Windows Scheduled Task on the CM site
        server that fires once, $DelayHours after registration, and
        flips DeltaDiscoveryMins on both ActiveDirectorySystemDiscovery
        and ActiveDirectoryUserDiscovery to $RelaxedDeltaMinutes
        (default 360 = 6 hours, matching CM's production default).
        After flipping, the task unregisters itself.

        Idempotent: removes any pre-existing task with the same name
        before creating a fresh one (so re-running Install-HomeLab
        resets the 6-hour clock).

        Runs as SYSTEM with -RunLevel Highest. The CM provider trusts
        the local SYSTEM account on the site server, so no domain
        credential is embedded in the task.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential -- used only to register the task on
        the remote machine, NOT embedded in the task itself.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER TaskName
        Scheduled-task name. Default 'HomeLab-Relax-Discovery'.

    .PARAMETER DelayHours
        Hours from now until the task fires. Default 6.

    .PARAMETER RelaxedDeltaMinutes
        Delta cadence the task sets after firing. Default 360 (6h).

    .EXAMPLE
        Register-CMDiscoveryRelaxTask -ComputerName CM01 `
            -DomainCredential $cred -SiteCode MCM
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

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = 'HomeLab-Relax-Discovery',

        [Parameter()]
        [ValidateRange(1, 168)]
        [int]$DelayHours = 6,

        [Parameter()]
        [ValidateRange(5, 1440)]
        [int]$RelaxedDeltaMinutes = 360
    )

    Write-LabLog "[$ComputerName] Scheduling discovery-relax task '$TaskName' to fire in ${DelayHours}h" -Status RUN

    # The relax script body. Must be self-contained -- runs as SYSTEM
    # on CM01 with no module pre-loaded, no parameters in scope.
    $relaxScript = @"
`$ErrorActionPreference = 'Stop'
`$failed = `$false
try {
    `$adminUi = `$env:SMS_ADMIN_UI_PATH
    if (-not `$adminUi) {
        # Cached/SYSTEM context may not have the env var. Fall back to
        # the documented default install location.
        `$adminUi = 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386'
    }
    `$cmModule = Join-Path `$adminUi '..\ConfigurationManager.psd1'
    Import-Module `$cmModule -Force
    if (-not (Get-PSDrive -Name '${SiteCode}' -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        `$null = New-PSDrive -Name '${SiteCode}' -PSProvider CMSite -Root `$env:COMPUTERNAME -ErrorAction Stop
    }
    Set-Location '${SiteCode}:'
    Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode '${SiteCode}' -DeltaDiscoveryMins ${RelaxedDeltaMinutes}
    Set-CMDiscoveryMethod -ActiveDirectoryUserDiscovery   -SiteCode '${SiteCode}' -DeltaDiscoveryMins ${RelaxedDeltaMinutes}
} catch {
    `$failed = `$true
    `$_.Exception.Message | Out-File -FilePath 'C:\Windows\Temp\HomeLab-Relax-Discovery.log' -Append
} finally {
    Unregister-ScheduledTask -TaskName '${TaskName}' -Confirm:`$false -ErrorAction SilentlyContinue
}
if (`$failed) { exit 1 }
"@

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($relaxScript)
    $encoded = [Convert]::ToBase64String($bytes)

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Register $TaskName" -ScriptBlock {
            param($TaskName, $Encoded, $DelayHours)

            # Idempotent: drop any prior copy.
            $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($existing) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            }

            $action = New-ScheduledTaskAction `
                -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $Encoded"

            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours($DelayHours)
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

            Register-ScheduledTask -TaskName $TaskName `
                -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                -Description 'HomeLab one-shot: relax CM AD discovery delta cadence and self-delete.' `
                -ErrorAction Stop | Out-Null

            $task = Get-ScheduledTask -TaskName $TaskName
            return [pscustomobject]@{
                TaskName = $task.TaskName
                State    = [string]$task.State
                NextRun  = (Get-ScheduledTaskInfo -TaskName $TaskName).NextRunTime
            }
        } -ArgumentList $TaskName, $encoded, $DelayHours

    Write-LabLog "[$ComputerName] Discovery-relax task '$($result.TaskName)' scheduled for $($result.NextRun)" -Status OK
    return $result
}
