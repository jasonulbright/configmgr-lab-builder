function Wait-LabReady {
    <#
    .SYNOPSIS
        Generic predicate-based readiness gate.

    .DESCRIPTION
        Polls a script block until it returns truthy or the timeout elapses.
        Used wherever the engine waits on a slow async surface (SMS_EXECUTIVE,
        WinRM, CM provider, etc.) instead of sprinkling ad-hoc retry loops.

        Returns $true if the predicate became truthy, $false on timeout.
        Throws only if -ThrowOnTimeout is set.

    .PARAMETER Predicate
        Script block. Treated as "ready" when it returns a truthy value (any
        non-null, non-empty, non-zero value). Exceptions inside the predicate
        are caught and treated as "not ready yet" so transient WMI/WinRM
        failures don't end the wait.

        IMPORTANT: do NOT pass a `.GetNewClosure()` script block here. The
        closure rebinds SessionState to the caller's global scope, which
        breaks helper resolution (HomeLab's `Invoke-LabCommand` stops
        resolving and a same-named helper from any other module on the
        PSModulePath silently wins). Pass values via -ArgumentList instead.

    .PARAMETER ArgumentList
        Optional positional arguments forwarded to the predicate via
        `& $Predicate @ArgumentList`. Use this to capture values from the
        caller's scope; do not use `.GetNewClosure()` (see Predicate above).

    .PARAMETER TimeoutSeconds
        Hard ceiling. Default 600 (10 minutes).

    .PARAMETER IntervalSeconds
        Delay between polls. Default 5.

    .PARAMETER Activity
        Short label written via Write-LabLog at start, on success, and on
        timeout. Pass $null to suppress logging.

    .PARAMETER ThrowOnTimeout
        Throw a TimeoutException on timeout instead of returning $false.

    .EXAMPLE
        Wait-LabReady -Activity 'CM provider' -TimeoutSeconds 360 -Predicate {
            try { Get-CimInstance -Namespace 'ROOT\SMS\site_MCM' -ClassName SMS_Site -ErrorAction Stop } catch { $null }
        }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$Predicate,

        [Parameter()]
        [object[]]$ArgumentList,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 600,

        [Parameter()]
        [ValidateRange(1, 600)]
        [int]$IntervalSeconds = 5,

        [Parameter()]
        [string]$Activity = 'readiness gate',

        [Parameter()]
        [switch]$ThrowOnTimeout
    )

    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSeconds)

    if ($Activity) {
        Write-LabLog "Waiting for $Activity (timeout ${TimeoutSeconds}s, interval ${IntervalSeconds}s)" -Status RUN
    }

    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        $result = $null
        try {
            if ($PSBoundParameters.ContainsKey('ArgumentList') -and $ArgumentList) {
                $result = & $Predicate @ArgumentList
            } else {
                $result = & $Predicate
            }
        } catch {
            $result = $null
            if ($Activity) {
                Write-LabLog "  attempt $attempt failed: $($_.Exception.Message)" -Level Verbose
            }
        }

        if ($result) {
            if ($Activity) {
                $elapsed = ((Get-Date) - $start).TotalSeconds
                Write-LabLog ("$Activity ready after attempt {0} ({1:F1}s)" -f $attempt, $elapsed) -Status OK
            }
            return $true
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    if ($Activity) {
        Write-LabLog "$Activity not ready after ${TimeoutSeconds}s (${attempt} attempts)" -Status FAIL
    }

    if ($ThrowOnTimeout) {
        throw [System.TimeoutException]::new("Wait-LabReady: '$Activity' did not become ready within ${TimeoutSeconds}s")
    }

    return $false
}
