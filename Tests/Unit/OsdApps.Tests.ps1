#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the S19 OSD + apps stub helpers
    (New-CMRoleBootImage / TaskSequenceStub / Application). Live CM
    cmdlets need an integration test; these cover parameter binding.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop

    $script:cred = New-Object System.Management.Automation.PSCredential(
        'CONTOSO\LabAdmin',
        (ConvertTo-SecureString -String 'P@ssw0rd!' -AsPlainText -Force))
    $script:secure = ConvertTo-SecureString -String 'localpw' -AsPlainText -Force
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-CMRoleBootImage parameter validation' {

    It 'rejects an empty WimPath' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleBootImage -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name 'WinPE x64' -WimPath '' } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleBootImage -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'TOOLONG' -Name 'WinPE x64' -WimPath '\\CM01\Sources$\winpe.wim' } |
                Should -Throw '*length*'
        }
    }
}

Describe 'New-CMRoleTaskSequenceStub parameter validation' {

    It 'rejects an empty BootImageName' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; Pwd = $script:secure } {
            param($Cred, $Pwd)
            { New-CMRoleTaskSequenceStub -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name 'Build Win11' `
                -BootImageName '' -OsImageName 'Win11 Enterprise' `
                -LocalAdminPassword $Pwd -DomainName contoso.com } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects an empty OsImageName' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; Pwd = $script:secure } {
            param($Cred, $Pwd)
            { New-CMRoleTaskSequenceStub -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name 'Build Win11' `
                -BootImageName 'WinPE x64' -OsImageName '' `
                -LocalAdminPassword $Pwd -DomainName contoso.com } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects OsImageIndex below 1' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; Pwd = $script:secure } {
            param($Cred, $Pwd)
            { New-CMRoleTaskSequenceStub -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name 'Build Win11' `
                -BootImageName 'WinPE x64' -OsImageName 'Win11 Enterprise' `
                -OsImageIndex 0 -LocalAdminPassword $Pwd -DomainName contoso.com } |
                Should -Throw '*range*'
        }
    }
}

Describe 'New-CMRoleApplication parameter validation' {

    It 'rejects an empty ContentLocation' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleApplication -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name '7-Zip' `
                -ContentLocation '' -InstallCommand 'i.bat' -UninstallCommand 'u.bat' `
                -DetectionRegistryKey 'k' -DetectionRegistryValue 'v' -DetectionRegistryExpectedValue 'x' } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects an empty InstallCommand' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleApplication -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name '7-Zip' `
                -ContentLocation '\\srv\src' -InstallCommand '' -UninstallCommand 'u.bat' `
                -DetectionRegistryKey 'k' -DetectionRegistryValue 'v' -DetectionRegistryExpectedValue 'x' } |
                Should -Throw '*null*empty*'
        }
    }

    It 'rejects an empty DetectionRegistryKey' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { New-CMRoleApplication -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -Name '7-Zip' `
                -ContentLocation '\\srv\src' -InstallCommand 'i.bat' -UninstallCommand 'u.bat' `
                -DetectionRegistryKey '' -DetectionRegistryValue 'v' -DetectionRegistryExpectedValue 'x' } |
                Should -Throw '*null*empty*'
        }
    }
}
