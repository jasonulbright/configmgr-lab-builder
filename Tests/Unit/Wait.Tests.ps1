#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Wait-LabReady.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    . (Join-Path $script:helpersRoot 'Write-LabLog.ps1')
    . (Join-Path $script:helpersRoot 'Wait-LabReady.ps1')

    # Suppress console output during tests by redirecting log to TestDrive.
    $env:HOMELAB_LOG_DIR = (New-Item -Path (Join-Path $TestDrive 'wait-logs') -ItemType Directory -Force).FullName
}

AfterAll {
    Remove-Item Env:\HOMELAB_LOG_DIR -ErrorAction SilentlyContinue
}

Describe 'Wait-LabReady' {

    It 'returns true when the predicate is immediately truthy' {
        $r = Wait-LabReady -TimeoutSeconds 5 -IntervalSeconds 1 -Activity 'immediate' -Predicate { $true }
        $r | Should -BeTrue
    }

    It 'returns true once the predicate becomes truthy' {
        $script:counter = 0
        $r = Wait-LabReady -TimeoutSeconds 10 -IntervalSeconds 1 -Activity 'eventual' -Predicate {
            $script:counter++
            $script:counter -ge 3
        }
        $r | Should -BeTrue
        $script:counter | Should -BeGreaterOrEqual 3
    }

    It 'returns false on timeout without -ThrowOnTimeout' {
        $r = Wait-LabReady -TimeoutSeconds 2 -IntervalSeconds 1 -Activity 'never' -Predicate { $false }
        $r | Should -BeFalse
    }

    It 'throws TimeoutException with -ThrowOnTimeout' {
        { Wait-LabReady -TimeoutSeconds 2 -IntervalSeconds 1 -Activity 'never' -ThrowOnTimeout -Predicate { $false } } |
            Should -Throw -ExceptionType ([System.TimeoutException])
    }

    It 'treats predicate exceptions as not-ready (continues until timeout)' {
        $script:tries = 0
        $r = Wait-LabReady -TimeoutSeconds 3 -IntervalSeconds 1 -Activity 'transient' -Predicate {
            $script:tries++
            if ($script:tries -lt 2) { throw 'transient WMI failure' }
            $true
        }
        $r | Should -BeTrue
        $script:tries | Should -BeGreaterOrEqual 2
    }
}
