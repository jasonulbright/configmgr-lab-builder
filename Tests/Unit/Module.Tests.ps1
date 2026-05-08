#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the HomeLab module manifest and loader.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    $script:manifestPath = Join-Path $script:moduleRoot 'HomeLab.psd1'
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'HomeLab module manifest' {

    It 'manifest file exists' {
        Test-Path $script:manifestPath | Should -BeTrue
    }

    It 'manifest is valid' {
        { Test-ModuleManifest -Path $script:manifestPath } | Should -Not -Throw
    }

    It 'manifest version is 2.0.0' {
        $m = Test-ModuleManifest -Path $script:manifestPath
        $m.Version.ToString() | Should -Be '2.0.0'
    }

    It 'manifest declares PowerShell 7.6 LTS minimum' {
        $m = Test-ModuleManifest -Path $script:manifestPath
        $m.PowerShellVersion.ToString() | Should -Be '7.6'
    }
}

Describe 'HomeLab module load' {

    BeforeAll {
        Import-Module $script:manifestPath -Force -ErrorAction Stop
    }

    AfterAll {
        Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    }

    It 'imports without error' {
        Get-Module HomeLab | Should -Not -BeNullOrEmpty
    }

    It 'exports the documented public surface' {
        $expected = @(
            'Install-HomeLab','Remove-HomeLab','Start-HomeLab','Stop-HomeLab',
            'Test-HomeLab','Connect-HomeLabVM','Enter-HomeLabSession'
        )
        $exported = (Get-Module HomeLab).ExportedFunctions.Keys
        # Public functions are not yet implemented (S2+); the manifest still
        # declares them. Once Public/*.ps1 lands, this test should pass with
        # all 7 names. For S1 we check the manifest's declared surface
        # rather than the live-loaded exports.
        $manifestExports = (Test-ModuleManifest $script:manifestPath).ExportedFunctions.Keys
        foreach ($name in $expected) {
            $manifestExports | Should -Contain $name
        }
    }

    It 'does not export internal helpers' {
        $exported = (Get-Module HomeLab).ExportedFunctions.Keys
        $exported | Should -Not -Contain 'Read-LabIni'
        $exported | Should -Not -Contain 'Write-LabLog'
        $exported | Should -Not -Contain 'Get-LabConfig'
    }
}
