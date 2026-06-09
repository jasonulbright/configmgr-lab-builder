# Changelog

## [1.0.0.1] - 2026-06-09

### Fixed

- **Non-interactive deploy crash.** `Install-HomeLab` (and the lab-wide
  resolver in `Get-LabCredential`) tried to predict whether the host could
  prompt for a password using `$Host.UI.RawUI`. On non-interactive hosts
  (scriptblock / `Start-Job` / remoting / CI) `RawUI` is non-null yet the
  host cannot prompt, so `Read-Host` threw a cryptic "host program does not
  support user interaction" error mid-deploy. The prompt is now attempted
  only when stdin is not redirected, and wrapped so a host that cannot
  prompt surfaces the actionable "lab password is required" message instead
  of a raw host exception.
- **Default lab passwords restored in `config.psd1`.** The published
  default password (`AdminPass` and the three service-account passwords)
  was missing, forcing a password prompt on a default deploy. Restored so a
  no-argument deploy runs without interaction, matching the documented
  "default passwords are published in source control" contract.

## [1.0.0] - 2026-05-02

MECM HomeLab is a native PowerShell + Hyper-V engine that builds a
fully-functional Microsoft Endpoint Configuration Manager 2509 home
lab from a fresh Windows host. One cmdlet (`Install-HomeLab`), no
external module dependencies.

### Highlights

- **One-cmdlet deploy.** `Install-HomeLab` provisions three VMs (DC,
  CM site server, Windows 11 client) on an isolated Hyper-V vSwitch
  with NAT, joins them to a domain, installs SQL Server 2022 +
  ConfigMgr 2509, configures discovery / boundaries / SUP / NAA /
  client push, and lays down PostCM customization (collections,
  maintenance windows, boot image, OS image, OSD task sequence
  stub). Clean end-to-end in roughly an hour on a healthy host.
- **PowerShell 7.6 LTS / .NET 10.** Host orchestrator. No external
  module dependencies; vendored everything (MahApps, ControlzEx,
  Xaml.Behaviors).
- **Bare-metal recovery model.** `Remove-HomeLab` strips the lab
  back to base images; re-running `Install-HomeLab` rebuilds. The
  engine is the recovery story.
- **Server 2025 + CM 2509 validated.** Engine targets the latest
  Microsoft eval ISOs and CM 2509 site install (with the fixed
  cmdlet schema, ODBC 18.5.2.1 pin, and MSOLEDBSQL19 prereq).
- **GUI wizard.** WPF + MahApps front-end (`gui/start-homelab-gui.ps1`)
  for hosts that prefer a click-through topology / template /
  PostCM picker. The wizard composes the same `Install-HomeLab`
  call.
- **Idempotent re-run.** Running `Install-HomeLab` against an
  existing lab short-circuits each phase via "AlreadyExists" /
  "AlreadyInstalled" / "AlreadyPromoted" probes; a no-op re-run
  finishes in well under 10 minutes.

### Topology

| VM | Role | IP | OS |
|---|---|---|---|
| DC01 | Domain controller, root CA | 192.168.50.10 | Windows Server 2025 |
| CM01 | SQL 2022 + ConfigMgr 2509 (site server / MP / DP) | 192.168.50.20 | Windows Server 2025 |
| CLIENT01 | Managed test client | 192.168.50.100 | Windows 11 Enterprise |

Domain `contoso.com`, NetBIOS `CONTOSO`, site code `MCM`. All
configurable via `templates/default.psd1`.

### Architecture

- `modules/HomeLab/` -- the engine. Public surface: 7 cmdlets
  (`Install-HomeLab`, `Remove-HomeLab`, `Start-HomeLab`,
  `Stop-HomeLab`, `Test-HomeLab`, `Connect-HomeLabVM`,
  `Enter-HomeLabSession`).
- `Private/` is organized by phase (01-Prereq through 11-PostCM)
  so each phase is independently auditable and re-entrant.
- `Helpers/` provides session pooling, logging, file copy,
  unattend INI generation, and predicate-based readiness gates.
- `gui/` is a self-contained WPF wizard that drives the engine.

### Hardware floor

| Resource | Minimum | Recommended |
|---|---|---|
| RAM | 32 GB | 64 GB |
| Disk | 300 GB SSD/NVMe | 500 GB+ |
| CPU | 4 cores | 8+ cores |

### Known limitations

- CAS hierarchy topology is not implemented; only standalone
  primary sites.
- Client install is verified once per deploy; re-running the
  ADWS / SMS provider gates after a long idle window may need
  a session refresh.
