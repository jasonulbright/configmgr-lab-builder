#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the S18 post-CM customisation helpers
    (New-CMRoleCollection / MaintenanceWindow / Deployment /
    DriverCategory). Live CM cmdlets need an integration test;
    these cover parameter binding only.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop

    $script:cred = New-Object System.Management.Automation.PSCredential(
        'CONTOSO\LabAdmin',
        (ConvertTo-SecureString -String 'P@ssw0rd!' -AsPlainText -Force))
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-CMRoleCollection parameter validation' {

    It 'rejects calls without -Query and without -Direct' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleCollection -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name 'TestColl' } |
                Should -Throw "*provide either -Query or -Direct*"
        }
    }

    It 'rejects -Query and -Direct together' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleCollection -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name 'TestColl' `
                -Query 'select * from SMS_R_System' -Direct @('CLIENT01') } |
                Should -Throw "*mutually exclusive*"
        }
    }

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleCollection -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'TOOLONG' -Name 'TestColl' -Direct @('CLIENT01') } |
                Should -Throw '*length*'
        }
    }
}

Describe 'New-CMRoleMaintenanceWindow parameter validation' {

    It 'rejects DurationHours below 1' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleMaintenanceWindow -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -CollectionName 'C' -Name 'MW' `
                -Start '02:00' -DurationHours 0 } |
                Should -Throw '*range*'
        }
    }

    It 'rejects DurationHours above 24' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleMaintenanceWindow -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -CollectionName 'C' -Name 'MW' `
                -Start '02:00' -DurationHours 25 } |
                Should -Throw '*range*'
        }
    }

    It 'rejects an invalid Cadence' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleMaintenanceWindow -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -CollectionName 'C' -Name 'MW' `
                -Start '02:00' -Cadence 'Hourly' } |
                Should -Throw '*ValidateSet*'
        }
    }

    It 'rejects an invalid DayOfWeek' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleMaintenanceWindow -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -CollectionName 'C' -Name 'MW' `
                -Start '02:00' -DayOfWeek 'Funday' } |
                Should -Throw '*ValidateSet*'
        }
    }

    It 'rejects an invalid ApplyTo' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleMaintenanceWindow -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -CollectionName 'C' -Name 'MW' `
                -Start '02:00' -ApplyTo 'WhateverElse' } |
                Should -Throw '*ValidateSet*'
        }
    }
}

Describe 'New-CMRoleDeployment parameter validation' {

    It 'rejects an invalid DeployPurpose' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleDeployment -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -ApplicationName '7-Zip' -CollectionName 'C' `
                -DeployPurpose 'Mandatory' } |
                Should -Throw '*ValidateSet*'
        }
    }

    It 'rejects an invalid UserNotification' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleDeployment -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -ApplicationName '7-Zip' -CollectionName 'C' `
                -UserNotification 'NeverShow' } |
                Should -Throw '*ValidateSet*'
        }
    }

    It 'rejects an empty ApplicationName' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleDeployment -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -ApplicationName '' -CollectionName 'C' } |
                Should -Throw '*null*empty*'
        }
    }
}

Describe 'New-CMRoleDriverCategory parameter validation' {

    It 'rejects an empty Name' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleDriverCategory -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name '' } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleDriverCategory -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'TOOLONG' -Name 'Dell-Latitude' } |
                Should -Throw '*length*'
        }
    }
}

Describe 'Invoke-LabPostCmCustomization mapping' {

    It 'maps selected collection, maintenance window, and driver choices to helper calls' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            $script:collectionCalls = @()
            $script:mwCalls = @()
            $script:driverCalls = @()
            Mock New-CMRoleCollection -MockWith {
                $script:collectionCalls += [pscustomobject]@{
                    Name   = $Name
                    Query  = $Query
                    Direct = $Direct
                }
                return [pscustomobject]@{ Status = 'Created'; Name = $Name }
            }
            Mock New-CMRoleMaintenanceWindow -MockWith {
                $script:mwCalls += [pscustomobject]@{
                    CollectionName = $CollectionName
                    Name           = $Name
                    ApplyTo        = $ApplyTo
                }
                return [pscustomobject]@{ Status = 'Created'; Name = $Name }
            }
            Mock New-CMRoleDriverCategory -MockWith {
                $script:driverCalls += [string]$Name
                return [pscustomobject]@{ Status = 'Created'; Name = $Name }
            }
            Mock Write-LabLog -MockWith { }

            $cfg = @{
                SiteCode = 'MCM'
                DomainName = 'contoso.com'
                AdminPass = 'P@ssw0rd!'
                RoleIndex = @{
                    Client = @(@{ Name='CLIENT01'; Roles=@('Client') })
                }
            }
            $post = @{
                Coll_AllWorkstations = $true
                Coll_AllServers      = $true
                Coll_TestDirect      = $true
                MW_PatchSaturday     = $true
                MW_TestDaily         = $true
                Drivers_Csv          = 'Dell-Latitude; Lenovo-T14'
            }

            $r = Invoke-LabPostCmCustomization -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Config $cfg -PostCmConfig $post

            $r.Status | Should -Be 'Complete'
            @($script:collectionCalls).Count | Should -Be 3
            @($script:collectionCalls.Name) | Should -Contain 'All Workstations'
            @($script:collectionCalls.Name) | Should -Contain 'All Servers'
            @($script:collectionCalls.Name) | Should -Contain 'HomeLab - Test Deployments'
            @($script:mwCalls).Count | Should -Be 2
            @($script:driverCalls) | Should -Be @('Dell-Latitude','Lenovo-T14')
        }
    }
}
