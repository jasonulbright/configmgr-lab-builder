#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Register-CMDiscoveryRelaxTask. Mocks
    Invoke-LabCommand so the test never registers a real Windows
    scheduled task; verifies parameter validation and that the
    encoded relax script the helper builds embeds the right site
    code and cadence.
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

Describe 'Register-CMDiscoveryRelaxTask parameter validation' {

    It 'rejects a SiteCode of length != 3' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Register-CMDiscoveryRelaxTask -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode 'TOOLONG' } | Should -Throw '*length*'
        }
    }

    It 'rejects DelayHours below 1' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Register-CMDiscoveryRelaxTask -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -DelayHours 0 } | Should -Throw '*range*'
        }
    }

    It 'rejects DelayHours above 168 (1 week)' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Register-CMDiscoveryRelaxTask -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -DelayHours 169 } | Should -Throw '*range*'
        }
    }

    It 'rejects RelaxedDeltaMinutes below 5' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            { Register-CMDiscoveryRelaxTask -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -RelaxedDeltaMinutes 1 } | Should -Throw '*range*'
        }
    }
}

Describe 'Register-CMDiscoveryRelaxTask payload' {

    It 'embeds the site code and cadence into the encoded relax script' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            $script:capturedArgs = $null
            Mock Write-LabLog -MockWith { }
            Mock Invoke-LabCommand -MockWith {
                $script:capturedArgs = $ArgumentList
                return [pscustomobject]@{
                    TaskName = 'HomeLab-Relax-Discovery'
                    State    = 'Ready'
                    NextRun  = (Get-Date).AddHours(6)
                }
            }

            Register-CMDiscoveryRelaxTask -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -DelayHours 6 -RelaxedDeltaMinutes 360 | Out-Null

            # ArgumentList passed to Invoke-LabCommand: TaskName, Encoded, DelayHours
            $script:capturedArgs[0] | Should -Be 'HomeLab-Relax-Discovery'
            $script:capturedArgs[2] | Should -Be 6

            $encoded = $script:capturedArgs[1]
            $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
            $decoded | Should -Match "Set-Location 'MCM:'"
            $decoded | Should -Match "ActiveDirectorySystemDiscovery -SiteCode 'MCM' -DeltaDiscoveryMins 360"
            $decoded | Should -Match "ActiveDirectoryUserDiscovery\s+-SiteCode 'MCM' -DeltaDiscoveryMins 360"
            $decoded | Should -Match "Unregister-ScheduledTask -TaskName 'HomeLab-Relax-Discovery'"
        }
    }

    It 'honours a custom RelaxedDeltaMinutes (e.g. 720 = 12h)' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            $script:capturedArgs = $null
            Mock Write-LabLog -MockWith { }
            Mock Invoke-LabCommand -MockWith {
                $script:capturedArgs = $ArgumentList
                return [pscustomobject]@{ TaskName='X'; State='Ready'; NextRun=(Get-Date) }
            }

            Register-CMDiscoveryRelaxTask -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -RelaxedDeltaMinutes 720 | Out-Null

            $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:capturedArgs[1]))
            $decoded | Should -Match 'DeltaDiscoveryMins 720'
        }
    }

    It 'honours a custom TaskName' {
        InModuleScope HomeLab -Parameters @{ Cred = $script:cred } {
            param($Cred)
            $script:capturedArgs = $null
            Mock Write-LabLog -MockWith { }
            Mock Invoke-LabCommand -MockWith {
                $script:capturedArgs = $ArgumentList
                return [pscustomobject]@{ TaskName='X'; State='Ready'; NextRun=(Get-Date) }
            }

            Register-CMDiscoveryRelaxTask -ComputerName CM01 -DomainCredential $Cred `
                -SiteCode MCM -TaskName 'Foo-Bar' | Out-Null

            $script:capturedArgs[0] | Should -Be 'Foo-Bar'
            $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:capturedArgs[1]))
            $decoded | Should -Match "Unregister-ScheduledTask -TaskName 'Foo-Bar'"
        }
    }
}
