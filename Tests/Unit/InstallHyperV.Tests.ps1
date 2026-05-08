#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Install-LabHyperV's fast-path skip logic.
    Mirrors the HostPrereq fast-path pattern: a running hypervisor
    or vmms service should short-circuit the DISM probe entirely so
    "Class not registered" failures on the COM provider can't kill
    the deploy.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Install-LabHyperV fast paths' {

    It 'skips DISM when HypervisorPresent is true' {
        InModuleScope HomeLab {
            Mock Test-LabIsElevated -MockWith { $true }
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -MockWith {
                if ($ClassName -eq 'Win32_OperatingSystem') {
                    return [pscustomobject]@{ Caption = 'Windows 11 Pro'; ProductType = 1 }
                }
                if ($ClassName -eq 'Win32_ComputerSystem') {
                    return [pscustomobject]@{ HypervisorPresent = $true }
                }
            }
            Mock Get-WindowsOptionalFeature -MockWith {
                throw 'DISM should not have been called when HypervisorPresent=True'
            }

            $r = Install-LabHyperV
            $r.Status | Should -Be 'NotRequired'
            $r.SKU    | Should -Be 'Client'
            Should -Invoke Get-WindowsOptionalFeature -Times 0
        }
    }

    It 'skips DISM when vmms service is Running' {
        InModuleScope HomeLab {
            Mock Test-LabIsElevated -MockWith { $true }
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' } -MockWith {
                [pscustomobject]@{ Caption = 'Windows 11 Pro'; ProductType = 1 }
            }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -MockWith {
                [pscustomobject]@{ HypervisorPresent = $false }
            }
            Mock Get-Service -ParameterFilter { $Name -eq 'vmms' } -MockWith {
                [pscustomobject]@{ Status = 'Running' }
            }
            Mock Get-WindowsOptionalFeature -MockWith {
                throw 'DISM should not have been called when vmms is Running'
            }

            $r = Install-LabHyperV
            $r.Status | Should -Be 'NotRequired'
            Should -Invoke Get-WindowsOptionalFeature -Times 0
        }
    }

    It 'tolerates a Class-not-registered DISM failure on Client SKU and falls through to enable' {
        InModuleScope HomeLab {
            Mock Test-LabIsElevated -MockWith { $true }
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -MockWith {
                if ($ClassName -eq 'Win32_OperatingSystem') {
                    return [pscustomobject]@{ Caption = 'Windows 11 Pro'; ProductType = 1 }
                }
                if ($ClassName -eq 'Win32_ComputerSystem') {
                    return [pscustomobject]@{ HypervisorPresent = $false }
                }
            }
            Mock Get-Service -MockWith { throw 'no service' }
            Mock Get-WindowsOptionalFeature -MockWith { throw 'Class not registered' }
            Mock Enable-WindowsOptionalFeature -MockWith {
                [pscustomobject]@{ RestartNeeded = $true }
            }

            $r = Install-LabHyperV
            $r.Status | Should -Be 'EnabledRebootRequired'
            $r.RebootRequired | Should -BeTrue
            Should -Invoke Enable-WindowsOptionalFeature -Times 1
        }
    }

    It 'throws when not elevated' {
        InModuleScope HomeLab {
            Mock Test-LabIsElevated -MockWith { $false }
            { Install-LabHyperV } | Should -Throw '*must be elevated*'
        }
    }
}
