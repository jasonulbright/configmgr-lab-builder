#requires -Module Pester
<#
.SYNOPSIS
    Tests for source ISO auto-discovery.
#>

BeforeAll {
    $script:repoRoot    = Resolve-Path "$PSScriptRoot\..\.."
    $script:helpersRoot = Join-Path $script:repoRoot 'modules\HomeLab\Helpers'
    . (Join-Path $script:helpersRoot 'Find-LabIsoPath.ps1')
}

Describe 'Find-LabIsoPath' {

    It 'matches any supplied wildcard pattern without using multi-value -Filter' {
        $dir = Join-Path $TestDrive 'isos'
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $dir '26200.CLIENTENTERPRISEEVAL.iso') -ItemType File | Out-Null

        $found = Find-LabIsoPath -Directory $dir -Patterns @(
            '*WIN11*EVAL*.iso'
            '*CLIENTENTERPRISE*EVAL*.iso'
        )

        Split-Path -Leaf $found | Should -Be '26200.CLIENTENTERPRISEEVAL.iso'
    }

    It 'returns null when the directory is missing' {
        Find-LabIsoPath -Directory (Join-Path $TestDrive 'missing') -Patterns @('*.iso') |
            Should -BeNullOrEmpty
    }
}

Describe 'Find-LabIsoPath against live C:\LabSources\ISOs' {
    It 'finds the Server eval ISO' -Skip:(-not (Test-Path 'C:\LabSources\ISOs')) {
        $script:isoRoot = 'C:\LabSources\ISOs'
        $found = Find-LabIsoPath -Directory $script:isoRoot -Patterns @('*SERVER*EVAL*.iso')
        Split-Path -Leaf $found | Should -Be '26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso'
    }

    It 'finds the Windows Client Enterprise Eval ISO' -Skip:(-not (Test-Path 'C:\LabSources\ISOs')) {
        $script:isoRoot = 'C:\LabSources\ISOs'
        $found = Find-LabIsoPath -Directory $script:isoRoot -Patterns @(
            '*WIN11*EVAL*.iso'
            '*Windows*11*Eval*.iso'
            '*CLIENTENTERPRISE*EVAL*.iso'
        )
        Split-Path -Leaf $found | Should -Be '26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso'
    }

    It 'finds the SQL Server 2022 ISO' -Skip:(-not (Test-Path 'C:\LabSources\ISOs')) {
        $script:isoRoot = 'C:\LabSources\ISOs'
        $found = Find-LabIsoPath -Directory $script:isoRoot -Patterns @('*SQL*2022*.iso')
        Split-Path -Leaf $found | Should -Be 'SQLServer2022-x64-ENU.iso'
    }
}
