function Resolve-CMSetupLogStatus {
    <#
    .SYNOPSIS
        Pure function that scans an array of ConfigMgrSetup.log lines and
        returns the most recent terminal status.

    .DESCRIPTION
        Extracted from Test-CMSetupLog so the parsing logic is unit-
        testable on synthetic input. Walks the lines BACKWARDS so the
        last terminal phrase wins (re-runs of setup append to the same
        log without truncating).

        Returns [pscustomobject]:
          Status       - Success / Failure / InProgress
          MatchLine    - the line that drove the decision (empty for
                         InProgress)
          ErrorContext - up to 50 lines around the failure
          LineCount    - total lines inspected

    .PARAMETER Lines
        String array of log lines (already decoded from UTF-16LE).

    .EXAMPLE
        $lines = Get-Content C:\ConfigMgrSetup.log -Encoding Unicode
        Resolve-CMSetupLogStatus -Lines $lines
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    $totalLines = $Lines.Count

    if ($totalLines -eq 0) {
        return [pscustomobject]@{
            Status       = 'InProgress'
            MatchLine    = ''
            ErrorContext = ''
            LineCount    = 0
        }
    }

    $successPattern  = 'Configuration Manager Setup has successfully installed'
    $failurePatterns = @(
        'Configuration Manager Setup failed'
        'An error occurred while installing the database'
        'Setup was unable to verify Microsoft \.NET'
        'CRITICAL: Setup failed'
        # CM 2509's own terminal banner. Word order differs from the
        # 'Configuration Manager Setup failed' phrase above and none of the
        # other patterns cover it, so a hard setup failure was classified
        # InProgress and then buried under the full Wait-CMReady timeout.
        'Failed Configuration Manager (\w+ )?Setup'
        'Setup failed to download prerequisite components'
    )

    for ($i = $totalLines - 1; $i -ge 0; $i--) {
        $line = $Lines[$i]
        if ($line -match $successPattern) {
            return [pscustomobject]@{
                Status       = 'Success'
                MatchLine    = $line
                ErrorContext = ''
                LineCount    = $totalLines
            }
        }
        foreach ($p in $failurePatterns) {
            if ($line -match $p) {
                $start = [Math]::Max(0, $i - 25)
                $end   = [Math]::Min($totalLines - 1, $i + 25)
                $ctx   = ($Lines[$start..$end]) -join "`n"
                return [pscustomobject]@{
                    Status       = 'Failure'
                    MatchLine    = $line
                    ErrorContext = $ctx
                    LineCount    = $totalLines
                }
            }
        }
    }

    return [pscustomobject]@{
        Status       = 'InProgress'
        MatchLine    = ''
        ErrorContext = ''
        LineCount    = $totalLines
    }
}
