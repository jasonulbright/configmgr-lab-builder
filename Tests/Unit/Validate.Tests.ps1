#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Invoke-LabValidation and Install-CMConsole. Both wrap
    remote work in Invoke-LabCommand; these tests mock that call and cover
    result shaping, failure aggregation and parameter validation. The live
    behavior is proved by phase 12-Validate in a real lab run.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    $script:modRoot     = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private"
    . (Join-Path $script:helpersRoot 'Write-LabLog.ps1')
    . (Join-Path $script:helpersRoot 'Wait-LabReady.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabSession.ps1')
    . (Join-Path $script:helpersRoot 'Invoke-LabCommand.ps1')
    . (Join-Path $script:modRoot '12-Validate\Invoke-LabValidation.ps1')
    . (Join-Path $script:modRoot '10-Tools\Install-CMConsole.ps1')

    function New-FakeCred {
        $sec = ConvertTo-SecureString -String 'p' -AsPlainText -Force
        New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $sec)
    }

    function New-ClientResult {
        param([hashtable]$Override = @{})
        $o = [ordered]@{
            CcmExec = $true; Authority = 'SMS:MCM'; SiteClient = 1
            Trusted = $true; TrustError = $null
            RestSite = 'MCM'; RestError = $null
            PivotRows = 1; PivotError = $null
        }
        foreach ($k in $Override.Keys) { $o[$k] = $Override[$k] }
        [pscustomobject]$o
    }
}

Describe 'Invoke-LabValidation' {
    BeforeEach {
        Mock Write-LabLog { }
        Mock Start-Sleep { }
    }

    It 'rejects a site code that is not 3 characters' {
        { Invoke-LabValidation -SiteServer CM01 -DomainName contoso.com -SiteCode 'XX' `
            -AllVmNames CM01 -DomainCredential (New-FakeCred) } | Should -Throw '*length*'
    }

    It 'passes when every check passes' {
        $good = New-ClientResult
        Mock Invoke-LabCommand -MockWith {
            if ($ArgumentList) { return $good }
            if ($ScriptBlock.ToString() -match 'COMPUTERNAME') { return [pscustomobject]@{ Name = 'X' } }
            return [pscustomobject]@{ Exe = $true; Module = $true }
        }
        $r = Invoke-LabValidation -SiteServer CM01 -DomainName contoso.com -SiteCode MCM `
            -ClientNames CLIENT01 -AllVmNames DC01, CM01, CLIENT01 -DomainCredential (New-FakeCred)
        @($r | Where-Object { -not $_.Passed }).Count | Should -Be 0
        ($r | Where-Object Name -eq 'CMPivot').Passed | Should -BeTrue
        @($r | Where-Object Name -eq 'WinRM').Count | Should -Be 3
    }

    It 'throws after running every check when the certificate is not trusted' {
        $bad = New-ClientResult @{ Trusted = $false; TrustError = 'remote certificate is invalid'; RestSite = $null; PivotRows = $null }
        Mock Invoke-LabCommand -MockWith {
            if ($ArgumentList) { return $bad }
            if ($ScriptBlock.ToString() -match 'COMPUTERNAME') { return [pscustomobject]@{ Name = 'X' } }
            return [pscustomobject]@{ Exe = $true; Module = $true }
        }
        { Invoke-LabValidation -SiteServer CM01 -DomainName contoso.com -SiteCode MCM `
            -ClientNames CLIENT01 -AllVmNames CM01, CLIENT01 -DomainCredential (New-FakeCred) -TimeoutMinutes 1 } |
            Should -Throw '*AdminServiceTrust on CLIENT01*'
    }

    It 'returns the results with -NoThrow and marks a client with no CcmExec as not managed' {
        $bad = New-ClientResult @{ CcmExec = $false }
        Mock Invoke-LabCommand -MockWith {
            if ($ArgumentList) { return $bad }
            if ($ScriptBlock.ToString() -match 'COMPUTERNAME') { return [pscustomobject]@{ Name = 'X' } }
            return [pscustomobject]@{ Exe = $true; Module = $true }
        }
        $r = Invoke-LabValidation -SiteServer CM01 -DomainName contoso.com -SiteCode MCM `
            -ClientNames CLIENT01 -AllVmNames CM01 -DomainCredential (New-FakeCred) -TimeoutMinutes 1 -NoThrow
        ($r | Where-Object Name -eq 'ManagedClient').Passed | Should -BeFalse
    }

    It 'reports a WinRM failure without stopping the other checks' {
        $good = New-ClientResult
        Mock Invoke-LabCommand -MockWith {
            if ($ArgumentList) { return $good }
            if ($ScriptBlock.ToString() -match 'COMPUTERNAME') { throw 'WinRM cannot connect' }
            return [pscustomobject]@{ Exe = $true; Module = $true }
        }
        $r = Invoke-LabValidation -SiteServer CM01 -DomainName contoso.com -SiteCode MCM `
            -ClientNames CLIENT01 -AllVmNames CM01 -DomainCredential (New-FakeCred) -NoThrow
        ($r | Where-Object Name -eq 'WinRM').Passed | Should -BeFalse
        ($r | Where-Object Name -eq 'CMPivot').Passed | Should -BeTrue
    }
}

Describe 'Install-CMConsole' {
    It 'rejects a site code that is not 3 characters' {
        { Install-CMConsole -ComputerName CLIENT01 -DomainCredential (New-FakeCred) `
            -SiteServerFqdn CM01.contoso.com -SiteCode 'X' } | Should -Throw '*length*'
    }
    It 'reports the guest status' {
        Mock Write-LabLog { }
        Mock Invoke-LabCommand -MockWith { [pscustomobject]@{ Status = 'AlreadyInstalled' } }
        (Install-CMConsole -ComputerName CLIENT01 -DomainCredential (New-FakeCred) `
            -SiteServerFqdn CM01.contoso.com -SiteCode MCM).Status | Should -Be 'AlreadyInstalled'
    }
    It 'copies the installer with an explicit credential and cleans up the copy' {
        $src = Get-Content -Raw (Join-Path $script:modRoot '10-Tools\Install-CMConsole.ps1')
        $src | Should -Match '-Credential \$Cred'
        $src | Should -Match 'Remove-Item -Path \$work'
        $src | Should -Match 'AlreadyInstalled'
    }
}
