#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the S15 distributed-role helpers
    (Add-CMRoleSiteSystem / Add-CMRoleManagementPoint /
    Add-CMRoleDistributionPoint / Add-CMRoleFallbackStatusPoint /
    Add-CMRoleServiceConnectionPoint / Add-CMRoleReportingServicePoint).
    Live CM cmdlets require a running primary site, so these tests
    cover parameter binding only; behavioural coverage lives under
    Tests/Integration.
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

Describe 'Add-CMRoleFallbackStatusPoint parameter validation' {

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleFallbackStatusPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'TL' -FspServerFqdn 'FSP01.contoso.com' } |
                Should -Throw '*length*'
        }
    }

    It 'rejects an empty FspServerFqdn' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleFallbackStatusPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -FspServerFqdn '' } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects an empty ComputerName' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleFallbackStatusPoint -ComputerName '' -DomainCredential $Cred `
                -SiteCode MCM -FspServerFqdn 'FSP01.contoso.com' } |
                Should -Throw '*null*empty*'
        }
    }

    It 'calls Add-CMRoleSiteSystem then Invoke-LabCommand and returns the result (mocked remoting)' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            # MOCK the remoting layer -- unit tests must never be able to
            # reach a lab or run a live CM cmdlet.
            Mock Add-CMRoleSiteSystem -MockWith {
                [pscustomobject]@{ Status = 'AlreadyExists' }
            }
            Mock Invoke-LabCommand -MockWith {
                [pscustomobject]@{ Status = 'Created'; ServerFqdn = 'FSP01.contoso.com' }
            }
            Mock Write-LabLog { }

            $result = Add-CMRoleFallbackStatusPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -FspServerFqdn 'FSP01.contoso.com'

            $result.Status | Should -Be 'Created'
            $result.ServerFqdn | Should -Be 'FSP01.contoso.com'
            Should -Invoke Add-CMRoleSiteSystem -Times 1 -Exactly
            Should -Invoke Invoke-LabCommand -Times 1 -Exactly
        }
    }
}

Describe 'Add-CMRoleServiceConnectionPoint parameter validation' {

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleServiceConnectionPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'TOOLONG' -ScpServerFqdn 'CM01.contoso.com' } |
                Should -Throw '*length*'
        }
    }

    It 'rejects an empty ScpServerFqdn' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleServiceConnectionPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -ScpServerFqdn '' } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects a Mode outside the ValidateSet (Online/Offline)' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Add-CMRoleServiceConnectionPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -ScpServerFqdn 'CM01.contoso.com' -Mode 'Hybrid' } |
                Should -Throw '*Mode*'
        }
    }

    It 'defaults Mode to Online and returns the result (mocked remoting)' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            # MOCK the remoting layer -- unit tests must never be able to
            # reach a lab or run a live CM cmdlet.
            Mock Add-CMRoleSiteSystem -MockWith {
                [pscustomobject]@{ Status = 'AlreadyExists' }
            }
            Mock Invoke-LabCommand -MockWith {
                [pscustomobject]@{ Status = 'Created'; ServerFqdn = 'CM01.contoso.com' }
            } -ParameterFilter { $ArgumentList[2] -eq 'Online' }
            Mock Write-LabLog { }

            $result = Add-CMRoleServiceConnectionPoint -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -ScpServerFqdn 'CM01.contoso.com'

            $result.Status | Should -Be 'Created'
            $result.ServerFqdn | Should -Be 'CM01.contoso.com'
            Should -Invoke Add-CMRoleSiteSystem -Times 1 -Exactly
            Should -Invoke Invoke-LabCommand -Times 1 -Exactly
        }
    }
}

Describe 'Add-CMRoleReportingServicePoint parameter validation' {

    BeforeAll {
        $script:rspBaseParams = @{
            ComputerName         = 'CM01'
            SiteCode             = 'MCM'
            RspServerFqdn        = 'CM01.contoso.com'
            UserName             = 'CONTOSO\svc-CMReporting'
            Password             = 'P@ssw0rd!'
            DatabaseServerName   = 'CM01.contoso.com'
            ReportServerInstance = 'SSRS'
        }
    }

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; P = $script:rspBaseParams } {
            param($Cred, $P)
            { Add-CMRoleReportingServicePoint @P -DomainCredential $Cred -SiteCode 'TOOLONG' } |
                Should -Throw '*length*'
        }
    }

    It 'rejects an empty RspServerFqdn' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; P = $script:rspBaseParams } {
            param($Cred, $P)
            $bad = $P.Clone(); $bad.RspServerFqdn = ''
            { Add-CMRoleReportingServicePoint @bad -DomainCredential $Cred } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects an empty UserName' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; P = $script:rspBaseParams } {
            param($Cred, $P)
            $bad = $P.Clone(); $bad.UserName = ''
            { Add-CMRoleReportingServicePoint @bad -DomainCredential $Cred } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects an empty ReportServerInstance' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; P = $script:rspBaseParams } {
            param($Cred, $P)
            $bad = $P.Clone(); $bad.ReportServerInstance = ''
            { Add-CMRoleReportingServicePoint @bad -DomainCredential $Cred } |
                Should -Throw '*null*empty*'
        }
    }

    It 'defaults DatabaseName to CM_<SiteCode> and returns the result (mocked remoting)' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; P = $script:rspBaseParams } {
            param($Cred, $P)
            # MOCK the remoting layer -- unit tests must never be able to
            # reach a lab or run a live CM cmdlet.
            Mock Add-CMRoleSiteSystem -MockWith {
                [pscustomobject]@{ Status = 'AlreadyExists' }
            }
            Mock Invoke-LabCommand -MockWith {
                [pscustomobject]@{ Status = 'Created'; ServerFqdn = 'CM01.contoso.com' }
            } -ParameterFilter { $ArgumentList[5] -eq 'CM_MCM' }
            Mock Write-LabLog { }

            $result = Add-CMRoleReportingServicePoint @P -DomainCredential $Cred

            $result.Status | Should -Be 'Created'
            $result.ServerFqdn | Should -Be 'CM01.contoso.com'
            Should -Invoke Add-CMRoleSiteSystem -Times 1 -Exactly
            Should -Invoke Invoke-LabCommand -Times 1 -Exactly
        }
    }
}
