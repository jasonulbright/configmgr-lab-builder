#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Read-LabIni and Write-LabIni. The CM 2509 unattend INI
    is parsed and written by these helpers; getting them wrong is a 90-minute
    fault in the deploy pipeline. Cover round-trip, edge cases, and encoding.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    . (Join-Path $script:helpersRoot 'Read-LabIni.ps1')
    . (Join-Path $script:helpersRoot 'Write-LabIni.ps1')

    $script:fixtureDir = Join-Path $TestDrive 'ini-fixtures'
    New-Item -Path $script:fixtureDir -ItemType Directory -Force | Out-Null
}

Describe 'Read-LabIni' {

    It 'returns an empty ordered hashtable for an empty file' {
        $p = Join-Path $script:fixtureDir 'empty.ini'
        Set-Content -Path $p -Value '' -NoNewline
        $r = Read-LabIni -Path $p
        $r.Count | Should -Be 0
        $r -is [System.Collections.Specialized.OrderedDictionary] | Should -BeTrue
    }

    It 'parses a single section with one key' {
        $p = Join-Path $script:fixtureDir 'simple.ini'
        Set-Content -Path $p -Value @"
[Options]
SiteCode = MCM
"@
        $r = Read-LabIni -Path $p
        $r['Options']['SiteCode'] | Should -Be 'MCM'
    }

    It 'preserves section and key insertion order' {
        $p = Join-Path $script:fixtureDir 'order.ini'
        Set-Content -Path $p -Value @"
[Z]
b = 2
a = 1

[A]
y = 25
x = 24
"@
        $r = Read-LabIni -Path $p
        @($r.Keys) | Should -Be @('Z','A')
        @($r['Z'].Keys) | Should -Be @('b','a')
        @($r['A'].Keys) | Should -Be @('y','x')
    }

    It 'splits Key=Value on the first = only' {
        $p = Join-Path $script:fixtureDir 'eqvalue.ini'
        Set-Content -Path $p -Value @"
[Section]
ConnectionString = Server=CM01;Database=CM_MCM;Trusted_Connection=True
"@
        $r = Read-LabIni -Path $p
        $r['Section']['ConnectionString'] | Should -Be 'Server=CM01;Database=CM_MCM;Trusted_Connection=True'
    }

    It 'ignores blank lines and trims whitespace' {
        $p = Join-Path $script:fixtureDir 'whitespace.ini'
        Set-Content -Path $p -Value @"

[Options]

   SiteCode   =   MCM
   SiteName=Home Lab Primary Site

"@
        $r = Read-LabIni -Path $p
        $r['Options']['SiteCode'] | Should -Be 'MCM'
        $r['Options']['SiteName'] | Should -Be 'Home Lab Primary Site'
    }

    It 'ignores ; and # comments' {
        $p = Join-Path $script:fixtureDir 'comments.ini'
        Set-Content -Path $p -Value @"
; this is a comment
# so is this
[Section]
; inline section comment
Key1 = Value1
# another comment
Key2 = Value2
"@
        $r = Read-LabIni -Path $p
        $r['Section'].Count | Should -Be 2
        $r['Section']['Key1'] | Should -Be 'Value1'
        $r['Section']['Key2'] | Should -Be 'Value2'
    }

    It 'trims whitespace inside section header brackets' {
        $p = Join-Path $script:fixtureDir 'bracketspace.ini'
        Set-Content -Path $p -Value @"
[ Options ]
SiteCode = MCM
"@
        $r = Read-LabIni -Path $p
        $r.Contains('Options') | Should -BeTrue
    }

    It 'throws on a key outside any section' {
        $p = Join-Path $script:fixtureDir 'orphan.ini'
        Set-Content -Path $p -Value 'OrphanKey = orphan'
        { Read-LabIni -Path $p } | Should -Throw '*key outside any section*'
    }

    It 'throws on a malformed line (no =)' {
        $p = Join-Path $script:fixtureDir 'malformed.ini'
        Set-Content -Path $p -Value @"
[Section]
NoEqualsHere
"@
        { Read-LabIni -Path $p } | Should -Throw "*malformed line*"
    }

    It 'throws on an empty section header' {
        $p = Join-Path $script:fixtureDir 'emptysection.ini'
        Set-Content -Path $p -Value @"
[]
Key = Value
"@
        { Read-LabIni -Path $p } | Should -Throw "*empty section header*"
    }

    It 'throws on a missing file' {
        { Read-LabIni -Path (Join-Path $TestDrive 'does-not-exist.ini') } |
            Should -Throw "*file not found*"
    }
}

Describe 'Write-LabIni' {

    It 'emits the expected layout for a CM-style config' {
        $p = Join-Path $script:fixtureDir 'cm-out.ini'
        $cfg = [ordered]@{
            Identification    = [ordered]@{ Action = 'InstallPrimarySite' }
            Options           = [ordered]@{ ProductID = 'EVAL'; SiteCode = 'MCM'; SiteName = 'Home Lab' }
            SQLConfigOptions  = [ordered]@{ SQLServerName = 'CM01'; DatabaseName = 'CM_MCM' }
        }
        Write-LabIni -Data $cfg -Path $p
        $content = Get-Content $p -Raw

        $content | Should -Match '\[Identification\]'
        $content | Should -Match '\[Options\]'
        $content | Should -Match '\[SQLConfigOptions\]'
        $content | Should -Match 'Action = InstallPrimarySite'
        $content | Should -Match 'SiteCode = MCM'
        $content | Should -Match 'SQLServerName = CM01'
    }

    It 'writes ASCII by default (no BOM)' {
        $p = Join-Path $script:fixtureDir 'ascii.ini'
        $cfg = [ordered]@{ S = [ordered]@{ K = 'V' } }
        Write-LabIni -Data $cfg -Path $p
        $bytes = [System.IO.File]::ReadAllBytes($p)
        # ASCII has no BOM. UTF-8 BOM is EF BB BF.
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
            Should -BeFalse
    }

    It 'writes UTF8NoBOM when requested' {
        $p = Join-Path $script:fixtureDir 'u8nobom.ini'
        $cfg = [ordered]@{ S = [ordered]@{ K = 'V' } }
        Write-LabIni -Data $cfg -Path $p -Encoding UTF8NoBOM
        $bytes = [System.IO.File]::ReadAllBytes($p)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }

    It 'writes a UTF8 BOM when -Encoding UTF8 is requested' {
        $p = Join-Path $script:fixtureDir 'u8bom.ini'
        $cfg = [ordered]@{ S = [ordered]@{ K = 'V' } }
        Write-LabIni -Data $cfg -Path $p -Encoding UTF8
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }

    It 'throws when a section value is not IDictionary' {
        $p = Join-Path $script:fixtureDir 'bad.ini'
        $bad = [ordered]@{ Section = 'string-not-dict' }
        { Write-LabIni -Data $bad -Path $p } | Should -Throw "*must be IDictionary*"
    }
}

Describe 'Read | Write round-trip' {

    It 'roundtrips a complete CM unattend INI shape' {
        $p1 = Join-Path $script:fixtureDir 'roundtrip-1.ini'
        $p2 = Join-Path $script:fixtureDir 'roundtrip-2.ini'

        $original = [ordered]@{
            Identification    = [ordered]@{
                Action = 'InstallPrimarySite'
            }
            Options           = [ordered]@{
                ProductID         = 'EVAL'
                SiteCode          = 'MCM'
                SiteName          = 'Home Lab Primary Site'
                SMSInstallDir     = 'C:\Program Files\Microsoft Configuration Manager'
                SDKServer         = 'CM01.contoso.com'
                PrerequisiteComp  = '1'
                PrerequisitePath  = 'C:\Install\CM-PreReqs'
                ManagementPoint   = 'CM01.contoso.com'
                DistributionPoint = 'CM01.contoso.com'
            }
            SQLConfigOptions  = [ordered]@{
                SQLServerName    = 'CM01.contoso.com'
                DatabaseName     = 'CM_MCM'
                SQLSSBPort       = '4022'
                SQLDataFilePath  = 'D:\SQLData'
                SQLLogFilePath   = 'E:\SQLLogs'
            }
            CloudConnectorOptions = [ordered]@{
                CloudConnector       = '0'
                CloudConnectorServer = 'CM01.contoso.com'
            }
        }

        Write-LabIni -Data $original -Path $p1
        $parsed = Read-LabIni -Path $p1
        Write-LabIni -Data $parsed -Path $p2

        $b1 = [System.IO.File]::ReadAllBytes($p1)
        $b2 = [System.IO.File]::ReadAllBytes($p2)
        @(Compare-Object $b1 $b2 -SyncWindow 0) | Should -BeNullOrEmpty -Because 'roundtrip output should be byte-identical'

        $parsed['Options']['SiteCode'] | Should -Be 'MCM'
        $parsed['SQLConfigOptions']['SQLSSBPort'] | Should -Be '4022'
    }
}
