#requires -Module Pester
<#
.SYNOPSIS
    Tier-3 integration: Install-HomeLab end-to-end against a clean host.

.DESCRIPTION
    The exit-criterion test for the engine. Walks every phase of
    Install-HomeLab against a real host with real ISOs, real VMs, real
    domain promotion, real SQL, real CM 2509 install, real CM
    post-config. Validates v2.3.0 functional parity.

    Skipped unless ALL of these are set:
      $env:HOMELAB_E2E              = '1'
      $env:HOMELAB_INT_ISO_SERVER   = path to Windows Server 2025 ISO
      $env:HOMELAB_INT_ISO_CLIENT   = path to Windows 11 Eval ISO
      $env:HOMELAB_INT_ISO_SQL      = path to SQL 2022 ISO
      $env:HOMELAB_INT_CM_SOURCE    = path to extracted CM 2509 baseline

    BEHAVIORAL NOTE: this test calls Remove-HomeLab BEFORE deploying so
    it always runs against a known-clean state. If the host has an
    active lab you care about, do NOT run this test.

    Typical runtime: 90-180 minutes.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force

    $script:requiredVars = @(
        'HOMELAB_E2E','HOMELAB_INT_ISO_SERVER','HOMELAB_INT_ISO_CLIENT',
        'HOMELAB_INT_ISO_SQL','HOMELAB_INT_CM_SOURCE'
    )
    $script:missing = $script:requiredVars | Where-Object {
        -not [Environment]::GetEnvironmentVariable($_)
    }
    $script:gate = ($script:missing.Count -eq 0)

    if ($script:gate) {
        # Validate the paths actually exist before declaring 'pass'.
        $missingPaths = @()
        foreach ($v in @('HOMELAB_INT_ISO_SERVER','HOMELAB_INT_ISO_CLIENT','HOMELAB_INT_ISO_SQL')) {
            $p = [Environment]::GetEnvironmentVariable($v)
            if (-not (Test-Path $p)) { $missingPaths += "$v=$p" }
        }
        $cmSource = [Environment]::GetEnvironmentVariable('HOMELAB_INT_CM_SOURCE')
        if (-not (Test-Path -Path $cmSource -PathType Container)) {
            $missingPaths += "HOMELAB_INT_CM_SOURCE=$cmSource"
        }
        if ($missingPaths.Count -gt 0) {
            $script:gate = $false
            Write-Host ("E2E gate paths missing: " + ($missingPaths -join '; ')) -ForegroundColor Yellow
        }
    }
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Install-HomeLab E2E from a clean host' -Tag 'Integration','Tier3','LongRun','E2E' {

    It 'completes Phases 01-10 and Test-HomeLab reports OverallReady' -Skip:(-not $script:gate) {
        InModuleScope HomeLab {
            # Bare-metal start: nuke any existing lab first.
            #
            # HOMELAB_E2E_FROMSCRATCH=1 makes "clean" PROVABLE: teardown
            # includes the base-image cache, and the artifact audit must
            # exit 0 before the deploy is allowed to start. Without it
            # (default), cached base images are reused -- faster, but the
            # run does NOT demonstrate a from-ISO build. The 2026-04 E2E
            # was invalidated by exactly that: a stale cached base image
            # was silently consumed and nobody noticed until review.
            if ($env:HOMELAB_E2E_FROMSCRATCH -eq '1') {
                Remove-HomeLab -RemoveBaseImageCache -Confirm:$false -ErrorAction SilentlyContinue

                $auditScript = Resolve-Path "$PSScriptRoot\..\..\tools\Audit-HomeLabArtifacts.ps1"
                & $auditScript
                $LASTEXITCODE | Should -Be 0 -Because 'the host must be provably clean of lab artifacts before a from-scratch E2E counts'
            } else {
                Remove-HomeLab -KeepBaseImages -Confirm:$false -ErrorAction SilentlyContinue
            }

            $start = Get-Date

            $r = Install-HomeLab `
                -ServerIsoPath $env:HOMELAB_INT_ISO_SERVER `
                -ClientIsoPath $env:HOMELAB_INT_ISO_CLIENT `
                -SqlIsoPath    $env:HOMELAB_INT_ISO_SQL `
                -CMSourcePath  $env:HOMELAB_INT_CM_SOURCE

            $r.Status | Should -Be 'Complete'
            $elapsed = (Get-Date) - $start
            Write-Host ("E2E elapsed: {0}h {1}m {2}s" -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds) -ForegroundColor Cyan

            $health = Test-HomeLab
            $health.OverallReady       | Should -BeTrue
            $health.DC.ADReady         | Should -BeTrue
            $health.CM.SqlRunning      | Should -BeTrue
            $health.CM.SmsExecutive    | Should -BeTrue
            $health.CM.CmProviderReady | Should -BeTrue
            $health.Client.DomainJoined | Should -BeTrue
        }
    }

    It 'is idempotent: a second Install-HomeLab on the populated lab short-circuits cleanly' -Skip:(-not $script:gate) {
        InModuleScope HomeLab {
            $start = Get-Date
            $r = Install-HomeLab `
                -ServerIsoPath $env:HOMELAB_INT_ISO_SERVER `
                -ClientIsoPath $env:HOMELAB_INT_ISO_CLIENT `
                -SqlIsoPath    $env:HOMELAB_INT_ISO_SQL `
                -CMSourcePath  $env:HOMELAB_INT_CM_SOURCE
            $r.Status | Should -Be 'Complete'

            # Second-run target: well under 5 minutes (everything short-
            # circuits). Tolerate up to 15 to leave headroom for slow disk.
            $elapsed = (Get-Date) - $start
            $elapsed.TotalMinutes | Should -BeLessThan 15
        }
    }
}
