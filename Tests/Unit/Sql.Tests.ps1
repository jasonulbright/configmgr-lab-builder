#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for S4 SQL helpers. New-LabSqlConfigIni gets full INI
    shape coverage (it's the gateway to setup.exe parameter-binding
    failures); the other three are remote-call orchestrators with
    parameter-validation tests only.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    $script:sqlRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\06-Sql"

    . (Join-Path $script:helpersRoot 'Read-LabIni.ps1')
    . (Join-Path $script:helpersRoot 'Write-LabIni.ps1')
    . (Join-Path $script:helpersRoot 'Write-LabLog.ps1')
    . (Join-Path $script:helpersRoot 'Wait-LabReady.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabSession.ps1')
    . (Join-Path $script:helpersRoot 'Invoke-LabCommand.ps1')
    . (Join-Path $script:helpersRoot 'Copy-LabFile.ps1')

    . (Join-Path $script:sqlRoot 'New-LabSqlConfigIni.ps1')
    . (Join-Path $script:sqlRoot 'Install-LabSqlServer.ps1')
    . (Join-Path $script:sqlRoot 'Set-LabSqlMemory.ps1')
    . (Join-Path $script:sqlRoot 'Set-LabSqlFirewall.ps1')

    function New-FakeCred {
        param([string]$User = 'CONTOSO\Administrator', [string]$Pass = 'p')
        $sec = ConvertTo-SecureString -String $Pass -AsPlainText -Force
        New-Object System.Management.Automation.PSCredential($User, $sec)
    }

    $script:goodAccounts = @(
        'BUILTIN\Administrators',
        'CONTOSO\Domain Admins',
        'CONTOSO\CM01$'
    )
}

Describe 'New-LabSqlConfigIni' {

    BeforeEach {
        $script:iniPath = Join-Path $TestDrive ('sql-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.ini')
        $null = New-LabSqlConfigIni `
            -SaPassword 'P@ssw0rd!' `
            -SqlSysAdminAccounts $script:goodAccounts `
            -OutputPath $script:iniPath
    }

    It 'writes the file at the path returned' {
        Test-Path $script:iniPath | Should -BeTrue
    }

    It 'is parseable by Read-LabIni and emits a single OPTIONS section' {
        $cfg = Read-LabIni -Path $script:iniPath
        @($cfg.Keys) | Should -Be @('OPTIONS')
    }

    It 'sets ACTION=Install and QUIET=True' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['ACTION'] | Should -Be 'Install'
        $cfg['OPTIONS']['QUIET']  | Should -Be 'True'
    }

    It 'declares only the SQLENGINE feature (no SSAS / IS / RS)' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['FEATURES'] | Should -Be 'SQLENGINE'
    }

    It 'sets the default instance name MSSQLSERVER' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['INSTANCENAME'] | Should -Be 'MSSQLSERVER'
    }

    It 'pins the CM 2509-required collation' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['SQLCOLLATION'] | Should -Be 'SQL_Latin1_General_CP1_CI_AS'
    }

    It 'sets SECURITYMODE=SQL (mixed mode)' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['SECURITYMODE'] | Should -Be 'SQL'
    }

    It 'wraps the sa password in double quotes (setup.exe expects quoting)' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['SAPWD'] | Should -Be '"P@ssw0rd!"'
    }

    It 'wraps each sysadmin account in double quotes, space-separated' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['SQLSYSADMINACCOUNTS'] |
            Should -Be '"BUILTIN\Administrators" "CONTOSO\Domain Admins" "CONTOSO\CM01$"'
    }

    It 'enables TCP and disables Named Pipes' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['TCPENABLED'] | Should -Be '1'
        $cfg['OPTIONS']['NPENABLED']  | Should -Be '0'
    }

    It 'turns UPDATEENABLED off (offline lab)' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['UPDATEENABLED'] | Should -Be 'False'
    }

    It 'accepts the SQL license terms' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['OPTIONS']['IACCEPTSQLSERVERLICENSETERMS'] | Should -Be 'True'
    }

    It 'writes ASCII (no BOM) so setup.exe parses cleanly' {
        $bytes = [System.IO.File]::ReadAllBytes($script:iniPath)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
            Should -BeFalse
    }

    It 'merges ConfigOverrides on top of defaults via a follow-up write' {
        # Round-trip the call path Install-LabSqlServer uses for overrides.
        $p = Join-Path $TestDrive 'override.ini'
        New-LabSqlConfigIni -SaPassword 'pw' -SqlSysAdminAccounts @('BUILTIN\Administrators') -OutputPath $p | Out-Null
        $cfg = Read-LabIni -Path $p
        $cfg['OPTIONS']['SQLUSERDBDIR'] = '"F:\OverrideData"'
        Write-LabIni -Data $cfg -Path $p -Encoding ASCII

        $reloaded = Read-LabIni -Path $p
        $reloaded['OPTIONS']['SQLUSERDBDIR'] | Should -Be '"F:\OverrideData"'
    }

    It 'rejects an empty SqlSysAdminAccounts list at parameter binding' {
        { New-LabSqlConfigIni -SaPassword 'pw' -SqlSysAdminAccounts @() -OutputPath (Join-Path $TestDrive 'x.ini') } |
            Should -Throw '*null*empty*'
    }
}

Describe 'Install-LabSqlServer parameter validation' {

    It 'rejects a missing ISO path' {
        { Install-LabSqlServer -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -IsoPath 'C:\does-not-exist.iso' -SaPassword 'pw' `
            -SqlSysAdminAccounts $script:goodAccounts } |
            Should -Throw '*ISO not found*'
    }

    It 'short-circuits when SQL is already installed' {
        $iso = Join-Path $TestDrive 'fake.iso'
        Set-Content -Path $iso -Value 'fake'
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ Installed = $true; Status = 'Running' }
        }
        $r = Install-LabSqlServer -ComputerName CM01 -DomainCredential (New-FakeCred) `
                -IsoPath $iso -SaPassword 'pw' -SqlSysAdminAccounts $script:goodAccounts
        $r.Status | Should -Be 'AlreadyInstalled'
    }
}

Describe 'Set-LabSqlMemory parameter validation' {

    It 'rejects MaxMemoryMB below 512' {
        { Set-LabSqlMemory -ComputerName CM01 -DomainCredential (New-FakeCred) -MaxMemoryMB 256 } |
            Should -Throw '*minimum allowed range*'
    }

    It 'short-circuits when current value already matches' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ Status = 'AlreadySet'; CurrentMB = 8192 }
        }
        $r = Set-LabSqlMemory -ComputerName CM01 -DomainCredential (New-FakeCred) -MaxMemoryMB 8192
        $r.Status | Should -Be 'AlreadySet'
    }
}

Describe 'Set-LabSqlFirewall' {

    It 'reports counts of created vs skipped rules' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ Created = @('HomeLab-SQL-Engine-1433'); Skipped = @('HomeLab-SQL-Browser-1434') }
        }
        $r = Set-LabSqlFirewall -ComputerName CM01 -DomainCredential (New-FakeCred)
        $r.Created.Count + $r.Skipped.Count | Should -Be 2
    }
}
