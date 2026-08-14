# Getting started with ConfigMgr Lab Builder

This is a start-to-finish walkthrough for someone who has never run
this tool before: staging the files it needs, launching the GUI
wizard, clicking through every page, and knowing what "it worked"
looks like. It does not assume you know ConfigMgr, Hyper-V, or this
project.

If you already know the tool and just need the reference tables
(templates, cmdlets, config keys, full troubleshooting list), see the
[main README](../README.md) instead -- this doc is the guided version
of its [GUI walkthrough](../README.md#gui-walkthrough) section.

## What you're building

One command (via a wizard, or via a single PowerShell cmdlet) turns a
blank Windows host into a working Microsoft Configuration Manager lab:
three virtual machines, networked, domain-joined, with a healthy CM
site at the end.

| VM | What it is | 
|---|---|
| DC01 | Domain controller + certificate authority |
| CM01 | SQL Server + the ConfigMgr site server |
| CLIENT01 | A Windows 11 PC managed by that site |

Everything runs locally in Hyper-V on your machine. Nothing leaves
the host. A first build takes about **70 minutes**; see
[timing](#how-long-this-takes) below.

## Before you begin

### 1. Check your hardware

| Resource | Minimum | Recommended |
|---|---|---|
| RAM | 32 GB | 64 GB |
| Free disk | 300 GB SSD/NVMe | 500 GB+ |
| CPU | 4 cores | 8+ cores |
| OS | Windows 10/11 Pro or Server 2022+, Hyper-V capable | Windows 11 Pro |

The lab is lighter once it's up and idling than the sizing above
implies -- it's the CM install and OS deployment work that spikes
usage. Size for the peak, not the idle.

### 2. Install PowerShell 7

The wizard and the engine both require PowerShell **7.6 LTS or
newer** (not the `powershell.exe` that ships in Windows -- that's
5.1). If you're not sure which you have, open a terminal and run
`pwsh -Version`; if that command isn't found, install it:

```powershell
winget install Microsoft.PowerShell
```

### 3. Download the installation media

The engine builds VMs from real Windows/SQL/ConfigMgr media. Create
the folders below (if they don't already exist) and place each file.
This is the step most worth double-checking before you launch the
wizard, since a missing file is the single most common first-run
failure. If you'd rather not do this by hand: the wizard's
[Media page](#step-4-media) checks all of it, downloads the
direct-link items for you (ADK, WinPE, VC++, ODBC), and opens the
sign-in-gated download pages for the rest.

- [ ] **Windows Server 2025 Eval ISO** -> `C:\LabSources\ISOs\`
      ([download](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025))
- [ ] **Windows 11 Enterprise Eval ISO** -> `C:\LabSources\ISOs\`
      ([download](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise))
- [ ] **SQL Server 2022 Eval ISO** -> `C:\LabSources\ISOs\`
      ([download](https://www.microsoft.com/en-us/evalcenter/download-sql-server-2022) --
      this runs a small bootstrapper first; choose "Download Media" to get the actual ISO)
- [ ] **ConfigMgr 2509 baseline, extracted** -> `C:\LabSources\SoftwarePackages\CM\ConfigMgr_2509\`
      ([download](https://www.microsoft.com/en-us/evalcenter/download-microsoft-endpoint-configuration-manager),
      then extract the download with 7-Zip into that folder)
- [ ] **ADK offline layout** -> `C:\LabSources\SoftwarePackages\ADK\Offline\`
      (get `adksetup.exe` [here](https://go.microsoft.com/fwlink/?linkid=2289980), then run
      `adksetup.exe /quiet /layout C:\LabSources\SoftwarePackages\ADK\Offline`)
- [ ] **WinPE offline layout** -> `C:\LabSources\SoftwarePackages\ADKPE\Offline\`
      (get `adkwinpesetup.exe` [here](https://go.microsoft.com/fwlink/?linkid=2289981), then run
      `adkwinpesetup.exe /quiet /layout C:\LabSources\SoftwarePackages\ADKPE\Offline`)
- [ ] **VC++ 14.50 redist, x64 and x86** -> `C:\LabSources\SoftwarePackages\VCRedist\`
      ([x64](https://aka.ms/vs/18/release/vc_redist.x64.exe), [x86](https://aka.ms/vs/18/release/vc_redist.x86.exe))
- [ ] **ODBC Driver 18.5.2.1 MSI** -> `C:\LabSources\SoftwarePackages\ODBC\msodbcsql.msi`
      ([download](https://go.microsoft.com/fwlink/?linkid=2335671) -- must be this exact version;
      18.6.x has a documented NULL-value regression that breaks CM)

You do **not** need to download an MSOLEDB driver -- CM 2509 setup
installs its own and the engine skips that step by default.

The wizard's [Media page](#step-4-media) scans for all of this and
tells you exactly what it can't find, so it's fine to move on even
if you're not 100% sure everything landed in the right spot.

### 4. Know that you'll need Administrator

Building Hyper-V switches, VMs, and a domain requires an elevated
session. The wizard checks for this and will not let you proceed
without it, so it's easiest to just open PowerShell as Administrator
from the start:

- Click **Start**, type `pwsh`, right-click **PowerShell 7 (x64)**,
  choose **Run as administrator**, and approve the prompt.
- Or, from an existing terminal: `Start-Process pwsh -Verb RunAs`.

## Two ways to deploy

Everything above -- hardware, PowerShell 7, staged media, elevation
-- is required either way. From here you can click through the GUI
wizard (the rest of this doc), or skip straight to a working lab with
one PowerShell command.

### The one-liner (no GUI)

From the same elevated PowerShell 7 window, at the project root:

```powershell
cd C:\projects\mecm-homelab
Import-Module .\modules\HomeLab\HomeLab.psd1
Install-HomeLab
```

`Install-HomeLab` is the whole engine -- it reads `config.psd1`,
builds the `default` 3-VM topology from the
[media you staged](#3-download-the-installation-media), and prints
progress straight to the console. Same engine, same result, same
[timing](#how-long-this-takes) as the GUI path; the GUI is just a
wizard sitting on top of this one cmdlet.

It deploys with the published default lab password unless you pass
your own:

```powershell
$pw = ConvertTo-SecureString 'Your-Lab-Password!' -AsPlainText -Force
Install-HomeLab -LabPassword $pw
```

To build one of the other six topologies instead of `default`, add
`-Template <name>` -- see the [template table](../README.md#templates)
in the README for what each one is.

Everything later in this doc -- verifying the site is healthy,
troubleshooting, starting over -- applies the same regardless of
which path you used to deploy. Skip ahead to
[What "done" looks like](#what-done-looks-like), or keep reading for
the GUI walkthrough.

## Launch the wizard

In your elevated PowerShell 7 window, move to wherever you cloned
this project and run the entry script:

```powershell
cd C:\projects\mecm-homelab
pwsh -NoProfile -File .\gui\start-homelab-gui.ps1
```

The wizard runs every phase in-process. Long steps (CM setup, SQL
install) execute on a background thread so the window stays
responsive and the log drawer at the bottom keeps streaming.

<!-- TODO screenshot: gui-post-cm.png missing, see shot list -->

## Walk through the wizard

The sidebar on the left is the workflow, top to bottom. You move
through it with the **Next** button on each page (or by clicking a
sidebar item directly once you've reached it). **Options** at the
bottom of the sidebar is not part of this flow -- see
[Options](#options-not-part-of-the-flow) below.

### Step 1: Welcome

![Welcome page](screenshots/gui-welcome.png)

Just a summary of the six steps ahead. Nothing to configure here --
click **Pick template** in the sidebar to start.

### Step 2: Pick a template

![Template picker](screenshots/gui-template.png)

Seven built-in topologies plus an option to load your own
`config.psd1`. **If this is your first deploy, pick `default`** --
it's the 3-VM lab described above and the one every part of the
engine fully supports. The other templates trade up to more VMs and
closer-to-enterprise role separation once you know what you're doing
-- see the [template table](../README.md#templates) in the README.

Click **Next: Host check**.

### Step 3: Host check

![Host check page](screenshots/gui-host-check.png)

Click **Run host check**. This is the wizard actually testing your
machine -- PowerShell version, Hyper-V, RAM, free disk,
virtualization extensions, elevation. Each row gets a checkmark or
an X; a summary line above the grid tells you pass/fail at a
glance. (Your staged media gets its own page next.)

**If something fails**, the Detail column names exactly what's wrong.
The two most common first-run misses:

| Detail says | Fix |
|---|---|
| Hyper-V not enabled, reboot required | Reboot the host, then re-run the wizard -- the engine already turned the feature on, it just needs the restart to take effect. |
| TrustedHosts / WinRM check failed | The check gives you the exact `Set-Item` command to run in an elevated window. Run it as shown, then re-run the check. |

Warnings (shown but not blocking) are fine to proceed past -- e.g.
RAM above the minimum but below the recommended number. Only a red
X blocks **Next**.

Click **Next: Media**.

### Step 4: Media

Every external file from the
[download checklist](#3-download-the-installation-media), checked
against your `LabSourcesRoot`, one row each. A checkmark means found
(the Detail column shows the file it matched and its size); an X
means missing. Each missing row offers what fits:

- **Download** -- for the direct-link assets (ODBC MSI, both VC++
  redistributables, the ADK and WinPE offline layouts), the wizard
  fetches straight into the correct folder. The two layouts run the
  Microsoft bootstrapper's `/quiet /layout`, which downloads a
  multi-gigabyte payload -- start those and let them run.
- **Web page** -- the three eval ISOs and the ConfigMgr media need a
  Microsoft sign-in, so the wizard opens the download page in your
  browser instead. Save the file into the folder the Detail column
  names (the **Folder** button opens it in Explorer, creating it if
  needed).
- **Re-check** rescans after you've staged anything.

The "CM prerequisite offline cache" row is optional -- without it,
CM setup downloads its prerequisites live during Phase 08. Missing
required rows here will keep the Review page's Deploy button
disabled, so this is the page to finish before moving on. The
filename match is a wildcard: the exact ISO name doesn't matter, the
folder does.

Click **Next: Topology**.

### Step 5: Topology

![Topology editor](screenshots/gui-topology.png)

A per-VM grid: name, roles, IP, CPU, memory, disk size, start delay.
**For a first deploy, leave everything as-is and click Validate,
then Next** -- the defaults are a known-good configuration. Come back
to this page on a later run once you want to, say, hand CM01 more
RAM or rename a VM.

**Validate** re-runs the same schema check the engine itself uses
before a real deploy: every IP inside the lab network, exactly one
domain controller, minimum memory not greater than maximum memory,
and so on. Fix anything it flags before moving on.

Click **Next: Post-CM**.

### Step 6: Post-CM

<!-- TODO screenshot: gui-post-cm.png missing, see shot list -->

Optional day-2 extras, applied after the site is up and healthy.
**Safe to leave everything unchecked on a first run** -- you're not
losing the ability to add these later, since re-running the wizard
against an already-built lab is quick (see
[Starting over](#starting-over)). Each section is independent:

- **Collections** -- ready-made device collections: All Workstations,
  All Servers, and a test collection containing CLIENT01.
- **Maintenance windows** -- a Saturday patch window and a daily test
  window, tied to the collections above.
- **Driver categories** -- vendor/model tags for OS deployment.
- **Applications** -- import output from the app-packager tool, if
  you have any staged.
- **OSD** -- imports a WinPE boot image and creates a starter
  "Build Win11" task sequence.

Click **Next: Review**.

### Step 7: Review

<!-- TODO screenshot: gui-review.png missing, see shot list -->

Read-only panes: the topology you're about to build, the Post-CM
options you selected, the media check, and the ordered list of
phases the engine will run. If any required media is still missing,
the media pane lists exactly what and **Deploy stays disabled** --
stage it, then click **Re-check media**. This is your last chance to
back out or go fix something -- nothing has been created yet.

Click **Deploy** to move to the final page.

### Step 8: Deploy

<!-- TODO screenshot: gui-deploy.png missing, see shot list -->

Click **Start deploy**. From this point the wizard is actually
building the lab: Hyper-V switch, VMs, domain promotion, SQL, CM
setup, CM configuration, then your Post-CM choices, in that order.
You'll see:

- A status line and spinner showing the current phase.
- A phase checklist that flips from `waiting` to `running` to `done`
  as it goes.
- A progress bar across all phases.
- The log drawer at the bottom streaming every engine line live.

**Keep the window open until this finishes** -- the deploy runs
inside the wizard process, so closing it stops the build. If your
host is a laptop, turn off sleep for this run.

**Cancel** stops the build after the phase currently in flight
finishes -- it will not abandon a phase mid-way (so if CM setup is
running, it finishes CM setup, then stops before the next phase).

#### A note on the lab password

If you didn't supply your own password (by editing `AdminPass` in a
config file, or setting the `HOMELAB_PASSWORD` environment variable
before launching), the wizard silently falls back to the same
published default password every copy of this repo ships with --
you'll see a `WARN` line about it in the log drawer. That's fine for
an isolated lab on your own machine; just know it's not a secret.

## How long this takes

Measured on a fairly capable host (20 threads, 32 GB RAM, NVMe):

| Scenario | Time |
|---|---|
| First deploy, building from ISOs | ~70 minutes (~25-30 of which is a one-time base-image build) |
| Full teardown + rebuild, base images cached | ~45-65 minutes |
| Re-running against an already-healthy lab | under 10 minutes |

The CM site install itself is the biggest single chunk and doesn't
get faster on repeat runs -- everything upstream of it does, thanks
to caching and idempotent phase checks.

## What "done" looks like

When the deploy finishes, the log drawer prints a summary: the VM
table, service health, the accounts that got created, which Post-CM
options applied, and where things live on disk.

Open the ConfigMgr console on CM01 and every site system should show
healthy:

![ConfigMgr console showing all site systems OK](screenshots/lab-console-site-status.png)

To get into a VM:

```powershell
Import-Module .\modules\HomeLab\HomeLab.psd1
Connect-HomeLabVM -Name CM01
```

That opens a console session (`vmconnect.exe` under the hood). Log
in as `CONTOSO\LabAdmin` with the lab password from the
[note above](#a-note-on-the-lab-password).

## If the wizard stops you

The [README's Troubleshooting section](../README.md#troubleshooting)
has the full list. The ones a first-timer is most likely to hit:

- **CM setup hangs or fails.** The log drawer will say so, but the
  authoritative source is `C:\ConfigMgrSetup.log` on CM01 itself.
  Re-running `Install-HomeLab` (or the wizard) is usually enough --
  every phase is idempotent and picks up where it left off.
- **"Cannot bind argument to parameter 'Path'" during CM
  configuration.** A stale WinRM session from an earlier phase. Just
  re-run -- the engine refreshes its environment on every attempt.
- **CM01 runs out of disk.** Content distribution filled the OS
  volume. See the README's
  [CM01 OS disk full](../README.md#cm01-os-disk-full) entry for the
  resize steps.

## Starting over

Made a mistake, or just want a clean lab again? From an elevated
PowerShell 7 window:

```powershell
Import-Module .\modules\HomeLab\HomeLab.psd1
Remove-HomeLab -KeepBaseImages
Install-HomeLab
```

`-KeepBaseImages` reuses the cached, already-sysprepped Windows
images, which is why a rebuild (~45-65 min) is faster than the first
deploy (~70 min). Drop that flag to wipe everything including the
image cache.

## Options (not part of the flow)

<!-- TODO screenshot: gui-options.png missing, see shot list -->

The **Options** item at the bottom of the sidebar is always
available and holds settings that apply across runs, not just this
one:

- **Paths** -- where staged media lives (`LabSourcesRoot`, default
  `C:\LabSources`) and where VM disks get built
  (`LabImagePath`, default `C:\LabImages`), plus how many VMs the
  engine provisions in parallel (1-16, default 3).
- **Logging** -- how much detail the log drawer shows (Quiet /
  Normal / Verbose), whether it timestamps each line, and the exact
  paths of the GUI and engine log files on disk.
- **Defaults** -- which Post-CM checkboxes come pre-checked the next
  time you open that page.
- **About** -- current version, project URL, and where the settings
  file itself lives on disk.

The dark/light theme toggle lives at the bottom of the sidebar, not
on this page.

## Where to go next

- [README](../README.md) -- full reference: all seven templates, the
  cmdlet path, every `config.psd1` key, exported cmdlets, and the
  complete troubleshooting list.
- [docs/architecture.md](architecture.md) -- how the engine's phases
  fit together, for anyone modifying it.
- [docs/native-engine-cookbook.md](native-engine-cookbook.md) --
  specific Microsoft-surface gotchas the engine works around.
- [docs/unattend-templates.md](unattend-templates.md) -- how the
  per-VM unattended-install answer files are built.
