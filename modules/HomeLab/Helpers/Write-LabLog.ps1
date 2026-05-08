function Write-LabLog {
    <#
    .SYNOPSIS
        Structured logger for the HomeLab module.

    .DESCRIPTION
        Replaces PSFramework's Write-PSFMessage. Writes a single log event to:
          1. The console with a brand-consistent severity tag and color
          2. A daily text log file (default $env:ProgramData\HomeLab\Logs\HomeLab-{yyyy-MM-dd}.log)
          3. A daily JSON log file alongside the text log (one JSON object per line)

        Severity levels follow the PSFMessage convention: Verbose, Debug,
        Info, Warning, Error, Critical. The 'Status' parameter sets the
        bracketed tag at the start of each line: [OK], [WARN], [FAIL],
        [INFO], [RUN], or [SKIP].

        Log file path can be overridden per-call via -LogPath, or globally for
        the session via $env:HOMELAB_LOG_DIR. JSON output can be disabled per
        call via -NoJson or globally via $env:HOMELAB_LOG_NOJSON=1.

    .PARAMETER Message
        The text to log.

    .PARAMETER Level
        Severity. Default Info.

    .PARAMETER Status
        Optional bracketed tag override (OK, WARN, FAIL, INFO, RUN, SKIP).
        Sets a sensible default Level if Level is not also passed.

    .PARAMETER Data
        Optional structured payload included in the JSON record only.

    .PARAMETER LogPath
        Override the text log file path. The JSON file will be written to the
        same path with .json appended.

    .PARAMETER NoJson
        Skip writing the JSON record for this call.

    .PARAMETER NoConsole
        Skip the console write for this call.

    .EXAMPLE
        Write-LabLog 'Hyper-V enabled' -Status OK
        Write-LabLog 'CM provider not ready, retrying' -Level Warning
        Write-LabLog 'Setup failed' -Level Error -Data @{ ExitCode = 5; Phase = 'CM' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Verbose','Debug','Info','Warning','Error','Critical')]
        [string]$Level,

        [Parameter()]
        [ValidateSet('OK','WARN','FAIL','INFO','RUN','SKIP')]
        [string]$Status,

        [Parameter()]
        [hashtable]$Data,

        [Parameter()]
        [string]$LogPath,

        [Parameter()]
        [switch]$NoJson,

        [Parameter()]
        [switch]$NoConsole
    )

    # Resolve effective Level. Status maps to a default Level when Level is
    # omitted; explicit Level always wins.
    if (-not $PSBoundParameters.ContainsKey('Level')) {
        $Level = switch ($Status) {
            'OK'   { 'Info' }
            'WARN' { 'Warning' }
            'FAIL' { 'Error' }
            'INFO' { 'Info' }
            'RUN'  { 'Info' }
            'SKIP' { 'Info' }
            default { 'Info' }
        }
    }

    # Resolve effective tag (the [BRACKETED] prefix on console output).
    $tag = if ($Status) { $Status } else {
        switch ($Level) {
            'Verbose'  { 'VERB' }
            'Debug'    { 'DBG ' }
            'Info'     { 'INFO' }
            'Warning'  { 'WARN' }
            'Error'    { 'FAIL' }
            'Critical' { 'CRIT' }
        }
    }

    $color = switch ($tag) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'INFO' { 'Cyan' }
        'RUN'  { 'Yellow' }
        'SKIP' { 'DarkGray' }
        'VERB' { 'DarkGray' }
        'DBG ' { 'DarkGray' }
        'CRIT' { 'Red' }
        default { 'Gray' }
    }

    $timestamp = Get-Date

    # 1. Console output (unless suppressed). Two-space indent + 4-char status tag.
    if (-not $NoConsole) {
        $line = '  [{0,-4}] {1}' -f $tag, $Message
        Write-Host $line -ForegroundColor $color
    }

    # 2. Resolve log paths.
    $logDir = if ($LogPath) {
        Split-Path -Path $LogPath -Parent
    } elseif ($env:HOMELAB_LOG_DIR) {
        $env:HOMELAB_LOG_DIR
    } else {
        Join-Path $env:ProgramData 'HomeLab\Logs'
    }

    $textPath = if ($LogPath) {
        $LogPath
    } else {
        Join-Path $logDir ('HomeLab-{0}.log' -f $timestamp.ToString('yyyy-MM-dd'))
    }
    $jsonPath = "$textPath.json"

    if (-not (Test-Path -Path $logDir -PathType Container)) {
        # Create silently. A failure here is a logger failure; surface via
        # Write-Warning so we don't recurse into ourselves.
        try {
            $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop
        } catch {
            Write-Warning "Write-LabLog: cannot create log dir '$logDir': $($_.Exception.Message)"
            return
        }
    }

    # 3. Text log: tab-separated, ISO timestamp, fixed-width level, message.
    $isoStamp = $timestamp.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    $tab = "`t"
    $textLine = '{0}{4}{1,-8}{4}{2,-4}{4}{3}' -f $isoStamp, $Level, $tag, $Message, $tab

    try {
        Add-Content -Path $textPath -Value $textLine -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning "Write-LabLog: cannot write text log '$textPath': $($_.Exception.Message)"
    }

    # 4. JSON log (one record per line; jq-friendly).
    $jsonOff = $NoJson -or ($env:HOMELAB_LOG_NOJSON -eq '1')
    if (-not $jsonOff) {
        $record = [ordered]@{
            timestamp = $isoStamp
            level     = $Level
            tag       = $tag.Trim()
            message   = $Message
            pid       = $PID
            host      = $env:COMPUTERNAME
        }
        if ($Data) { $record['data'] = $Data }

        try {
            $json = $record | ConvertTo-Json -Compress -Depth 6
            Add-Content -Path $jsonPath -Value $json -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Warning "Write-LabLog: cannot write JSON log '$jsonPath': $($_.Exception.Message)"
        }
    }
}
