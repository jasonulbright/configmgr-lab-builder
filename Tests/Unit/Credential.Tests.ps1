#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Get-LabCredential.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    . (Join-Path $script:helpersRoot 'Get-LabConfig.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabCredential.ps1')

    $script:liveConfig = Resolve-Path "$PSScriptRoot\..\..\config.psd1"
    $script:cfg = Get-LabConfig -Path $script:liveConfig
    # Get-LabCredential resolves the lab-wide password from $cfg.AdminPass,
    # $env:HOMELAB_PASSWORD, or Read-Host. Tests run non-interactively, so
    # seed the in-memory config with a synthetic password (NEVER persisted).
    $script:cfg.AdminPass = 'TestP@ss123!'
}

Describe 'Get-LabCredential' {

    It 'returns a PSCredential for Admin' {
        $c = Get-LabCredential -Identity Admin -Config $script:cfg
        $c | Should -BeOfType ([System.Management.Automation.PSCredential])
    }

    It 'username is NETBIOS\sAMAccountName' {
        $c = Get-LabCredential -Identity Admin -Config $script:cfg
        $c.UserName | Should -Be 'CONTOSO\LabAdmin'
    }

    It 'returns ClientPush credential' {
        $c = Get-LabCredential -Identity ClientPush -Config $script:cfg
        $c.UserName | Should -Be 'CONTOSO\svc-CMPush'
    }

    It 'returns NAA credential' {
        $c = Get-LabCredential -Identity NAA -Config $script:cfg
        $c.UserName | Should -Be 'CONTOSO\svc-CMNAA'
    }

    It 'returns Join credential (OSD task-sequence domain-join account)' {
        $c = Get-LabCredential -Identity Join -Config $script:cfg
        $c.UserName | Should -Be 'CONTOSO\svc-CMJoin'
    }

    It 'rejects invalid identity at parameter binding' {
        { Get-LabCredential -Identity NotAnIdentity -Config $script:cfg } |
            Should -Throw "*ValidateSet*"
    }

    It 'throws if username is empty in the supplied config' {
        $bad = @{
            DomainName = 'contoso.com'
            AdminUser  = ''
            AdminPass  = 'P@ssw0rd!'
            ServiceAccounts = @{ ClientPush = @{ Name=''; Password='x' } }
        }
        { Get-LabCredential -Identity Admin -Config $bad } |
            Should -Throw "*resolved to empty*"
    }
}
