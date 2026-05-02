# Native engine cookbook

Each entry is a Microsoft-surface gotcha that broke a real deploy,
the fix that actually works, and where the engine encodes that fix.

## CM 2509 unattended setup

### Pitfall: "Preview=1" in [Identification] for Current Branch

`setup.exe /script` rejects the entire INI file if `Preview=1`
is present and the branch is CB. The key must be **omitted**, not
set to 0.

**Where encoded:** `Private/08-CM/New-CMUnattendIni.ps1`. The
`-Branch CB` path never adds the key; only `-Branch TP` injects
`Preview=1`.

### Pitfall: setup.exe exit code is unreliable

`setup.exe /script` is a wrapper that kicks off installer threads
and exits early. A 0 exit can land while the database creation is
still failing. **Use the log, not the exit code.**

**Where encoded:** `Install-CMSite` always calls `Test-CMSetupLog`
after `setup.exe` returns. Failure markers in the log throw with
the matching line and 50 lines of context, regardless of what
setup.exe reported.

### Pitfall: ConfigMgrSetup.log is UTF-16LE

Default `Get-Content` decodes the log as ASCII / Default and
returns garbage. The first byte sequence (0xFF 0xFE) is the
Unicode BOM and gets dropped silently if you read it wrong.

**Where encoded:** `Test-CMSetupLog`'s inside-VM script opens
the file via `[System.IO.File]::Open` with FileShare.ReadWrite
and passes `[System.Text.Encoding]::Unicode` to a StreamReader.
This also avoids the "process cannot access the file" lock from
setup.exe still writing to it.

### Pitfall: re-running setup.exe appends to the same log

Walking the log forward returns the FIRST run's status. The third
re-run's Success line is at the END.

**Where encoded:** `Resolve-CMSetupLogStatus` walks the lines
**backwards**. Success or Failure of the most recent run wins.

### Pitfall: Pending-reboot from VC++ blocks CM setup

If VC++ 14.50 returned 3010 (success-reboot-required) and the box
hasn't rebooted, CM setup's prereq check fails with
`Setup was unable to verify Microsoft .NET` (a misleading message,
the real fault is the pending reboot).

**Where encoded:** `Install-HomeLab` Phase 07-CMPrereqs reboots
CM01 after `Install-LabVcRedist` if `RebootRequired=$true`,
before continuing to ODBC / MSOLEDB / ADK / WSUS.

### Pitfall: CM provider takes 1-6 min to come up after setup completes

The Success line appears in the log; `Get-Service SMS_EXECUTIVE`
shows Running; but `Set-Location MCM:` fails with "Drive 'MCM' does
not exist." for a few more minutes because the CM provider is
still building its WMI namespace.

**Where encoded:** `Wait-CMReady` polls both
`Get-Service SMS_EXECUTIVE -eq 'Running'` AND
`Get-CimInstance -Namespace ROOT\SMS\site_<code> -ClassName SMS_Site`.
Default timeout: 12 min (matches AL's cadence).

### Pitfall: System Management container ACL must be set BEFORE site install

CM publishes site / boundary / MP info to
`CN=System Management,CN=System,<DomainDN>`. If the container
doesn't exist or the CM server's computer account doesn't have
GenericAll, site install completes but cross-site auto-discovery
silently fails.

**Where encoded:** `Add-LabSchemaContainer` runs the
extadsch.exe schema bump on the CM server AND creates the System
Management container on the DC with a GenericAll ACE for `CM01$`,
ALL before `Install-CMSite` runs.

### Pitfall: NO_SMS_ON_DRIVE.SMS markers

Without these markers on every fixed drive ≠ C:, CM picks the
first available drive (often the SQL data drive) for content
storage and you end up with content distribution chewing up the
SQL data volume.

**Where encoded:** `Install-CMSite` writes `NO_SMS_ON_DRIVE.SMS`
to every fixed drive whose DeviceID is not C: before running
setup.exe.

## SQL Server 2022

### Pitfall: ODBC 18.6.x has a NULL-handling regression

Microsoft shipped ODBC Driver 18.6.1.1 with a regression in NULL
handling that causes CM to crash on certain site database writes.
Microsoft's published documentation does not call this out.

**Fix:** pin to **18.5.2.1**, the last known-good build.

**Where encoded:** `Install-LabOdbcDriver` parameter `-MsiPath`
expects the 18.5.2.1 MSI. Default URL captured in README:
https://go.microsoft.com/fwlink/?linkid=2335671

### Pitfall: SQLSYSADMINACCOUNTS at install time

The CM site server's computer account (`<DOMAIN>\<CMServer>$`)
needs sysadmin on SQL to create the CM site database during CM
setup. AL added it pre-CM-install; without it CM setup fails
with a misleading "An error occurred while installing the database".

**Where encoded:** `New-LabSqlConfigIni` accepts a
`-SqlSysAdminAccounts` array; `Install-HomeLab`'s Phase 06-Sql
populates it with `BUILTIN\Administrators`,
`<NetBIOS>\Domain Admins`, AND `<NetBIOS>\<CMServer>$`.

### Pitfall: SQL Eval ISO is hidden behind a bootstrapper

The "SQL Server 2022 Evaluation" download is an .exe that
**downloads the actual ISO** when you click "Download Media".
Pointing your engine at the bootstrapper instead of the real ISO
fails Mount-DiskImage in obscure ways.

**Where documented:** README's "Software prerequisites" table.

### Pitfall: Required collation

CM 2509 requires `SQL_Latin1_General_CP1_CI_AS`. Other collations
fail at site install with a CRITICAL prereq error.

**Where encoded:** `New-LabSqlConfigIni` defaults
`-Collation 'SQL_Latin1_General_CP1_CI_AS'`. Override at your own risk.

## WSUS

### Pitfall: WsusPool IIS app pool recycles under sync load

Default IIS WsusPool settings: Private Memory limit 1.8 GB,
periodic restart every 1740 minutes. WSUS sync loads easily
exceed 1.8 GB; the pool recycles mid-sync; sync fails; CM SUP
stays in "syncing" forever.

**Fix:** set Private Memory limit, periodic restart memory, and
periodic restart time all to **0** (unlimited). Increase queue
length to 2000.

**Where encoded:** `Install-CMSoftwareUpdatePoint`'s WsusPool
tune block (`Set-ItemProperty IIS:\AppPools\WsusPool ...`).

### Pitfall: wsusutil postinstall must specify the SQL instance

WSUS feature install creates the IIS sites but NOT SUSDB. You
have to run `wsusutil.exe postinstall SQL_INSTANCE_NAME=...
CONTENT_DIR=...` to create the database and finish setup.

**Where encoded:** `Install-LabWsus` invokes wsusutil postinstall
with `SQL_INSTANCE_NAME=$env:COMPUTERNAME` (default instance,
co-located with CM).

## ADK / WinPE

### Pitfall: adksetup.exe downloads ~1.5 GB at install time

ADK is a small bootstrapper that downloads its features at
install time. Lab VMs are internal-only (no internet); the
default install fails.

**Fix:** pre-stage the ADK and WinPE add-on offline layouts on the
host:
```
adksetup.exe        /quiet /layout C:\LabSources\SoftwarePackages\ADK\Offline
adkwinpesetup.exe   /quiet /layout C:\LabSources\SoftwarePackages\ADKPE\Offline
```

Then push the layout folder to the VM and run the same
.exe inside the VM with `/quiet /installpath ... /features ...`.

**Where encoded:** `Install-LabAdk` / `Install-LabAdkPe` accept an
`-OfflineLayoutPath` parameter; Copy-LabFile pushes the layout;
inside-VM run uses the layout's adksetup.exe.

### Pitfall: ADK and WinPE are SEPARATE downloads

Microsoft split the WinPE add-on out of the main ADK in ADK 2004+.
You need both bootstrappers and both `/layout` runs. CM 2509 needs
the WinPE add-on installed for OSD.

**Where documented:** README's "Software prerequisites" table.

## VC++ runtime

### Pitfall: stale VC++ runtime URLs

Older lab automation pinned VC++ 2015 and 2017 runtime URLs that
404'd by 2024. CM 2509 needs **VC++ 14.50** (the latest VS
2015-2022 redist line).

**Fix:** use `https://aka.ms/vs/18/release/vc_redist.x64.exe` (and
the matching x86 URL).

**Where encoded:** README's "Software prerequisites" table pins
the URLs. `Install-LabVcRedist` accepts the local .exe paths.

## AD DS

### Pitfall: Install-ADDSForest auto-reboots; WinRM session drops

Install-ADDSForest schedules an immediate restart after the AD
role install. The WinRM session runs setup, then disconnects with
a generic transport error as the box reboots.

**Where encoded:** `Install-LabDC` catches the transport error,
calls `Clear-LabSessionCache` to drop the dead PSSession, then
`Wait-LabVM` until the box returns. After the reboot the
Administrator account is the **domain** admin, not the local
admin (same SAM, different identity).

### Pitfall: AD Web Services takes 1-3 min after the reboot

Get-ADDomain throws "Unable to find a default server" until ADWS
is fully up.

**Where encoded:** `Install-LabDC` adds a `Wait-LabReady`
after the post-reboot WinRM gate that polls
`(Get-Service ADWS).Status -eq 'Running'` AND `Get-ADDomain`
both succeed.

## Hyper-V

### Pitfall: Server vs Client Hyper-V feature install differs

`Install-WindowsFeature -Name Hyper-V -IncludeManagementTools`
works on Server SKUs but fails on Windows 10/11. Client SKUs
need `Enable-WindowsOptionalFeature -Online -FeatureName
Microsoft-Hyper-V -All`.

**Where encoded:** `Install-LabHyperV` checks
`(Get-CimInstance Win32_OperatingSystem).ProductType` and picks
the right API.

### Pitfall: NIC identification in Unattend.xml

The Microsoft-Windows-TCPIP component matches NICs by
`<Identifier>`. Friendly names (`Ethernet`, `Ethernet 2`) are
order-dependent and not reliable. **MAC is reliable.**

**Where encoded:** `New-LabVM` pins a deterministic MAC via
`Set-VMNetworkAdapter -StaticMacAddress` BEFORE generating the
per-VM Unattend, then passes the same MAC to `New-Unattend`'s
`-LabNicMac`. Format-LabMacAddress normalizes between the
plain-12-hex form Hyper-V wants and the dashed form Unattend
wants.

### Pitfall: Default Switch absence

Earlier Windows 10 builds shipped without "Default Switch".
Win 11 / Server 2025 always have it. The lab depends on it for
NAT internet access (OS activation, Eval-edition KMS lookups).

**Where encoded:** `New-LabSwitch` verifies "Default Switch"
exists before creating the lab Internal switch and throws with
a "reinstall the Hyper-V feature" message if it's gone.

## Sysprep + base image cache

### Pitfall: Differencing children of a non-syspreped parent share a SID

If you skip the sysprep `/generalize` step on the base image,
every VM that uses a differencing child gets the same Windows SID.
Domain join works but Group Policy / WSUS / CM client identity
all fail in subtle ways.

**Where encoded:** `New-LabBaseImage` always boots the freshly-
applied VHDX in a temp VM and waits for sysprep `/generalize
/oobe /shutdown` to complete (driven via FirstLogonCommands in
`New-LabBaseUnattend`). The default flow leaves a sysprepped
VHDX. `-NoSysprep` is available for testing the WIM-apply path
without paying the ~10 min sysprep cost, but the result is
explicitly NOT suitable as a multi-VM differencing parent.

### Pitfall: Cache invalidation

Hashing only the ISO file path means moving the ISO between
folders rebuilds the cache unnecessarily. Hashing the ISO bytes
costs SHA-256 over a multi-GB file every call. Stat metadata
(size + LastWriteTimeUtc) is reliable enough for the lab.

**Where encoded:** `Get-LabBaseImageCacheKey` uses
`{file size}|{LastWriteTimeUtc.Ticks}|{ImageIndex}|{ImageName}|{LcuLevel}`
as the SHA-256 input. Path is intentionally NOT in the hash.

## PowerShell + WinRM

### Pitfall: Invoke-Command -Session adds note properties to results

Every value returned from `Invoke-Command -Session` gets
`PSComputerName`, `RunspaceId`, and `PSShowComputerName` glued on
as note properties. AL's downstream code worked around this with
`[bool]($result | Select-Object -First 1)` casts everywhere.

**Where encoded:** `Invoke-LabCommand` strips all three properties
from returned objects so `$r -is [bool]` and `$r.Property`
behave as expected. Pass `-Raw` to skip the strip.

### Pitfall: Inside-VM script blocks need PS 5.1 compatibility

The host orchestrator runs PS 7.6 LTS. Inside-VM script blocks
that touch the ConfigurationManager module or AD cmdlets must
stay on PS 5.1 syntax — both modules are 5.1-coupled. The CM
provider has subtle PS 7 incompatibilities; AD module is
5.1-tested.

**Where encoded:** No engine-level enforcement; convention is to
keep CM/AD-touching script blocks free of PS 7-only syntax
(`??`, `?:`, `ForEach-Object -Parallel` inside the block, etc.).
File-copy / registry / Set-ItemProperty work inside VMs is fine
on PS 7.

### Pitfall: WinRM cross-workgroup SMB doesn't work

The dev workstation is not domain-joined. `\\CM01\c$` style
admin shares fail with "the network name cannot be found" no
matter how clean the credentials are.

**Where encoded:** All host-to-VM file copy goes through
`Copy-LabFile` (= `Copy-Item -ToSession`) over WinRM, never SMB.
