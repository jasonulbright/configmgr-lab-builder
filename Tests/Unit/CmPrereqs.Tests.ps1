#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for S5 (CM prereqs + WSUS + host-side Hyper-V).
    Mostly remote orchestrators; parameter-validation + idempotency
    short-circuit + fail-soft paths covered. Live install behavior
    lives in Tests/Integration/.
#>

BeforeAll {
    $script:helpersRoot   = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    $script:prereqRoot    = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\01-Prereq"
    $script:cmPrereqRoot  = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\07-CMPrereqs"

    . (Join-Path $script:helpersRoot 'Write-LabLog.ps1')
    . (Join-Path $script:helpersRoot 'Wait-LabReady.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabSession.ps1')
    . (Join-Path $script:helpersRoot 'Invoke-LabCommand.ps1')
    . (Join-Path $script:helpersRoot 'Copy-LabFile.ps1')

    . (Join-Path $script:prereqRoot 'Install-LabHyperV.ps1')

    . (Join-Path $script:cmPrereqRoot 'Install-LabVcRedist.ps1')
    . (Join-Path $script:cmPrereqRoot 'Install-LabOdbcDriver.ps1')
    . (Join-Path $script:cmPrereqRoot 'Install-LabMsOleDb.ps1')
    . (Join-Path $script:cmPrereqRoot 'Install-LabAdk.ps1')
    . (Join-Path $script:cmPrereqRoot 'Install-LabAdkPe.ps1')
    . (Join-Path $script:cmPrereqRoot 'Install-LabWsus.ps1')
    . (Join-Path $script:cmPrereqRoot 'Set-LabDefenderExclusions.ps1')

    function New-FakeCred {
        $sec = ConvertTo-SecureString -String 'p' -AsPlainText -Force
        New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $sec)
    }

    function New-FakeFile {
        param([string]$Name)
        $p = Join-Path $TestDrive $Name
        Set-Content -Path $p -Value 'fake'
        return $p
    }
}

Describe 'Install-LabVcRedist' {

    It 'rejects a missing x64 source path' {
        { Install-LabVcRedist -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -X64Path 'C:\does-not-exist.exe' } |
            Should -Throw '*source not found*'
    }

    It 'reports RebootRequired=true when either arch returns 3010' {
        $x64 = New-FakeFile 'vc_redist.x64.exe'
        $x86 = New-FakeFile 'vc_redist.x86.exe'
        $script:exits = @(3010, 0)
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            if ($ScriptBlock.ToString() -match 'New-Item') { return $null }
            $script:exits[0]
            $script:exits = $script:exits[1..($script:exits.Count - 1)]
        }
        Mock Copy-LabFile -MockWith { }

        $r = Install-LabVcRedist -ComputerName CM01 -DomainCredential (New-FakeCred) -X64Path $x64 -X86Path $x86
        $r.RebootRequired | Should -BeTrue
        $r.X64ExitCode    | Should -Be 3010
        $r.X86ExitCode    | Should -Be 0
    }

    It 'throws on an unexpected non-zero exit' {
        $x64 = New-FakeFile 'vc_redist.x64.exe'
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            if ($ScriptBlock.ToString() -match 'New-Item') { return $null }
            5
        }
        Mock Copy-LabFile -MockWith { }
        { Install-LabVcRedist -ComputerName CM01 -DomainCredential (New-FakeCred) -X64Path $x64 } |
            Should -Throw '*returned 5*'
    }
}

Describe 'Install-LabOdbcDriver' {

    It 'rejects a missing MSI path' {
        { Install-LabOdbcDriver -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -MsiPath 'C:\does-not-exist.msi' } |
            Should -Throw '*MSI not found*'
    }

    It 'reports RebootRequired on exit 3010' {
        $msi = New-FakeFile 'msodbcsql.msi'
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            if ($ScriptBlock.ToString() -match 'New-Item') { return $null }
            3010
        }
        Mock Copy-LabFile -MockWith { }
        $r = Install-LabOdbcDriver -ComputerName CM01 -DomainCredential (New-FakeCred) -MsiPath $msi
        $r.RebootRequired | Should -BeTrue
        $r.ExitCode | Should -Be 3010
    }

    It 'reports AlreadyNewer on exit 1638' {
        $msi = New-FakeFile 'msodbcsql.msi'
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            if ($ScriptBlock.ToString() -match 'New-Item') { return $null }
            1638
        }
        Mock Copy-LabFile -MockWith { }
        $r = Install-LabOdbcDriver -ComputerName CM01 -DomainCredential (New-FakeCred) -MsiPath $msi
        $r.AlreadyNewer | Should -BeTrue
    }
}

Describe 'Install-LabMsOleDb (fail-soft)' {

    It 'returns Skipped=true when source MSI is missing' {
        $r = Install-LabMsOleDb -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -MsiPath 'C:\does-not-exist.msi'
        $r.Skipped | Should -BeTrue
        $r.Reason  | Should -Be 'SourceNotFound'
    }

    It 'returns Skipped=true when copy fails' {
        $msi = New-FakeFile 'msoledbsql.msi'
        Mock Invoke-LabCommand -MockWith { return $null }
        Mock Copy-LabFile -MockWith { throw 'simulated copy failure' }
        $r = Install-LabMsOleDb -ComputerName CM01 -DomainCredential (New-FakeCred) -MsiPath $msi
        $r.Skipped | Should -BeTrue
        $r.Reason  | Should -Be 'CopyFailed'
    }
}

Describe 'Install-LabAdk' {

    It 'rejects a missing offline layout folder' {
        { Install-LabAdk -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -OfflineLayoutPath 'C:\does-not-exist' } |
            Should -Throw '*offline layout not found*'
    }

    It 'rejects a layout folder without adksetup.exe' {
        $empty = Join-Path $TestDrive 'empty-adk'
        New-Item -Path $empty -ItemType Directory -Force | Out-Null
        { Install-LabAdk -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -OfflineLayoutPath $empty } |
            Should -Throw '*adksetup.exe missing*'
    }

    It 'forwards the configured features to the inside-VM script' {
        $layout = Join-Path $TestDrive 'adk-layout'
        New-Item -Path $layout -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $layout 'adksetup.exe') -Value 'fake'

        $script:capturedFeatures = $null
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            if ($ScriptBlock.ToString() -match 'Test-Path') { return $null }
            $script:capturedFeatures = $ArgumentList[2]
            return 0
        }
        Mock Copy-LabFile -MockWith { }

        Install-LabAdk -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -OfflineLayoutPath $layout `
            -Features @('OptionId.DeploymentTools','OptionId.UserStateMigrationTool','OptionId.WindowsPerformanceToolkit') | Out-Null

        $script:capturedFeatures | Should -Be @('OptionId.DeploymentTools','OptionId.UserStateMigrationTool','OptionId.WindowsPerformanceToolkit')
    }
}

Describe 'Install-LabAdkPe' {

    It 'rejects a missing offline layout folder' {
        { Install-LabAdkPe -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -OfflineLayoutPath 'C:\does-not-exist' } |
            Should -Throw '*offline layout not found*'
    }
}

Describe 'Install-LabWsus' {

    It 'short-circuits when WSUS service is already running' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ Status = 'AlreadyInstalled'; ContentDir = 'C:\WSUS' }
        }
        $r = Install-LabWsus -ComputerName CM01 -DomainCredential (New-FakeCred)
        $r.Status | Should -Be 'AlreadyInstalled'
    }

    It 'returns Installed status from a fresh install' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ Status = 'Installed'; ContentDir = 'C:\WSUS'; SqlInstance = 'CM01'; RestartNeeded = $false }
        }
        $r = Install-LabWsus -ComputerName CM01 -DomainCredential (New-FakeCred)
        $r.Status | Should -Be 'Installed'
    }
}

Describe 'Set-LabDefenderExclusions' {

    It 'appends ExtraPaths to the default exclusion list' {
        $script:capturedPaths = $null
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            # Function passes the path array wrapped via (,$allPaths) so
            # the script block's $Paths receives the array intact.
            # ArgumentList[0] is therefore the full path array.
            $script:capturedPaths = $ArgumentList[0]
            return [pscustomobject]@{ Applied = $ArgumentList[0].Count; Skipped = 0 }
        }
        Set-LabDefenderExclusions -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -ExtraPaths @('D:\Extra1','E:\Extra2') | Out-Null

        $script:capturedPaths.Count | Should -BeGreaterThan 10
        $script:capturedPaths | Should -Contain 'C:\Program Files\Microsoft Configuration Manager'
        $script:capturedPaths | Should -Contain 'D:\SQLData'
        $script:capturedPaths | Should -Contain 'D:\Extra1'
        $script:capturedPaths | Should -Contain 'E:\Extra2'
    }

    It 'passes no null element when -ExtraPaths is omitted' {
        # Regression: @($defaultPaths) + @($ExtraPaths) with $null
        # ExtraPaths appended a literal $null, which made the remote
        # Add-MpPreference reject the entire array (first real-host run,
        # 2026-07-16).
        $script:capturedPaths2 = $null
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:capturedPaths2 = $ArgumentList[0]
            return [pscustomobject]@{ Applied = $ArgumentList[0].Count; Skipped = 0 }
        }
        Set-LabDefenderExclusions -ComputerName CM01 -DomainCredential (New-FakeCred) | Out-Null

        $script:capturedPaths2 | Should -Not -Contain $null
        @($script:capturedPaths2 | Where-Object { [string]::IsNullOrEmpty($_) }).Count | Should -Be 0
        $script:capturedPaths2.Count | Should -BeGreaterThan 10
    }
}
