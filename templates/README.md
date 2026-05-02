# HomeLab templates

Six built-in topology templates. Each is a fully-formed
`config.psd1` the engine consumes via `Install-HomeLab -Template
<name>`.

## Inventory

| Template | VMs | Engine support | When to use |
|---|---|---|---|
| `default.psd1` | 3 | Full | Smallest fully-functional lab. DC + CM (all CM roles co-located) + Client. |
| `split-sql.psd1` | 4 | Full | Mirrors enterprise tier-2: dedicated SQL VM. CM site DB lives on SQL01. |
| `role-per-server.psd1` | 7 | Partial (SUP falls back to site server) | Mirrors enterprise tier-1: each CM role on its own VM. |
| `aio.psd1` | 2 | Schema-only | DC + CM role bundle on one VM. CM 2509 setup rejects DC-co-resident installs; this template documents the topology but will not produce a working lab. |
| `cas-2-dps.psd1` | 6 | Schema-only | CAS hierarchy + 2 regional DPs. Orchestrator rejects CAS until CAS install + replication ships in a future tag. |
| `cas-role-per-server.psd1` | 9 | Schema-only | Full enterprise mirror: parent CAS + child primary + dedicated SQL + MP + multi-DP + SUP. Same CAS deferral as above. |

## Usage

```powershell
# Default 3-VM lab.
Install-HomeLab -Template default

# Role-per-server lab with more parallelism.
Install-HomeLab -Template role-per-server -ParallelThrottle 6

# Custom path bypasses the templates folder.
Install-HomeLab -ConfigPath C:\my-custom-lab.psd1
```

`-Template` and `-ConfigPath` are mutually exclusive. `-Template`
resolves to `templates/<name>.psd1` relative to the module root.

## Customising

Templates are not "frozen" -- copy any of them to your own path,
edit, and pass via `-ConfigPath`. The schema validation in
`Get-LabConfig` catches the common mistakes (missing roles, IPs
outside the network prefix, duplicate names, MinMemory > MaxMemory)
at config-load time.

## Authoring rules

- Top-level keys must include: `LabName`, `DomainName`, `SiteCode`,
  `SiteName`, `Network`, `AdminUser`, `AdminPass`,
  `ServerOSFilter`, `ClientOSFilter`, `ServiceAccounts`, and either
  `VMs[]` (canonical) or legacy `DC` / `CM` / `Client` blocks.
- Every VM needs `Name`, `Roles`, `IP`, `Memory`, `MinMemory`,
  `MaxMemory`, `Processors`. `OSDiskSize` and `AutoStartDelay` are
  optional.
- All IPs must share the `Network` prefix.
- Exactly one VM must carry `DomainController`.
- At least one VM must carry each of `SiteServer`, `SqlServer`,
  `ManagementPoint`, `DistributionPoint`, `SoftwareUpdatePoint`.
- At most one VM may carry `CentralAdministrationSite`.
- Roles may freely co-locate on a single VM (the default template
  uses this for CM01).
