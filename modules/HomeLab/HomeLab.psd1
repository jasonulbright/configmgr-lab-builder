@{
    RootModule        = 'HomeLab.psm1'
    ModuleVersion     = '1.5.1'
    # 1.5.1: automate Fallback Status Point, Service Connection Point, and
    #        Reporting Services Point roles; install + configure SSRS.
    # 1.5.0: Test-LabMedia pre-flight + GUI Media wizard page (staged-media
    #        check, per-item download/open-folder actions, deploy gate).
    # 1.4.1: create the CM prereq download folder when no offline cache is
    #        staged; recognise CM 2509's terminal failure banner.
    # 1.4.0: rebrand to ConfigMgr Lab Builder. Product name only -- the module
    #        name and every exported function are unchanged.
    # 1.0.0.1: fix non-interactive deploy crash; restore default lab passwords.
    # 1.0.0: initial public release. Native PowerShell + Hyper-V engine.
    GUID              = 'a8f4c2d1-9b6e-4a73-8c5f-2e1d0a7b4e96'
    Author            = 'jasonulbright'
    CompanyName       = 'jasonulbright'
    Copyright         = '(c) jasonulbright. All rights reserved.'
    Description       = 'ConfigMgr Lab Builder -- native PowerShell + Hyper-V engine that builds a Microsoft Configuration Manager home lab. Self-contained: no PSGallery dependencies. PowerShell 7.6 LTS (.NET 10) on the host orchestrator; inside-VM Invoke-Command blocks run on whatever shell the target VM has.'
    PowerShellVersion = '7.6'

    # Public surface only. Private functions are dot-sourced but not exported.
    FunctionsToExport = @(
        'Install-HomeLab'
        'Remove-HomeLab'
        'Start-HomeLab'
        'Stop-HomeLab'
        'Test-HomeLab'
        'Test-LabMedia'
        'Connect-HomeLabVM'
        'Enter-HomeLabSession'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('ConfigMgr','ConfigurationManager','SCCM','HyperV','Lab','HomeLab')
            ProjectUri   = 'https://github.com/jasonulbright/configmgr-lab-builder'
            ReleaseNotes = 'v1.5.1 automates the Fallback Status Point, Service Connection Point, and Reporting Services Point, including unattended SSRS installation and configuration plus a dedicated Reporting account. See CHANGELOG.md.'
        }
    }
}
