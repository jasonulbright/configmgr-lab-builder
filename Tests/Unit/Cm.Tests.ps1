#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for S6 (CM 2509 site install). Covers the testable
    bits: CM unattend INI shape, ConfigMgrSetup.log parser on
    synthetic input, idempotency short-circuits.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    $script:cmRoot      = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\08-CM"

    . (Join-Path $script:helpersRoot 'Read-LabIni.ps1')
    . (Join-Path $script:helpersRoot 'Write-LabIni.ps1')
    . (Join-Path $script:helpersRoot 'Write-LabLog.ps1')
    . (Join-Path $script:helpersRoot 'Wait-LabReady.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabSession.ps1')
    . (Join-Path $script:helpersRoot 'Invoke-LabCommand.ps1')
    . (Join-Path $script:helpersRoot 'Copy-LabFile.ps1')

    . (Join-Path $script:cmRoot 'New-CMUnattendIni.ps1')
    . (Join-Path $script:cmRoot 'Resolve-CMSetupLogStatus.ps1')
    . (Join-Path $script:cmRoot 'Test-CMSetupLog.ps1')
    . (Join-Path $script:cmRoot 'Wait-CMReady.ps1')
    . (Join-Path $script:cmRoot 'Import-CMModule.ps1')
    . (Join-Path $script:cmRoot 'Install-CMSite.ps1')

    function New-FakeCred {
        $sec = ConvertTo-SecureString -String 'p' -AsPlainText -Force
        New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $sec)
    }
}

Describe 'New-CMUnattendIni' {

    BeforeEach {
        $script:iniPath = Join-Path $TestDrive ('cm-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.ini')
        $null = New-CMUnattendIni `
            -CMServerFqdn 'CM01.contoso.com' `
            -SiteCode 'MCM' -SiteName 'Home Lab Primary Site' `
            -OutputPath $script:iniPath
    }

    It 'is parseable by Read-LabIni and has the documented sections' {
        $cfg = Read-LabIni -Path $script:iniPath
        @($cfg.Keys) | Should -Be @(
            'Identification','Options','SQLConfigOptions',
            'CloudConnectorOptions','SystemCenterOptions','HierarchyExpansionOption'
        )
    }

    It 'sets Action=InstallPrimarySite' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['Identification']['Action'] | Should -Be 'InstallPrimarySite'
    }

    It 'omits the Preview key for Branch=CB (default)' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['Identification'].Contains('Preview') | Should -BeFalse
    }

    It 'emits Preview=1 for Branch=TP' {
        $p = Join-Path $TestDrive 'tp.ini'
        New-CMUnattendIni `
            -CMServerFqdn 'CM01.contoso.com' `
            -SiteCode 'MCM' -SiteName 'TP Lab' -Branch TP `
            -OutputPath $p | Out-Null
        $cfg = Read-LabIni -Path $p
        $cfg['Identification']['Preview'] | Should -Be '1'
    }

    It 'pins ProductID to EVAL by default' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['Options']['ProductID'] | Should -Be 'EVAL'
    }

    It 'sets SiteCode + SiteName + SDKServer correctly' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['Options']['SiteCode']  | Should -Be 'MCM'
        $cfg['Options']['SiteName']  | Should -Be 'Home Lab Primary Site'
        $cfg['Options']['SDKServer'] | Should -Be 'CM01.contoso.com'
    }

    It 'configures both Management Point and Distribution Point on the site server' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['Options']['ManagementPoint']            | Should -Be 'CM01.contoso.com'
        $cfg['Options']['ManagementPointProtocol']    | Should -Be 'HTTP'
        $cfg['Options']['DistributionPoint']          | Should -Be 'CM01.contoso.com'
        $cfg['Options']['DistributionPointProtocol']  | Should -Be 'HTTP'
        $cfg['Options']['DistributionPointInstallIIS']| Should -Be '1'
    }

    It 'sets PrerequisiteComp=0 by default (no offline cache)' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['Options']['PrerequisiteComp'] | Should -Be '0'
    }

    It 'sets PrerequisiteComp=1 when -PrerequisitePathHasFiles is true' {
        $p = Join-Path $TestDrive 'prereq.ini'
        New-CMUnattendIni `
            -CMServerFqdn 'CM01.contoso.com' `
            -SiteCode 'MCM' -SiteName 'X' -PrerequisitePathHasFiles $true `
            -OutputPath $p | Out-Null
        $cfg = Read-LabIni -Path $p
        $cfg['Options']['PrerequisiteComp'] | Should -Be '1'
    }

    It 'configures the SQL section with default DB name CM_<SiteCode>' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['SQLConfigOptions']['SQLServerName']   | Should -Be 'CM01.contoso.com'
        $cfg['SQLConfigOptions']['DatabaseName']    | Should -Be 'CM_MCM'
        $cfg['SQLConfigOptions']['SQLSSBPort']      | Should -Be '4022'
        $cfg['SQLConfigOptions']['SQLDataFilePath'] | Should -Be 'C:\SQLData'
        $cfg['SQLConfigOptions']['SQLLogFilePath']  | Should -Be 'C:\SQLLogs'
    }

    It 'turns off CloudConnector for the offline lab' {
        $cfg = Read-LabIni -Path $script:iniPath
        $cfg['CloudConnectorOptions']['CloudConnector'] | Should -Be '0'
    }

    It 'rejects a 4-character SiteCode' {
        { New-CMUnattendIni -CMServerFqdn 'x' -SiteCode 'TOOX' -SiteName 'x' `
            -OutputPath (Join-Path $TestDrive 'bad.ini') } |
            Should -Throw '*length*'
    }

    It 'writes ASCII (no BOM)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:iniPath)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
            Should -BeFalse
    }
}

Describe 'Resolve-CMSetupLogStatus' {

    It 'returns InProgress for an empty log' {
        $r = Resolve-CMSetupLogStatus -Lines @()
        $r.Status    | Should -Be 'InProgress'
        $r.LineCount | Should -Be 0
    }

    It 'returns Success when the success phrase is present at the end' {
        $lines = @(
            '<some prelude>'
            'Configuration Manager Setup has successfully installed Configuration Manager'
        )
        (Resolve-CMSetupLogStatus -Lines $lines).Status | Should -Be 'Success'
    }

    It 'returns Failure for "Configuration Manager Setup failed"' {
        $lines = @(
            'starting...'
            'INFO: validating database'
            'CRITICAL: Configuration Manager Setup failed'
        )
        $r = Resolve-CMSetupLogStatus -Lines $lines
        $r.Status | Should -Be 'Failure'
        $r.MatchLine | Should -Match 'Setup failed'
    }

    It 'returns Failure for the database error pattern' {
        $r = Resolve-CMSetupLogStatus -Lines @('INFO: prep ok','An error occurred while installing the database')
        $r.Status | Should -Be 'Failure'
    }

    It 'returns Failure for the .NET pattern' {
        $r = Resolve-CMSetupLogStatus -Lines @('Setup was unable to verify Microsoft .NET 4.x')
        $r.Status | Should -Be 'Failure'
    }

    # Verbatim from the log in issue #1. CM 2509's terminal banner reverses
    # the word order of the 'Configuration Manager Setup failed' phrase and
    # inserts "Server", so it matched none of the original patterns: a hard
    # failure was reported InProgress and then hidden behind the full
    # Wait-CMReady timeout.
    It 'returns Failure for the CM 2509 terminal banner (issue #1)' {
        $lines = @(
            'WARNING: Download folder C:\Install\CM-PreReqs does not exist'
            'ERROR: Failed to download product updates (0x80070003)'
            '~~===================== Failed Configuration Manager Server Setup ====================='
        )
        $r = Resolve-CMSetupLogStatus -Lines $lines
        $r.Status       | Should -Be 'Failure'
        $r.MatchLine    | Should -Match 'Failed Configuration Manager Server Setup'
        $r.ErrorContext | Should -Match 'Download folder'
    }

    It 'returns Failure for the prerequisite download failure (issue #1)' {
        $r = Resolve-CMSetupLogStatus -Lines @(
            'INFO: Checking for component updates...'
            '~Setup failed to download prerequisite components.'
        )
        $r.Status | Should -Be 'Failure'
    }

    It 'matches the terminal banner regardless of the component word' {
        foreach ($banner in @(
            '~~===== Failed Configuration Manager Server Setup ====='
            '~~===== Failed Configuration Manager Console Setup ====='
            '~~===== Failed Configuration Manager Setup ====='
        )) {
            (Resolve-CMSetupLogStatus -Lines @($banner)).Status | Should -Be 'Failure'
        }
    }

    It 'does not treat a successful run as failed (regression guard)' {
        # Verified 2026-08-12: a healthy install logs InProgress at
        # setup.exe exit and is recovered by Wait-CMReady. The new banner
        # patterns must not flip that to Failure.
        $lines = @(
            'INFO: Checking for component updates...'
            'INFO: Setup downloader FINISHED'
            'INFO: Verified computer account by installing service SMS_ACCOUNT_TEST_SERVICE'
        )
        (Resolve-CMSetupLogStatus -Lines $lines).Status | Should -Be 'InProgress'
    }

    It 'walks backwards: a later Success wins over an earlier Failure (re-run case)' {
        $lines = @(
            'CRITICAL: Configuration Manager Setup failed (first attempt)'
            'INFO: re-running setup after fix'
            'Configuration Manager Setup has successfully installed Configuration Manager'
        )
        (Resolve-CMSetupLogStatus -Lines $lines).Status | Should -Be 'Success'
    }

    It 'returns InProgress when no terminal phrase is present' {
        $lines = @('INFO: copying files', 'INFO: configuring SQL')
        (Resolve-CMSetupLogStatus -Lines $lines).Status | Should -Be 'InProgress'
    }

    It 'includes context lines around the failure point' {
        $lines = 1..60 | ForEach-Object { "line $_" }
        $lines[40] = 'Configuration Manager Setup failed at step 40'
        $r = Resolve-CMSetupLogStatus -Lines $lines
        $r.Status       | Should -Be 'Failure'
        $r.ErrorContext | Should -Match 'line 16'   # 25 lines before idx 40
        $r.ErrorContext | Should -Match 'line 65|line 60'   # window may clip at 60
    }

    It 'parses lines that came from a UTF-16LE source roundtrip' {
        # Real Get-Content -Encoding Unicode round-trip
        $p = Join-Path $TestDrive 'fake.log'
        $content = "INFO: starting`r`nConfiguration Manager Setup has successfully installed Configuration Manager`r`n"
        [System.IO.File]::WriteAllText($p, $content, [System.Text.UnicodeEncoding]::new($false, $true))
        $lines = Get-Content -Path $p -Encoding Unicode
        (Resolve-CMSetupLogStatus -Lines $lines).Status | Should -Be 'Success'
    }
}

Describe 'Wait-CMReady' {

    It 'returns true when the predicate eventually reports Ready' {
        $script:tries = 0
        Mock Invoke-LabCommand -MockWith {
            $script:tries++
            if ($script:tries -lt 3) {
                return [pscustomobject]@{ Ready = $false; Reason = 'WMI unavailable' }
            }
            return [pscustomobject]@{ Ready = $true; Reason = 'SMS_Site returned' }
        }
        $r = Wait-CMReady -ComputerName CM01 -DomainCredential (New-FakeCred) `
                          -SiteCode MCM -TimeoutSeconds 30 -IntervalSeconds 1
        $r | Should -BeTrue
    }

    It 'returns false on timeout when predicate never reports Ready' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ Ready = $false; Reason = 'never' }
        }
        $r = Wait-CMReady -ComputerName CM01 -DomainCredential (New-FakeCred) `
                          -SiteCode MCM -TimeoutSeconds 2 -IntervalSeconds 1
        $r | Should -BeFalse
    }

    It 'rejects a non-3-character SiteCode' {
        { Wait-CMReady -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'XX' -TimeoutSeconds 2 } |
            Should -Throw '*length*'
    }
}

Describe 'Install-CMSite parameter validation + idempotency' {

    It 'rejects a missing CMSourcePath when supplied' {
        { Install-CMSite -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode MCM -SiteName 'x' -CMServerFqdn 'CM01.contoso.com' `
            -CMSourcePath 'C:\does-not-exist' } |
            Should -Throw '*CMSourcePath not found*'
    }

    It 'rejects a missing CMPreReqsPath when supplied' {
        { Install-CMSite -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode MCM -SiteName 'x' -CMServerFqdn 'CM01.contoso.com' `
            -CMPreReqsPath 'C:\does-not-exist' } |
            Should -Throw '*CMPreReqsPath not found*'
    }

    It 'short-circuits with AlreadyInstalled when SMS_Site reports the site' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ Installed = $true; Version = '5.00.9999.1000' }
        }
        $r = Install-CMSite -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode MCM -SiteName 'x' -CMServerFqdn 'CM01.contoso.com'
        $r.Status   | Should -Be 'AlreadyInstalled'
        $r.SiteCode | Should -Be 'MCM'
        $r.Version  | Should -Be '5.00.9999.1000'
    }

    It 'rejects a non-3-character SiteCode at parameter binding' {
        { Install-CMSite -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'TOOX' -SiteName 'x' -CMServerFqdn 'CM01.contoso.com' } |
            Should -Throw '*length*'
    }

    # Issue #1: with no offline cache staged the prereq push block is
    # skipped entirely, so nothing created C:\Install\CM-PreReqs -- but the
    # INI still points PrerequisitePath at it. CM setup does not create its
    # own download folder and aborted with 0x80070003.
    It 'creates the prereq download folder when no offline cache is staged (issue #1)' {
        $script:sent = [System.Collections.Generic.List[string]]::new()

        Mock Invoke-LabCommand -MockWith {
            $text = if ($ScriptBlock) { $ScriptBlock.ToString() } else { '' }
            $script:sent.Add($text)
            if ($text -match 'SMS_Site')               { return [pscustomobject]@{ Installed = $false } }
            if ($text -match 'setup\.exe')             { return $true }
            if ($text -match 'Register-ScheduledTask') { return [pscustomobject]@{ ExitCode = 0 } }
            return $null
        }
        Mock Copy-LabFile   { }
        Mock Test-CMSetupLog { [pscustomobject]@{ Status = 'Success'; MatchLine = ''; ErrorContext = '' } }
        Mock Wait-CMReady   { $true }

        $r = Install-CMSite -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode MCM -SiteName 'x' -CMServerFqdn 'CM01.contoso.com'

        $r.Status | Should -Be 'Installed'
        @($script:sent | Where-Object { $_ -match 'CM-PreReqs' -and $_ -match 'New-Item' }).Count |
            Should -BeGreaterThan 0
    }

    It 'still creates the folder when an offline cache IS staged' {
        $script:sent2 = [System.Collections.Generic.List[string]]::new()
        $cache = Join-Path $TestDrive 'CM-Prereqs'
        New-Item -Path $cache -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $cache 'payload.cab') -Value 'x'

        Mock Invoke-LabCommand -MockWith {
            $text = if ($ScriptBlock) { $ScriptBlock.ToString() } else { '' }
            $script:sent2.Add($text)
            if ($text -match 'SMS_Site')               { return [pscustomobject]@{ Installed = $false } }
            if ($text -match 'setup\.exe')             { return $true }
            if ($text -match 'Register-ScheduledTask') { return [pscustomobject]@{ ExitCode = 0 } }
            # "already pushed" probe and the post-move "has files" probe
            if ($text -match 'Get-ChildItem')          { return $true }
            return $null
        }
        Mock Copy-LabFile   { }
        Mock Test-CMSetupLog { [pscustomobject]@{ Status = 'Success'; MatchLine = ''; ErrorContext = '' } }
        Mock Wait-CMReady   { $true }

        $r = Install-CMSite -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode MCM -SiteName 'x' -CMServerFqdn 'CM01.contoso.com' `
            -CMPreReqsPath $cache

        $r.Status | Should -Be 'Installed'
        @($script:sent2 | Where-Object { $_ -match 'CM-PreReqs' -and $_ -match 'New-Item' }).Count |
            Should -BeGreaterThan 0
    }
}

Describe 'Import-CMModule parameter validation' {

    It 'rejects a non-3-character SiteCode' {
        { Import-CMModule -ComputerName CM01 -DomainCredential (New-FakeCred) -SiteCode 'XX' } |
            Should -Throw '*length*'
    }
}
