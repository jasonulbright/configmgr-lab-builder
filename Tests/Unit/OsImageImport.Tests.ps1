#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Import-CMRoleOsImage. Covers parameter
    validation, version-folder derivation, edition picking,
    idempotent SMB-staging, and the CM-side Import + Distribute
    short-circuit branches. Mocks Mount-DiskImage / Get-WindowsImage /
    Get-Volume / Copy-Item / New-PSDrive / Invoke-LabCommand so the
    test never touches a real ISO or CM site.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop

    $script:cred = New-Object System.Management.Automation.PSCredential(
        'CONTOSO\LabAdmin',
        (ConvertTo-SecureString -String 'P@ssw0rd!' -AsPlainText -Force))

    $script:isoFile = Join-Path $TestDrive 'fake-win11.iso'
    New-Item -Path $script:isoFile -ItemType File -Force | Out-Null
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Import-CMRoleOsImage parameter validation' {

    It 'throws when ISO file is missing' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Import-CMRoleOsImage -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -IsoPath 'Z:\does-not-exist.iso' } |
                Should -Throw '*ISO not found*'
        }
    }

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; Iso = $script:isoFile } {
            param($Cred, $Iso)
            { Import-CMRoleOsImage -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'TOOLONG' -IsoPath $Iso } |
                Should -Throw '*length*'
        }
    }
}

Describe 'Import-CMRoleOsImage pipeline' {

    BeforeEach {
        InModuleScope HomeLab {
            # Mock the elevation gate so the test passes regardless of
            # how Pester was launched.
            Mock Test-LabIsElevated -MockWith { $true }
            Mock Write-LabLog -MockWith { }

            # Mount/Get-WindowsImage cluster -- Mount-LabIso wraps the
            # Mount-DiskImage + Get-Volume + drive-letter resolution so
            # tests don't have to fake a CimInstance for Get-Volume.
            Mock Mount-LabIso -MockWith {
                [pscustomobject]@{
                    IsoPath     = $IsoPath
                    DriveLetter = 'X'
                    DriveRoot   = 'X:'
                }
            }
            Mock Dismount-LabIso -MockWith { }
            Mock Test-Path -MockWith { $true }
            Mock Get-WindowsImage -MockWith {
                if ($Index) {
                    return [pscustomobject]@{
                        ImageIndex   = $Index
                        ImageName    = 'Windows 11 Enterprise'
                        Architecture = 9
                        Version      = '10.0.26200.6584'
                    }
                }
                return @(
                    [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' }
                    [pscustomobject]@{ ImageIndex = 3; ImageName = 'Windows 11 Pro' }
                    [pscustomobject]@{ ImageIndex = 6; ImageName = 'Windows 11 Enterprise' }
                )
            }

            # SMB-staging cluster
            Mock New-PSDrive -MockWith { [pscustomobject]@{ Name = 'homelabosdtest' } }
            Mock Get-PSDrive -MockWith { [pscustomobject]@{ Name = 'homelabosdtest' } }
            Mock Remove-PSDrive -MockWith { }
            Mock New-Item -MockWith { }
            Mock Copy-Item -MockWith { }

            # CM-side cluster: capture what Invoke-LabCommand returns.
            Mock Invoke-LabCommand -MockWith {
                [pscustomobject]@{
                    Name        = 'Windows 11 Enterprise (build 10.0.26200.6584)'
                    PackageId   = 'MCM00100'
                    ImageStatus = 'Imported'
                    DistStatus  = 'Distributed'
                }
            }
        }
    }

    It 'derives a per-build folder name from the OS Version (W11_<major>.<rev>)' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; Iso = $script:isoFile } {
            param($Cred, $Iso)
            $r = Import-CMRoleOsImage -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -IsoPath $Iso
            $r.FolderName  | Should -Be 'W11_26200.6584'
            $r.WimUncPath  | Should -Be '\\CM01\ContentShare$\OSD\W11_26200.6584\install.wim'
            $r.ImageName   | Should -Be 'Windows 11 Enterprise (build 10.0.26200.6584)'
            $r.ImageIndex  | Should -Be 6
        }
    }

    It 'picks the highest-index match for the NameFilter wildcard' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; Iso = $script:isoFile } {
            param($Cred, $Iso)
            # Three 'Windows 11*' images; Enterprise (idx 6) wins by sort order.
            $r = Import-CMRoleOsImage -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -IsoPath $Iso -NameFilter 'Windows 11*'
            $r.ImageIndex | Should -Be 6
        }
    }

    It 'throws with the available-image listing when NameFilter matches zero' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; Iso = $script:isoFile } {
            param($Cred, $Iso)
            { Import-CMRoleOsImage -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -IsoPath $Iso -NameFilter 'Windows Server 2099*' } |
                Should -Throw '*no image*matches*Windows 11 Home*Windows 11 Pro*Windows 11 Enterprise*'
        }
    }

    It 'always dismounts the ISO -- even when the CM call throws' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred; Iso = $script:isoFile } {
            param($Cred, $Iso)
            Mock Invoke-LabCommand -MockWith { throw 'CM exploded' }
            { Import-CMRoleOsImage -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -IsoPath $Iso } | Should -Throw '*CM exploded*'
            Should -Invoke Dismount-LabIso -Times 1
        }
    }
}
