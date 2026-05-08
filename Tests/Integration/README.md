# HomeLab integration tests

Manual-gate Pester tests that exercise the native engine against
real Hyper-V / a real lab. Default `Invoke-Pester Tests/Unit` runs only
the 214 unit tests; integration tests are **skipped** unless their
gating environment variable is set.

## Why gated

Each integration test costs real time, real disk, and real CPU.
A naive run of every file in this folder would burn ~3-4 hours of
host wall time, several hundred GB of VHDX, and Microsoft eval
ISO downloads. Gates make the cost opt-in.

## Tiers

| Tier | What it touches | Gate env var | Typical runtime |
|------|-----------------|--------------|-----------------|
| 2    | Local host (admin needed, no Hyper-V required) | `HOMELAB_INTEGRATION=1` | seconds |
| 2-ISO | Local host + a Windows ISO | `HOMELAB_INT_ISO_SERVER` / `HOMELAB_INT_ISO_CLIENT` | < 1 min |
| 3    | Full lab provisioning (admin + Hyper-V + ISOs + CM source) | `HOMELAB_E2E=1` | 30 min - 4 hours |

A test sets `-Skip` when its gate variable is unset, so a default
Pester run logs them as Skipped rather than Failed.

## Files

| File | Tier | What it does | Prereqs |
|------|------|--------------|---------|
| `HostPrereq.Integration.Tests.ps1` | 2 | Runs `Test-HostPrereq` against the actual host and checks the report shape against reality | Admin |
| `IsoResolve.Integration.Tests.ps1` | 2-ISO | Mounts a real ISO via `Resolve-IsoEdition`, confirms a sane image index returns | Admin + a Windows ISO at `$env:HOMELAB_INT_ISO_SERVER` |
| `BaseImage.Integration.Tests.ps1` | 3 | Calls `New-LabBaseImage` end-to-end (mount + apply + sysprep) and verifies a usable VHDX comes out | Admin + Hyper-V + Windows 11 Eval ISO + ~30 min |
| `VmProvisioning.Integration.Tests.ps1` | 3 | `New-LabVM` against a cached base image, gates on Wait-LabVM | Admin + Hyper-V + a built base image + ~5 min |
| `InstallHomeLab.E2E.Tests.ps1` | 3 | Full `Install-HomeLab` from a clean host. Validates v2.3.0 functional parity. | Admin + Hyper-V + Server 2025 ISO + Windows 11 ISO + SQL 2022 ISO + CM 2509 source + ~2-4 hours |

## How to run

### Unit only (default)

```powershell
Invoke-Pester Tests/Unit
```

### Tier 2 (host-admin tests, fast)

```powershell
$env:HOMELAB_INTEGRATION = '1'
Invoke-Pester Tests/Integration/HostPrereq.Integration.Tests.ps1
```

### Tier 2-ISO (ISO mount tests)

```powershell
$env:HOMELAB_INTEGRATION = '1'
$env:HOMELAB_INT_ISO_SERVER = 'C:\LabSources\ISOs\WindowsServer2025-Eval.iso'
$env:HOMELAB_INT_ISO_CLIENT = 'C:\LabSources\ISOs\Windows11-Enterprise-Eval.iso'
Invoke-Pester Tests/Integration/IsoResolve.Integration.Tests.ps1
```

### Tier 3 (full E2E, hours)

```powershell
$env:HOMELAB_E2E = '1'
$env:HOMELAB_INT_ISO_SERVER = 'C:\LabSources\ISOs\WindowsServer2025-Eval.iso'
$env:HOMELAB_INT_ISO_CLIENT = 'C:\LabSources\ISOs\Windows11-Enterprise-Eval.iso'
$env:HOMELAB_INT_ISO_SQL    = 'C:\LabSources\ISOs\SQLServer2022-x64-ENU.iso'
$env:HOMELAB_INT_CM_SOURCE  = 'C:\LabSources\SoftwarePackages\CM'
Invoke-Pester Tests/Integration/InstallHomeLab.E2E.Tests.ps1
```

The E2E test deletes any existing lab via `Remove-HomeLab` before
deploying. **Run it on a host you are willing to wipe of lab state.**

## Bare-metal scope rule

These tests assume the lab is **rebuildable from nothing**. There is
no preservation, no migration, no rollback snapshot beyond what a
specific test takes for its own duration. If a test fails halfway,
the recovery is `Remove-HomeLab -RemoveBaseImageCache` followed by
re-running the test from scratch.
