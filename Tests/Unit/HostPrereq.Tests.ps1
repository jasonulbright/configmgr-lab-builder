#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Test-HostPrereq fast-path logic. Covers the
    HypervisorPresent / vmms shortcuts that were added after the
    GUI host-check page surfaced two false-negatives on a healthy
    box where Hyper-V was already running:
      - HyperVFeature reported "Class not registered" (DISM glitch)
      - VirtExtensions reported "not enabled in firmware" (the
        VirtualizationFirmwareEnabled flag becomes unreliable once
        the hypervisor is loaded)
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Test-HostPrereq HyperVFeature fast paths' {

    It 'passes via HypervisorPresent without calling DISM' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -MockWith {
                [pscustomobject]@{ HypervisorPresent = $true }
            }
            Mock Get-WindowsOptionalFeature -MockWith {
                throw 'DISM should not have been called'
            }

            $r = Test-HostPrereq -LabImagePath 'C:\LabImages'
            $r.Checks['HyperVFeature'].Pass | Should -BeTrue
            $r.Checks['HyperVFeature'].Message | Should -Match 'HypervisorPresent=True'
            Should -Invoke Get-WindowsOptionalFeature -Times 0
        }
    }

    It 'passes via vmms service when HypervisorPresent is false' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -MockWith {
                [pscustomobject]@{ HypervisorPresent = $false }
            }
            Mock Get-Service -ParameterFilter { $Name -eq 'vmms' } -MockWith {
                [pscustomobject]@{ Status = 'Running' }
            }
            Mock Get-WindowsOptionalFeature -MockWith {
                throw 'DISM should not have been called'
            }

            $r = Test-HostPrereq -LabImagePath 'C:\LabImages'
            $r.Checks['HyperVFeature'].Pass | Should -BeTrue
            $r.Checks['HyperVFeature'].Message | Should -Match 'Virtual Machine Management service is Running'
            Should -Invoke Get-WindowsOptionalFeature -Times 0
        }
    }

    It 'falls through to DISM when no fast path hits and reports the State' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -MockWith {
                [pscustomobject]@{ HypervisorPresent = $false }
            }
            Mock Get-Service -ParameterFilter { $Name -eq 'vmms' } -MockWith {
                throw 'no service'
            }
            Mock Get-WindowsOptionalFeature -MockWith {
                [pscustomobject]@{ State = 'Disabled' }
            }

            $r = Test-HostPrereq -LabImagePath 'C:\LabImages'
            $r.Checks['HyperVFeature'].Pass | Should -BeFalse
            $r.Checks['HyperVFeature'].Message | Should -Match 'Microsoft-Hyper-V state: Disabled'
            Should -Invoke Get-WindowsOptionalFeature -Times 1
        }
    }

    It 'reports the DISM error message when the COM provider fails' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -MockWith {
                [pscustomobject]@{ HypervisorPresent = $false }
            }
            Mock Get-Service -ParameterFilter { $Name -eq 'vmms' } -MockWith {
                throw 'no service'
            }
            Mock Get-WindowsOptionalFeature -MockWith {
                throw 'Class not registered'
            }

            $r = Test-HostPrereq -LabImagePath 'C:\LabImages'
            $r.Checks['HyperVFeature'].Pass | Should -BeFalse
            $r.Checks['HyperVFeature'].Message | Should -Match 'Class not registered'
        }
    }
}

Describe 'Test-HostPrereq MemoryBudget' {

    It 'skips the check when no demand is passed' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            $r = Test-HostPrereq -LabImagePath 'C:\LabImages'
            $r.Checks.Keys | Should -Not -Contain 'MemoryBudget'
        }
    }

    It 'passes a tiny demand against real host memory' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            $r = Test-HostPrereq -LabImagePath 'C:\LabImages' -VMStartupMemoryBytes 64MB
            $r.Checks['MemoryBudget'].Pass | Should -BeTrue
        }
    }

    It 'fails an absurd demand with an actionable message' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            $r = Test-HostPrereq -LabImagePath 'C:\LabImages' -VMStartupMemoryBytes 1PB
            $r.Checks['MemoryBudget'].Pass | Should -BeFalse
            $r.Checks['MemoryBudget'].Message | Should -Match 'Close host applications|reduce VM Memory'
        }
    }
}

Describe 'Test-HostPrereq VirtExtensions fast path' {

    It 'passes via HypervisorPresent without trusting Win32_Processor.VirtualizationFirmwareEnabled' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -MockWith {
                [pscustomobject]@{ HypervisorPresent = $true }
            }
            # Deliberately set the unreliable flag to $false to prove
            # the fast path ignores it.
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Processor' } -MockWith {
                [pscustomobject]@{
                    Name                          = 'Intel(R) Core(TM) Ultra 7 265K'
                    VirtualizationFirmwareEnabled = $false
                }
            }

            $r = Test-HostPrereq -LabImagePath 'C:\LabImages'
            $r.Checks['VirtExtensions'].Pass | Should -BeTrue
            $r.Checks['VirtExtensions'].Message | Should -Match 'hypervisor running, firmware virt enabled'
        }
    }

    It 'falls back to VirtualizationFirmwareEnabled when no hypervisor is loaded -- pass case' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -MockWith {
                [pscustomobject]@{ HypervisorPresent = $false }
            }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Processor' } -MockWith {
                [pscustomobject]@{
                    Name                          = 'Intel(R) Core(TM) Ultra 7 265K'
                    VirtualizationFirmwareEnabled = $true
                }
            }

            $r = Test-HostPrereq -LabImagePath 'C:\LabImages'
            $r.Checks['VirtExtensions'].Pass | Should -BeTrue
            $r.Checks['VirtExtensions'].Message | Should -Match 'virt enabled'
            $r.Checks['VirtExtensions'].Message | Should -Not -Match 'hypervisor running'
        }
    }

    It 'falls back to VirtualizationFirmwareEnabled when no hypervisor is loaded -- fail case' {
        InModuleScope HomeLab {
            Mock Write-LabLog -MockWith { }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } -MockWith {
                [pscustomobject]@{ HypervisorPresent = $false }
            }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Processor' } -MockWith {
                [pscustomobject]@{
                    Name                          = 'Some Older CPU'
                    VirtualizationFirmwareEnabled = $false
                }
            }

            $r = Test-HostPrereq -LabImagePath 'C:\LabImages'
            $r.Checks['VirtExtensions'].Pass | Should -BeFalse
            $r.Checks['VirtExtensions'].Message | Should -Match 'virt extensions not enabled in firmware'
        }
    }
}
