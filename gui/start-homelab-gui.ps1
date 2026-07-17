<#
.SYNOPSIS
    Launch the MECM HomeLab GUI (PS+WPF MahApps shell).

.DESCRIPTION
    Entry script for the GUI. Loads the MahApps
    DLLs from gui/Lib/, parses MainWindow.xaml, wires the workflow
    sidebar buttons to placeholder pages, swaps theme on toggle, and
    routes engine logs into the in-window drawer + a per-session
    file under Logs/.

    The cmdlet path stays primary; this GUI is additive. Every
    sidebar button maps to an Install-HomeLab parameter set under
    the hood (the wizard pages translate UI selections into cmdlet
    invocations executed in a background runspace).

    For now (S20) the page contents are placeholders. S21..S24 fill
    in the wizard pages, topology editor, post-CM editor, and live
    deploy view.

.NOTES
    Requires PS 7.6 LTS. The HomeLab module manifest declares the
    same floor; we re-check here for a friendlier error than
    "ForEach-Object -Parallel parameter not found" later in the
    deploy path.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Self-bootstrap into pwsh 7.6+ when invoked from Windows PowerShell
# 5.1 (where '&' runs the script in the current shell, not pwsh).
# winget-installed PowerShell 7 lands as 'pwsh' on PATH.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) {
        throw "start-homelab-gui requires PowerShell 7.6 LTS+. Got $($PSVersionTable.PSVersion). pwsh not found on PATH. Install via 'winget install Microsoft.PowerShell'."
    }
    & $pwsh -NoProfile -File $PSCommandPath @args
    exit $LASTEXITCODE
}

if ($PSVersionTable.PSVersion -lt [version]'7.6') {
    throw "start-homelab-gui requires PowerShell 7.6 LTS+. Got $($PSVersionTable.PSVersion). Update via 'winget install Microsoft.PowerShell'."
}

$script:Root      = Split-Path -Parent $PSCommandPath
$script:LibDir    = Join-Path $script:Root 'Lib'
$script:PagesDir  = Join-Path $script:Root 'Pages'
$script:LogDir    = Join-Path $script:Root 'Logs'
$script:RepoRoot  = Split-Path -Parent $script:Root
$script:Module    = Join-Path $script:RepoRoot 'modules\HomeLab\HomeLab.psd1'

if (-not (Test-Path $script:LogDir)) {
    New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
}
$script:LogFile = Join-Path $script:LogDir ('homelab-gui-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# ─── Persistent GUI settings ─────────────────────────────────────────
# Settings live in gui/Settings/options.json next to the script; per-clone,
# auto-generated on first save, never tracked (matches the project's
# no-json-in-public-repos rule via .git/info/exclude *.json).
$script:SettingsDir  = Join-Path $script:Root 'Settings'
$script:SettingsFile = Join-Path $script:SettingsDir 'options.json'

$script:GuiSettingsDefaults = @{
    Paths = @{
        LabSourcesRoot   = 'C:\LabSources'
        LabImagePath     = 'C:\LabImages'
        ParallelThrottle = 3
    }
    Logging = @{
        Verbosity      = 'Normal'    # Quiet | Normal | Verbose
        ShowTimestamps = $true
    }
    Defaults = @{
        # Default Post-CM toggles -- pre-checked on the Post-CM page.
        # Template selection lives on the Pick Template page (the first
        # radio button = "default" is checked at launch). Theme defaults
        # to Dark.Steel; the sidebar toggle handles per-session light/dark.
        PostCm = @{
            Coll_AllWorkstations = $true
            Coll_AllServers      = $true
            Coll_TestDirect      = $true
            MW_PatchSaturday     = $true
            MW_TestDaily         = $true
            Osd_BootImage        = $false
            Osd_TaskSequenceStub = $false
        }
    }
}

function Merge-GuiSettings {
    # Recursively overlay $Custom values on top of the $Default schema.
    # Anything missing from the saved file falls through to defaults so
    # an older / stripped-down options.json still loads cleanly.
    param([hashtable]$Default, [object]$Custom)
    $result = @{}
    foreach ($k in $Default.Keys) {
        $hasKey = $false
        $cv = $null
        if ($Custom -is [hashtable]) {
            if ($Custom.ContainsKey($k)) { $hasKey = $true; $cv = $Custom[$k] }
        } elseif ($Custom -is [psobject]) {
            $prop = $Custom.PSObject.Properties[$k]
            if ($prop) { $hasKey = $true; $cv = $prop.Value }
        }
        if ($hasKey) {
            if ($Default[$k] -is [hashtable]) {
                $result[$k] = Merge-GuiSettings -Default $Default[$k] -Custom $cv
            } else {
                $result[$k] = $cv
            }
        } else {
            if ($Default[$k] -is [hashtable]) {
                $result[$k] = Merge-GuiSettings -Default $Default[$k] -Custom @{}
            } else {
                $result[$k] = $Default[$k]
            }
        }
    }
    return $result
}

function Get-HomeLabGuiSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsFile)) {
        return Merge-GuiSettings -Default $script:GuiSettingsDefaults -Custom @{}
    }
    try {
        $raw = Get-Content -Raw -LiteralPath $script:SettingsFile -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return Merge-GuiSettings -Default $script:GuiSettingsDefaults -Custom @{}
        }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        return Merge-GuiSettings -Default $script:GuiSettingsDefaults -Custom $obj
    } catch {
        # Corrupt / unreadable settings -> fall back to defaults silently.
        return Merge-GuiSettings -Default $script:GuiSettingsDefaults -Custom @{}
    }
}

function Save-HomeLabGuiSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsDir)) {
        New-Item -Path $script:SettingsDir -ItemType Directory -Force | Out-Null
    }
    try {
        $json = $script:GuiSettings | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $script:SettingsFile -Value $json -Encoding UTF8
    } catch {
        # Save failures are non-fatal; user can still operate the UI
        # without persistence. Surface in the log drawer when available.
        if (Get-Command Add-LogLine -ErrorAction SilentlyContinue) {
            Add-LogLine ("Settings save failed: {0}" -f $_.Exception.Message) 'WARN'
        }
    }
}

$script:GuiSettings = Get-HomeLabGuiSettings

# WPF assemblies. PS 7 / .NET 10 does not auto-load these the way
# Windows PowerShell 5.1 did, so any reference to System.Windows.*
# types (BrushConverter, XamlReader, etc.) must come AFTER this.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Load MahApps DLLs.
foreach ($dll in 'Microsoft.Xaml.Behaviors.dll','ControlzEx.dll','MahApps.Metro.dll') {
    $p = Join-Path $script:LibDir $dll
    if (-not (Test-Path $p)) {
        throw "start-homelab-gui: missing vendored DLL '$p'. The gui/Lib/ folder must contain MahApps.Metro.dll, ControlzEx.dll, and Microsoft.Xaml.Behaviors.dll."
    }
    Unblock-File -Path $p -ErrorAction SilentlyContinue
    [void][System.Reflection.Assembly]::LoadFrom($p)
}

# Pull in the engine module so wizard pages can call its public
# cmdlets directly.
Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module $script:Module -Force -ErrorAction Stop

# Also dot-source key helpers + private engine functions so the GUI
# can call them without going through the public surface.
$helpersDir = Join-Path $script:RepoRoot 'modules\HomeLab\Helpers'
. (Join-Path $helpersDir 'Get-LabConfig.ps1')
. (Join-Path $helpersDir 'Get-LabVMByRole.ps1')
. (Join-Path $helpersDir 'Resolve-LabVM.ps1')

$privateDir = Join-Path $script:RepoRoot 'modules\HomeLab\Private'
. (Join-Path $privateDir '01-Prereq\Test-HostPrereq.ps1')

# Brand colours that need runtime swap (XAML hardcoded values do not
# survive ChangeTheme; only Gray1 is genuinely theme-adaptive in
# MahApps, everything else stays the same hex across themes and has
# to be swapped here).
$script:DarkButtonBg      = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#1E1E1E')
$script:DarkButtonBorder  = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#555555')
$script:LightButtonBg     = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0078D4')
$script:LightButtonBorder = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#006CBE')
$script:TitleBarBlue         = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0078D4')
$script:TitleBarBlueInactive = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#4BA3E0')
$script:LogLabelDark      = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#B0B0B0')
$script:LogLabelLight     = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#595959')
# Module band + status bar background: Gray10 in MahApps is static
# (#2F2F2F dark / #F7F7F7 light per the brand spec); apply per-theme
# hex pair at runtime.
$script:BandBgDark        = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#2F2F2F')
$script:BandBgLight       = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F7F7F7')

# Load + parse MainWindow.xaml.
$xamlPath = Join-Path $script:Root 'MainWindow.xaml'
[xml]$xml = Get-Content -LiteralPath $xamlPath -Raw
$reader   = New-Object System.Xml.XmlNodeReader $xml
$window   = [System.Windows.Markup.XamlReader]::Load($reader)

# Resolve named controls.
$script:lblLogOutput = $window.FindName('lblLogOutput')
$script:txtLog       = $window.FindName('txtLog')
$script:txtStatus    = $window.FindName('txtStatus')
$script:moduleHost   = $window.FindName('moduleHost')
$script:txtModuleTitle    = $window.FindName('txtModuleTitle')
$script:txtModuleSubtitle = $window.FindName('txtModuleSubtitle')
$script:tglTheme     = $window.FindName('tglTheme')
$script:bdModuleBand = $window.FindName('bdModuleBand')
$script:bdStatusBar  = $window.FindName('bdStatusBar')

$script:SidebarButtons = @(
    'btnWelcome','btnTemplate','btnHostCheck','btnTopology',
    'btnPostCm','btnReview','btnDeploy','btnOptions'
) | ForEach-Object { $window.FindName($_) } | Where-Object { $_ }

# ─── Title-bar drag fallback ─────────────────────────────────────────
function Get-TitleBarDragHeight {
    param([MahApps.Metro.Controls.MetroWindow]$Window)

    try {
        $h = [double]$Window.TitleBarHeight
        if ($h -gt 0 -and -not [double]::IsNaN($h)) { return $h }
    } catch {
        $null = $_
    }
    return 30.0
}

function Get-InputAncestors {
    param([System.Windows.DependencyObject]$Start)

    $cur = $Start
    while ($cur) {
        $cur

        $parent = $null
        if ($cur -is [System.Windows.Media.Visual] -or $cur -is [System.Windows.Media.Media3D.Visual3D]) {
            try { $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($cur) } catch { $parent = $null }
        }
        if (-not $parent -and $cur -is [System.Windows.FrameworkElement]) {
            $parent = $cur.Parent
        }
        if (-not $parent -and $cur -is [System.Windows.FrameworkContentElement]) {
            $parent = $cur.Parent
        }
        if (-not $parent -and $cur -is [System.Windows.ContentElement]) {
            try { $parent = [System.Windows.ContentOperations]::GetParent($cur) } catch { $parent = $null }
        }

        $cur = $parent
    }
}

function Test-IsWindowCommandPoint {
    param(
        [MahApps.Metro.Controls.MetroWindow]$Window,
        [System.Windows.Point]$Point
    )

    try {
        [void]$Window.ApplyTemplate()
        $commands = $Window.Template.FindName('PART_WindowButtonCommands', $Window)
        if ($commands -and $commands.IsVisible -and $commands.ActualWidth -gt 0 -and $commands.ActualHeight -gt 0) {
            $origin = $commands.TransformToAncestor($Window).Transform([System.Windows.Point]::new(0, 0))
            if ($Point.X -ge $origin.X -and
                $Point.X -le ($origin.X + $commands.ActualWidth) -and
                $Point.Y -ge $origin.Y -and
                $Point.Y -le ($origin.Y + $commands.ActualHeight)) {
                return $true
            }
        }
    } catch {
        $null = $_
    }

    # Template lookup can fail before the first layout pass. Keep the
    # right-side caption buttons available with a conservative fallback.
    return ($Window.ActualWidth -gt 150 -and $Point.X -ge ($Window.ActualWidth - 150))
}

function Add-NativeTitleBarHitTestHook {
    param([MahApps.Metro.Controls.MetroWindow]$Window)

    if ($script:TitleBarHitTestHookInstalled) { return }

    try {
        $helper = [System.Windows.Interop.WindowInteropHelper]::new($Window)
        $source = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
        if (-not $source) { return }

        $script:TitleBarHitTestWindow = $Window
        $script:TitleBarHitTestHook = [System.Windows.Interop.HwndSourceHook]{
            param(
                [IntPtr]$hwnd,
                [int]$msg,
                [IntPtr]$wParam,
                [IntPtr]$lParam,
                [ref]$handled
            )

            $WM_NCHITTEST = 0x0084
            $HTCAPTION = 2
            if ($msg -ne $WM_NCHITTEST) { return [IntPtr]::Zero }

            try {
                $target = $script:TitleBarHitTestWindow
                if (-not $target) { return [IntPtr]::Zero }

                $raw = $lParam.ToInt64()
                $screenX = [int]($raw -band 0xffff)
                if ($screenX -ge 0x8000) { $screenX -= 0x10000 }
                $screenY = [int](($raw -shr 16) -band 0xffff)
                if ($screenY -ge 0x8000) { $screenY -= 0x10000 }
                $pt = $target.PointFromScreen([System.Windows.Point]::new($screenX, $screenY))
                $titleBarH = Get-TitleBarDragHeight -Window $target

                if ($pt.X -lt 0 -or $pt.X -gt $target.ActualWidth) { return [IntPtr]::Zero }
                if ($pt.Y -lt 4 -or $pt.Y -gt $titleBarH) { return [IntPtr]::Zero }
                if (Test-IsWindowCommandPoint -Window $target -Point $pt) { return [IntPtr]::Zero }

                $handled.Value = $true
                return [IntPtr]$HTCAPTION
            } catch {
                return [IntPtr]::Zero
            }
        }

        $source.AddHook($script:TitleBarHitTestHook)
        $script:TitleBarHitTestHookInstalled = $true
    } catch {
        Add-LogLine ("Title-bar native hit-test fallback failed: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function Install-TitleBarDragFallback {
    param([MahApps.Metro.Controls.MetroWindow]$Window)

    # Prefer the native path: returning HTCAPTION from WM_NCHITTEST lets
    # Windows perform the move, including drag-to-restore when maximized.
    $Window.Add_SourceInitialized({
        param($s, $e)
        Add-NativeTitleBarHitTestHook -Window $s
    })

    # Keep a managed fallback for environments where HwndSource cannot be
    # hooked. This also avoids a dead title band if MahApps' title Thumb
    # stops receiving DragDelta after XamlReader-created content changes.
    $Window.Add_PreviewMouseLeftButtonDown({
        param($s, $e)
        try {
            if ($s.WindowState -eq [System.Windows.WindowState]::Maximized) { return }
            $titleBarH = Get-TitleBarDragHeight -Window $s
            $pos = $e.GetPosition($s)
            if ($pos.Y -lt 4 -or $pos.Y -gt $titleBarH) { return }
            if (Test-IsWindowCommandPoint -Window $s -Point $pos) { return }

            foreach ($ancestor in Get-InputAncestors -Start ($e.OriginalSource -as [System.Windows.DependencyObject])) {
                if ($ancestor -is [System.Windows.Controls.Primitives.ButtonBase]) { return }
            }

            $s.DragMove()
            $e.Handled = $true
        } catch {
            # DragMove throws if the button is released before it starts.
            # Do not let a drag miss crash the WPF dispatcher.
            $null = $_
        }
    })
}

Install-TitleBarDragFallback -Window $window

function Add-LogLine {
    param([string]$Message, [string]$Level = 'INFO')

    # File log always captures everything regardless of UI verbosity;
    # the file is the source of truth for diagnostics.
    $fileStamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $fileLine  = '[{0}] [{1}] {2}' -f $fileStamp, $Level.PadRight(5), $Message
    Add-Content -Path $script:LogFile -Value $fileLine -Encoding UTF8 -ErrorAction SilentlyContinue

    if ($null -eq $script:txtLog) { return }

    # UI filter: settings-driven verbosity floor. Levels above the floor
    # surface in the log drawer; the rest only hit the file.
    $verbosity = if ($script:GuiSettings) { [string]$script:GuiSettings.Logging.Verbosity } else { 'Normal' }
    $lvl = $Level.Trim().ToUpperInvariant()
    $isVerbose = $lvl -in 'VERB','VERBOSE','DEBUG'
    $isError   = $lvl -in 'ERROR','FATAL','WARN'
    $allow = switch ($verbosity) {
        'Quiet'   { $isError }
        'Verbose' { $true }
        default   { -not $isVerbose }
    }
    if (-not $allow) { return }

    $showStamp = $true
    if ($script:GuiSettings) { $showStamp = [bool]$script:GuiSettings.Logging.ShowTimestamps }
    $line = if ($showStamp) {
        '{0}  [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.PadRight(5), $Message
    } else {
        '[{0}] {1}' -f $Level.PadRight(5), $Message
    }
    $script:txtLog.AppendText($line + [Environment]::NewLine)
    $script:txtLog.ScrollToEnd()
}

function Set-Status { param([string]$Text) $script:txtStatus.Text = $Text }

function Test-GuiIsElevated {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Copy-PostCmConfig {
    $copy = @{}
    foreach ($key in $script:PostCmConfig.Keys) {
        $copy[$key] = $script:PostCmConfig[$key]
    }
    return $copy
}

function Show-ThemedMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Owner,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('OK','YesNo')]
        [string]$Buttons = 'OK'
    )

    $dialogXaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Width="460"
    SizeToContent="Height"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterOwner"
    ShowIconOnTitleBar="False"
    TitleCharacterCasing="Normal"
    GlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    NonActiveGlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    BorderThickness="1">
    <Controls:MetroWindow.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Steel.xaml" />
            </ResourceDictionary.MergedDictionaries>
        </ResourceDictionary>
    </Controls:MetroWindow.Resources>
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="txtMessage"
                   TextWrapping="Wrap"
                   FontSize="12"
                   Margin="0,0,0,18"/>
        <StackPanel Grid.Row="1"
                    Orientation="Horizontal"
                    HorizontalAlignment="Right">
            <Button x:Name="btnPrimary"
                    Style="{DynamicResource MahApps.Styles.Button.Square.Accent}"
                    MinWidth="90"
                    Height="32"
                    IsDefault="True"
                    Controls:ControlsHelper.ContentCharacterCasing="Normal"/>
            <Button x:Name="btnSecondary"
                    Style="{DynamicResource MahApps.Styles.Button.Square}"
                    MinWidth="90"
                    Height="32"
                    Margin="8,0,0,0"
                    IsCancel="True"
                    Controls:ControlsHelper.ContentCharacterCasing="Normal"/>
        </StackPanel>
    </Grid>
</Controls:MetroWindow>
'@

    [xml]$dialogXml = $dialogXaml
    $reader = New-Object System.Xml.XmlNodeReader $dialogXml
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Title = $Title
    $dlg.Owner = $Owner
    [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($dlg, $script:CurrentTheme)

    $txt = $dlg.FindName('txtMessage')
    $btnPrimary = $dlg.FindName('btnPrimary')
    $btnSecondary = $dlg.FindName('btnSecondary')
    if ($txt) { $txt.Text = $Message }

    $script:__ThemedMessageResult = if ($Buttons -eq 'YesNo') { 'No' } else { 'OK' }
    if ($Buttons -eq 'YesNo') {
        $btnPrimary.Content = 'Yes'
        $btnSecondary.Content = 'No'
        $btnSecondary.Visibility = [System.Windows.Visibility]::Visible
        $btnPrimary.Add_Click({
            $script:__ThemedMessageResult = 'Yes'
            $dlg.Close()
        })
        $btnSecondary.Add_Click({
            $script:__ThemedMessageResult = 'No'
            $dlg.Close()
        })
    } else {
        $btnPrimary.Content = 'OK'
        $btnSecondary.Visibility = [System.Windows.Visibility]::Collapsed
        $btnPrimary.Add_Click({
            $script:__ThemedMessageResult = 'OK'
            $dlg.Close()
        })
    }

    [void]$dlg.ShowDialog()
    return [string]$script:__ThemedMessageResult
}

$script:CurrentTheme = 'Dark.Steel'

function Apply-Theme {
    param([bool]$IsDark)
    $themeName = if ($IsDark) { 'Dark.Steel' } else { 'Light.Blue' }
    $script:CurrentTheme = $themeName
    [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, $themeName)
    # Also push the theme into any UserControl currently hosted in
    # moduleHost: hosted pages merge their own Themes/Dark.Steel.xaml
    # so they parse standalone via XamlReader, but that hardcoded
    # merge ignores the window-level ChangeTheme. Re-applying directly
    # to the page swaps its merged theme dict to match.
    if ($script:moduleHost -and $script:moduleHost.Content) {
        [ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($script:moduleHost.Content, $themeName) | Out-Null
    }

    $bg     = if ($IsDark) { $script:DarkButtonBg     } else { $script:LightButtonBg }
    $border = if ($IsDark) { $script:DarkButtonBorder } else { $script:LightButtonBorder }
    foreach ($b in $script:SidebarButtons) {
        $b.Background  = $bg
        $b.BorderBrush = $border
    }

    $bandBg = if ($IsDark) { $script:BandBgDark } else { $script:BandBgLight }
    if ($script:bdModuleBand) { $script:bdModuleBand.Background = $bandBg }
    if ($script:bdStatusBar)  { $script:bdStatusBar.Background  = $bandBg }

    if ($IsDark) {
        $window.ClearValue([MahApps.Metro.Controls.MetroWindow]::WindowTitleBrushProperty)
        $window.ClearValue([MahApps.Metro.Controls.MetroWindow]::NonActiveWindowTitleBrushProperty)
    } else {
        $window.WindowTitleBrush          = $script:TitleBarBlue
        $window.NonActiveWindowTitleBrush = $script:TitleBarBlueInactive
    }

    $script:lblLogOutput.Foreground = if ($IsDark) { $script:LogLabelDark } else { $script:LogLabelLight }

    Add-LogLine ('Theme: {0}' -f $themeName)
}

$script:SelectedTemplate = 'default'
$script:CurrentConfig    = $null
$script:CurrentPage      = $null

# Post-CM choices captured by the PostCm wizard page; surfaced on
# Review and (when S24 lands) consumed by the background deploy
# runspace. Booleans for opt-in customizations + free-form text for
# driver categories and app-packager root.
$script:PostCmCheckMap = [ordered]@{
    chkCollWorkstations = 'Coll_AllWorkstations'
    chkCollServers      = 'Coll_AllServers'
    chkCollTestDirect   = 'Coll_TestDirect'
    chkMwSaturday       = 'MW_PatchSaturday'
    chkMwTestDaily      = 'MW_TestDaily'
    chkOsdBoot          = 'Osd_BootImage'
    chkOsdTs            = 'Osd_TaskSequenceStub'
}
$script:PostCmConfig = @{
    Coll_AllWorkstations = [bool]$script:GuiSettings.Defaults.PostCm.Coll_AllWorkstations
    Coll_AllServers      = [bool]$script:GuiSettings.Defaults.PostCm.Coll_AllServers
    Coll_TestDirect      = [bool]$script:GuiSettings.Defaults.PostCm.Coll_TestDirect
    MW_PatchSaturday     = [bool]$script:GuiSettings.Defaults.PostCm.MW_PatchSaturday
    MW_TestDaily         = [bool]$script:GuiSettings.Defaults.PostCm.MW_TestDaily
    Osd_BootImage        = [bool]$script:GuiSettings.Defaults.PostCm.Osd_BootImage
    Osd_TaskSequenceStub = [bool]$script:GuiSettings.Defaults.PostCm.Osd_TaskSequenceStub
    Drivers_Csv          = ''
    AppPackager_Root     = ''
}

# Maps the template radio button x:Name to its templates/<file>.psd1 stem.
$script:TemplateRadioMap = [ordered]@{
    rbDefault          = 'default'
    rbTwoClients       = 'two-clients'
    rbSplitSql         = 'split-sql'
    rbRolePerServer    = 'role-per-server'
    rbAio              = 'aio'
    rbCas2Dps          = 'cas-2-dps'
    rbCasRolePerServer = 'cas-role-per-server'
    rbCustom           = 'custom'
}

function Resolve-TemplatePath {
    param([string]$Template)
    if ($Template -eq 'custom') { return $script:CustomConfigPath }
    return (Join-Path (Split-Path $script:Root -Parent) (Join-Path 'templates' "$Template.psd1"))
}

function Load-CurrentConfig {
    $path = Resolve-TemplatePath -Template $script:SelectedTemplate
    if (-not $path -or -not (Test-Path $path)) {
        Add-LogLine ("Config not found: {0}" -f $path) 'ERROR'
        return $null
    }
    try {
        $script:CurrentConfig = Get-LabConfig -Path $path
        Add-LogLine ("Loaded {0} ({1} VMs)" -f $script:SelectedTemplate, @($script:CurrentConfig.VMs).Count)
        return $script:CurrentConfig
    } catch {
        Add-LogLine ("Get-LabConfig failed: {0}" -f $_.Exception.Message) 'ERROR'
        return $null
    }
}

function Load-Page {
    param([string]$Name, [string]$Title, [string]$Subtitle)
    $xamlFile = Join-Path $script:PagesDir ("$Name.xaml")
    if (-not (Test-Path $xamlFile)) {
        Set-Status ("Page '{0}' not implemented yet." -f $Name)
        Add-LogLine ("Page '{0}' XAML missing at {1}; placeholder loaded." -f $Name, $xamlFile) 'WARN'
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "Coming in S21+: $Title"
        $tb.FontSize = 14
        $tb.Margin = '8,8,8,8'
        $script:moduleHost.Content = $tb
        $script:CurrentPage = $null
    } else {
        [xml]$pageXml = Get-Content -LiteralPath $xamlFile -Raw
        $pageReader   = New-Object System.Xml.XmlNodeReader $pageXml
        $page         = [System.Windows.Markup.XamlReader]::Load($pageReader)
        $script:moduleHost.Content = $page
        $script:CurrentPage = $page
        # Match the page's hardcoded theme dict to the current window
        # theme. See Apply-Theme for the reasoning.
        [ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($page, $script:CurrentTheme) | Out-Null

        # Per-page wiring (S22). Each branch hooks engine state into
        # the freshly-loaded UserControl.
        switch ($Name) {
            'Template'  { Wire-TemplatePage  -Page $page }
            'HostCheck' { Wire-HostCheckPage -Page $page }
            'Topology'  { Wire-TopologyPage  -Page $page }
            'PostCm'    { Wire-PostCmPage    -Page $page }
            'Review'    { Wire-ReviewPage    -Page $page }
            'Deploy'    { Wire-DeployPage    -Page $page }
            'Options'   { Wire-OptionsPage   -Page $page }
        }
    }
    $script:txtModuleTitle.Text    = $Title
    $script:txtModuleSubtitle.Text = $Subtitle
    Set-Status ("Page: {0}" -f $Title)
}

# ---- Per-page wiring ----------------------------------------------------

function Wire-TemplatePage {
    param([System.Windows.Controls.UserControl]$Page)
    # Restore prior selection.
    foreach ($name in $script:TemplateRadioMap.Keys) {
        $rb = $Page.FindName($name)
        if ($rb) {
            $rb.IsChecked = ($script:TemplateRadioMap[$name] -eq $script:SelectedTemplate)
        }
    }
    $btnNext = $Page.FindName('btnTemplateNext')
    if ($btnNext) {
        $btnNext.Add_Click({
            foreach ($name in $script:TemplateRadioMap.Keys) {
                $rb = $script:CurrentPage.FindName($name)
                if ($rb -and $rb.IsChecked) {
                    $script:SelectedTemplate = $script:TemplateRadioMap[$name]
                    break
                }
            }
            Add-LogLine ("Template selected: {0}" -f $script:SelectedTemplate)
            Load-Page -Name 'HostCheck' -Title 'Host check' -Subtitle 'Hyper-V, RAM, free disk, virt extensions, ISO catalog'
        })
    }
}

$script:HostCheckRunspace = $null
$script:HostCheckPS       = $null
$script:HostCheckTimer    = $null
$script:HostCheckHandle   = $null
$script:HostCheckState    = $null

function Initialize-HostCheckRunspace {
    if ($script:HostCheckRunspace -and $script:HostCheckRunspace.RunspaceStateInfo.State -eq 'Opened') { return }
    $script:HostCheckRunspace = [runspacefactory]::CreateRunspace()
    $script:HostCheckRunspace.ApartmentState = 'STA'
    $script:HostCheckRunspace.ThreadOptions  = 'ReuseThread'
    $script:HostCheckRunspace.Open()
}

function Start-HostCheckAsync {
    $page = $script:CurrentPage
    if (-not $page) { return }

    if ($script:HostCheckTimer) { try { $script:HostCheckTimer.Stop() } catch { $null = $_ } }
    if ($script:HostCheckPS) {
        try { [void]$script:HostCheckPS.Stop() } catch { $null = $_ }
        try { $script:HostCheckPS.Dispose() } catch { $null = $_ }
        $script:HostCheckPS = $null
    }

    $summary = $page.FindName('txtHostCheckSummary')
    $grid    = $page.FindName('dgHostCheck')
    $btnRun  = $page.FindName('btnHostCheckRun')
    if ($summary) { $summary.Text = 'Running...' }
    if ($grid) { $grid.ItemsSource = @() }
    if ($btnRun) { $btnRun.IsEnabled = $false }

    Initialize-HostCheckRunspace

    $script:HostCheckState = [hashtable]::Synchronized(@{
        Done     = $false
        Result   = $null
        ErrorMsg = $null
    })

    $writeLogPath = Join-Path $script:RepoRoot 'modules\HomeLab\Helpers\Write-LabLog.ps1'
    $testPath = Join-Path $script:RepoRoot 'modules\HomeLab\Private\01-Prereq\Test-HostPrereq.ps1'

    $script:HostCheckPS = [powershell]::Create()
    $script:HostCheckPS.Runspace = $script:HostCheckRunspace
    [void]$script:HostCheckPS.AddScript({
        param($WriteLogPath, $TestPath, $State)
        try {
            . $WriteLogPath
            . $TestPath
            $State.Result = Test-HostPrereq -LabImagePath 'C:\LabImages'
        } catch {
            $State.ErrorMsg = '{0} :: {1}' -f $_.Exception.Message, $_.ScriptStackTrace
        } finally {
            $State.Done = $true
        }
    }).AddArgument($writeLogPath).AddArgument($testPath).AddArgument($script:HostCheckState)

    $script:HostCheckHandle = $script:HostCheckPS.BeginInvoke()

    $script:HostCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:HostCheckTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:HostCheckTimer.Add_Tick({
        $st = $script:HostCheckState
        if (-not $st -or -not $st.Done) { return }

        $script:HostCheckTimer.Stop()
        try { [void]$script:HostCheckPS.EndInvoke($script:HostCheckHandle) } catch { $null = $_ }
        try { $script:HostCheckPS.Dispose() } catch { $null = $_ }
        $script:HostCheckPS = $null

        $page = $script:CurrentPage
        if (-not $page) { return }

        $summary = $page.FindName('txtHostCheckSummary')
        $grid    = $page.FindName('dgHostCheck')
        $btnRun  = $page.FindName('btnHostCheckRun')
        if ($btnRun) { $btnRun.IsEnabled = $true }

        if ($st.ErrorMsg) {
            if ($summary) { $summary.Text = ('Host check error: {0}' -f $st.ErrorMsg) }
            Add-LogLine ("Host check error: {0}" -f $st.ErrorMsg) 'ERROR'
            return
        }

        $report = $st.Result
        $rows = @()
        foreach ($key in $report.Checks.Keys) {
            $r = $report.Checks[$key]
            $glyph = if ($r.Pass) { [char]0x2713 } else { [char]0x2717 }
            $rows += [pscustomobject]@{
                Glyph   = [string]$glyph
                Name    = $key
                Message = [string]$r.Message
            }
        }
        if ($grid) { $grid.ItemsSource = $rows }
        if ($summary) {
            $summary.Text = if ($report.Pass) { 'All checks passed.' } else { 'Some checks failed; see grid.' }
        }
        Add-LogLine ("Host check: pass={0}" -f $report.Pass)
    })
    $script:HostCheckTimer.Start()
}

function Wire-HostCheckPage {
    param([System.Windows.Controls.UserControl]$Page)
    $btnRun  = $Page.FindName('btnHostCheckRun')
    $btnBack = $Page.FindName('btnHostCheckBack')
    $btnNext = $Page.FindName('btnHostCheckNext')
    if ($btnRun) {
        $btnRun.Add_Click({
            Start-HostCheckAsync
        })
    }
    if ($btnBack) {
        $btnBack.Add_Click({
            Load-Page -Name 'Template' -Title 'Pick template' -Subtitle 'Choose a built-in topology or load a custom config.psd1'
        })
    }
    if ($btnNext) {
        $btnNext.Add_Click({
            Load-Page -Name 'Topology' -Title 'Topology' -Subtitle 'Per-VM CPU / memory / role assignment'
        })
    }
}

function Get-TopologyRows {
    param([Parameter(Mandatory)] $Config)
    foreach ($vm in $Config.VMs) {
        [pscustomobject]@{
            Name           = [string]$vm.Name
            RolesCsv       = ((@($vm.Roles)) -join ', ')
            IP             = [string]$vm.IP
            Processors     = [int]$vm.Processors
            MemoryGB       = [math]::Round([double]$vm.Memory    / 1GB, 1)
            MinMemoryGB    = [math]::Round([double]$vm.MinMemory / 1GB, 1)
            MaxMemoryGB    = [math]::Round([double]$vm.MaxMemory / 1GB, 1)
            OSDiskGB       = if ($vm.ContainsKey('OSDiskSize')) { [int]$vm.OSDiskSize } else { 0 }
            AutoStartDelay = if ($vm.ContainsKey('AutoStartDelay')) { [int]$vm.AutoStartDelay } else { 30 }
        }
    }
}

function Wire-TopologyPage {
    param([System.Windows.Controls.UserControl]$Page)
    $cfg = if ($script:CurrentConfig) { $script:CurrentConfig } else { Load-CurrentConfig }
    if ($cfg) {
        $grid = $Page.FindName('dgTopology')
        if ($grid) { $grid.ItemsSource = @(Get-TopologyRows -Config $cfg) }
    }
    $btnValidate = $Page.FindName('btnTopologyValidate')
    $btnBack = $Page.FindName('btnTopologyBack')
    $btnNext = $Page.FindName('btnTopologyNext')
    if ($btnValidate) {
        $btnValidate.Add_Click({
            $path = Resolve-TemplatePath -Template $script:SelectedTemplate
            if (-not $path -or -not (Test-Path -LiteralPath $path)) {
                $msg = "Config not found: $path"
                Add-LogLine $msg 'ERROR'
                [void](Show-ThemedMessage -Owner $window -Title 'Validate failed' -Message $msg -Buttons OK)
                return
            }
            try {
                $cfg = Get-LabConfig -Path $path
                $script:CurrentConfig = $cfg
                $vmCount    = @($cfg.VMs).Count
                $totalCpu   = ($cfg.VMs | Measure-Object -Property Processors -Sum).Sum
                $totalRamGB = [math]::Round((($cfg.VMs | ForEach-Object { [double]$_.Memory } | Measure-Object -Sum).Sum / 1GB), 1)
                $roles      = (($cfg.VMs | ForEach-Object { $_.Roles }) | Sort-Object -Unique) -join ', '

                $page = $script:CurrentPage
                if ($page) {
                    $grid = $page.FindName('dgTopology')
                    if ($grid) { $grid.ItemsSource = @(Get-TopologyRows -Config $cfg) }
                }

                $msg = "Schema OK ({0}).`r`n`r`n{1} VMs, {2} vCPU, {3}GB RAM total.`r`n`r`nRoles assigned: {4}" -f `
                    $script:SelectedTemplate, $vmCount, $totalCpu, $totalRamGB, $roles
                Add-LogLine ("Topology validate: {0} VMs, {1} vCPU, {2}GB RAM" -f $vmCount, $totalCpu, $totalRamGB)
                [void](Show-ThemedMessage -Owner $window -Title 'Topology valid' -Message $msg -Buttons OK)
            } catch {
                $msg = "Get-LabConfig rejected the config:`r`n`r`n{0}" -f $_.Exception.Message
                Add-LogLine ("Topology validate failed: {0}" -f $_.Exception.Message) 'ERROR'
                [void](Show-ThemedMessage -Owner $window -Title 'Topology invalid' -Message $msg -Buttons OK)
            }
        })
    }
    if ($btnBack) {
        $btnBack.Add_Click({
            Load-Page -Name 'HostCheck' -Title 'Host check' -Subtitle 'Hyper-V, RAM, free disk, virt extensions, ISO catalog'
        })
    }
    if ($btnNext) {
        $btnNext.Add_Click({
            Load-Page -Name 'PostCm' -Title 'Post-CM' -Subtitle 'Collections, deployments, MWs, driver categories'
        })
    }
}

function Wire-PostCmPage {
    param([System.Windows.Controls.UserControl]$Page)

    # Restore prior selection from the persistent post-CM model.
    $checkMap = [ordered]@{
        chkCollWorkstations = 'Coll_AllWorkstations'
        chkCollServers      = 'Coll_AllServers'
        chkCollTestDirect   = 'Coll_TestDirect'
        chkMwSaturday       = 'MW_PatchSaturday'
        chkMwTestDaily      = 'MW_TestDaily'
        chkOsdBoot          = 'Osd_BootImage'
        chkOsdTs            = 'Osd_TaskSequenceStub'
    }
    foreach ($name in $checkMap.Keys) {
        $cb = $Page.FindName($name)
        if ($cb) {
            $cb.IsChecked = [bool]$script:PostCmConfig[$checkMap[$name]]
        }
    }
    $txtDrv = $Page.FindName('txtDriverCategories')
    if ($txtDrv) { $txtDrv.Text = [string]$script:PostCmConfig['Drivers_Csv'] }
    $txtAp  = $Page.FindName('txtAppPackagerRoot')
    if ($txtAp) { $txtAp.Text = [string]$script:PostCmConfig['AppPackager_Root'] }

    $btnBack = $Page.FindName('btnPostCmBack')
    $btnNext = $Page.FindName('btnPostCmNext')
    if ($btnBack) {
        $btnBack.Add_Click({
            Capture-PostCmFromPage
            Load-Page -Name 'Topology' -Title 'Topology' -Subtitle 'Per-VM CPU / memory / role assignment'
        })
    }
    if ($btnNext) {
        $btnNext.Add_Click({
            Capture-PostCmFromPage
            Load-Page -Name 'Review' -Title 'Review' -Subtitle 'Resolved config + deploy plan'
        })
    }
}

function Capture-PostCmFromPage {
    $cm = $script:CurrentPage
    if (-not $cm) { return }
    foreach ($name in $script:PostCmCheckMap.Keys) {
        $cb = $cm.FindName($name)
        if ($cb) {
            $script:PostCmConfig[$script:PostCmCheckMap[$name]] = [bool]$cb.IsChecked
        }
    }
    $td = $cm.FindName('txtDriverCategories')
    if ($td) { $script:PostCmConfig['Drivers_Csv'] = [string]$td.Text }
    $ta = $cm.FindName('txtAppPackagerRoot')
    if ($ta) { $script:PostCmConfig['AppPackager_Root'] = [string]$ta.Text }
    $colls = @('Coll_AllWorkstations','Coll_AllServers','Coll_TestDirect') | Where-Object { $script:PostCmConfig[$_] }
    $mws   = @('MW_PatchSaturday','MW_TestDaily') | Where-Object { $script:PostCmConfig[$_] }
    $osd   = @('Osd_BootImage','Osd_TaskSequenceStub') | Where-Object { $script:PostCmConfig[$_] }
    Add-LogLine ('Post-CM captured: collections={0} mws={1} osd={2}' -f $colls.Count, $mws.Count, $osd.Count)
}

function Wire-ReviewPage {
    param([System.Windows.Controls.UserControl]$Page)
    $cfg = if ($script:CurrentConfig) { $script:CurrentConfig } else { Load-CurrentConfig }

    # Single format string for every label : value line. Width 11 covers
    # the longest label ("Collections" / "App import") so colons align in
    # both sections without per-line space-counting.
    $fmt = '{0,-11} : {1}'

    $txtTopo = $Page.FindName('txtReviewTopology')
    if ($txtTopo -and $cfg) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine(($fmt -f 'Template', $script:SelectedTemplate))
        [void]$sb.AppendLine(($fmt -f 'Domain',   $cfg.DomainName))
        [void]$sb.AppendLine(($fmt -f 'Site',     ("{0} ({1})" -f $cfg.SiteCode, $cfg.SiteName)))
        [void]$sb.AppendLine(($fmt -f 'Network',  ("{0}.0/24" -f $cfg.Network)))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('VMs:')
        foreach ($vm in $cfg.VMs) {
            [void]$sb.AppendLine(("  {0,-10} {1,-15} cpu={2} mem={3:F0}GB roles={4}" -f $vm.Name, $vm.IP, $vm.Processors, ($vm.Memory / 1GB), (@($vm.Roles) -join ',')))
        }
        $txtTopo.Text = $sb.ToString().TrimEnd()
    }

    $txtPost = $Page.FindName('txtReviewPostCm')
    if ($txtPost) {
        $sb2 = [System.Text.StringBuilder]::new()

        $colls = @()
        if ($script:PostCmConfig['Coll_AllWorkstations']) { $colls += 'All Workstations' }
        if ($script:PostCmConfig['Coll_AllServers'])      { $colls += 'All Servers' }
        if ($script:PostCmConfig['Coll_TestDirect'])      { $colls += 'HomeLab - Test Deployments' }
        $collsText = if ($colls.Count) { $colls -join ', ' } else { '(none)' }
        [void]$sb2.AppendLine(($fmt -f 'Collections', $collsText))

        $mws = @()
        if ($script:PostCmConfig['MW_PatchSaturday']) { $mws += 'Patch Saturday 02:00-06:00' }
        if ($script:PostCmConfig['MW_TestDaily'])     { $mws += 'Daily 00:00-06:00 (test)' }
        $mwsText = if ($mws.Count) { $mws -join ', ' } else { '(none)' }
        [void]$sb2.AppendLine(($fmt -f 'MWs', $mwsText))

        $osd = @()
        if ($script:PostCmConfig['Osd_BootImage'])         { $osd += 'WinPE boot image' }
        if ($script:PostCmConfig['Osd_TaskSequenceStub'])  { $osd += "'Build Win11' TS stub" }
        $osdText = if ($osd.Count) { $osd -join ', ' } else { '(none)' }
        [void]$sb2.AppendLine(($fmt -f 'OSD', $osdText))

        $drv = [string]$script:PostCmConfig['Drivers_Csv']
        $drvText = if ($drv) { $drv } else { '(none)' }
        [void]$sb2.AppendLine(($fmt -f 'Drivers', $drvText))

        $ap = [string]$script:PostCmConfig['AppPackager_Root']
        $apText = if ($ap) { $ap } else { '(none)' }
        [void]$sb2.AppendLine(($fmt -f 'App import', $apText))

        $txtPost.Text = $sb2.ToString().TrimEnd()
    }
    $btnBack   = $Page.FindName('btnReviewBack')
    $btnDeploy = $Page.FindName('btnReviewDeploy')
    if ($btnBack) {
        $btnBack.Add_Click({
            Load-Page -Name 'PostCm' -Title 'Post-CM' -Subtitle 'Collections, deployments, MWs, driver categories'
        })
    }
    if ($btnDeploy) {
        $btnDeploy.Add_Click({
            Load-Page -Name 'Deploy' -Title 'Deploy' -Subtitle 'Live deploy view'
        })
    }
}

$script:DeployPhases = @(
    '01-Prereq', '02-Network', '03-Image', '04-VM', '05-Domain',
    '07-CMPrereqs', '06-Sql', '08-CM', '09-CMConfig', '10-Tools',
    '11-PostCM'
)
$script:DeployRunspace = $null
$script:DeployPS       = $null
$script:DeployTimer    = $null
$script:DeployHandle   = $null
$script:DeployState    = $null

function Initialize-DeployRunspace {
    if ($script:DeployRunspace -and $script:DeployRunspace.RunspaceStateInfo.State -eq 'Opened') { return }
    $script:DeployRunspace = [runspacefactory]::CreateRunspace()
    $script:DeployRunspace.ApartmentState = 'STA'
    $script:DeployRunspace.ThreadOptions  = 'ReuseThread'
    $script:DeployRunspace.Open()
}

function Register-DeployStreamHandlers {
    param(
        [Parameter(Mandatory)]
        [powershell]$PowerShell,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string[]]$Phases
    )

    $infoState = $State
    $infoPhases = $Phases
    $null = $PowerShell.Streams.Information.add_DataAdded({
        param($sender, $eventArgs)
        try {
            $record = $sender[$eventArgs.Index]
            $text = [string]$record.MessageData
            if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$record }
            $text = $text.Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return }

            [void]$infoState.Lines.Add(('{0:HH:mm:ss}  [INFO ] {1}' -f (Get-Date), $text))
            if ($text -match 'Phase\s+([0-9]{2}-[A-Za-z0-9]+)') {
                $phase = $matches[1]
                $idx = [array]::IndexOf($infoPhases, $phase)
                if ($idx -ge 0) {
                    $infoState.PhaseIndex = $idx
                    $infoState.Step = ('Phase {0}' -f $phase)
                }
            }
        } catch { }
    }.GetNewClosure())

    $verboseState = $State
    $null = $PowerShell.Streams.Verbose.add_DataAdded({
        param($sender, $eventArgs)
        try {
            $record = $sender[$eventArgs.Index]
            $text = [string]$record.Message
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                [void]$verboseState.Lines.Add(('{0:HH:mm:ss}  [VERB ] {1}' -f (Get-Date), $text.Trim()))
            }
        } catch { }
    }.GetNewClosure())

    $errorState = $State
    $null = $PowerShell.Streams.Error.add_DataAdded({
        param($sender, $eventArgs)
        try {
            $record = $sender[$eventArgs.Index]
            $text = [string]$record.Exception.Message
            if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$record }
            [void]$errorState.Lines.Add(('{0:HH:mm:ss}  [ERROR] {1}' -f (Get-Date), $text.Trim()))
            if (-not $errorState.ErrorMsg) { $errorState.ErrorMsg = $text.Trim() }
        } catch { }
    }.GetNewClosure())
}

function Wire-DeployPage {
    param([System.Windows.Controls.UserControl]$Page)

    # Reset visual state on every page load.
    $lb = $Page.FindName('lbPhases')
    if ($lb) {
        $lb.Items.Clear()
        foreach ($p in $script:DeployPhases) {
            [void]$lb.Items.Add(("{0,-15} - waiting" -f $p))
        }
    }
    $pb = $Page.FindName('pbDeploy')
    if ($pb) { $pb.Value = 0 }
    $ring = $Page.FindName('ringDeploy')
    if ($ring) { $ring.IsActive = $false }
    $txtStatus = $Page.FindName('txtDeployStatus')
    $txtStep   = $Page.FindName('txtDeployStep')
    if ($txtStatus) { $txtStatus.Text = 'Ready to deploy.' }
    if ($txtStep)   { $txtStep.Text   = 'No phase active.' }

    $btnStart  = $Page.FindName('btnDeployStart')
    $btnCancel = $Page.FindName('btnDeployCancel')

    if ($btnStart) {
        $btnStart.Add_Click({
            try {
                $page = $script:CurrentPage
                if (-not $page) { return }

                $templatePath = Resolve-TemplatePath -Template $script:SelectedTemplate
                if (-not $templatePath -or -not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
                    $msg = "Config not found: $templatePath"
                    Add-LogLine $msg 'ERROR'
                    $page.FindName('txtDeployStatus').Text = $msg
                    [void](Show-ThemedMessage -Owner $window -Title 'Deploy blocked' -Message $msg -Buttons OK)
                    return
                }

                if (-not (Test-GuiIsElevated)) {
                    $msg = 'Install-HomeLab requires an elevated process because Hyper-V cmdlets need admin rights. Relaunch the GUI elevated, then start deploy again.'
                    Add-LogLine $msg 'ERROR'
                    $page.FindName('txtDeployStatus').Text = 'Deploy blocked: not elevated.'
                    [void](Show-ThemedMessage -Owner $window -Title 'Deploy blocked' -Message $msg -Buttons OK)
                    return
                }

                $answer = Show-ThemedMessage -Owner $window -Title 'Confirm deploy' `
                    -Message "This will create or change lab VHDX files and Hyper-V VMs for the selected template. Continue?" `
                    -Buttons YesNo
                if ($answer -ne 'Yes') {
                    Add-LogLine 'Deploy cancelled before start.' 'WARN'
                    return
                }

                Add-LogLine ("Deploy started: config={0}" -f $templatePath)

                # Cancel any in-flight pump.
                if ($script:DeployTimer) { try { $script:DeployTimer.Stop() } catch { $null = $_ } }
                if ($script:DeployPS) {
                    try { [void]$script:DeployPS.Stop() } catch { $null = $_ }
                    try { $script:DeployPS.Dispose() }   catch { $null = $_ }
                    $script:DeployPS = $null
                }

                Initialize-DeployRunspace

                # Synchronized hashtable bridges runspace -> UI thread.
                $script:DeployState = [hashtable]::Synchronized(@{
                    Step       = 'Starting...'
                    PhaseIndex = -1
                    PhaseTotal = $script:DeployPhases.Count
                    Done       = $false
                    ErrorMsg   = $null
                    Lines      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
                })

                # Show overlay.
                $page.FindName('btnDeployStart').IsEnabled  = $false
                $page.FindName('btnDeployCancel').IsEnabled = $true
                $page.FindName('ringDeploy').IsActive       = $true
                $page.FindName('txtDeployStatus').Text      = 'Deploying...'
                $page.FindName('txtDeployStep').Text        = 'Starting...'

                $modulePath = $script:Module
                $postCm = Copy-PostCmConfig

                # Pull Paths settings into a flat hashtable the runspace
                # can splat into Install-HomeLab.
                $deploySettings = @{
                    LabSourcesRoot   = [string]$script:GuiSettings.Paths.LabSourcesRoot
                    LabImagePath     = [string]$script:GuiSettings.Paths.LabImagePath
                    ParallelThrottle = [int]$script:GuiSettings.Paths.ParallelThrottle
                    LabPassword      = $null
                }

                # Lab password resolution. Built-in templates ship without
                # plaintext passwords, and the deploy runspace has no
                # interactive host -- Install-HomeLab's Read-Host fallback
                # throws "lab password is required" there. Resolve a
                # password on the UI side instead, but only when the
                # selected config does not carry its own AdminPass and
                # $env:HOMELAB_PASSWORD is not set (both of which the
                # engine already honors). Fallback is the published
                # default lab password (same one config.psd1 ships).
                $cfgHasPass = $false
                try {
                    $cfgRaw = Import-PowerShellDataFile -LiteralPath $templatePath
                    $cfgHasPass = -not [string]::IsNullOrEmpty([string]$cfgRaw['AdminPass'])
                } catch {
                    # Unreadable config: let Install-HomeLab produce its
                    # own (actionable) config error.
                    $null = $_
                }
                if (-not $cfgHasPass -and -not $env:HOMELAB_PASSWORD) {
                    Add-LogLine 'No password in config and HOMELAB_PASSWORD not set; using the published default lab password.' 'WARN'
                    $deploySettings.LabPassword = ConvertTo-SecureString -String 'P@ssw0rd!' -AsPlainText -Force
                }

                $script:DeployPS = [powershell]::Create()
                $script:DeployPS.Runspace = $script:DeployRunspace
                Register-DeployStreamHandlers -PowerShell $script:DeployPS -State $script:DeployState -Phases $script:DeployPhases
                [void]$script:DeployPS.AddScript({
                    param($ModulePath, $ConfigPath, $PostCmConfig, $Settings, $State)
                    try {
                        $InformationPreference = 'Continue'
                        $VerbosePreference = 'Continue'
                        # Defensive: unload AutomatedLab + SHiPS if a user
                        # has them installed for unrelated reasons. Both
                        # hook the same Hyper-V / PSGallery surfaces this
                        # engine drives and will collide. Strip any
                        # AutomatedLab path from PSModulePath so auto-load
                        # cannot drag it back in. Platform modules
                        # (CimCmdlets, Hyper-V, Storage, NetTCPIP, Dism,
                        # ScheduledTasks) are kept; the engine relies on
                        # them.
                        Get-Module AutomatedLab,SHiPS -ErrorAction SilentlyContinue |
                            Remove-Module -Force -ErrorAction SilentlyContinue
                        $env:PSModulePath = (
                            ($env:PSModulePath -split [IO.Path]::PathSeparator) |
                                Where-Object { $_ -and $_ -notmatch 'AutomatedLab' }
                        ) -join [IO.Path]::PathSeparator
                        $State.Step = 'Importing HomeLab module...'
                        Import-Module $ModulePath -Force -ErrorAction Stop

                        $State.Step = 'Running Install-HomeLab...'
                        $params = @{
                            ConfigPath         = $ConfigPath
                            PostCmConfig       = $PostCmConfig
                            LabSourcesRoot     = $Settings.LabSourcesRoot
                            LabImagePath       = $Settings.LabImagePath
                            ParallelThrottle   = $Settings.ParallelThrottle
                            ErrorAction        = 'Stop'
                            InformationAction  = 'Continue'
                        }
                        if ($Settings.LabPassword) {
                            $params.LabPassword = $Settings.LabPassword
                        }
                        [void](Install-HomeLab @params)
                        $State.PhaseIndex = $State.PhaseTotal
                    } catch {
                        $State.ErrorMsg = '{0} :: {1}' -f $_.Exception.Message, $_.ScriptStackTrace
                    } finally {
                        $State.Done = $true
                    }
                }).AddArgument($modulePath).AddArgument($templatePath).AddArgument($postCm).AddArgument($deploySettings).AddArgument($script:DeployState)

                $script:DeployHandle = $script:DeployPS.BeginInvoke()

                # DispatcherTimer pumps state into the UI 10x/sec.
                $script:DeployTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:DeployTimer.Interval = [TimeSpan]::FromMilliseconds(100)
                $script:DeployTimer.Add_Tick({
                    $st = $script:DeployState
                    if (-not $st) { return }
                    $page = $script:CurrentPage
                    if (-not $page) { return }

                    $stepCtl = $page.FindName('txtDeployStep')
                    if ($stepCtl -and $stepCtl.Text -ne $st.Step) { $stepCtl.Text = $st.Step }

                    $pbCtl = $page.FindName('pbDeploy')
                    if ($pbCtl -and $st.PhaseTotal -gt 0) {
                        $idx = [Math]::Max(0, $st.PhaseIndex)
                        $pct = [int](100.0 * $idx / $st.PhaseTotal)
                        if ($pbCtl.Value -ne $pct) { $pbCtl.Value = $pct }
                    }

                    $lbCtl = $page.FindName('lbPhases')
                    if ($lbCtl) {
                        for ($i = 0; $i -lt $script:DeployPhases.Count; $i++) {
                            $tag = if ($i -lt $st.PhaseIndex) { 'done' }
                                   elseif ($i -eq $st.PhaseIndex) { 'running' }
                                   else { 'waiting' }
                            $expected = ('{0,-15} - {1}' -f $script:DeployPhases[$i], $tag)
                            if ([string]$lbCtl.Items[$i] -ne $expected) { $lbCtl.Items[$i] = $expected }
                        }
                    }

                    # Drain log lines from the runspace.
                    while ($st.Lines.Count -gt 0) {
                        $line = [string]$st.Lines[0]
                        $st.Lines.RemoveAt(0)
                        if ($script:txtLog) {
                            $script:txtLog.AppendText($line + [Environment]::NewLine)
                            $script:txtLog.ScrollToEnd()
                        }
                        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
                    }

                    if ($st.Done) {
                        $script:DeployTimer.Stop()
                        try { [void]$script:DeployPS.EndInvoke($script:DeployHandle) } catch { $null = $_ }
                        try { $script:DeployPS.Dispose() } catch { $null = $_ }
                        $script:DeployPS = $null

                        $page.FindName('ringDeploy').IsActive       = $false
                        $page.FindName('btnDeployStart').IsEnabled  = $true
                        $page.FindName('btnDeployCancel').IsEnabled = $false

                        if ($st.ErrorMsg) {
                            $page.FindName('txtDeployStatus').Text = ('Failed: {0}' -f $st.ErrorMsg)
                            Add-LogLine ('Deploy ended: {0}' -f $st.ErrorMsg) 'ERROR'
                        } else {
                            $page.FindName('txtDeployStatus').Text = 'Deploy complete.'
                            $page.FindName('txtDeployStep').Text   = ('All {0} phases done.' -f $script:DeployPhases.Count)
                            Add-LogLine 'Deploy ended: complete.'
                        }
                    }
                })
                $script:DeployTimer.Start()
            } catch {
                Add-LogLine ("Start deploy handler error: {0}" -f $_.Exception.Message) 'ERROR'
                Add-LogLine ("Position: {0}" -f $_.InvocationInfo.PositionMessage) 'ERROR'
                Add-LogLine ("Stack: {0}" -f $_.ScriptStackTrace) 'ERROR'
            }
        })
    }

    if ($btnCancel) {
        $btnCancel.Add_Click({
            if ($script:DeployState) {
                $script:DeployState.ErrorMsg = 'Cancelled'
                $script:DeployState.Done = $true
                Add-LogLine 'Deploy cancel requested.' 'WARN'
            }
            if ($script:DeployPS) {
                try { [void]$script:DeployPS.Stop() } catch { $null = $_ }
            }
        })
    }
}

function Set-ComboBoxByContent {
    param([System.Windows.Controls.ComboBox]$Combo, [string]$Content)
    if (-not $Combo) { return }
    foreach ($item in $Combo.Items) {
        if ([string]$item.Content -eq $Content) {
            $Combo.SelectedItem = $item
            return
        }
    }
}

function Start-ShellTarget {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [string]$Arguments
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.UseShellExecute = $true
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $psi.Arguments = $Arguments
    }
    [void][System.Diagnostics.Process]::Start($psi)
}

function Open-ExternalUri {
    param([Parameter(Mandatory)][uri]$Uri)

    try {
        Start-ShellTarget -FileName $Uri.AbsoluteUri
        return $true
    } catch {
        Add-LogLine ("Open URL failed: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Open-SettingsFileLocation {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Start-ShellTarget -FileName 'explorer.exe' -Arguments ('/select,"{0}"' -f $Path)
            return $true
        }

        $parent = Split-Path -Parent $Path
        if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
            Start-ShellTarget -FileName 'explorer.exe' -Arguments ('"{0}"' -f $parent)
            return $true
        }

        Add-LogLine 'Settings file does not exist yet (parent folder also missing). Save a setting to create it.' 'WARN'
        return $false
    } catch {
        Add-LogLine ("Open settings location failed: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Wire-OptionsPage {
    param([System.Windows.Controls.UserControl]$Page)

    $script:OptionsPanels = [ordered]@{
        'Paths'    = $Page.FindName('pnlOptionsPaths')
        'Logging'  = $Page.FindName('pnlOptionsLogging')
        'Defaults' = $Page.FindName('pnlOptionsDefaults')
        'About'    = $Page.FindName('pnlOptionsAbout')
    }

    # ─── Paths panel ───────────────────────────────────────────────
    $txtSrc = $Page.FindName('txtLabSourcesRoot')
    if ($txtSrc) {
        $txtSrc.Text = [string]$script:GuiSettings.Paths.LabSourcesRoot
        $txtSrc.Add_LostFocus({
            param($s, $e)
            $script:GuiSettings.Paths.LabSourcesRoot = [string]$s.Text.Trim()
            Save-HomeLabGuiSettings
        })
    }
    $txtImg = $Page.FindName('txtLabImagePath')
    if ($txtImg) {
        $txtImg.Text = [string]$script:GuiSettings.Paths.LabImagePath
        $txtImg.Add_LostFocus({
            param($s, $e)
            $script:GuiSettings.Paths.LabImagePath = [string]$s.Text.Trim()
            Save-HomeLabGuiSettings
        })
    }
    $txtThr = $Page.FindName('txtParallelThrottle')
    if ($txtThr) {
        $txtThr.Text = [string]$script:GuiSettings.Paths.ParallelThrottle
        $txtThr.Add_LostFocus({
            param($s, $e)
            [int]$n = 0
            if ([int]::TryParse([string]$s.Text, [ref]$n) -and $n -ge 1 -and $n -le 16) {
                $script:GuiSettings.Paths.ParallelThrottle = $n
            } else {
                $n = [int]$script:GuiSettings.Paths.ParallelThrottle
                if ($n -lt 1 -or $n -gt 16) { $n = 3 }
                $script:GuiSettings.Paths.ParallelThrottle = $n
                $s.Text = [string]$n
            }
            Save-HomeLabGuiSettings
        })
    }

    $btnSrc = $Page.FindName('btnBrowseLabSources')
    if ($btnSrc -and $txtSrc) {
        $btnSrc.Add_Click({
            $picked = Show-FolderPicker -InitialPath $txtSrc.Text -Description 'Select LabSourcesRoot folder'
            if ($picked) {
                $txtSrc.Text = $picked
                $script:GuiSettings.Paths.LabSourcesRoot = $picked
                Save-HomeLabGuiSettings
            }
        })
    }
    $btnImg = $Page.FindName('btnBrowseLabImages')
    if ($btnImg -and $txtImg) {
        $btnImg.Add_Click({
            $picked = Show-FolderPicker -InitialPath $txtImg.Text -Description 'Select LabImagePath folder'
            if ($picked) {
                $txtImg.Text = $picked
                $script:GuiSettings.Paths.LabImagePath = $picked
                Save-HomeLabGuiSettings
            }
        })
    }

    # ─── Logging panel ─────────────────────────────────────────────
    $cmbVerb = $Page.FindName('cmbLogVerbosity')
    if ($cmbVerb) {
        Set-ComboBoxByContent -Combo $cmbVerb -Content ([string]$script:GuiSettings.Logging.Verbosity)
        $cmbVerb.Add_SelectionChanged({
            param($s, $e)
            if ($s.SelectedItem) {
                $script:GuiSettings.Logging.Verbosity = [string]$s.SelectedItem.Content
                Save-HomeLabGuiSettings
            }
        })
    }
    $chkTs = $Page.FindName('chkShowTimestamps')
    if ($chkTs) {
        $chkTs.IsChecked = [bool]$script:GuiSettings.Logging.ShowTimestamps
        $tsHandler = {
            param($s, $e)
            $script:GuiSettings.Logging.ShowTimestamps = [bool]$s.IsChecked
            Save-HomeLabGuiSettings
        }
        $chkTs.Add_Checked($tsHandler)
        $chkTs.Add_Unchecked($tsHandler)
    }
    $txtLogGui = $Page.FindName('txtLogGui')
    if ($txtLogGui -and $script:LogFile) { $txtLogGui.Text = [string]$script:LogFile }

    # ─── Defaults panel ────────────────────────────────────────────
    # Maps the Defaults-panel checkbox names to PostCm setting keys.
    $defChkMap = [ordered]@{
        chkDefCollWorkstations = 'Coll_AllWorkstations'
        chkDefCollServers      = 'Coll_AllServers'
        chkDefCollTestDirect   = 'Coll_TestDirect'
        chkDefMwSaturday       = 'MW_PatchSaturday'
        chkDefMwTestDaily      = 'MW_TestDaily'
        chkDefOsdBoot          = 'Osd_BootImage'
        chkDefOsdTs            = 'Osd_TaskSequenceStub'
    }
    foreach ($name in $defChkMap.Keys) {
        $cb = $Page.FindName($name)
        if (-not $cb) { continue }
        $key = $defChkMap[$name]
        $cb.IsChecked = [bool]$script:GuiSettings.Defaults.PostCm.$key
        $cb.Tag = $key
        $cbHandler = {
            param($s, $e)
            $k = [string]$s.Tag
            if ($k) {
                $script:GuiSettings.Defaults.PostCm.$k = [bool]$s.IsChecked
                Save-HomeLabGuiSettings
            }
        }
        $cb.Add_Checked($cbHandler)
        $cb.Add_Unchecked($cbHandler)
    }

    # ─── About panel ───────────────────────────────────────────────
    # Use link-styled Buttons instead of WPF Hyperlink. Buttons keep
    # keyboard activation and avoid the navigation command plumbing that
    # can perturb MahApps' custom chrome when loaded from PowerShell.
    $btnGitHub = $Page.FindName('btnGitHub')
    if ($btnGitHub) {
        $btnGitHub.Add_Click({
            [void](Open-ExternalUri -Uri 'https://github.com/jasonulbright/mecm-homelab')
        })
    }

    $txtSettingsPath = $Page.FindName('txtAboutSettingsPath')
    if ($txtSettingsPath) {
        $txtSettingsPath.Text = [string]$script:SettingsFile
    }

    $btnSettings = $Page.FindName('btnAboutSettingsPath')
    if ($btnSettings) {
        $btnSettings.Add_Click({
            [void](Open-SettingsFileLocation -Path $script:SettingsFile)
        })
    }

    # ─── Category selector ────────────────────────────────────────
    $lb = $Page.FindName('lbOptionsCategories')
    if (-not $lb) { return }
    $lb.Add_SelectionChanged({
        param($s, $e)
        $sel = $s.SelectedItem
        if (-not $sel) { return }
        $name = [string]$sel.Content
        foreach ($k in $script:OptionsPanels.Keys) {
            $p = $script:OptionsPanels[$k]
            if (-not $p) { continue }
            $p.Visibility = if ($k -eq $name) {
                [System.Windows.Visibility]::Visible
            } else {
                [System.Windows.Visibility]::Collapsed
            }
        }
    })
}

function Show-FolderPicker {
    param([string]$InitialPath, [string]$Description = 'Select folder')
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $Description
        if ($InitialPath -and (Test-Path -LiteralPath $InitialPath)) {
            $dlg.SelectedPath = $InitialPath
        }
        $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dlg.SelectedPath
        }
    } catch {
        Add-LogLine ("Folder picker failed: {0}" -f $_.Exception.Message) 'WARN'
    }
    return $null
}

# Wire workflow buttons. Each maps to a wizard step; S21+ replaces
# the placeholder Load-Page calls with real page logic + engine
# bindings.
$window.FindName('btnWelcome').Add_Click(  { Load-Page -Name 'Welcome'   -Title 'Welcome'      -Subtitle 'Start here' })
$window.FindName('btnTemplate').Add_Click( { Load-Page -Name 'Template'  -Title 'Pick template' -Subtitle 'Choose a built-in topology or load a custom config.psd1' })
$window.FindName('btnHostCheck').Add_Click({ Load-Page -Name 'HostCheck' -Title 'Host check'   -Subtitle 'Hyper-V, RAM, free disk, virt extensions, ISO catalog' })
$window.FindName('btnTopology').Add_Click( { Load-Page -Name 'Topology'  -Title 'Topology'     -Subtitle 'Per-VM CPU / memory / role assignment' })
$window.FindName('btnPostCm').Add_Click(   { Load-Page -Name 'PostCm'    -Title 'Post-CM'      -Subtitle 'Collections, deployments, MWs, driver categories' })
$window.FindName('btnReview').Add_Click(   { Load-Page -Name 'Review'    -Title 'Review'       -Subtitle 'Resolved config + deploy plan' })
$window.FindName('btnDeploy').Add_Click(   { Load-Page -Name 'Deploy'    -Title 'Deploy'       -Subtitle 'Live deploy view' })
$window.FindName('btnOptions').Add_Click(  { Load-Page -Name 'Options'   -Title 'Options'      -Subtitle 'Settings, paths, logging' })

$script:tglTheme.Add_Toggled({
    Apply-Theme -IsDark $script:tglTheme.IsOn
})

# Initial state: Dark.Steel theme + Welcome page. Theme is per-session
# (sidebar toggle); Dark.Steel matches the brand-default starting state.
Apply-Theme -IsDark $true
Load-Page -Name 'Welcome' -Title 'Welcome' -Subtitle 'MECM HomeLab GUI'
Add-LogLine ('GUI started; logs at {0}' -f $script:LogFile)
Add-LogLine ('Settings loaded from {0}' -f $script:SettingsFile)

$window.Add_Closing({
    if ($script:HostCheckTimer) { try { $script:HostCheckTimer.Stop() } catch { $null = $_ } }
    if ($script:HostCheckPS) {
        try { [void]$script:HostCheckPS.Stop() } catch { $null = $_ }
        try { $script:HostCheckPS.Dispose() }   catch { $null = $_ }
    }
    if ($script:HostCheckRunspace) {
        try { $script:HostCheckRunspace.Close()   } catch { $null = $_ }
        try { $script:HostCheckRunspace.Dispose() } catch { $null = $_ }
    }
    if ($script:DeployTimer) { try { $script:DeployTimer.Stop() } catch { $null = $_ } }
    if ($script:DeployPS) {
        try { [void]$script:DeployPS.Stop() } catch { $null = $_ }
        try { $script:DeployPS.Dispose() }   catch { $null = $_ }
    }
    if ($script:DeployRunspace) {
        try { $script:DeployRunspace.Close()   } catch { $null = $_ }
        try { $script:DeployRunspace.Dispose() } catch { $null = $_ }
    }
})

# Show.
$null = $window.ShowDialog()
