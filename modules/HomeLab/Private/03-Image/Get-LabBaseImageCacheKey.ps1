function Get-LabBaseImageCacheKey {
    <#
    .SYNOPSIS
        Compute the deterministic cache filename for a base image.

    .DESCRIPTION
        The base image cache lives at $LabImagePath\<hash>.base.vhdx. The
        hash is a SHA-256 over the inputs that should invalidate the cached
        image:
          - ISO file size (long)
          - ISO file LastWriteTime (UTC ticks)
          - ImageIndex (int)
          - ImageName (string)
          - Optional LcuLevel (string)

        ISO path is intentionally NOT in the hash so that moving the same ISO
        to a different folder doesn't rebuild. The file size + LastWriteTime
        pair is a reliable identity proxy without paying for a SHA-256 over
        the multi-GB ISO contents.

        Returns the truncated 16-character hex form by default (32 hex chars
        is overkill for filename uniqueness in a single host's cache dir).

    .PARAMETER IsoPath
        Path to the ISO file. Used to read file size and LastWriteTime; the
        path itself is NOT part of the hash.

    .PARAMETER ImageIndex
        DISM image index inside the ISO's install.wim/install.esd.

    .PARAMETER ImageName
        Full ImageName string from Get-WindowsImage.

    .PARAMETER LcuLevel
        Optional string identifying applied cumulative updates. When the
        caller has a deterministic LCU id (e.g. KB number or hash of the .msu
        file path), pass it here to invalidate the cache after a Windows
        Update.

    .PARAMETER FullHash
        Return the full 64-char SHA-256 hash instead of the 16-char truncated
        form.

    .EXAMPLE
        Get-LabBaseImageCacheKey -IsoPath C:\ISOs\WS2025.iso -ImageIndex 4 -ImageName 'Windows Server 2025 Datacenter Evaluation (Desktop Experience)'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IsoPath,

        [Parameter(Mandatory)]
        [int]$ImageIndex,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ImageName,

        [Parameter()]
        [string]$LcuLevel = '',

        [Parameter()]
        [switch]$FullHash
    )

    if (-not (Test-Path -Path $IsoPath -PathType Leaf)) {
        throw "Get-LabBaseImageCacheKey: ISO not found: $IsoPath"
    }

    $isoFile = Get-Item -Path $IsoPath
    $material = '{0}|{1}|{2}|{3}|{4}' -f `
        $isoFile.Length,
        $isoFile.LastWriteTimeUtc.Ticks,
        $ImageIndex,
        $ImageName,
        $LcuLevel

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }

    $hex = -join ($hash | ForEach-Object { '{0:x2}' -f $_ })
    if ($FullHash) { return $hex }
    return $hex.Substring(0, 16)
}
