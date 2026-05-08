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
            # Will not actually invoke the CM cmdlet because there's no
            # live session; we verify the binding succeeds (i.e. the
            # value is in range and the function gets to the elevation /
            # remoting layer where it would fail).
            $err = $null
            try {
                Add-CMRoleDistributionPoint -ComputerName CM01 -DomainCredential $Cred `
                    -SiteCode MCM -DpServerFqdn 'DP01.contoso.com' `
                    -MinimumFreeSpaceMB 1048576 -ErrorAction Stop
            } catch { $err = $_.Exception.Message }
            $err | Should -Not -Match 'range'
        }
    }
}
