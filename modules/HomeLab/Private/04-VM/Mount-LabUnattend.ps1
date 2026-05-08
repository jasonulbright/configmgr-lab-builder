function Mount-LabUnattend {
    <#
    .SYNOPSIS
        Inject an Unattend.xml into a VHDX's Windows partition before
        first boot.

    .DESCRIPTION
        Mount-VHD the target VHDX, find the volume that contains a
        \Windows directory (the OS partition; differencing children of a
        sysprepped base will have exactly one), copy Unattend.xml into
        \Windows\Panther\Unattend.xml, dismount.

        Idempotent: replaces any existing Unattend.xml at the target path.
        Always dismounts on failure.

        Requires elevation (Mount-VHD).

    .PARAMETER VhdxPath
        Path to the differencing-child VHDX.

    .PARAMETER UnattendXmlPath
        Path to the Unattend.xml on the host (produced by New-Unattend or
        New-LabBaseUnattend).

    .EXAMPLE
        Mount-LabUnattend -VhdxPath C:\LabImages\CM01.vhdx `
                          -UnattendXmlPath C:\Temp\CM01-unattend.xml
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$VhdxPath,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$UnattendXmlPath
    )

    if (-not (Test-Path -Path $VhdxPath -PathType Leaf)) {
        throw "Mount-LabUnattend: VHDX not found: $VhdxPath"
    }
    if (-not (Test-Path -Path $UnattendXmlPath -PathType Leaf)) {
        throw "Mount-LabUnattend: Unattend.xml not found: $UnattendXmlPath"
    }

    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Mount-LabUnattend: process must be elevated; Mount-VHD requires admin'
    }

    # If a previous run died after Mount-VHD but before Dismount-VHD, the VHDX
    # is still attached and Mount-VHD throws "the file is in use". Detect and
    # dismount the stale mount before proceeding so Install-HomeLab can resume
    # cleanly after a partial failure.
    try {
        $existing = Get-VHD -Path $VhdxPath -ErrorAction Stop
        if ($existing.Attached) {
            Write-LabLog "Mount-LabUnattend: $VhdxPath was already mounted (stale from prior run); dismounting first" -Status WARN
            Dismount-VHD -Path $VhdxPath -ErrorAction Stop
        }
    } catch {
        # Get-VHD failure is not fatal; Mount-VHD below will raise the real
        # error if the file is genuinely unreadable.
        Write-LabLog "Mount-LabUnattend: pre-mount probe failed (continuing): $($_.Exception.Message)" -Level Verbose
    }

    $mounted = $false
    try {
        Write-LabLog "Mounting $VhdxPath" -Level Verbose
        $disk = Mount-VHD -Path $VhdxPath -Passthru -ErrorAction Stop | Get-Disk
        $mounted = $true

        $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction Stop |
            Where-Object { $_.DriveLetter }

        $osDrive = $null
        foreach ($p in $partitions) {
            $candidate = "$($p.DriveLetter):"
            if (Test-Path (Join-Path $candidate 'Windows')) {
                $osDrive = $candidate
                break
            }
        }
        if (-not $osDrive) {
            throw "Mount-LabUnattend: no \\Windows folder found on any partition of $VhdxPath"
        }

        $pantherDir = Join-Path "$osDrive\" 'Windows\Panther'
        if (-not (Test-Path $pantherDir)) {
            $null = New-Item -Path $pantherDir -ItemType Directory -Force
        }

        $target = Join-Path $pantherDir 'Unattend.xml'
        Copy-Item -Path $UnattendXmlPath -Destination $target -Force -ErrorAction Stop

        Write-LabLog "Injected Unattend.xml -> $target" -Status OK

    } finally {
        if ($mounted) {
            try {
                Dismount-VHD -Path $VhdxPath -ErrorAction Stop
                Write-LabLog "Dismounted $VhdxPath" -Level Verbose
            } catch {
                Write-LabLog "Mount-LabUnattend: dismount failed: $($_.Exception.Message)" -Status WARN
            }
        }
    }
}
