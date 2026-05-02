#Requires -Version 7
<#
.SYNOPSIS
    Tail the most recent homelab-gui-*.log, surface any [ERROR] block
    with context, exit clean on success.

.DESCRIPTION
    Background-friendly companion for the GUI deploy. Polls every 2s,
    streams new log lines to stdout, and short-circuits exit on:
      - The first  '[ERROR] Deploy ended:' line  (exit 1, dumps last 80 lines)
      - 'Install-HomeLab complete'              (exit 0)
      - The deploy log file disappearing/not produced inside StartTimeoutSec

    Designed to run via `bash run_in_background` so the CLI session can
    just check the captured stdout to know what happened.

.PARAMETER LogDir
    Directory containing homelab-gui-*.log. Default: gui/Logs relative
    to this script.

.PARAMETER StartTimeoutSec
    How long to wait for a NEW log file to appear once Watch-Deploy
    starts. Default 600s.

.PARAMETER PollIntervalSec
    Seconds between log reads. Default 2.

.PARAMETER ContextLines
    Lines of context to print before/around an [ERROR]. Default 80.
#>
[CmdletBinding()]
param(
    [string]$LogDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'gui\Logs'),
    [int]$StartTimeoutSec = 600,
    [int]$PollIntervalSec = 2,
    [int]$ContextLines = 80
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogDir)) {
    Write-Host "WATCHDOG: log dir missing: $LogDir"
    exit 2
}

# Track logs that already exist so we wait for a NEW one.
$baseline = @(
    Get-ChildItem -LiteralPath $LogDir -Filter 'homelab-gui-*.log' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName }
)
Write-Host ("WATCHDOG: started; baseline count = {0}" -f $baseline.Count)

$startedAt = Get-Date
$logFile = $null
while (-not $logFile -and ((Get-Date) - $startedAt).TotalSeconds -lt $StartTimeoutSec) {
    $current = @(
        Get-ChildItem -LiteralPath $LogDir -Filter 'homelab-gui-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    )
    $newest = $current | Select-Object -First 1
    if ($newest -and ($newest.FullName -notin $baseline)) {
        $logFile = $newest.FullName
        Write-Host ("WATCHDOG: tailing new log: {0}" -f $logFile)
        break
    }
    Start-Sleep -Seconds $PollIntervalSec
}

if (-not $logFile) {
    Write-Host ("WATCHDOG: no new log appeared within {0}s; aborting" -f $StartTimeoutSec)
    exit 3
}

$position = 0L
$buffer = [System.Collections.Generic.Queue[string]]::new()
$exitCode = $null

while ($null -eq $exitCode) {
    Start-Sleep -Seconds $PollIntervalSec

    try {
        $fs = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs)
        [void]$fs.Seek($position, 'Begin')
        $newText = $sr.ReadToEnd()
        $position = $fs.Position
        $sr.Close()
        $fs.Close()
    } catch {
        # Log file mid-write or briefly locked; try again next tick.
        continue
    }

    if (-not $newText) { continue }

    foreach ($line in ($newText -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $buffer.Enqueue($line)
        while ($buffer.Count -gt $ContextLines) { [void]$buffer.Dequeue() }

        if ($line -match '\[ERROR\] Deploy ended:') {
            Write-Host ''
            Write-Host '==================== DEPLOY FAILED ===================='
            Write-Host "Log: $logFile"
            Write-Host '------- last context (most recent first) -------'
            $bufferArray = @($buffer.ToArray())
            for ($i = $bufferArray.Count - 1; $i -ge 0; $i--) {
                Write-Host $bufferArray[$i]
            }
            Write-Host '======================================================'
            $exitCode = 1
            break
        }

        if ($line -match 'Install-HomeLab complete in \d') {
            Write-Host ''
            Write-Host '==================== DEPLOY SUCCEEDED ===================='
            Write-Host $line
            Write-Host '=========================================================='
            $exitCode = 0
            break
        }
    }
}

exit $exitCode
