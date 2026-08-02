# configmgr-lab-builder architecture

## One-paragraph overview

`Install-HomeLab` is a single PowerShell cmdlet that takes a Windows
host with no Hyper-V, no VMs, no ISOs-mounted, and turns it into a
working ConfigMgr 2509 lab in 45-90 minutes. The engine lives in
one PowerShell module (`modules/HomeLab/`), exports seven public
cmdlets, and has zero PSGallery dependencies. Recovery from any
failure is `Remove-HomeLab` followed by re-running `Install-HomeLab`;
the engine is idempotent everywhere.

## Phase flow

```
                 ┌────────────────────────────────────────────────────────┐
                 │                  Install-HomeLab                       │
                 └────────────────────────────────────────────────────────┘
                                          │
                                          ▼
   01-Prereq         Test-HostPrereq  ─►  Install-LabHyperV  (reboot if 3010)
                                          │
   02-Network        New-LabSwitch (Internal vSwitch)
                                          │
   03-Image          New-LabBaseImage   ─►  cache miss?
                       (Server)              │ yes: mount ISO → New-VHD →
                       (Client)              │      partition → Expand-WindowsImage →
                                             │      bcdboot → inject Unattend →
                                             │      boot temp VM → sysprep /generalize
                                             │      /shutdown → rename to <hash>.base.vhdx
                                             │ no:  return cached path
                                          │
   04-VM             ForEach-Object -Parallel ThrottleLimit 3:
                       New-LabVM DC01 ─┐
                       New-LabVM CM01 ─┼─►  Differencing VHDX from base.vhdx
                       New-LabVM CLI01 ┘   New-VM (Gen2)
                                            Set-VMMemory dynamic / Processor count
                                            Replace default NIC: pinned MAC + Default Switch
                                            New-Unattend (per-VM IP/DNS/MAC/computer name)
                                            Mount-LabUnattend (inject into Panther)
                                            Start-VM
                                            Wait-LabVM (TCP 5985 + Test-WSMan + 1+1 round-trip)
                                          │
   05-Domain         Install-LabDC (sequential)
                       Install-WindowsFeature AD-Domain-Services
                       Install-ADDSForest contoso.com
                       Wait for ADWS + Get-ADDomain
                     Install-LabRootCA (Enterprise Root CA, RSA 4096)
                     ForEach-Object -Parallel ThrottleLimit 2:
                       Join-LabDomain CM01 ─┐
                       Join-LabDomain CLI01 ┘
                     New-LabServiceAccounts (DC01)
                                          │
   07-CMPrereqs      Install-LabVcRedist (3010 = reboot, gated)
                     ─► reboot CM01 if VC++ requested it
                     Install-LabOdbcDriver (pinned 18.5.2.1)
                     Install-LabMsOleDb (fail-soft)
                     Install-LabAdk + Install-LabAdkPe (offline layouts)
                     Install-LabWsus (feature + wsusutil postinstall)
                     Set-LabDefenderExclusions
                                          │
   06-Sql            Install-LabSqlServer
                       Add-VMDvdDrive (zero-copy ISO mount)
                       Push ConfigurationFile.ini via Copy-LabFile
                       setup.exe /CONFIGURATIONFILE=...
                       Tail Setup Bootstrap\Log\Summary.txt
                     Set-LabSqlMemory (8 GB cap)
                     Set-LabSqlFirewall (1433 TCP + 1434 UDP)
                                          │
   05-Domain (cont.) Add-LabSchemaContainer
                       extadsch.exe on CM01
                       Create CN=System Management on DC01
                       GenericAll for CM01$ on the container
                                          │
   08-CM             Install-CMSite  (the long one, 30-60 min)
                       Probe SMS_Site → AlreadyInstalled? short-circuit
                       Push CM 2509 source (~5-30 min copy)
                       New-CMUnattendIni → push as ConfigurationFile-CM.ini
                       NO_SMS_ON_DRIVE.SMS markers on every fixed drive ≠ C:
                       setup.exe /script /noUserInput (synchronous)
                       Test-CMSetupLog (Success/Failure/InProgress on
                         the UTF-16LE log, walked backwards)
                       Wait-CMReady (SMS_EXECUTIVE + SMS_Site WMI)
                                          │
   09-CMConfig       New-CMContentShare
                     Add-CMFullAdministrator (svc-CMAdmin)
                     Set-CMServiceAccount (Push + NAA registered with CM)
                     Set-CMDiscovery (Forest/System/User, 5m delta)
                     New-CMBoundary (192.168.50.0/24)
                     New-CMBoundaryGroup + boundary attach + site system
                     New-CMDistributionPointGroup ('All DPs')
                     Set-CMClientPush (svc-CMPush)
                     Set-CMSoftwareDistributionThreads (NAA + 10/3)
                     Install-CMSoftwareUpdatePoint
                       (WsusPool IIS tune + SUP role + products +
                        classifications + 02:00 daily sync schedule +
                        initial Sync-CMSoftwareUpdate)
                     New-CMTestCollection ('HomeLab - Test Deployments'
                       + CLIENT01 direct member + daily 00:00-06:00 MW)
                     Set-CMClientCacheSize (40 GB default-setting)
                                          │
   10-Tools          Copy-CMTools (cc4cm + ApplicationPackager, fail-soft)
                     Set-LabAutoStartStop (per-VM Hyper-V autostart policy)
                                          │
                                          ▼
                              Install-HomeLab returns {
                                Status   = 'Complete'
                                Domain   = 'contoso.com'
                                SiteCode = 'MCM'
                                Elapsed  = TimeSpan
                              }
```

Each phase is independently skippable via `-SkipPhases` and
independently idempotent. Re-running on a partially-deployed lab
short-circuits at the first incomplete step.

## Module layout

```
modules/HomeLab/
    HomeLab.psd1                     # PS 7.6 LTS / .NET 10 floor; 7 functions exported
    HomeLab.psm1                     # Dot-source loader (Helpers/, Private/**, Public/)
    Public/                          # The 7 exported cmdlets
    Helpers/                         # No internal deps; safe to call from anywhere
        Read-LabIni / Write-LabIni        # INI roundtrip (CM + SQL setup configs)
        Write-LabLog                      # Severity logger; text + JSONL
        Get-LabConfig                     # Typed config.psd1 loader + validation
        Get-LabCredential                 # PSCredential resolver (4 identities)
        Wait-LabReady                     # Predicate-poll readiness gate
        Get-LabSession + Clear            # PSSession pool keyed by computer+user
        Invoke-LabCommand                 # Pooled-session wrapper, strips PSObject noise
        Copy-LabFile                      # Copy-Item -ToSession with remote-dir guard
    Private/                         # Implementation by phase
        01-Prereq/   Test-HostPrereq, Install-LabHyperV, Resolve-IsoEdition
        02-Network/  New-LabSwitch
        03-Image/    Get-LabBaseImageCacheKey, New-LabBaseUnattend, New-LabBaseImage
        04-VM/       Format-LabMacAddress, New-LabVhdx, New-Unattend, Mount-LabUnattend,
                     New-LabVM, Wait-LabVM
        05-Domain/   Install-LabDC, Install-LabRootCA, Add-LabSchemaContainer,
                     Join-LabDomain, New-LabServiceAccounts
        06-Sql/      New-LabSqlConfigIni, Install-LabSqlServer, Set-LabSqlMemory,
                     Set-LabSqlFirewall
        07-CMPrereqs/ Install-LabVcRedist, Install-LabOdbcDriver, Install-LabMsOleDb,
                     Install-LabAdk, Install-LabAdkPe, Install-LabWsus,
                     Set-LabDefenderExclusions
        08-CM/       New-CMUnattendIni, Resolve-CMSetupLogStatus, Test-CMSetupLog,
                     Wait-CMReady, Import-CMModule, Install-CMSite
        09-CMConfig/ Set-CMDiscovery, New-CMBoundary, New-CMBoundaryGroup,
                     New-CMDistributionPointGroup, Set-CMServiceAccount,
                     Set-CMClientPush, Set-CMSoftwareDistributionThreads,
                     Add-CMFullAdministrator, New-CMContentShare,
                     Install-CMSoftwareUpdatePoint, New-CMTestCollection,
                     Set-CMClientCacheSize
        10-Tools/    Copy-CMTools, Set-LabAutoStartStop
```

## Session pool model

PSSession overhead is the dominant cost when an orchestrator makes
60+ Invoke-Command calls against the same VM. The engine pools the
sessions per VM and reuses them for the run.

```
                   ┌─────────────────────────────────────┐
                   │  $script:LabSessionCache (hashtable)│
                   │  key = "<computer>|<username>"      │
                   └────────────┬────────────────────────┘
                                │
   Get-LabSession                ─►  cached? ─►  yes: State=Opened?
                                                  yes: return it
                                                  no:  Remove-PSSession + drop
                                                       fall through ↓
                                                  no:  fall through ↓
                                                ▼
                                       New-PSSession -ComputerName -Credential
                                       cache it
                                       return it

   Invoke-LabCommand   ─►  Get-LabSession ─►  Invoke-Command -Session
                                              strip PSComputerName /
                                                    RunspaceId /
                                                    PSShowComputerName
                                              return clean result

   Clear-LabSessionCache  ─►  iterate, Remove-PSSession each, empty hashtable
```

The `(computer, username)` cache key matters because the engine
authenticates as four different identities (Admin / ClientPush /
NAA / CMAdmin) for different operations. A single VM may hold up
to four open PSSessions concurrently.

## Parallelism

Two natural parallel sub-phases use `ForEach-Object -Parallel`:

| Sub-phase | Concurrency | Why parallel-safe |
|---|---|---|
| Phase 04-VM | 3 (DC + CM + CLI) | New-LabVM is per-VM; differencing VHDX, new VM, attach NIC, generate Unattend, inject, Start-VM are all independent. Wait-LabVM gates each runspace on its own VM. |
| Phase 05-Domain join | 2 (CM + CLIENT) | Domain join is independent per VM after DC01 has been promoted. |

Each parallel runspace re-imports the HomeLab module via
`Import-Module $using:modulePath -Force` because runspaces start
fresh. Variables flow in via `$using:` (config, credentials, paths).

Other phases that LOOK parallel but aren't:

- **Multiple CM cmdlets in a row** — most CM cmdlets in a row touch
  the same site database; serial is correct.
- **Multiple CM-Prereqs (VC++ then ODBC then MSOLEDB)** — sequential
  because VC++ exits 3010 (reboot required) and ODBC refuses to
  install while a reboot is pending.

## Cache: base-image VHDX

The killer-feature for re-deploys.

```
   New-LabBaseImage(IsoPath, NameFilter, ...)
       │
       │ 1. Resolve-IsoEdition (mount ISO, Get-WindowsImage,
       │                        return ImageIndex + ImageName + Architecture)
       │
       │ 2. Get-LabBaseImageCacheKey(IsoPath, ImageIndex, ImageName, LcuLevel)
       │     Hash material:
       │       ISO file size (long)
       │       ISO LastWriteTimeUtc (ticks)
       │       ImageIndex (int)
       │       ImageName (string)
       │       LcuLevel (string)
       │     SHA-256 → first 16 hex chars → cache filename
       │
       │ 3. C:\LabImages\<hash>.base.vhdx exists?
       │       yes: return path; CacheHit=true
       │       no:  fall through ↓
       │
       ▼
       Mount ISO → New-VHD 100GB Dynamic → Mount-VHD
       Initialize-Disk GPT
       New-Partition EFI 100MB FAT32 'System'
       New-Partition MSR 16MB
       New-Partition Windows UseMaximumSize NTFS
       Expand-WindowsImage (DISM Apply-Image, ~5-10 min)
       bcdboot W:\Windows /s S: /f UEFI
       New-LabBaseUnattend → inject \Windows\Panther\Unattend.xml
         (FirstLogonCommands runs sysprep /generalize /oobe /shutdown)
       Dismount-VHD
       Boot temp VM → poll for State=Off (~10 min sysprep)
       Remove temp VM
       Move-Item build-<hash>.vhdx → <hash>.base.vhdx
       return path; CacheHit=false
```

Path is intentionally NOT in the hash — moving the same ISO between
folders does not invalidate the cache. (File size + LastWriteTimeUtc
are the identity proxy; cheaper than a SHA-256 over a multi-GB ISO.)

`-Force` rebuilds. `Remove-HomeLab -RemoveBaseImageCache` nukes
the cache directory.

## Idempotency contracts

Every leaf operation has a documented short-circuit. A re-run on a
partial deploy resumes from the first incomplete step.

| Function | Short-circuit |
|---|---|
| `Install-LabHyperV` | `Status='NotRequired'` when feature already enabled |
| `New-LabSwitch` | Get-VMSwitch returns existing switch; reused |
| `New-LabBaseImage` | Cache hit on `<hash>.base.vhdx` |
| `New-LabVhdx` | Throws unless `-Force` (caller decides) |
| `New-LabVM` | Throws unless `-Force` |
| `Install-LabDC` | `Get-ADDomain` returns matching NetBIOS → `AlreadyPromoted` |
| `Install-LabRootCA` | `CertSvc.Status='Running'` → `AlreadyInstalled` |
| `Add-LabSchemaContainer` | `extadsch.exe` exit 0 (it's idempotent itself); ACL rule scan |
| `Join-LabDomain` | Win32_ComputerSystem.PartOfDomain + Domain match → `AlreadyJoined` |
| `New-LabServiceAccounts` | Per-account `Get-ADUser` skip; per-OU + per-group |
| `Install-LabSqlServer` | `Get-Service MSSQLSERVER` already up → `AlreadyInstalled` |
| `Set-LabSqlMemory` | `value_in_use` already matches → `AlreadySet` |
| `Set-LabSqlFirewall` | Per-rule `Get-NetFirewallRule` skip |
| `Install-LabVcRedist` | exit 1638 = newer-already-present treated as success |
| `Install-LabOdbcDriver` | exit 1638 = `AlreadyNewer` |
| `Install-LabMsOleDb` | fail-soft on every error path; `Skipped=true` |
| `Install-LabAdk` / `AdkPe` | (relies on adksetup.exe's own idempotency) |
| `Install-LabWsus` | `Get-Service WsusService.Status='Running'` → `AlreadyInstalled` |
| `Set-LabDefenderExclusions` | Add-MpPreference is additive; no-op for existing entries |
| `Install-CMSite` | SMS_Site WMI returns matching SiteCode → `AlreadyInstalled` |
| `New-CMBoundary` | Get-CMBoundary by name → reused |
| `New-CMBoundaryGroup` | Get-CMBoundaryGroup by name; per-action try/catch |
| `New-CMDistributionPointGroup` | Get-CMDistributionPointGroup by name |
| `Set-CMServiceAccount` | New-CMAccount tolerates "already exists" throw |
| `Set-CMClientPush` | Set-CMClientPushInstallation overwrites idempotently |
| `Add-CMFullAdministrator` | Get-CMAdministrativeUser by name → `AlreadyExists` |
| `New-CMContentShare` | Get-SmbShare + Get-Acl checks |
| `Install-CMSoftwareUpdatePoint` | Get-CMSoftwareUpdatePoint by site |
| `New-CMTestCollection` | Get-CMDeviceCollection / direct-member rule / MW each |
| `Set-CMClientCacheSize` | Set-CMClientSettingClientCache overwrites idempotently |
| `Copy-CMTools` | Each tool is fail-soft on missing source |

## What the engine deliberately does not do

- **No snapshots.** Per `feedback_homelab_build_from_bare_metal.md`,
  the engine does not take preservation snapshots. Recovery is
  re-run, not restore.
- **No backup / export tooling.** The lab is rebuildable from
  scratch; backup is out of scope.
- **No PSGallery dependencies.** Self-contained module; logging,
  session pooling, file copy, and unattend INI generation all live
  in-tree under `Helpers/`.
