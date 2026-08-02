#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Get-LabGuiLogPath and the GUI-logs line in
    Write-LabDeploySummary.

.DESCRIPTION
    Regression cover for the 1.4.0 fix: the GUI log directory used to be
    the hardcoded literal 'C:\projects\mecm-homelab\gui\Logs'. Guarded by
    Test-Path, it silently rendered nothing for every clone that did not
    sit at that exact path. These tests pin the derived behaviour so the
    literal cannot come back unnoticed.

    Test-HomeLab is mocked throughout. Write-LabDeploySummary calls it,
    and an unmocked call opens sessions to the live lab by name.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-LabGuiLogPath' {

    # TestDrive is not cleared between It blocks, so each case gets its own
    # synthetic checkout. <case>\modules\HomeLab is what the function is
    # handed; it walks up two levels to find <case>\gui\Logs.
    BeforeEach {
        $script:caseRoot   = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:fakeModule = Join-Path $script:caseRoot 'modules\HomeLab'
        New-Item -Path $script:fakeModule -ItemType Directory -Force | Out-Null
    }

    It 'returns <repo>\gui\Logs when the directory exists' {
        InModuleScope HomeLab -Parameters @{ Root = $script:fakeModule; Repo = $script:caseRoot } {
            param($Root, $Repo)
            $expected = Join-Path $Repo 'gui\Logs'
            New-Item -Path $expected -ItemType Directory -Force | Out-Null

            Get-LabGuiLogPath -ModuleRoot $Root | Should -Be $expected
        }
    }

    It 'returns null when gui\Logs does not exist' {
        InModuleScope HomeLab -Parameters @{ Root = $script:fakeModule } {
            param($Root)
            Get-LabGuiLogPath -ModuleRoot $Root | Should -BeNullOrEmpty
        }
    }

    It 'returns null when gui exists but Logs was never created' {
        InModuleScope HomeLab -Parameters @{ Root = $script:fakeModule; Repo = $script:caseRoot } {
            param($Root, $Repo)
            New-Item -Path (Join-Path $Repo 'gui') -ItemType Directory -Force | Out-Null

            Get-LabGuiLogPath -ModuleRoot $Root | Should -BeNullOrEmpty
        }
    }

    It 'returns null when gui\Logs is a file rather than a directory' {
        InModuleScope HomeLab -Parameters @{ Root = $script:fakeModule; Repo = $script:caseRoot } {
            param($Root, $Repo)
            New-Item -Path (Join-Path $Repo 'gui') -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $Repo 'gui\Logs') -Value 'not a directory'

            Get-LabGuiLogPath -ModuleRoot $Root | Should -BeNullOrEmpty
        }
    }

    It 'resolves against the real checkout without throwing' {
        # No assertion on the result: gui\Logs exists only once the GUI has
        # run. What matters is that the derivation works on a real tree.
        InModuleScope HomeLab {
            { Get-LabGuiLogPath } | Should -Not -Throw
        }
    }

    It 'does not return the pre-1.4.0 hardcoded literal' {
        # The literal appears in the .DESCRIPTION explaining the fix, but
        # must never be something the function can return.
        $src = Get-Content (Join-Path $script:moduleRoot 'Helpers\Get-LabGuiLogPath.ps1') -Raw
        $src | Should -Not -Match "return\s+'C:\\projects"
        $src | Should -Not -Match "Test-Path\s+'C:\\projects"
    }
}

Describe 'Write-LabDeploySummary GUI logs line' {

    BeforeAll {
        $script:config = @{
            DomainName      = 'contoso.com'
            NetBIOS         = 'CONTOSO'
            SiteCode        = 'MCM'
            AdminUser       = 'LabAdmin'
            DC              = @{ Name = 'DC01' }
            CM              = @{ Name = 'CM01' }
            Client          = @{ Name = 'CLIENT01' }
            ServiceAccounts = @{
                ClientPush = @{ Name = 'svc-CMPush' }
                NAA        = @{ Name = 'svc-CMNAA' }
                Join       = @{ Name = 'svc-CMJoin' }
            }
        }
    }

    It 'renders the GUI logs line when a GUI log directory exists' {
        InModuleScope HomeLab -Parameters @{ Config = $script:config } {
            param($Config)
            $script:emitted = [System.Collections.Generic.List[string]]::new()

            Mock Test-HomeLab { $null }
            Mock Get-LabGuiLogPath { 'D:\somewhere\gui\Logs' }
            Mock Write-LabLog { $script:emitted.Add($Message) }

            $null = Write-LabDeploySummary -Config $Config

            ($script:emitted -join "`n") | Should -Match 'GUI logs:\s+D:\\somewhere\\gui\\Logs'
        }
    }

    It 'omits the GUI logs line when there is no GUI log directory' {
        InModuleScope HomeLab -Parameters @{ Config = $script:config } {
            param($Config)
            $script:emitted = [System.Collections.Generic.List[string]]::new()

            Mock Test-HomeLab { $null }
            Mock Get-LabGuiLogPath { $null }
            Mock Write-LabLog { $script:emitted.Add($Message) }

            $null = Write-LabDeploySummary -Config $Config

            ($script:emitted -join "`n") | Should -Not -Match 'GUI logs:'
            # Guard against a vacuous pass: the summary really did render.
            ($script:emitted -join "`n") | Should -Match 'Engine log:'
        }
    }

    It 'never probes the live lab (Test-HomeLab stays mocked)' {
        InModuleScope HomeLab -Parameters @{ Config = $script:config } {
            param($Config)
            Mock Test-HomeLab { $null }
            Mock Get-LabGuiLogPath { $null }
            Mock Write-LabLog { }

            $null = Write-LabDeploySummary -Config $Config

            Should -Invoke Test-HomeLab -Times 1 -Exactly
        }
    }
}
