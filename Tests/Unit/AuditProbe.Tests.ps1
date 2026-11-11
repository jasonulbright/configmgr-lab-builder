#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for tools\Audit-HomeLabArtifacts.ps1: a failed image probe
    must be reported, and the audit must not claim a clean host (exit 3).
    The script needs PowerShell 7 and runs in a child process. The child
    replaces Get-DiskImage with a function that throws.
#>

BeforeDiscovery {
    $script:skipAudit = -not (Get-Command pwsh -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    $script:auditScript = (Resolve-Path "$PSScriptRoot\..\..\tools\Audit-HomeLabArtifacts.ps1").Path

    if ($script:pwshPath) {
        $script:wrapper = Join-Path $TestDrive 'run-audit.ps1'
        Set-Content -LiteralPath $script:wrapper -Encoding UTF8 -Value @(
            'param([string]$Audit, [string]$ImagePath, [string]$SourcesRoot)'
            "function Get-DiskImage { throw 'disk image probe unit-test failure' }"
            '& $Audit -LabImagePath $ImagePath -LabSourcesRoot $SourcesRoot -AsJson'
            'exit $LASTEXITCODE'
        )

        $script:imgRoot = Join-Path $TestDrive 'LabImages'
        $script:srcRoot = Join-Path $TestDrive 'LabSources'
        New-Item -ItemType Directory -Path $script:imgRoot, (Join-Path $script:srcRoot 'ISOs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:srcRoot 'ISOs\probe.iso') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:imgRoot 'probe.vhdx') -Value 'x'

        $out = & $script:pwshPath -NoProfile -NonInteractive -File $script:wrapper `
            -Audit $script:auditScript -ImagePath $script:imgRoot -SourcesRoot $script:srcRoot 2>$null
        $script:exitCode = $LASTEXITCODE
        $script:report = ($out | Out-String) | ConvertFrom-Json
    }
}

Describe 'Audit-HomeLabArtifacts image probe failure' -Skip:$script:skipAudit {

    It 'reports the failed ISO probe' {
        $hit = @($script:report.ProbeFailures | Where-Object { $_.Class -eq 'MountedIso' -and $_.Item -eq 'probe.iso' })
        $hit.Count | Should -Be 1
        $hit[0].Detail | Should -Match 'disk image probe unit-test failure'
    }

    It 'reports the failed VHDX probe' {
        $hit = @($script:report.ProbeFailures | Where-Object { $_.Class -eq 'MountedVhd' -and $_.Item -eq 'probe.vhdx' })
        $hit.Count | Should -Be 1
    }

    It 'marks the audit incomplete and exits 3, never clean' {
        $script:report.AuditComplete | Should -BeFalse
        $script:exitCode | Should -Be 3
    }
}
