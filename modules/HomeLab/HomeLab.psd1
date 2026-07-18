@{
    RootModule        = 'HomeLab.psm1'
    ModuleVersion     = '1.3.0'
    # 1.0.0.1: fix non-interactive deploy crash; restore default lab passwords.
    # 1.0.0: initial public release. Native PowerShell + Hyper-V engine.
    GUID              = 'a8f4c2d1-9b6e-4a73-8c5f-2e1d0a7b4e96'
    Author            = 'jasonulbright'
    CompanyName       = 'jasonulbright'
    Copyright         = '(c) jasonulbright. All rights reserved.'
    Description       = 'Native PowerShell + Hyper-V engine for the MECM home lab. Self-contained: no PSGallery dependencies. PowerShell 7.6 LTS (.NET 10) on the host orchestrator; inside-VM Invoke-Command blocks run on whatever shell the target VM has.'
    PowerShellVersion = '7.6'

    # Public surface only. Private functions are dot-sourced but not exported.
    FunctionsToExport = @(
        'Install-HomeLab'
        'Remove-HomeLab'
        'Start-HomeLab'
        'Stop-HomeLab'
        'Test-HomeLab'
        'Connect-HomeLabVM'
        'Enter-HomeLabSession'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('MECM','ConfigMgr','HyperV','Lab','HomeLab')
            ProjectUri   = 'https://github.com/jasonulbright/mecm-homelab'
            ReleaseNotes = 'v1.0.0.1 fixes a non-interactive deploy crash and restores the default lab passwords. See CHANGELOG.md.'
        }
    }
}
