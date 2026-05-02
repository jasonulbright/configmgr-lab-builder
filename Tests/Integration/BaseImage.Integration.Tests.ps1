#requires -Module Pester
<#
.SYNOPSIS
    Tier-3 integration: New-LabBaseImage end-to-end build.

.DESCRIPTION
    The keystone integration test. Builds a sysprepped base VHDX from
    a real Windows ISO, end-to-end:
      Mount-DiskImage -> Get-WindowsImage -> New-VHD -> partition ->
      Expand-WindowsImage -> bcdboot UEFI -> inject Unattend.xml ->
      boot temp VM -> wait for sysprep /generalize /shutdown -> rename
      to <hash>.base.vhdx.

    Skipped unless HOMELAB_E2E=1 and an ISO is configured. Typical
    runtime: 25-40 minutes.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force

    $script:iso = $env:HOMELAB_INT_ISO_CLIENT
    $script:gate = ($env:HOMELAB_E2E -eq '1') -and `
        $script:iso -and (Test-Path $script:iso)
    $script:imagePath = Join-Path $env:TEMP ('homelab-int-' + [guid]::NewGuid().ToString('N').Substring(0,8))

    $script:cfg = if ($script:gate) {
        InModuleScope HomeLab { Get-LabConfig }
    } else { $null }
}

AfterAll {
    if (Test-Path $script:imagePath) {
        Remove-Item $script:imagePath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-LabBaseImage end-to-end' -Tag 'Integration','Tier3','LongRun' {

    It 'produces a sysprepped VHDX the next phase can consume' -Skip:(-not $script:gate) {
        $iso = $script:iso
        $cfg = $script:cfg
        $imagePath = $script:imagePath

        $result = InModuleScope HomeLab -Parameters @{
            Iso = $iso; Filter = $cfg.ClientOSFilter
            Pass = $cfg.AdminPass; ImagePath = $imagePath
        } {
            param($Iso, $Filter, $Pass, $ImagePath)
            New-LabBaseImage `
                -IsoPath $Iso -NameFilter $Filter `
                -LabImagePath $ImagePath `
                -AdministratorPassword $Pass `
                -SizeGB 50
        }

        $result.Path | Should -Exist
        $result.CacheKey.Length | Should -Be 16
        $result.Sysprepped | Should -BeTrue
        $result.CacheHit   | Should -BeFalse

        # Cache hit on the second invocation
        $second = InModuleScope HomeLab -Parameters @{
            Iso = $iso; Filter = $cfg.ClientOSFilter
            Pass = $cfg.AdminPass; ImagePath = $imagePath
        } {
            param($Iso, $Filter, $Pass, $ImagePath)
            New-LabBaseImage `
                -IsoPath $Iso -NameFilter $Filter `
                -LabImagePath $ImagePath `
                -AdministratorPassword $Pass `
                -SizeGB 50
        }

        $second.CacheHit | Should -BeTrue
        $second.Path     | Should -Be $result.Path
    }
}
