function Set-LabHostsEntries {
    <#
    .SYNOPSIS
        Ensure the host's hosts file resolves every lab VM name to its
        lab IP. Idempotent.

    .DESCRIPTION
        The engine connects to lab VMs by name (New-PSSession CM01,
        DC01.contoso.com, ...) from a host that is NOT joined to the lab
        domain and whose DNS knows nothing about it. Until 2026-07 the
        scripts silently assumed name resolution existed -- on the real
        host it only worked because someone had hand-added hosts-file
        entries. This function makes the engine own that dependency:
        Phase 02-Network writes one managed line per VM, and
        Remove-LabHostsEntries strips them at teardown.

        Managed lines carry the trailing marker '# HomeLab-managed'.
        Any pre-existing line -- managed or hand-made -- that resolves
        one of the target names is replaced, so a stale IP can't shadow
        the new lab.

        Writing %SystemRoot%\System32\drivers\etc\hosts requires
        elevation; callers (Install-HomeLab) are already elevated.

    .PARAMETER Entries
        Array of @{ IP = '192.168.50.10'; Names = @('DC01','DC01.contoso.com') }.

    .PARAMETER Path
        Hosts file path override (for tests). Default: the system hosts file.

    .EXAMPLE
        Set-LabHostsEntries -Entries @(
            @{ IP = '192.168.50.10'; Names = @('DC01','DC01.contoso.com') }
        )
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Entries,

        [Parameter()]
        [string]$Path = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')
    )

    $marker = '# HomeLab-managed'

    $targetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Entries) {
        foreach ($n in @($e.Names)) { $null = $targetNames.Add($n) }
    }

    $lines = if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path) } else { @() }

    $kept = foreach ($line in $lines) {
        if ($line -match [regex]::Escape($marker)) { continue }
        # Non-comment lines: token 0 is the IP, remaining tokens are
        # hostnames. Drop the line if ANY of its names is one we manage
        # (a stale hand-made entry would otherwise shadow the lab).
        $content = ($line -split '#', 2)[0].Trim()
        if ($content) {
            $tokens = $content -split '\s+'
            $names = @($tokens | Select-Object -Skip 1)
            if (@($names | Where-Object { $targetNames.Contains($_) }).Count -gt 0) { continue }
        }
        $line
    }

    $added = foreach ($e in $Entries) {
        '{0}{1}{2} {3}' -f $e.IP, "`t", (@($e.Names) -join ' '), $marker
    }

    $newContent = @($kept) + @($added)
    try {
        # PS7 'utf8' is BOM-less, which is what the hosts parser wants.
        Set-Content -LiteralPath $Path -Value $newContent -Encoding utf8 -ErrorAction Stop
    } catch {
        throw "Set-LabHostsEntries: cannot write '$Path' (elevation required): $($_.Exception.Message)"
    }

    Write-LabLog "hosts file: $($Entries.Count) lab entr$(if ($Entries.Count -eq 1) {'y'} else {'ies'}) written ($Path)" -Status OK
    return [pscustomobject]@{
        Path    = $Path
        Written = $Entries.Count
        Removed = ($lines.Count - @($kept).Count)
    }
}

function Remove-LabHostsEntries {
    <#
    .SYNOPSIS
        Remove lab entries from the hosts file: every '# HomeLab-managed'
        line, plus any unmanaged line that resolves one of the given
        names (hand-made entries from before the engine owned this).

    .PARAMETER Names
        Hostnames whose lines should be removed even without the marker.

    .PARAMETER Path
        Hosts file path override (for tests).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string[]]$Names = @(),

        [Parameter()]
        [string]$Path = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')
    )

    $marker = '# HomeLab-managed'
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Path = $Path; Removed = 0 }
    }

    $nameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $Names) { $null = $nameSet.Add($n) }

    $lines = @(Get-Content -LiteralPath $Path)
    $kept = foreach ($line in $lines) {
        if ($line -match [regex]::Escape($marker)) { continue }
        $content = ($line -split '#', 2)[0].Trim()
        if ($content) {
            $tokens = $content -split '\s+'
            $lineNames = @($tokens | Select-Object -Skip 1)
            if (@($lineNames | Where-Object { $nameSet.Contains($_) }).Count -gt 0) { continue }
        }
        $line
    }

    $removed = $lines.Count - @($kept).Count
    if ($removed -gt 0) {
        try {
            Set-Content -LiteralPath $Path -Value @($kept) -Encoding utf8 -ErrorAction Stop
        } catch {
            throw "Remove-LabHostsEntries: cannot write '$Path' (elevation required): $($_.Exception.Message)"
        }
        Write-LabLog "hosts file: removed $removed lab entr$(if ($removed -eq 1) {'y'} else {'ies'}) ($Path)" -Status OK
    }
    return [pscustomobject]@{ Path = $Path; Removed = $removed }
}
