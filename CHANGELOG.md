# Changelog

## [1.4.0] - 2026-08-02

Rebrand only. No engine behaviour changes, no schema changes, and no
change to any exported cmdlet -- this is a minor bump because the
public API is untouched.

### Changed

- **Product renamed to ConfigMgr Lab Builder** (was "MECM HomeLab").
  Microsoft dropped "Endpoint" from the product name; the current name
  is Microsoft Configuration Manager and the product team's approved
  short name is **ConfigMgr**. "MECM" and "MCM" are neither current nor
  approved, so every occurrence in the README, docs, GUI, help blocks,
  and inline comments now reads ConfigMgr.
- **Repository renamed** `mecm-homelab` -> `configmgr-lab-builder`.
  GitHub redirects the old URL, so existing clones and links keep
  working; `git remote set-url` is optional but tidier.
- **Service-account descriptions** now read `ConfigMgr Client Push`,
  `ConfigMgr Network Access Account`, and `ConfigMgr OSD Domain Join`
  in `config.psd1`, every topology template, and
  `New-LabServiceAccounts`. This is the only rebrand change that
  reaches deployed state: it applies to accounts created from now on.
  Labs built before 1.4.0 keep the old AD descriptions until rebuilt,
  which is cosmetic -- nothing keys off the description string.
- Module manifest `Description`, `Tags`, `ProjectUri`, and
  `ReleaseNotes` refreshed. `ReleaseNotes` had been stale at v1.0.0.1
  since the 1.0 line.

### Fixed

- GUI version badges in `MainWindow.xaml` and the Options "About"
  panel were hardcoded to `v1.0.0` and never updated across the 1.1,
  1.2, and 1.3 releases. Both now read `v1.4.0`.

### Unchanged (deliberately)

- **Module name and public surface.** The module is still `HomeLab`,
  and all seven exported cmdlets (`Install-HomeLab`, `Remove-HomeLab`,
  `Start-HomeLab`, `Stop-HomeLab`, `Test-HomeLab`, `Connect-HomeLabVM`,
  `Enter-HomeLabSession`) keep their names. Renaming them would be a
  breaking change and a major bump, not a minor one.
- **Site code `MCM`.** This is a ConfigMgr three-letter site code, not
  branding. It is baked into the database name `CM_MCM`, the WMI
  namespace `ROOT\SMS\site_MCM`, and the unattend INI. Changing it
  would break every existing lab for no naming benefit.

## [1.3.1] - 2026-08-01

### Fixed

- `Audit-HomeLabArtifacts.ps1`: when cached base images are the only
  dirty findings, the verdict now names `-AllowBaseImageCache` (or
  `Remove-HomeLab -RemoveBaseImageCache`) instead of advising a plain
  `Remove-HomeLab` re-run. The old message was unreachable guidance for
  anyone on the documented `-KeepBaseImages` path: the teardown
  preserves those images by design, so repeating it could never clear
  the verdict.
- `Remove-HomeLab`: the hosts-file step now checks for lab entries
  before asking for confirmation. A repeat teardown on an already-clean
  hosts file no longer prompts, and no longer implies it removed
  entries that were not there.

## [1.3.0] - 2026-07-17

Backed by three verified end-to-end runs on the reference host
(20-thread / 32 GB): two from-scratch builds (3-VM default topology,
1h 10m each, from ISO, each gated on an artifact audit proving the
host held zero lab artifacts first) and one cache-reuse build (4-VM
`two-clients` topology, 1h 05m, both base images cache-hit).
Evidence transcripts live in `%ProgramData%\HomeLab\Logs`.

### Added

- **`Invoke-VerifiedE2E.ps1 -KeepBaseImages` and `-Template`.**
  Cache-reuse mode: teardown preserves the base-image cache, the audit
  gate runs with `-AllowBaseImageCache`, and the build should log Phase
  03 cache hits -- validating the rapid teardown/rebuild workflow the
  cache exists for. `-Template` passes a topology template through to
  Install-HomeLab (e.g. `two-clients`) and resolves the lab password
  runner-side ($env:HOMELAB_PASSWORD, else the published default with
  a warning) -- templates ship without AdminPass, and the runner's
  hidden elevated window turned Install-HomeLab's interactive
  Read-Host fallback into an invisible hour-long hang.
- **`tools/Audit-HomeLabArtifacts.ps1` -- provable-clean referee.** The
  2026-04 E2E was invalidated because a prior run's cached base image
  survived teardown and was silently consumed by the next build. The
  audit script enumerates every artifact class a lab run creates on the
  host (lab VMs incl. strays from older configs and temp sysprep VMs,
  checkpoints, lab vSwitches by name AND by the Notes marker, cached
  base images, per-VM/orphaned/build-temp VHDXs, leaked ISO/VHD mounts,
  %TEMP% debris, orphaned host NIC IPs on lab subnets) and exits 0 only
  when the host is provably clean. Exit 3 = incomplete (not elevated;
  never certify clean on 3). `-AllowBaseImageCache` supports the
  `-KeepBaseImages` workflow.
- **E2E from-scratch gate.** `HOMELAB_E2E_FROMSCRATCH=1` makes the
  integration E2E tear down with `-RemoveBaseImageCache` and require
  the artifact audit to exit 0 before deploying, so a "from scratch"
  run demonstrably starts from a clean slate.
- **`two-clients` template (4 VMs).** default + a second client, so
  app install/uninstall testing gets a clean-machine control instead
  of checkpoint rollbacks. Codifies the hand-built CLIENT02 that lived
  on the lab host May-July 2026. Wired into the GUI template picker.
- **`tools/Invoke-VerifiedE2E.ps1` -- evidence-first E2E runner.**
  Teardown (incl. base-image cache) -> audit gate (must exit 0, else
  abort) -> Install-HomeLab -> Test-HomeLab, all under
  Start-Transcript. `-PreserveVM <name>` rescues a hand-made VM first
  by merging its differencing chain into a standalone VHDX (so the
  cached base image its chain hung off can still be destroyed).

### Changed

- **`Remove-HomeLab` is now provably complete.** Closes every gap that
  allowed the invalid 2026-04 E2E: the removal set now includes temp
  sysprep VMs (`HomeLabBaseSysprep-*`) and any VM whose disk lives
  under `-LabImagePath` (not just the current config's names); the
  `$LabImagePath` sweep runs unconditionally so orphaned per-VM VHDXs,
  failed `build-*.vhdx` images, and stray VM config files die even when
  their VM object is already gone; attached VHDXs/ISOs are dismounted
  before deletion; `%TEMP%` debris (`homelab-unattend-*`,
  `homelab-base-unattend-*.xml`, `HomeLab-VcStage`) is removed; lab
  switches are found by config name AND the New-LabSwitch Notes marker;
  a final verification pass logs any leftover artifact as WARN.
  `-KeepBaseImages` now preserves every `*.base.vhdx` by pattern
  (previously only chain-reachable parents of still-existing VMs, so
  orphaned caches were unreachable either way). Removed the unused
  `-VMRoot` parameter; added `-LabSourcesRoot`. `-KeepBaseImages` and
  `-RemoveBaseImageCache` are now explicitly mutually exclusive.

- **MSOLEDB pre-install is now opt-in (`-MsOleDbMsiPath` only).** The
  2026-07-16 E2E proved the step redundant: CM 2509 setup manages the
  OLE DB driver itself as an external dependency file -- it installed
  msoledbsql.msi 19.3.5 x64 from the CM-PreReqs cache (exit 0) after
  the site media's own copy failed hash verification, while the site
  DB connection is enforced over ODBC ("Enforce using MSODBC for SQL
  connection"; the MSOLEDBSQL prereq rule is Warning-severity). With
  no -MsOleDbMsiPath the engine now skips the step with a SKIP log
  instead of resolving a default MSI path.

### Fixed

- **Automatic checkpoints silently stacked an .avhdx diff on every lab
  VM.** Windows 11 client Hyper-V defaults `AutomaticCheckpointsEnabled`
  on, taking a Standard checkpoint at first VM start -- every write
  after provisioning landed in a checkpoint diff on top of the
  differencing chain (observed after a host reboot: CM01's diff at
  33GB, its .vhdx empty). `New-LabVM` and the base-image sysprep VM now
  disable automatic checkpoints. `Remove-HomeLab`'s chain deletion also
  retries on a deadline, because deleting a VM with a checkpoint starts
  an async avhdx merge that keeps the chain files locked.
- **Nothing checked whether the host could actually allocate the
  topology's startup memory.** Test-HostPrereq only asserted total RAM
  >= 32GB; the first two-clients deploy (20GB startup demand) died at
  Phase 04 with 0x800705AA "unable to allocate 4096 MB" because the
  desktop session held the balance. Phase 01 now fails fast:
  `Test-HostPrereq -VMStartupMemoryBytes` compares the config's summed
  startup memory against free physical memory plus memory currently
  assigned to same-named lab VMs (which Phase 04 clobbers and
  reclaims), with a 1GB margin and an actionable message.
- **`two-clients` template right-sized: clients start at 2GB (dynamic
  1-4GB) instead of 4GB.** Startup demand drops 20GB -> 16GB -- same
  as the default 3-VM lab; dynamic memory grows clients on guest
  demand.
- **"setup.exe exited but log shows InProgress" downgraded WARN ->
  INFO.** It fired on 3 of 3 verified CM 2509 installs and the
  Wait-CMReady gate recovered every time: it is the product's normal
  async setup handoff, not an anomaly.
- **Teardown could destroy non-lab VMs' configuration.** The straggler
  sweep recursed through every VM's `Path`/`ConfigurationLocation`
  deleting `.vmcx`/`.vmrs`/`.vhdx` files. VMs created at the Hyper-V
  default store share `C:\ProgramData\Microsoft\Windows\Hyper-V` (as
  all four VMs on the real host do), so on a host with non-lab VMs the
  sweep would have deleted their configs too. Sweep is now restricted
  to folders under `-LabImagePath` or named after a lab VM; shared
  folders are skipped (Remove-VM already deletes the lab VM's own
  config files).
- **Host->VM name resolution was an unmanaged host dependency.** Every
  phase connects by name from a non-domain host, but nothing in the
  engine provided resolution -- deploys only worked because of
  hand-added hosts-file entries (real-host drift, 2026-07-16). Phase
  02-Network now writes `# HomeLab-managed` hosts entries for every
  lab VM (replacing stale hand-made ones), `Remove-HomeLab` strips
  them (including unmanaged lines that resolve lab VM names), and the
  artifact audit flags leftover lab hosts entries.
- **WinRM TrustedHosts was an unmanaged host dependency.** NTLM from
  the non-domain host requires the lab VM names in the WinRM client's
  TrustedHosts; the engine never checked or documented this (the real
  host happened to have `*`). `Test-HostPrereq -WinRMProbeNames` now
  verifies coverage and `Install-HomeLab` fails Phase 01 with the
  exact elevated `Set-Item` fix command instead of dying mid-Phase-05
  with a bare WinRM error.
- **`New-LabSwitch` now stamps the Notes marker on pre-existing
  switches.** The real host's `HomeLab-Network` predated the marker
  convention and carried empty Notes, so marker-based lab-switch
  detection (teardown + audit) couldn't recognize it after a rename;
  name-based detection was the only net.
- **`Add-CMRoleDistributionPoint` accepted `-MinimumFreeSpaceMB` values
  the real CM cmdlet rejects.** ValidateRange said 0..1048576; CM
  2509's `Add-CMDistributionPoint` caps at 100000 and would fail
  mid-deploy on the remote side. The range now mirrors the real limit,
  and the default drops 1024 -> 500 MB -- MECM's own product default
  for the DP role, guaranteed accepted on every supported build.
- **`-VcRedistPath` default missed the canonical `VCRedist\` subfolder.**
  `Install-HomeLab` looked only in flat `SoftwarePackages\`, so with
  the canonical layout (as on the real host) the Phase 07 VC++ install
  silently skipped behind its Test-Path gate. Now resolves
  `SoftwarePackages\VCRedist` first, flat layout as fallback -- same
  pattern as ODBC/MSOLEDB.
- **Unit test could execute real CM cmdlets against a live lab.** The
  `CmRoles` upper-bound test assumed no live session was possible and
  let the call run through the remoting layer; on a host with a
  running lab and default passwords it opened a real PSSession to CM01
  and created a real site system. The remoting layer is now mocked.
- **`Set-LabDefenderExclusions` failed with no `-ExtraPaths`.**
  `@($defaultPaths) + @($ExtraPaths)` appended a literal `$null` when
  ExtraPaths was omitted, and the remote `Add-MpPreference` rejected
  the whole array ("argument is null or empty") -- so the default
  Install-HomeLab path applied ZERO Defender exclusions (fail-soft
  WARN, caught on the first verified E2E, 2026-07-16). Nulls/empties
  are now filtered; regression test added for the no-extras path.
- **MSOLEDB exit 1633 now names the fix.** 1633 is
  ERROR_INSTALL_PLATFORM_UNSUPPORTED -- on the verified E2E the staged
  msoledbsql.msi turned out to be the Arm64 build. The WARN now says
  "stage the x64 build in SoftwarePackages\MSOLEDB" instead of a bare
  exit code.
- **Client push could never reach a Windows 11 client.** The very
  first CCR failed "access denied or invalid network path" on a
  healthy, WinRM-reachable CLIENT01: Win11 blocks inbound SMB/admin$
  (445) and RPC/WMI (135) by default even on the Domain profile, and
  neither the engine nor any GPO opened them (WinRM only works out of
  the box because the WinRM service ships its own domain allow rule).
  New Phase 05 leaf `Enable-LabClientPushFirewall` enables the File
  and Printer Sharing + WMI inbound rule groups (Domain/Private-scoped
  rules only; the NAT NIC's Public profile stays closed) on every
  Client-role VM after domain join. Validated live: push installed the
  client in ~2 minutes once the rules were enabled. (Also fixed inside
  the leaf: the NetSecurity Profile enum does not support -band on
  live Win11 -- profile filtering is done via ToString matching.)
- **The test collection stayed empty forever on a fresh build.**
  `New-CMTestCollection` runs minutes after site install -- before AD
  discovery has produced the client's device record -- and used a
  direct membership rule plus `RefreshType None`, so the miss was
  permanent (verified E2E: collection empty, deployment targeted=0).
  The collection now uses Continuous (incremental) refresh and an
  ordering-proof name-scoped query membership rule, with the direct
  rule still added when the device already exists; existing
  collections at RefreshType Manual are upgraded on re-run.
- **The engine-created content share silently broke every application
  deployment.** `New-CMContentShare` granted share-level access to
  Domain Admins / Domain Computers / NAA only -- no `NT AUTHORITY\
  SYSTEM`. Distribution Manager runs as SYSTEM and reads the package
  source via loopback UNC, and share-level access is evaluated before
  NTFS, so distmgr failed its content snapshot (status 2306, error 5)
  -> the content hash never landed in SMSContentHash -> objreplmgr
  could not generate the app's VersionInfo policy ("Unable to process
  VersionInfo policy ... Failed to process Application Assignment")
  -> clients never received ANY app-deployment policy. All of it
  fail-soft and invisible to Test-HomeLab. The share now grants SYSTEM
  Full + the site server computer account Read at share level, and
  re-runs repair shares created by older engine versions.
- **Stale manifest-version assertion.** `Module.Tests` asserted a
  literal `2.0.0` long after the repo renumbered to 1.0.0.x; it now
  asserts against the latest CHANGELOG release heading.

- **Phase 02 crash on fresh sessions: "Unable to find type
  [Microsoft.HyperV.PowerShell.VMSwitch]".** `New-LabSwitch` declared
  its `[OutputType()]` with a type literal. PowerShell resolves
  attribute type literals at first invocation and type resolution does
  not auto-load modules, so on a session where nothing had loaded the
  Hyper-V assembly yet the function failed before its body ran (the
  `Get-VMSwitch` call that would have auto-loaded the module sits
  inside the body). Switched to the string form
  `[OutputType('...')]`, which never requires the assembly.
- **GUI deploy always failed with "lab password is required".** The
  GUI deploys built-in templates, which intentionally ship without
  `AdminPass`, and ran `Install-HomeLab` in a background runspace whose
  host cannot `Read-Host` -- so the v1.0.0.1 password restore in
  `config.psd1` never applied to GUI deploys. The GUI now resolves the
  password before launching the runspace: a config-supplied `AdminPass`
  or `$env:HOMELAB_PASSWORD` is honored as before; otherwise the
  published default lab password is passed via `-LabPassword` (with a
  WARN line in the deploy log).
- **Mojibake in `config.psd1`.** The "CHANGE THESE PASSWORDS" comment
  ruler had been double-encoded (UTF-8 box-drawing dashes re-saved
  through Windows-1252) and rendered as `â”€` garbage. Replaced with
  plain ASCII dashes.

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
