#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Set-LabHostsEntries / Remove-LabHostsEntries.
    All tests run against a temp file via -Path; the system hosts file
    is never touched.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Set-LabHostsEntries' {

    BeforeEach {
        $script:hostsPath = Join-Path $TestDrive 'hosts'
    }

    It 'writes managed entries into a fresh file' {
        InModuleScope HomeLab -Parameters @{ Path = $script:hostsPath } {
            param($Path)
            $r = Set-LabHostsEntries -Path $Path -Entries @(
                @{ IP = '192.168.50.10'; Names = @('DC01','DC01.contoso.com') }
                @{ IP = '192.168.50.20'; Names = @('CM01','CM01.contoso.com') }
            )
            $r.Written | Should -Be 2
            $lines = Get-Content $Path
            $lines | Should -Contain "192.168.50.10`tDC01 DC01.contoso.com # HomeLab-managed"
            $lines | Should -Contain "192.168.50.20`tCM01 CM01.contoso.com # HomeLab-managed"
        }
    }

    It 'is idempotent: re-running produces the same file' {
        InModuleScope HomeLab -Parameters @{ Path = $script:hostsPath } {
            param($Path)
            $entries = @(@{ IP = '192.168.50.10'; Names = @('DC01','DC01.contoso.com') })
            $null = Set-LabHostsEntries -Path $Path -Entries $entries
            $first = Get-Content $Path -Raw
            $null = Set-LabHostsEntries -Path $Path -Entries $entries
            (Get-Content $Path -Raw) | Should -Be $first
        }
    }

    It 'replaces a stale hand-made entry for the same name' {
        Set-Content $script:hostsPath -Value @(
            '# my comment'
            "10.0.0.99`tdc01"
            "127.0.0.1`tlocalhost"
        )
        InModuleScope HomeLab -Parameters @{ Path = $script:hostsPath } {
            param($Path)
            $null = Set-LabHostsEntries -Path $Path -Entries @(
                @{ IP = '192.168.50.10'; Names = @('DC01','DC01.contoso.com') }
            )
            $lines = Get-Content $Path
            ($lines | Where-Object { $_ -match '10\.0\.0\.99' }) | Should -BeNullOrEmpty
            $lines | Should -Contain '# my comment'
            $lines | Should -Contain "127.0.0.1`tlocalhost"
            ($lines | Where-Object { $_ -match '192\.168\.50\.10' }).Count | Should -Be 1
        }
    }

    It 'preserves unrelated lines byte-for-byte' {
        Set-Content $script:hostsPath -Value @(
            '# Copyright (c) 1993-2009 Microsoft Corp.'
            ''
            "10.1.1.1`tsomeother.example.com  # keep me"
        )
        InModuleScope HomeLab -Parameters @{ Path = $script:hostsPath } {
            param($Path)
            $null = Set-LabHostsEntries -Path $Path -Entries @(
                @{ IP = '192.168.50.20'; Names = @('CM01') }
            )
            $lines = Get-Content $Path
            $lines | Should -Contain '# Copyright (c) 1993-2009 Microsoft Corp.'
            $lines | Should -Contain "10.1.1.1`tsomeother.example.com  # keep me"
        }
    }
}

Describe 'Remove-LabHostsEntries' {

    BeforeEach {
        $script:hostsPath = Join-Path $TestDrive 'hosts'
        Set-Content $script:hostsPath -Value @(
            '# header comment'
            "127.0.0.1`tlocalhost"
            "192.168.50.10`tDC01 DC01.contoso.com # HomeLab-managed"
            "192.168.50.20`tcm01"                       # hand-made, no marker
            "10.1.1.1`tsomeother.example.com"
        )
    }

    It 'removes managed lines and hand-made lines matching Names' {
        InModuleScope HomeLab -Parameters @{ Path = $script:hostsPath } {
            param($Path)
            $r = Remove-LabHostsEntries -Path $Path -Names @('CM01','CM01.contoso.com')
            $r.Removed | Should -Be 2
            $lines = Get-Content $Path
            ($lines | Where-Object { $_ -match 'HomeLab-managed' }) | Should -BeNullOrEmpty
            ($lines | Where-Object { $_ -match 'cm01' }) | Should -BeNullOrEmpty
            $lines | Should -Contain "127.0.0.1`tlocalhost"
            $lines | Should -Contain "10.1.1.1`tsomeother.example.com"
        }
    }

    It 'removes managed lines even with an empty Names list' {
        InModuleScope HomeLab -Parameters @{ Path = $script:hostsPath } {
            param($Path)
            $r = Remove-LabHostsEntries -Path $Path
            $r.Removed | Should -Be 1
            (Get-Content $Path | Where-Object { $_ -match 'HomeLab-managed' }) | Should -BeNullOrEmpty
        }
    }

    It 'is a no-op on a missing file' {
        InModuleScope HomeLab {
            $r = Remove-LabHostsEntries -Path (Join-Path $TestDrive 'does-not-exist')
            $r.Removed | Should -Be 0
        }
    }
}
