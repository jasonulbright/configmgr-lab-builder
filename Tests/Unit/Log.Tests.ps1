#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Write-LabLog.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    . (Join-Path $script:helpersRoot 'Write-LabLog.ps1')
}

Describe 'Write-LabLog' {

    BeforeEach {
        $script:logDir = Join-Path $TestDrive ('log-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -Path $script:logDir -ItemType Directory -Force | Out-Null
        $script:logPath = Join-Path $script:logDir 'test.log'
    }

    It 'writes a text line and a JSON line for one call' {
        Write-LabLog 'hello' -Status OK -LogPath $script:logPath -NoConsole
        Test-Path $script:logPath | Should -BeTrue
        Test-Path "$($script:logPath).json" | Should -BeTrue

        (Get-Content $script:logPath -Raw) | Should -Match 'hello'
        $json = Get-Content "$($script:logPath).json" -Raw | ConvertFrom-Json
        $json.message | Should -Be 'hello'
        $json.tag | Should -Be 'OK'
        $json.level | Should -Be 'Info'
    }

    It 'maps Status WARN to Level Warning by default' {
        Write-LabLog 'careful' -Status WARN -LogPath $script:logPath -NoConsole
        $json = Get-Content "$($script:logPath).json" -Raw | ConvertFrom-Json
        $json.level | Should -Be 'Warning'
        $json.tag | Should -Be 'WARN'
    }

    It 'maps Status FAIL to Level Error by default' {
        Write-LabLog 'broke' -Status FAIL -LogPath $script:logPath -NoConsole
        $json = Get-Content "$($script:logPath).json" -Raw | ConvertFrom-Json
        $json.level | Should -Be 'Error'
        $json.tag | Should -Be 'FAIL'
    }

    It 'lets explicit Level override Status mapping' {
        Write-LabLog 'noisy info' -Status FAIL -Level Info -LogPath $script:logPath -NoConsole
        $json = Get-Content "$($script:logPath).json" -Raw | ConvertFrom-Json
        $json.level | Should -Be 'Info'
        $json.tag | Should -Be 'FAIL'
    }

    It 'includes Data hashtable in the JSON record' {
        Write-LabLog 'with data' -LogPath $script:logPath -NoConsole `
            -Data @{ ExitCode = 3010; Phase = 'CM' }
        $json = Get-Content "$($script:logPath).json" -Raw | ConvertFrom-Json
        $json.data.ExitCode | Should -Be 3010
        $json.data.Phase   | Should -Be 'CM'
    }

    It 'skips JSON when -NoJson is set' {
        Write-LabLog 'no json plz' -LogPath $script:logPath -NoConsole -NoJson
        Test-Path $script:logPath           | Should -BeTrue
        Test-Path "$($script:logPath).json" | Should -BeFalse
    }

    It 'writes one JSON record per call (line-delimited JSON)' {
        Write-LabLog 'one' -LogPath $script:logPath -NoConsole
        Write-LabLog 'two' -LogPath $script:logPath -NoConsole
        Write-LabLog 'three' -LogPath $script:logPath -NoConsole

        $lines = Get-Content "$($script:logPath).json"
        $lines.Count | Should -Be 3
        ($lines | ForEach-Object { ($_ | ConvertFrom-Json).message }) |
            Should -Be @('one','two','three')
    }
}
