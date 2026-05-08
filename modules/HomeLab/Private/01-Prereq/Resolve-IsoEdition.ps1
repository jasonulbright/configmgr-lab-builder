function Resolve-IsoEdition {
    <#
    .SYNOPSIS
        Mount a Windows installer ISO and resolve a wildcard edition filter
        to a concrete WIM image index.

    .DESCRIPTION
        Mounts the ISO via Mount-DiskImage (requires admin), locates the
        sources/install.wim or sources/install.esd inside, enumerates images
        via Get-WindowsImage (DISM), and returns the first image whose
        ImageName matches the wildcard filter (sorted by ImageIndex
        descending so the highest-edition match wins).

        Always dismounts the ISO before returning.

        Returns [pscustomobject] with:
          IsoPath      - absolute path to the source ISO
          ImagePath    - absolute path to install.wim/.esd inside the mount
          ImageIndex   - integer DISM index
          ImageName    - exact image name string
          Architecture - x64 / x86 / ARM64
          Version      - OS version string from DISM (Windows.Image.Version)

        Throws on:
          - ISO not found / not mountable
          - No install.wim or install.esd inside
          - Filter matches zero images (lists available names in the error)
          - Process not elevated (Mount-DiskImage requires admin)

    .PARAMETER IsoPath
        Path to the .iso file.

    .PARAMETER NameFilter
        Wildcard pattern matched against ImageName, e.g.
        'Windows Server 2025*Desktop Experience*' or 'Windows 11*Enterprise*'.

    .EXAMPLE
        $r = Resolve-IsoEdition -IsoPath C:\LabSources\ISOs\WS2025.iso `
                                -NameFilter 'Windows Server 2025*Datacenter*Desktop Experience*'
        $r.ImageIndex   # 4
        $r.ImageName    # Windows Server 2025 Datacenter Evaluation (Desktop Experience)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$IsoPath,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$NameFilter
    )

    if (-not (Test-Path -Path $IsoPath -PathType Leaf)) {
        throw "Resolve-IsoEdition: ISO not found: $IsoPath"
    }

    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Resolve-IsoEdition: process must be elevated; Mount-DiskImage requires admin'
    }

    $mounted = $false
    $disk = $null
    try {
        Write-LabLog "Mounting ISO: $IsoPath" -Status RUN
        $disk = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $mounted = $true

        $vol = Get-Volume -DiskImage $disk -ErrorAction Stop
        if (-not $vol -or -not $vol.DriveLetter) {
            throw "ISO mounted but no drive letter assigned"
        }
        $drive = "$($vol.DriveLetter):"
        Write-LabLog "  mounted at $drive" -Level Verbose

        $wim = Join-Path $drive 'sources\install.wim'
        $esd = Join-Path $drive 'sources\install.esd'

        $imagePath = if (Test-Path $wim) { $wim }
                     elseif (Test-Path $esd) { $esd }
                     else {
                        throw "Resolve-IsoEdition: no sources\install.wim or install.esd found inside $IsoPath"
                     }

        $images = Get-WindowsImage -ImagePath $imagePath -ErrorAction Stop

        $matches = @($images | Where-Object { $_.ImageName -like $NameFilter })
        if ($matches.Count -eq 0) {
            $available = ($images | ForEach-Object { "  [$($_.ImageIndex)] $($_.ImageName)" }) -join "`n"
            throw ("Resolve-IsoEdition: no image in '$IsoPath' matches filter '$NameFilter'. Available:`n$available")
        }

        $pick = $matches | Sort-Object ImageIndex -Descending | Select-Object -First 1

        # Architecture and Version come from a deeper Get-WindowsImage call
        # against the specific index.
        $detail = Get-WindowsImage -ImagePath $imagePath -Index $pick.ImageIndex -ErrorAction Stop

        $arch = switch ([int]$detail.Architecture) {
            0       { 'x86' }
            5       { 'ARM' }
            9       { 'x64' }
            12      { 'ARM64' }
            default { "unknown($($detail.Architecture))" }
        }

        $result = [pscustomobject]@{
            IsoPath      = (Resolve-Path $IsoPath).Path
            ImagePath    = $imagePath
            ImageIndex   = [int]$pick.ImageIndex
            ImageName    = [string]$pick.ImageName
            Architecture = $arch
            Version      = [string]$detail.Version
        }

        Write-LabLog ("Resolved: [{0}] {1} ({2}, {3})" -f $result.ImageIndex, $result.ImageName, $result.Architecture, $result.Version) -Status OK
        return $result

    } finally {
        if ($mounted -and $disk) {
            try {
                Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop | Out-Null
                Write-LabLog "  dismounted $IsoPath" -Level Verbose
            } catch {
                Write-LabLog "Resolve-IsoEdition: failed to dismount $IsoPath`: $($_.Exception.Message)" -Status WARN
            }
        }
    }
}
