#requires -Module Pester
<#
.SYNOPSIS
    Tier-2-ISO integration: Resolve-IsoEdition against real Windows ISOs.

.DESCRIPTION
    Mounts the configured Server / Client ISO via Mount-DiskImage,
    runs Get-WindowsImage, validates the wildcard filter resolves to
    a sensible image index. Skipped when the gate env vars are unset
    or the ISO files are missing.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force

    $script:serverIso = $env:HOMELAB_INT_ISO_SERVER
    $script:clientIso = $env:HOMELAB_INT_ISO_CLIENT

    $script:serverGate = ($env:HOMELAB_INTEGRATION -eq '1') -and `
        $script:serverIso -and (Test-Path $script:serverIso)
    $script:clientGate = ($env:HOMELAB_INTEGRATION -eq '1') -and `
        $script:clientIso -and (Test-Path $script:clientIso)

    $script:cfg = if ($script:serverGate -or $script:clientGate) {
        InModuleScope HomeLab { Get-LabConfig }
    } else { $null }
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-IsoEdition against Windows Server ISO' -Tag 'Integration','Tier2-ISO' {

    It 'resolves the configured ServerOSFilter to an image index' -Skip:(-not $script:serverGate) {
        $cfg = $script:cfg
        $iso = $script:serverIso
        InModuleScope HomeLab -Parameters @{ Iso = $iso; Filter = $cfg.ServerOSFilter } {
            param($Iso, $Filter)
            $r = Resolve-IsoEdition -IsoPath $Iso -NameFilter $Filter
            $r.ImageIndex | Should -BeGreaterThan 0
            $r.ImageName  | Should -Match 'Server'
            $r.Architecture | Should -Be 'x64'
        }
    }
}

Describe 'Resolve-IsoEdition against Windows Client ISO' -Tag 'Integration','Tier2-ISO' {

    It 'resolves the configured ClientOSFilter to an image index' -Skip:(-not $script:clientGate) {
        $cfg = $script:cfg
        $iso = $script:clientIso
        InModuleScope HomeLab -Parameters @{ Iso = $iso; Filter = $cfg.ClientOSFilter } {
            param($Iso, $Filter)
            $r = Resolve-IsoEdition -IsoPath $Iso -NameFilter $Filter
            $r.ImageIndex | Should -BeGreaterThan 0
            $r.ImageName  | Should -Match 'Windows 1[01]'
        }
    }
}

Describe 'Get-LabBaseImageCacheKey deterministic on a real ISO' -Tag 'Integration','Tier2-ISO' {

    It 'returns the same 16-char key on two consecutive calls against the same ISO' -Skip:(-not $script:serverGate) {
        $iso = $script:serverIso
        InModuleScope HomeLab -Parameters @{ Iso = $iso } {
            param($Iso)
            $a = Get-LabBaseImageCacheKey -IsoPath $Iso -ImageIndex 4 -ImageName 'X'
            $b = Get-LabBaseImageCacheKey -IsoPath $Iso -ImageIndex 4 -ImageName 'X'
            $a | Should -Be $b
            $a.Length | Should -Be 16
        }
    }
}
