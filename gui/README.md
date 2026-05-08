# MECM HomeLab GUI

PowerShell + WPF (MahApps.Metro) wizard layered on top of the
HomeLab module. The cmdlet path stays primary; this GUI is additive.

## Launch

```powershell
pwsh -NoProfile -File c:\projects\mecm-homelab\gui\start-homelab-gui.ps1
```

PS 7.6 LTS required (matches the engine floor).

## Layout

```
gui/
    MainWindow.xaml        Shell: sidebar + content + log drawer + status bar
    start-homelab-gui.ps1  Entry script: load MahApps, parse XAML, theme + sidebar wiring
    Lib/                   Vendored MahApps + ControlzEx + Microsoft.Xaml.Behaviors DLLs
    Pages/                 Per-step UserControls (one .xaml per workflow page)
        Welcome.xaml       Cover page (S20)
        ...                S21..S24 fill in Template / HostCheck / Topology /
                           PostCm / Review / Deploy / Options
    Logs/                  Per-session GUI logs (auto-created; excluded from git)
```

## Dependencies

The `gui/Lib/` folder vendors:

- `MahApps.Metro.dll` (+ XML doc)
- `ControlzEx.dll`
- `Microsoft.Xaml.Behaviors.dll`

Same set as `app-packager/Lib/`, `mmc-if/Lib/`, etc. -- standard for
the personal-bucket PS+WPF apps.

No NuGet, no PSGallery, no network pulls at runtime.

## Brand

Conforms to the project WPF brand spec:

- Theme: `Dark.Steel` (default) / `Light.Blue` toggle on the sidebar
- Square buttons only (`MahApps.Styles.Button.Square`) with the
  brand-standard pressed-state shade-lift template
- Type scale: 20 (app title), 18 (page title), 13 (sidebar buttons),
  11 (section headers / status), 10 (version / log label)
- Cascadia monospace stack for the log drawer
- No red / green; status conveyed by glyph shape

## Engine integration

Each sidebar button maps to a step in the deploy workflow:

| Button | Engine surface |
|---|---|
| Welcome | -- (cover page) |
| Pick template | `Install-HomeLab -Template <name>` resolution |
| Host check | `Test-HostPrereq` + ISO catalog scan |
| Topology | per-VM editor that writes back into `$cfg.VMs[]` |
| Post-CM | `New-CMRoleCollection / MaintenanceWindow / Deployment / DriverCategory` etc. |
| Review | resolved config + deploy plan summary |
| Deploy | `Install-HomeLab` in a background runspace; live log stream |
| Options | preferences (paths, logging, default template) |

## Status

- **S20 (this scaffold)**: shell + theme + log drawer + Welcome page +
  placeholder workflow buttons that load stub pages.
- **S21..S24**: progressive fill-in of the wizard pages, topology
  editor, post-CM editor, live deploy view.
