function Mount-LabIso {
    <#
    .SYNOPSIS
        Mount a Windows ISO and return the assigned drive letter.

    .DESCRIPTION
        Wraps Mount-DiskImage + Get-Volume into a single call that
        returns a pscustomobject with the IsoPath and DriveLetter so
        callers can read the mount contents. Always elevation-checks
        first because Mount-DiskImage requires admin.

        Use Dismount-LabIso to release. Both functions exist as
        Helpers so engine code can mock them in Pester (the underlying
        Get-Volume -DiskImage call binds against a CimInstance which
        can't be faked through a Pester mock without New-MockObject).

    .PARAMETER IsoPath
        Local path to the .iso file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IsoPath
    )

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "Mount-LabIso: ISO not found: $IsoPath"
    }
    if (-not (Test-LabIsElevated)) {
        throw 'Mount-LabIso: process must be elevated; Mount-DiskImage requires admin'
    }

    # Already-mounted? Reuse the existing letter instead of stacking
    # a second mount (which produces a no-letter DiskImage and trips
    # the rest of this function).
    $existing = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Attached) {
        $existingVol = Get-Volume -DiskImage $existing -ErrorAction SilentlyContinue
        if ($existingVol -and $existingVol.DriveLetter) {
            return [pscustomobject]@{
                IsoPath     = (Resolve-Path -LiteralPath $IsoPath).Path
                DriveLetter = [string]$existingVol.DriveLetter
                DriveRoot   = "$($existingVol.DriveLetter):"
            }
        }
        # Attached but no letter: clean state and re-mount below.
        try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null } catch { }
        Start-Sleep -Milliseconds 500
    }

    # Retry the mount + drive-letter probe up to 3 times. Windows
    # occasionally races and Get-Volume returns no letter on the first
    # call right after Mount-DiskImage.
    $disk = $null
    $vol = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $disk = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        for ($probe = 1; $probe -le 5; $probe++) {
            Start-Sleep -Milliseconds (500 * $probe)
            $vol = Get-Volume -DiskImage $disk -ErrorAction SilentlyContinue
            if ($vol -and $vol.DriveLetter) { break }
        }
        if ($vol -and $vol.DriveLetter) { break }
        # No letter after 5 probes: dismount and try the whole sequence again.
        try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null } catch { }
        Start-Sleep -Seconds 1
    }
    if (-not $vol -or -not $vol.DriveLetter) {
        try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null } catch { }
        throw "Mount-LabIso: '$IsoPath' mounted but no drive letter assigned after 3 retries"
    }

    return [pscustomobject]@{
        IsoPath     = (Resolve-Path -LiteralPath $IsoPath).Path
        DriveLetter = [string]$vol.DriveLetter
        DriveRoot   = "$($vol.DriveLetter):"
    }
}

function Dismount-LabIso {
    <#
    .SYNOPSIS
        Dismount a previously Mount-LabIso'd image. Idempotent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IsoPath
    )

    try {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop | Out-Null
    } catch {
        Write-LabLog "Dismount-LabIso: failed to dismount $IsoPath`: $($_.Exception.Message)" -Status WARN
    }
}
