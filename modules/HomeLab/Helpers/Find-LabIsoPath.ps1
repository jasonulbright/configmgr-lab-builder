function Find-LabIsoPath {
    <#
    .SYNOPSIS
        Find the first ISO under a source directory matching any name pattern.

    .DESCRIPTION
        Get-ChildItem -Filter accepts only a single string. This helper keeps
        ISO auto-discovery readable while supporting multiple filename patterns
        such as older Win11 eval names and the newer CLIENTENTERPRISEEVAL names.

    .PARAMETER Directory
        Directory to scan.

    .PARAMETER Patterns
        One or more wildcard patterns matched against ISO file names.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Directory,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Patterns
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $null
    }

    # Don't use $matches as a regular variable -- it's a PowerShell
    # automatic populated by the -match operator and reusing it is a
    # latent shadow-trap.
    $isos = foreach ($iso in Get-ChildItem -LiteralPath $Directory -Filter '*.iso' -File -ErrorAction SilentlyContinue) {
        foreach ($pattern in $Patterns) {
            if ($iso.Name -like $pattern) {
                $iso
                break
            }
        }
    }

    $first = @($isos | Sort-Object Name | Select-Object -First 1)
    if ($first.Count -eq 0) { return $null }
    return [string]$first[0].FullName
}
