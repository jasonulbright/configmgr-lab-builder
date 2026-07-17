#Requires -Version 7.6
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Verified from-scratch E2E: teardown -> provably-clean audit gate ->
    Install-HomeLab, with a full transcript as evidence.

.DESCRIPTION
    Encodes the lesson of the invalidated 2026-04 E2E: the run only
    counts if the host demonstrably starts with ZERO lab artifacts.

      0. Optionally preserve named VMs (-PreserveVM): the VM is shut
         down, its differencing chain is merged into a standalone
         dynamic VHDX under -PreserveRoot, and the VM is re-pointed at
         it -- so teardown can still delete the cached base image the
         chain hung off. The preserved VM survives (its lab-switch NIC
         goes disconnected when the switch is removed).
      1. Remove-HomeLab -RemoveBaseImageCache (full teardown incl. the
         base-image cache -- the artifact class that poisoned the last run)
      2. tools/Audit-HomeLabArtifacts.ps1 MUST exit 0, else abort
      3. Install-HomeLab (from ISOs; no cache can exist at this point)
      4. Test-HomeLab health report

    Everything is captured via Start-Transcript to
    %ProgramData%\HomeLab\Logs\E2E-<stamp>.transcript.log; the engine's
    own Write-LabLog files land in the same folder. Evidence beats vibes.

.PARAMETER PreserveVM
    VM names to rescue before teardown (e.g. CLIENT02). Their disks are
    merged to standalone VHDXs under -PreserveRoot.

.PARAMETER PreserveRoot
    Where preserved standalone VHDXs go. Default C:\PreservedVMs.
    Must NOT be under -LabImagePath.

.PARAMETER SkipDeploy
    Stop after the teardown + clean audit (steps 0-2).

.EXAMPLE
    pwsh -File tools\Invoke-VerifiedE2E.ps1 -PreserveVM CLIENT02
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),

    [Parameter()]
    [string]$LabSourcesRoot = 'C:\LabSources',

    [Parameter()]
    [string]$LabImagePath = 'C:\LabImages',

    [Parameter()]
    [string[]]$PreserveVM = @(),

    [Parameter()]
    [string]$PreserveRoot = 'C:\PreservedVMs',

    [Parameter()]
    [switch]$SkipDeploy
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:ProgramData 'HomeLab\Logs'
if (-not (Test-Path $logDir)) { $null = New-Item -Path $logDir -ItemType Directory -Force }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcript = Join-Path $logDir "E2E-$stamp.transcript.log"
Start-Transcript -Path $transcript

try {
    Import-Module (Join-Path $RepoRoot 'modules\HomeLab\HomeLab.psd1') -Force

    # ---- 0. Preserve requested VMs off the lab's disk chains --------
    foreach ($name in $PreserveVM) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-Warning "Preserve: VM '$name' not found; skipping"
            continue
        }
        Write-Host "Preserving VM '$name' (merge chain -> standalone VHDX)" -ForegroundColor Cyan
        if ($vm.State -ne 'Off') {
            Stop-VM -Name $name -Force          # graceful guest shutdown
            $deadline = (Get-Date).AddMinutes(5)
            while ((Get-VM -Name $name).State -ne 'Off' -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 5
            }
            if ((Get-VM -Name $name).State -ne 'Off') {
                throw "Preserve: '$name' did not shut down within 5 minutes"
            }
        }
        if (-not (Test-Path $PreserveRoot)) { $null = New-Item -Path $PreserveRoot -ItemType Directory -Force }
        foreach ($d in @(Get-VMHardDiskDrive -VMName $name)) {
            $leaf = [IO.Path]::GetFileNameWithoutExtension($d.Path)
            $dest = Join-Path $PreserveRoot ("{0}.vhdx" -f $leaf)
            if (Test-Path $dest) { throw "Preserve: $dest already exists; refusing to overwrite" }
            Write-Host "  Convert-VHD $($d.Path) -> $dest (merges differencing chain)"
            Convert-VHD -Path $d.Path -DestinationPath $dest -VHDType Dynamic
            Set-VMHardDiskDrive -VMName $name `
                -ControllerType $d.ControllerType `
                -ControllerNumber $d.ControllerNumber `
                -ControllerLocation $d.ControllerLocation `
                -Path $dest
            Remove-Item -LiteralPath $d.Path -Force
            Write-Host "  '$name' now runs standalone from $dest" -ForegroundColor Green
        }
    }

    # ---- 1. Full teardown (incl. base-image cache) ------------------
    Write-Host "`n===== Teardown (Remove-HomeLab -RemoveBaseImageCache) =====" -ForegroundColor Cyan
    Remove-HomeLab -RemoveBaseImageCache -LabImagePath $LabImagePath -LabSourcesRoot $LabSourcesRoot -Confirm:$false

    # ---- 2. The gate: host must be provably clean -------------------
    Write-Host "`n===== Clean-slate audit gate =====" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Audit-HomeLabArtifacts.ps1') -LabImagePath $LabImagePath -LabSourcesRoot $LabSourcesRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Audit is not clean (exit $LASTEXITCODE). The E2E does not count -- fix the leftovers and re-run."
    }
    Write-Host 'Host verified clean. This E2E starts from scratch.' -ForegroundColor Green

    if ($SkipDeploy) {
        Write-Host 'SkipDeploy set -- stopping after verified-clean teardown.' -ForegroundColor Yellow
        return
    }

    # ---- 3. The build ------------------------------------------------
    Write-Host "`n===== Install-HomeLab (from ISO; no cache exists) =====" -ForegroundColor Cyan
    $result = Install-HomeLab -LabSourcesRoot $LabSourcesRoot -LabImagePath $LabImagePath
    $result | Format-List | Out-Host

    # ---- 4. Health ----------------------------------------------------
    Write-Host "`n===== Test-HomeLab =====" -ForegroundColor Cyan
    $health = Test-HomeLab
    $health | ConvertTo-Json -Depth 5 | Out-Host
    if (-not $health.OverallReady) {
        throw 'Test-HomeLab reports the lab is NOT fully ready; inspect the transcript.'
    }
    Write-Host "`nE2E COMPLETE AND HEALTHY. Evidence: $transcript" -ForegroundColor Green

} finally {
    Stop-Transcript
}
