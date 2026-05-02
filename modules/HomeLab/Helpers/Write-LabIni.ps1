function Write-LabIni {
    <#
    .SYNOPSIS
        Serialize an ordered hashtable to a setup.exe-style INI file.

    .DESCRIPTION
        Writes the data structure produced by Read-LabIni back to disk in a
        format compatible with CM 2509 setup.exe /script and SQL Server
        ConfigurationFile.ini.

        Default encoding is ASCII because CM/SQL setup.exe parsers do not
        accept a UTF-8 BOM. Override -Encoding only when the consumer is known
        to handle other encodings.

        Section order and key order within each section follow insertion order
        of the input dictionary, so a Read | Write round-trip produces stable
        output.

    .PARAMETER Data
        Ordered or regular hashtable. Outer keys are section names (no
        brackets); inner values must be IDictionary mapping key to value.

    .PARAMETER Path
        Output file path. Will overwrite if it exists.

    .PARAMETER Encoding
        File encoding. Default ASCII. Use 'UTF8' (no BOM via System.Text.UTF8Encoding(false)),
        'Unicode', etc. only when the consuming tool supports it.

    .EXAMPLE
        $cfg = [ordered]@{
            Identification    = [ordered]@{ Action = 'InstallPrimarySite' }
            Options           = [ordered]@{ ProductID = 'EVAL'; SiteCode = 'MCM' }
            SQLConfigOptions  = [ordered]@{ SQLServerName = 'CM01'; DatabaseName = 'CM_MCM' }
        }
        Write-LabIni -Data $cfg -Path C:\Install\ConfigurationFile-CM.ini
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [System.Collections.IDictionary]$Data,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [ValidateSet('ASCII','UTF8','UTF8NoBOM','Unicode','UTF7','UTF32','BigEndianUnicode','Default','OEM')]
        [string]$Encoding = 'ASCII'
    )

    # Build the full string in memory then write once. Avoids partial files on
    # error and keeps round-trip determinism (no trailing whitespace surprises
    # from streaming Add-Content).
    $sb = [System.Text.StringBuilder]::new()

    $first = $true
    foreach ($sectionEntry in $Data.GetEnumerator()) {
        $sectionName = $sectionEntry.Key
        $sectionData = $sectionEntry.Value

        if (-not ($sectionData -is [System.Collections.IDictionary])) {
            throw "Write-LabIni: section '$sectionName' value must be IDictionary, got $($sectionData.GetType().FullName)"
        }

        if (-not $first) { [void]$sb.AppendLine() }
        $first = $false

        [void]$sb.Append('[').Append($sectionName).Append(']').AppendLine()

        foreach ($kvp in $sectionData.GetEnumerator()) {
            [void]$sb.Append($kvp.Key).Append(' = ').Append([string]$kvp.Value).AppendLine()
        }
    }

    # Resolve the .NET encoding. Use UTF8(false) for UTF8NoBOM; PS 5.1's
    # 'UTF8' string in Set-Content emits a BOM, which CM setup.exe rejects.
    $encObj = switch ($Encoding) {
        'ASCII'             { [System.Text.Encoding]::ASCII }
        'UTF8'              { New-Object System.Text.UTF8Encoding($true) }
        'UTF8NoBOM'         { New-Object System.Text.UTF8Encoding($false) }
        'Unicode'           { [System.Text.Encoding]::Unicode }
        'UTF7'              { [System.Text.Encoding]::UTF7 }
        'UTF32'             { [System.Text.Encoding]::UTF32 }
        'BigEndianUnicode'  { [System.Text.Encoding]::BigEndianUnicode }
        'Default'           { [System.Text.Encoding]::Default }
        'OEM'               { [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
    }

    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $encObj)
}
