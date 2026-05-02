#requires -Module Pester
<#
.SYNOPSIS
    Tier-2 integration: Test-HostPrereq against the actual host.

.DESCRIPTION
    Skipped when $env:HOMELAB_INTEGRATION is unset. When run, validates
    that the report shape matches what Install-HomeLab consumes and
    that PSVersion / RAM / VirtExtensions checks return real values
    instead of the unit-test placeholders.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force

    $script:gate = ($env:HOMELAB_INTEGRATION -eq '1')
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Test-HostPrereq integration' -Tag 'Integration','Tier2' {

    It 'returns a populated report on the live host' -Skip:(-not $script:gate) {
        InModuleScope HomeLab {
            $r = Test-HostPrereq
            $r              | Should -Not -BeNullOrEmpty
            $r.Checks.Count | Should -BeGreaterOrEqual 6
            $r.Checks.PSVersion.Value | Should -Match '^\d+\.\d+'
            $r.Checks.RAM.Value       | Should -Match '\d+GB'
        }
    }

    It 'reports HyperVFeature accurately for the current host' -Skip:(-not $script:gate) {
        InModuleScope HomeLab {
            $r = Test-HostPrereq
            $hv = $r.Checks.HyperVFeature
            $hv.Value | Should -Not -BeNullOrEmpty

            # Ground truth: query the OS directly. Server vs Client SKU
            # picks the API.
            $os = Get-CimInstance Win32_OperatingSystem
            if ($os.ProductType -eq 1) {
                $live = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
                $expected = ($live.State -eq 'Enabled')
            } else {
                $live = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
                $expected = ($live.InstallState -eq 'Installed')
            }

            $hv.Pass | Should -Be $expected
        }
    }

    It 'fails Elevation check when -RequireElevation runs in a non-elevated session' -Skip:(-not $script:gate) {
        InModuleScope HomeLab {
            $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
            $isElevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

            $r = Test-HostPrereq -RequireElevation
            $r.Checks.Elevation.Pass | Should -Be $isElevated
        }
    }
}
