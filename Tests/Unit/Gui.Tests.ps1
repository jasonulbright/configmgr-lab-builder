#requires -Module Pester
<#
.SYNOPSIS
    Smoke tests for the S20 GUI scaffold. Verifies MainWindow.xaml
    parses through XamlReader and that the named controls the entry
    script depends on resolve correctly. Live UI behaviour (theme
    swap, sidebar wiring, runspace pump) is exercised manually + by
    autotest.
#>

BeforeAll {
    $script:repoRoot = Resolve-Path "$PSScriptRoot\..\.."
    $script:guiRoot  = Join-Path $script:repoRoot 'gui'
    $script:libDir   = Join-Path $script:guiRoot 'Lib'
    $script:pagesDir = Join-Path $script:guiRoot 'Pages'

    # WPF assemblies + vendored MahApps.
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    foreach ($dll in 'Microsoft.Xaml.Behaviors.dll','ControlzEx.dll','MahApps.Metro.dll') {
        $p = Join-Path $script:libDir $dll
        if (Test-Path $p) {
            Unblock-File -Path $p -ErrorAction SilentlyContinue
            [void][System.Reflection.Assembly]::LoadFrom($p)
        }
    }
}

Describe 'GUI scaffold layout' {

    It 'has the gui/ folder' {
        Test-Path $script:guiRoot | Should -BeTrue
    }

    It 'vendors the three MahApps DLLs in gui/Lib' {
        Test-Path (Join-Path $script:libDir 'MahApps.Metro.dll')         | Should -BeTrue
        Test-Path (Join-Path $script:libDir 'ControlzEx.dll')            | Should -BeTrue
        Test-Path (Join-Path $script:libDir 'Microsoft.Xaml.Behaviors.dll') | Should -BeTrue
    }

    It 'has the entry script' {
        Test-Path (Join-Path $script:guiRoot 'start-homelab-gui.ps1') | Should -BeTrue
    }

    It 'has MainWindow.xaml' {
        Test-Path (Join-Path $script:guiRoot 'MainWindow.xaml') | Should -BeTrue
    }

    It 'has Pages/Welcome.xaml' {
        Test-Path (Join-Path $script:pagesDir 'Welcome.xaml') | Should -BeTrue
    }
}

Describe 'MainWindow.xaml parses through XamlReader' {

    BeforeAll {
        $xamlPath = Join-Path $script:guiRoot 'MainWindow.xaml'
        [xml]$xml = Get-Content -LiteralPath $xamlPath -Raw
        $reader   = New-Object System.Xml.XmlNodeReader $xml
        $script:window = [System.Windows.Markup.XamlReader]::Load($reader)
    }

    It 'returns a MetroWindow' {
        $script:window | Should -Not -BeNullOrEmpty
        $script:window.GetType().FullName | Should -Be 'MahApps.Metro.Controls.MetroWindow'
    }

    It 'exposes every control the entry script binds via FindName' {
        $expected = @(
            'lblLogOutput','txtLog','txtStatus',
            'moduleHost','txtModuleTitle','txtModuleSubtitle',
            'tglTheme','bdModuleBand','bdStatusBar',
            'btnWelcome','btnTemplate','btnHostCheck','btnTopology',
            'btnPostCm','btnReview','btnDeploy','btnOptions'
        )
        foreach ($name in $expected) {
            $script:window.FindName($name) | Should -Not -BeNullOrEmpty `
                -Because "MainWindow.xaml must expose '$name' for start-homelab-gui.ps1 to resolve"
        }
    }

    It 'sets brand-conformant title bar attributes' {
        $script:window.TitleCharacterCasing | Should -Be 'Normal'
        $script:window.ShowIconOnTitleBar    | Should -BeFalse
    }
}

Describe 'Welcome.xaml parses through XamlReader' {

    It 'loads a UserControl' {
        $xamlPath = Join-Path $script:pagesDir 'Welcome.xaml'
        [xml]$xml = Get-Content -LiteralPath $xamlPath -Raw
        $reader   = New-Object System.Xml.XmlNodeReader $xml
        $page     = [System.Windows.Markup.XamlReader]::Load($reader)
        $page | Should -Not -BeNullOrEmpty
        $page.GetType().FullName | Should -Be 'System.Windows.Controls.UserControl'
    }
}

Describe 'S21 wizard pages parse through XamlReader' {

    $cases = @(
        @{ File = 'Template.xaml'  }
        @{ File = 'HostCheck.xaml' }
        @{ File = 'Topology.xaml'  }
        @{ File = 'PostCm.xaml'    }
        @{ File = 'Review.xaml'    }
        @{ File = 'Deploy.xaml'    }
        @{ File = 'Options.xaml'   }
    )

    It '<File> parses cleanly' -ForEach $cases {
        $xamlPath = Join-Path $script:pagesDir $File
        Test-Path $xamlPath | Should -BeTrue
        [xml]$xml = Get-Content -LiteralPath $xamlPath -Raw
        $reader   = New-Object System.Xml.XmlNodeReader $xml
        $page     = [System.Windows.Markup.XamlReader]::Load($reader)
        $page | Should -Not -BeNullOrEmpty
        $page.GetType().FullName | Should -Be 'System.Windows.Controls.UserControl'
    }

    It 'HostCheck and Topology DataGrid styles resolve standalone and hosted' {
        $mainPath = Join-Path $script:guiRoot 'MainWindow.xaml'
        [xml]$mainXml = Get-Content -LiteralPath $mainPath -Raw
        $mainReader = New-Object System.Xml.XmlNodeReader $mainXml
        $window = [System.Windows.Markup.XamlReader]::Load($mainReader)
        $contentHost = $window.FindName('moduleHost')

        foreach ($file in 'HostCheck.xaml','Topology.xaml') {
            $xamlPath = Join-Path $script:pagesDir $file
            [xml]$xml = Get-Content -LiteralPath $xamlPath -Raw
            $reader = New-Object System.Xml.XmlNodeReader $xml
            $page = [System.Windows.Markup.XamlReader]::Load($reader)
            $contentHost.Content = $page
            [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Light.Blue')
            [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($page, 'Light.Blue')

            $gridName = if ($file -eq 'HostCheck.xaml') { 'dgHostCheck' } else { 'dgTopology' }
            $grid = $page.FindName($gridName)
            $grid | Should -Not -BeNullOrEmpty
            $grid.ColumnHeaderStyle | Should -Not -BeNullOrEmpty
            $grid.CellStyle | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Per-page named-control surfaces' {

    It 'Template.xaml exposes radio buttons + Next button' {
        $xamlPath = Join-Path $script:pagesDir 'Template.xaml'
        [xml]$xml = Get-Content -LiteralPath $xamlPath -Raw
        $reader   = New-Object System.Xml.XmlNodeReader $xml
        $page     = [System.Windows.Markup.XamlReader]::Load($reader)
        foreach ($n in 'rbDefault','rbSplitSql','rbRolePerServer','rbAio','rbCas2Dps','rbCasRolePerServer','rbCustom','txtCustomPath','btnBrowseCustom','btnTemplateNext') {
            $page.FindName($n) | Should -Not -BeNullOrEmpty -Because "Template.xaml must expose '$n'"
        }
    }

    It 'HostCheck.xaml exposes Run button + DataGrid + Next' {
        $xamlPath = Join-Path $script:pagesDir 'HostCheck.xaml'
        [xml]$xml = Get-Content -LiteralPath $xamlPath -Raw
        $reader   = New-Object System.Xml.XmlNodeReader $xml
        $page     = [System.Windows.Markup.XamlReader]::Load($reader)
        foreach ($n in 'btnHostCheckRun','txtHostCheckSummary','dgHostCheck','btnHostCheckBack','btnHostCheckNext') {
            $page.FindName($n) | Should -Not -BeNullOrEmpty -Because "HostCheck.xaml must expose '$n'"
        }
    }

    It 'Topology.xaml exposes the DataGrid + Validate / Back / Next' {
        $xamlPath = Join-Path $script:pagesDir 'Topology.xaml'
        [xml]$xml = Get-Content -LiteralPath $xamlPath -Raw
        $reader   = New-Object System.Xml.XmlNodeReader $xml
        $page     = [System.Windows.Markup.XamlReader]::Load($reader)
        foreach ($n in 'dgTopology','btnTopologyValidate','btnTopologyBack','btnTopologyNext') {
            $page.FindName($n) | Should -Not -BeNullOrEmpty -Because "Topology.xaml must expose '$n'"
        }
    }

    It 'Deploy.xaml exposes spinner + phase list + progress bar + buttons' {
        $xamlPath = Join-Path $script:pagesDir 'Deploy.xaml'
        [xml]$xml = Get-Content -LiteralPath $xamlPath -Raw
        $reader   = New-Object System.Xml.XmlNodeReader $xml
        $page     = [System.Windows.Markup.XamlReader]::Load($reader)
        foreach ($n in 'txtDeployStatus','txtDeployStep','ringDeploy','lbPhases','pbDeploy','btnDeployStart','btnDeployCancel') {
            $page.FindName($n) | Should -Not -BeNullOrEmpty -Because "Deploy.xaml must expose '$n'"
        }
    }

    It 'Options.xaml exposes About actions as buttons, not WPF Hyperlinks' {
        $xamlPath = Join-Path $script:pagesDir 'Options.xaml'
        $raw = Get-Content -LiteralPath $xamlPath -Raw
        $raw | Should -Not -Match '<Hyperlink|RequestNavigate|NavigateUri'

        [xml]$xml = $raw
        $reader   = New-Object System.Xml.XmlNodeReader $xml
        $page     = [System.Windows.Markup.XamlReader]::Load($reader)

        $page.FindName('btnGitHub').GetType().FullName | Should -Be 'System.Windows.Controls.Button'
        $page.FindName('btnAboutSettingsPath').GetType().FullName | Should -Be 'System.Windows.Controls.Button'
        $page.FindName('txtAboutSettingsPath').GetType().FullName | Should -Be 'System.Windows.Controls.TextBlock'
    }
}

Describe 'GUI chrome and shell-link regression guards' {

    It 'uses shell-execute helpers instead of WPF navigation handlers' {
        $entryPath = Join-Path $script:guiRoot 'start-homelab-gui.ps1'
        $entry = Get-Content -LiteralPath $entryPath -Raw

        $entry | Should -Match 'function Open-ExternalUri'
        $entry | Should -Match 'function Open-SettingsFileLocation'
        $entry | Should -Match 'UseShellExecute = \$true'
        $entry | Should -Not -Match 'Add_RequestNavigate|RequestNavigate|NavigateUri'
    }

    It 'installs a native title-bar hit-test fallback' {
        $entryPath = Join-Path $script:guiRoot 'start-homelab-gui.ps1'
        $entry = Get-Content -LiteralPath $entryPath -Raw

        $entry | Should -Match 'HwndSourceHook'
        $entry | Should -Match 'WM_NCHITTEST'
        $entry | Should -Match 'HTCAPTION'
        $entry | Should -Not -Match '\[int16\]\('
    }
}
