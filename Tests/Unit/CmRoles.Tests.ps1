#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the S15 distributed-role helpers
    (Add-CMRoleSiteSystem / Add-CMRoleManagementPoint /
    Add-CMRoleDistributionPoint). Live CM cmdlets require a running
    primary site, so these tests cover parameter binding only;
    behavioural coverage lives under Tests/Integration.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop

    # Helpers are private; pull them via InModuleScope.
    $script:cred = New-Object System.Management.Automation.PSCredential(
        'CONTOSO\LabAdmin',
        (ConvertTo-SecureString -String 'P@ssw0rd!' -AsPlainText -Force))
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Add-CMRoleSiteSystem parameter validation' {

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleSiteSystem -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'TOOLONG' -SiteSystemServerFqdn 'DP01.contoso.com' } |
                Should -Throw '*length*'
        }
    }

    It 'rejects an empty ComputerName' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleSiteSystem -ComputerName '' -DomainCredential $Cred `
                -SiteCode MCM -SiteSystemServerFqdn 'DP01.contoso.com' } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects an empty SiteSystemServerFqdn' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleSiteSystem -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -SiteSystemServerFqdn '' } |
                Should -Throw '*null*empty*'
        }
    }
}

Describe 'Add-CMRoleManagementPoint parameter validation' {

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleManagementPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'TL' -MpServerFqdn 'MP01.contoso.com' } |
                Should -Throw '*length*'
        }
    }

    It 'rejects an empty MpServerFqdn' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleManagementPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -MpServerFqdn '' } |
                Should -Throw '*null*empty*'
        }
    }
}

Describe 'Add-CMRoleDistributionPoint parameter validation' {

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleDistributionPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'X' -DpServerFqdn 'DP01.contoso.com' } |
                Should -Throw '*length*'
        }
    }

    It 'rejects MinimumFreeSpaceMB outside the allowed range' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleDistributionPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -DpServerFqdn 'DP01.contoso.com' `
                -MinimumFreeSpaceMB -1 } |
                Should -Throw '*range*'
        }
    }

    It 'accepts MinimumFreeSpaceMB at the upper bound' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            # MOCK the remoting layer. The previous version of this test
            # assumed "no live session exists" and let the call run --
            # on a host with a live lab and default passwords it opened
            # a REAL PSSession to CM01 and executed REAL CM cmdlets
            # (2026-07-16: it created a real DP01.contoso.com site
            # system in the live site). Unit tests must never be able
            # to reach a lab.
            Mock Add-CMRoleSiteSystem -MockWith {
                [pscustomobject]@{ Status = 'AlreadyExists' }
            }
            Mock Invoke-LabCommand -MockWith {
                [pscustomobject]@{ Status = 'Created'; ServerFqdn = 'DP01.contoso.com' }
            }

            # 100000 is the real Add-CMDistributionPoint maximum; the
            # module's ValidateRange mirrors it.
            { Add-CMRoleDistributionPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -DpServerFqdn 'DP01.contoso.com' `
                -MinimumFreeSpaceMB 100000 -ErrorAction Stop } |
                Should -Not -Throw
        }
    }

    It 'rejects MinimumFreeSpaceMB above the real CM cmdlet maximum (100000)' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleDistributionPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -DpServerFqdn 'DP01.contoso.com' `
                -MinimumFreeSpaceMB 1048576 } |
                Should -Throw '*range*'
        }
    }
}
