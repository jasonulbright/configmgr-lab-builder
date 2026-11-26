#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for WSUS publishing prep: Install-LabWsusConsole and
    Set-LabWsusPublishing. Both wrap remote work in Invoke-LabCommand; these
    tests mock that call and cover result shaping, failure aggregation, the
    idempotency rules in the guest code, and that the orchestrator runs the
    step by default. The live behavior is proved in a real lab run.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    $script:toolsRoot   = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\10-Tools"
    $script:publicRoot  = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Public"
    . (Join-Path $script:helpersRoot 'Write-LabLog.ps1')
    . (Join-Path $script:helpersRoot 'Wait-LabReady.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabSession.ps1')
    . (Join-Path $script:helpersRoot 'Invoke-LabCommand.ps1')
    . (Join-Path $script:toolsRoot 'Install-LabWsusConsole.ps1')
    . (Join-Path $script:toolsRoot 'Set-LabWsusPublishing.ps1')

    function New-FakeCred {
        $sec = ConvertTo-SecureString -String 'p' -AsPlainText -Force
        New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $sec)
    }
}

Describe 'Install-LabWsusConsole' {
    BeforeEach { Mock Write-LabLog { } }

    It 'reports the guest status' {
        Mock Invoke-LabCommand -MockWith { [pscustomobject]@{ Status = 'AlreadyInstalled' } }
        (Install-LabWsusConsole -ComputerName CLIENT01 -DomainCredential (New-FakeCred)).Status |
            Should -Be 'AlreadyInstalled'
    }

    It 'uses the server feature and the client RSAT capability, and skips when the API exists' {
        $src = Get-Content -Raw (Join-Path $script:toolsRoot 'Install-LabWsusConsole.ps1')
        $src | Should -Match 'UpdateServices-UI'
        $src | Should -Match 'Rsat\.WSUS\.Tools~~~~0\.0\.1\.0'
        $src | Should -Match 'Microsoft\.UpdateServices\.Administration'
        $src | Should -Match 'AlreadyInstalled'
        $src | Should -Match 'missing after the install'
    }
}

Describe 'Install-LabWsusConsole client install' {
    BeforeAll {
        $script:consoleSource = Get-Content -Raw (Join-Path $script:toolsRoot 'Install-LabWsusConsole.ps1')
    }

    It 'takes the WSUS source values and the policy cache away and puts both back after a failure' {
        $script:consoleSource | Should -Match 'UpdatePolicy\\GPCache'
        $script:consoleSource | Should -Match "'WUServer', 'WUStatusServer'"
        $script:consoleSource | Should -Match '(?s)finally\s*\{\s*Restore-UpdatePolicy'
    }

    It 'does not redirect the error stream of reg import' {
        $script:consoleSource | Should -Not -Match 'reg\.exe import [^\r\n]*2>&1'
    }

    It 'installs on a client in a task as SYSTEM and removes the task' {
        $script:consoleSource | Should -Match "-User 'SYSTEM'"
        $script:consoleSource | Should -Match 'Unregister-ScheduledTask'
    }
}

Describe 'Set-LabWsusPublishing' {
    BeforeEach { Mock Write-LabLog { } }

    It 'rejects a subject that is not a CN' {
        { Set-LabWsusPublishing -ComputerName CM01 -DomainCredential (New-FakeCred) -CertificateSubject 'Bad' } |
            Should -Throw
    }

    It 'trusts the server and every client and returns the thumbprint' {
        Mock Invoke-LabCommand -MockWith {
            if ($Activity -like 'Create*') {
                return [pscustomobject]@{
                    Thumbprint = 'AB12'; Status = 'Created'; CertBase64 = 'AAAA'
                    Trust = [pscustomobject]@{ Computer = 'CM01'; Added = @('Root'); Trusted = $true }
                }
            }
            [pscustomobject]@{ Computer = $ComputerName; Added = @(); Trusted = $true }
        }
        $r = Set-LabWsusPublishing -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -TrustedComputerName CLIENT01, CLIENT02
        $r.Thumbprint | Should -Be 'AB12'
        $r.Status | Should -Be 'Created'
        @($r.Computers).Count | Should -Be 3
        Should -Invoke Invoke-LabCommand -Times 3 -Exactly
    }

    It 'throws and names the computer when a trust check fails' {
        Mock Invoke-LabCommand -MockWith {
            if ($Activity -like 'Create*') {
                return [pscustomobject]@{
                    Thumbprint = 'AB12'; Status = 'Reused'; CertBase64 = 'AAAA'
                    Trust = [pscustomobject]@{ Computer = 'CM01'; Added = @(); Trusted = $true }
                }
            }
            [pscustomobject]@{ Computer = 'CLIENT01'; Added = @(); Trusted = $false }
        }
        { Set-LabWsusPublishing -ComputerName CM01 -DomainCredential (New-FakeCred) -TrustedComputerName CLIENT01 } |
            Should -Throw '*incomplete on: CLIENT01*'
    }

    It 'throws when the server itself is not trusted' {
        Mock Invoke-LabCommand -MockWith {
            [pscustomobject]@{
                Thumbprint = 'AB12'; Status = 'Reused'; CertBase64 = 'AAAA'
                Trust = [pscustomobject]@{ Computer = 'CM01'; Added = @(); Trusted = $false }
            }
        }
        { Set-LabWsusPublishing -ComputerName CM01 -DomainCredential (New-FakeCred) } |
            Should -Throw '*incomplete on: CM01*'
    }

    It 'checks the self-signed certificate registry value' {
        $src = Get-Content -Raw (Join-Path $script:toolsRoot 'Set-LabWsusPublishing.ps1')
        $src | Should -Match 'EnableSelfSignedCertificates is not set'
    }

    It 'keeps the guest steps idempotent and sends only the public certificate' {
        $src = Get-Content -Raw (Join-Path $script:toolsRoot 'Set-LabWsusPublishing.ps1')
        $src | Should -Match "Status = 'Reused'"
        $src | Should -Match "Where-Object \{ \`$_\.Thumbprint -eq \`$cert\.Thumbprint \}"
        $src | Should -Match "'TrustedPublisher', 'Root'"
        $src | Should -Match 'AcceptTrustedPublisherCerts'
        $src | Should -Match 'EnableSelfSignedCertificates'
        $src | Should -Match "Export\('Cert'\)"
        $src | Should -Not -Match "Export\('Pfx'"
    }
}

Describe 'Install-HomeLab WSUS publishing option' {
    It 'is on by default and has an opt-out switch' {
        $src = Get-Content -Raw (Join-Path $script:publicRoot 'Install-HomeLab.ps1')
        $src | Should -Match '\[switch\]\$SkipWsusPublishing'
        $src | Should -Match 'if \(-not \$SkipWsusPublishing\)'
        $src | Should -Match 'Install-LabWsusConsole'
        $src | Should -Match 'Set-LabWsusPublishing'
    }
}
