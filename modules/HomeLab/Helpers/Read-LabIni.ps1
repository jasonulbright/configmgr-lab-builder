function Read-LabIni {
    <#
    .SYNOPSIS
        Parse a setup.exe-style INI file into an ordered hashtable.

    .DESCRIPTION
        Reads an INI file with [Section] headers and Key = Value pairs.
        Returns an ordered hashtable keyed by section name (no brackets), where
        each section's value is an ordered hashtable of keys to string values.

        Insertion order of sections and keys is preserved so a Read | Write
        round-trip produces a stable layout.

        Comments (lines starting with ; or #) and blank lines are ignored.
        Values may contain '='; only the first '=' is treated as the separator.
        Whitespace around the separator is trimmed; whitespace inside the value
        is preserved.

    .PARAMETER Path
        Absolute or relative path to the INI file.

    .EXAMPLE
        $cfg = Read-LabIni -Path C:\Install\ConfigurationFile-CM.ini
        $cfg['Options']['SiteCode']
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Read-LabIni: file not found: $Path"
    }

    $result = [ordered]@{}
    $currentSection = $null

    # Read line-by-line. Get-Content with -ReadCount 0 keeps memory bounded
    # for huge INIs but the CM unattend INI is ~30 lines, so this is fine.
    $lines = Get-Content -Path $Path -ErrorAction Stop
    $lineNo = 0

    foreach ($rawLine in $lines) {
        $lineNo++
        $line = $rawLine.Trim()

        # Skip blank and comment lines.
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line.StartsWith(';') -or $line.StartsWith('#')) { continue }

        # Section header: [Name]
        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $sectionName = $line.Substring(1, $line.Length - 2).Trim()
            if ([string]::IsNullOrEmpty($sectionName)) {
                throw "Read-LabIni: empty section header at line $lineNo in $Path"
            }
            if (-not $result.Contains($sectionName)) {
                $result[$sectionName] = [ordered]@{}
            }
            $currentSection = $sectionName
            continue
        }

        # Key = Value (split on first '=' only)
        $eq = $line.IndexOf('=')
        if ($eq -lt 0) {
            throw "Read-LabIni: malformed line $lineNo in $Path (no '='): $rawLine"
        }
        if ($null -eq $currentSection) {
            throw "Read-LabIni: key outside any section at line $lineNo in $Path"
        }

        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()

        if ([string]::IsNullOrEmpty($key)) {
            throw "Read-LabIni: empty key at line $lineNo in $Path"
        }

        $result[$currentSection][$key] = $val
    }

    return $result
}
