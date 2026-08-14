#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Test-LabMedia. The resolution rules must mirror
    Install-HomeLab's defaults (ISO wildcard patterns, canonical-then-
    flat fallbacks, nested CM SMSSETUP detection); these tests pin each
    rule so a drift between the two shows up as a red test rather than
    a pre-flight report that disagrees with the engine.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop

    function New-MediaFixture {
        param([string]$Root)
        New-Item -ItemType Directory -Force -Path (Join-Path $Root 'ISOs') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $Root 'SoftwarePackages') | Out-Null
        $Root
    }
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Test-LabMedia on an empty tree' {

    BeforeAll {
        $script:root = New-MediaFixture -Root (Join-Path $TestDrive 'empty')
        $script:report = Test-LabMedia -LabSourcesRoot $script:root
    }

    It 'reports every required item missing' {
        $script:report.Pass | Should -BeFalse
        $script:report.RequiredMissing | Should -Be 8
    }

    It 'returns nine items total (eight required + optional prereq cache)' {
        @($script:report.Items).Count | Should -Be 9
        @($script:report.Items | Where-Object Required).Count | Should -Be 8
    }

    It 'marks the CM prerequisite cache optional so it never fails the gate' {
        $cache = $script:report.Items | Where-Object Id -eq 'CMPreReqs'
        $cache.Required | Should -BeFalse
        $cache.Found | Should -BeFalse
    }

    It 'gives every required item a target folder and a download page' {
        foreach ($item in ($script:report.Items | Where-Object Required)) {
            $item.TargetDir | Should -Not -BeNullOrEmpty
            $item.DownloadUrl | Should -Not -BeNullOrEmpty
        }
    }

    It 'offers direct-download metadata only for the direct-link assets' {
        ($script:report.Items | Where-Object Id -eq 'Odbc').AutoFiles.Count | Should -Be 1
        ($script:report.Items | Where-Object Id -eq 'VcRedist').AutoFiles.Count | Should -Be 2
        ($script:report.Items | Where-Object Id -eq 'AdkLayout').LayoutSetupUrl | Should -Not -BeNullOrEmpty
        ($script:report.Items | Where-Object Id -eq 'AdkPeLayout').LayoutSetupName | Should -Be 'adkwinpesetup.exe'
        ($script:report.Items | Where-Object Id -eq 'ServerIso').AutoFiles.Count | Should -Be 0
        ($script:report.Items | Where-Object Id -eq 'CMSource').AutoFiles.Count | Should -Be 0
    }
}

Describe 'Test-LabMedia on a fully staged tree' {

    BeforeAll {
        $root = New-MediaFixture -Root (Join-Path $TestDrive 'staged')
        $isos = Join-Path $root 'ISOs'
        $sw   = Join-Path $root 'SoftwarePackages'

        # ISO names taken from real Microsoft eval downloads, including the
        # 25H2 CLIENTENTERPRISEEVAL client naming.
        Set-Content -Path (Join-Path $isos '26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso') -Value 'x'
        Set-Content -Path (Join-Path $isos '26200.6584.250915-1905.25h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso') -Value 'x'
        Set-Content -Path (Join-Path $isos 'SQLServer2022-x64-ENU-Dev.iso') -Value 'x'

        New-Item -ItemType Directory -Force -Path (Join-Path $sw 'CM\ConfigMgr_2509\SMSSETUP') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $sw 'ADK\Offline\Installers') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $sw 'ADKPE\Offline\Installers') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $sw 'VCRedist') | Out-Null
        Set-Content -Path (Join-Path $sw 'VCRedist\vc_redist.x64.exe') -Value 'x'
        Set-Content -Path (Join-Path $sw 'VCRedist\vc_redist.x86.exe') -Value 'x'
        New-Item -ItemType Directory -Force -Path (Join-Path $sw 'ODBC') | Out-Null
        Set-Content -Path (Join-Path $sw 'ODBC\msodbcsql.msi') -Value 'x'

        $script:report = Test-LabMedia -LabSourcesRoot $root
    }

    It 'passes with zero required items missing' {
        $script:report.Pass | Should -BeTrue
        $script:report.RequiredMissing | Should -Be 0
    }

    It 'resolves the nested CM layout to the SMSSETUP parent' {
        $cm = $script:report.Items | Where-Object Id -eq 'CMSource'
        $cm.Found | Should -BeTrue
        $cm.Path | Should -BeLike '*ConfigMgr_2509'
    }

    It 'matches the 25H2 CLIENTENTERPRISEEVAL client ISO naming' {
        ($script:report.Items | Where-Object Id -eq 'ClientIso').Found | Should -BeTrue
    }
}

Describe 'Test-LabMedia fallback and partial-staging rules' {

    It 'accepts the flat SoftwarePackages ODBC layout' {
        $root = New-MediaFixture -Root (Join-Path $TestDrive 'flat-odbc')
        Set-Content -Path (Join-Path $root 'SoftwarePackages\msodbcsql.msi') -Value 'x'
        $report = Test-LabMedia -LabSourcesRoot $root
        $odbc = $report.Items | Where-Object Id -eq 'Odbc'
        $odbc.Found | Should -BeTrue
        $odbc.Path | Should -BeLike '*SoftwarePackages\msodbcsql.msi'
    }

    It 'prefers the canonical ODBC subfolder over the flat file' {
        $root = New-MediaFixture -Root (Join-Path $TestDrive 'canon-odbc')
        $sw = Join-Path $root 'SoftwarePackages'
        New-Item -ItemType Directory -Force -Path (Join-Path $sw 'ODBC') | Out-Null
        Set-Content -Path (Join-Path $sw 'ODBC\msodbcsql.msi') -Value 'x'
        Set-Content -Path (Join-Path $sw 'msodbcsql.msi') -Value 'x'
        $report = Test-LabMedia -LabSourcesRoot $root
        ($report.Items | Where-Object Id -eq 'Odbc').Path | Should -BeLike '*ODBC\msodbcsql.msi'
    }

    It 'flags a VC++ pair split across folders (engine resolves one directory only)' {
        $root = New-MediaFixture -Root (Join-Path $TestDrive 'vc-split')
        $sw = Join-Path $root 'SoftwarePackages'
        New-Item -ItemType Directory -Force -Path (Join-Path $sw 'VCRedist') | Out-Null
        Set-Content -Path (Join-Path $sw 'VCRedist\vc_redist.x64.exe') -Value 'x'
        Set-Content -Path (Join-Path $sw 'vc_redist.x86.exe') -Value 'x'
        $report = Test-LabMedia -LabSourcesRoot $root
        $vc = $report.Items | Where-Object Id -eq 'VcRedist'
        $vc.Found | Should -BeFalse
        $vc.Detail | Should -BeLike '*vc_redist.x86.exe*'
    }

    It 'accepts the flat VC++ layout when the canonical folder is absent' {
        $root = New-MediaFixture -Root (Join-Path $TestDrive 'vc-flat')
        $sw = Join-Path $root 'SoftwarePackages'
        Set-Content -Path (Join-Path $sw 'vc_redist.x64.exe') -Value 'x'
        Set-Content -Path (Join-Path $sw 'vc_redist.x86.exe') -Value 'x'
        ((Test-LabMedia -LabSourcesRoot $root).Items | Where-Object Id -eq 'VcRedist').Found | Should -BeTrue
    }

    It 'treats an empty ADK layout folder as missing' {
        $root = New-MediaFixture -Root (Join-Path $TestDrive 'adk-empty')
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'SoftwarePackages\ADK\Offline') | Out-Null
        ((Test-LabMedia -LabSourcesRoot $root).Items | Where-Object Id -eq 'AdkLayout').Found | Should -BeFalse
    }

    It 'ignores a CM folder without SMSSETUP anywhere' {
        $root = New-MediaFixture -Root (Join-Path $TestDrive 'cm-junk')
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'SoftwarePackages\CM\NotMedia') | Out-Null
        ((Test-LabMedia -LabSourcesRoot $root).Items | Where-Object Id -eq 'CMSource').Found | Should -BeFalse
    }

    It 'finds SMSSETUP directly at the CM root (pre-extracted flat layout)' {
        $root = New-MediaFixture -Root (Join-Path $TestDrive 'cm-flat')
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'SoftwarePackages\CM\SMSSETUP') | Out-Null
        $cm = (Test-LabMedia -LabSourcesRoot $root).Items | Where-Object Id -eq 'CMSource'
        $cm.Found | Should -BeTrue
        $cm.Path | Should -BeLike '*\CM'
    }

    It 'recognises each CM prereq cache folder candidate' {
        foreach ($name in 'CM-Prereqs', 'CMPrereqs', 'CM-Prereqs-2509-CB') {
            $root = New-MediaFixture -Root (Join-Path $TestDrive "cache-$name")
            New-Item -ItemType Directory -Force -Path (Join-Path $root "SoftwarePackages\$name") | Out-Null
            ((Test-LabMedia -LabSourcesRoot $root).Items | Where-Object Id -eq 'CMPreReqs').Found | Should -BeTrue
        }
    }
}
