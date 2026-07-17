#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the public surface (S8): Install / Remove / Start /
    Stop / Test / Connect / Enter-HomeLab*. Orchestrators are tested by
    parameter shape + module exports; live behavior is integration-only.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    $script:manifest   = Join-Path $script:moduleRoot 'HomeLab.psd1'

    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $script:manifest -Force -ErrorAction Stop
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Module exports the documented public surface' {

    It 'exports all 7 public cmdlets' {
        $expected = @(
            'Install-HomeLab','Remove-HomeLab','Start-HomeLab','Stop-HomeLab',
            'Test-HomeLab','Connect-HomeLabVM','Enter-HomeLabSession'
        )
        $exported = (Get-Module HomeLab).ExportedFunctions.Keys
        foreach ($name in $expected) {
            $exported | Should -Contain $name
        }
    }

    It 'does not export internal helpers' {
        $exported = (Get-Module HomeLab).ExportedFunctions.Keys
        $internal = @(
            'Read-LabIni','Write-LabIni','Write-LabLog','Wait-LabReady',
            'Get-LabSession','Get-LabSessionCacheKey','Clear-LabSessionCache',
            'Invoke-LabCommand','Copy-LabFile',
            'Test-HostPrereq','Resolve-IsoEdition',
            'New-LabBaseImage','Install-LabDC','Install-CMSite',
            'New-CMUnattendIni','Set-CMDiscovery'
        )
        foreach ($name in $internal) {
            $exported | Should -Not -Contain $name
        }
    }
}

Describe 'Connect-HomeLabVM' {

    It 'rejects an empty ComputerName' {
        { Connect-HomeLabVM -ComputerName '' } | Should -Throw '*null*empty*'
    }
}

Describe 'Enter-HomeLabSession' {

    It 'rejects an unsupported Identity at parameter binding' {
        { Enter-HomeLabSession -ComputerName CM01 -Identity NotAnIdentity } |
            Should -Throw '*ValidateSet*'
    }
}

Describe 'Test-HomeLab' {

    It 'returns a report shape with DC / CM / Client / OverallReady fields when no VMs exist' {
        InModuleScope HomeLab {
            $cfg = Get-LabConfig
            # Seed a synthetic password so Get-LabCredential doesn't fall
            # through to its non-interactive throw inside the test runner.
            $cfg.AdminPass = 'TestP@ss123!'
            $r = Test-HomeLab -Config $cfg -ProbeTimeoutSeconds 5
            $r.PSObject.Properties.Name | Should -Contain 'DC'
            $r.PSObject.Properties.Name | Should -Contain 'CM'
            $r.PSObject.Properties.Name | Should -Contain 'Client'
            $r.PSObject.Properties.Name | Should -Contain 'OverallReady'
            $r.OverallReady              | Should -BeFalse
            $r.DC.State                  | Should -Be 'Missing'
        }
    }
}

Describe 'Stop-HomeLab' {

    It 'rejects a GracefulTimeoutSeconds below 10' {
        { Stop-HomeLab -GracefulTimeoutSeconds 5 } |
            Should -Throw '*minimum allowed range*'
    }

    It 'is a no-op when all configured VMs are missing' {
        InModuleScope HomeLab {
            { Stop-HomeLab } | Should -Not -Throw
        }
    }
}

Describe 'Install-HomeLab parameter validation' {

    It 'accepts -SkipPhases' {
        InModuleScope HomeLab {
            # Mock the elevation helper so the elevation throw fires
            # deterministically regardless of how the test harness was
            # launched (admin or not).
            Mock Test-LabIsElevated -MockWith { $false }
            { Install-HomeLab -SkipPhases @('01-Prereq') } |
                Should -Throw '*must be elevated*'
        }
    }

    It 'accepts -ParallelThrottle within range' {
        InModuleScope HomeLab {
            Mock Test-LabIsElevated -MockWith { $false }
            { Install-HomeLab -ParallelThrottle 6 } |
                Should -Throw '*must be elevated*'
        }
    }

    It 'rejects -ParallelThrottle below 1' {
        { Install-HomeLab -ParallelThrottle 0 } |
            Should -Throw '*minimum allowed range*'
    }

    It 'rejects -ParallelThrottle above 16' {
        { Install-HomeLab -ParallelThrottle 17 } |
            Should -Throw '*maximum allowed range*'
    }
}

Describe 'Remove-HomeLab parameter validation' {

    It 'requires elevation' {
        InModuleScope HomeLab {
            Mock Test-LabIsElevated -MockWith { $false }
            { Remove-HomeLab -Confirm:$false } |
                Should -Throw '*must be elevated*'
        }
    }

    It 'rejects -KeepBaseImages together with -RemoveBaseImageCache' {
        InModuleScope HomeLab {
            Mock Test-LabIsElevated -MockWith { $true }
            { Remove-HomeLab -KeepBaseImages -RemoveBaseImageCache -Confirm:$false } |
                Should -Throw '*mutually exclusive*'
        }
    }
}
