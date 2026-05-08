# HomeLab module loader.
# Dot-sources Helpers/, Private/**, and Public/ in order so that helpers are
# available before any private or public function references them.

$ErrorActionPreference = 'Stop'

# Defensive: AutomatedLab* modules export commands whose names collide with
# our helpers (Invoke-LabCommand, New-LabVM, New-LabVhdx, Wait-LabVM,
# Install-LabHyperV). When a script block escapes module scope -- which
# happens any time `.GetNewClosure()` is applied or a predicate is invoked
# from a runspace pool -- our helpers stop resolving and AL's versions get
# called instead. AL's Invoke-LabCommand silently fails when no AL Lab is
# loaded, masking the real issue. Unload AL up front to prevent shadowing.
$alLoaded = Get-Module 'AutomatedLab*' -ErrorAction SilentlyContinue
if ($alLoaded) {
    foreach ($m in $alLoaded) {
        Remove-Module -ModuleInfo $m -Force -ErrorAction SilentlyContinue
    }
}

$root = $PSScriptRoot

# Load order matters: Helpers first (they have no internal deps), then Private
# (organized by phase 01..10), then Public (the exported surface).
$loadDirs = @(
    (Join-Path $root 'Helpers')
    (Join-Path $root 'Private')
    (Join-Path $root 'Public')
)

foreach ($dir in $loadDirs) {
    if (-not (Test-Path $dir)) { continue }
    $files = Get-ChildItem -Path $dir -Filter '*.ps1' -Recurse -File |
        Sort-Object FullName
    foreach ($file in $files) {
        try {
            . $file.FullName
        } catch {
            throw "HomeLab: failed to dot-source '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

# Public surface is declared in HomeLab.psd1 FunctionsToExport. The manifest
# is the single source of truth; do not Export-ModuleMember from here.
