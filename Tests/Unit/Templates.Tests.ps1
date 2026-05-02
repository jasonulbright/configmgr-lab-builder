#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the built-in templates (S17). Each template
    must load via Get-LabConfig (schema-valid). Install-HomeLab
    -Template parameter validation lives here too.
#>

BeforeAll {
    $script:repoRoot    = Resolve-Path "$PSScriptRoot\..\.."
    $script:helpersRoot = Join-Path $script:repoRoot 'modules\HomeLab\Helpers'
    . (Join-Path $script:helpersRoot 'Get-LabConfig.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabVMByRole.ps1')
    . (Join-Path $script:helpersRoot 'Resolve-LabVM.ps1')

    $script:templatesDir = Join-Path $script:repoRoot 'templates'

    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:repoRoot 'modules\HomeLab\HomeLab.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Built-in templates load via Get-LabConfig' {

    It 'loads default.psd1' {
        $cfg = Get-LabConfig -Path (Join-Path $script:templatesDir 'default.psd1')
        @($cfg.VMs).Count                              | Should -Be 3
        @($cfg.RoleIndex['DomainController'])[0].Name  | Should -Be 'DC01'
        @($cfg.RoleIndex['SiteServer'])[0].Name        | Should -Be 'CM01'
        @($cfg.RoleIndex['Client'])[0].Name            | Should -Be 'CLIENT01'
    }

    It 'loads split-sql.psd1 (SQL on its own VM)' {
        $cfg = Get-LabConfig -Path (Join-Path $script:templatesDir 'split-sql.psd1')
        @($cfg.VMs).Count                            | Should -Be 4
        @($cfg.RoleIndex['SqlServer'])[0].Name       | Should -Be 'SQL01'
        @($cfg.RoleIndex['SiteServer'])[0].Name      | Should -Be 'CM01'
        # SQL01 is NOT also the SiteServer.
        @($cfg.RoleIndex['SqlServer'])[0].Name |
            Should -Not -Be (@($cfg.RoleIndex['SiteServer'])[0].Name)
    }

    It 'loads role-per-server.psd1 (every CM role on its own VM)' {
        $cfg = Get-LabConfig -Path (Join-Path $script:templatesDir 'role-per-server.psd1')
        @($cfg.VMs).Count                                | Should -Be 7
        @($cfg.RoleIndex['SqlServer'])[0].Name           | Should -Be 'SQL01'
        @($cfg.RoleIndex['SiteServer'])[0].Name          | Should -Be 'CM01'
        @($cfg.RoleIndex['ManagementPoint'])[0].Name     | Should -Be 'MP01'
        @($cfg.RoleIndex['DistributionPoint'])[0].Name   | Should -Be 'DP01'
        @($cfg.RoleIndex['SoftwareUpdatePoint'])[0].Name | Should -Be 'SUP01'
        @($cfg.RoleIndex['Client'])[0].Name              | Should -Be 'CLIENT01'
    }

    It 'loads aio.psd1 (DC + CM bundle on one VM, schema-only)' {
        $cfg = Get-LabConfig -Path (Join-Path $script:templatesDir 'aio.psd1')
        @($cfg.VMs).Count                              | Should -Be 2
        $lab01 = @($cfg.RoleIndex['DomainController'])[0]
        $lab01.Name                                    | Should -Be 'LAB01'
        $lab01.Roles                                   | Should -Contain 'SiteServer'
        $lab01.Roles                                   | Should -Contain 'SqlServer'
        @($cfg.RoleIndex['Client'])[0].Name            | Should -Be 'CLIENT01'
    }

    It 'loads cas-2-dps.psd1 (CAS + 2 DPs, schema-only)' {
        $cfg = Get-LabConfig -Path (Join-Path $script:templatesDir 'cas-2-dps.psd1')
        @($cfg.VMs).Count                                       | Should -Be 6
        @($cfg.RoleIndex['CentralAdministrationSite'])[0].Name  | Should -Be 'CAS01'
        @($cfg.RoleIndex['DistributionPoint']).Count            | Should -Be 2
    }

    It 'loads cas-role-per-server.psd1 (full enterprise mirror, schema-only)' {
        $cfg = Get-LabConfig -Path (Join-Path $script:templatesDir 'cas-role-per-server.psd1')
        @($cfg.VMs).Count                                       | Should -Be 9
        @($cfg.RoleIndex['CentralAdministrationSite'])[0].Name  | Should -Be 'CAS01'
        @($cfg.RoleIndex['DistributionPoint']).Count            | Should -Be 2
        @($cfg.RoleIndex['SqlServer'])[0].Name                  | Should -Be 'SQL01'
        @($cfg.RoleIndex['SoftwareUpdatePoint'])[0].Name        | Should -Be 'SUP01'
    }

    It 'every template defines unique VM names within itself' {
        foreach ($f in Get-ChildItem -Path $script:templatesDir -Filter '*.psd1') {
            $cfg = Get-LabConfig -Path $f.FullName
            $names = @($cfg.VMs | ForEach-Object { $_.Name })
            ($names | Sort-Object -Unique).Count | Should -Be $names.Count `
                -Because "$($f.Name) must have unique VM names"
        }
    }
}

Describe 'Install-HomeLab -Template parameter validation' {

    It 'rejects -ConfigPath and -Template together' {
        { Install-HomeLab -ConfigPath 'C:\does-not-exist.psd1' -Template default } |
            Should -Throw '*mutually exclusive*'
    }

    It 'rejects an unknown template name' {
        { Install-HomeLab -Template 'no-such-template' } |
            Should -Throw "*template 'no-such-template' not found*"
    }

    It 'lists available templates in the unknown-template error' {
        # Different templates may be present; just verify "Available:"
        # appears with at least one known name.
        try {
            Install-HomeLab -Template 'no-such-template'
        } catch {
            $_.Exception.Message | Should -Match 'Available:'
            $_.Exception.Message | Should -Match 'default'
        }
    }

    It 'accepts -Template default and reaches the elevation gate' {
        InModuleScope HomeLab {
            Mock Test-LabIsElevated -MockWith { $false }
            { Install-HomeLab -Template default } |
                Should -Throw '*must be elevated*'
        }
    }

    It 'accepts -Template role-per-server and reaches the elevation gate' {
        InModuleScope HomeLab {
            Mock Test-LabIsElevated -MockWith { $false }
            { Install-HomeLab -Template role-per-server } |
                Should -Throw '*must be elevated*'
        }
    }
}
