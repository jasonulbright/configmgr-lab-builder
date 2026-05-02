@{
    # Default 3-VM HomeLab topology.
    #
    # DC01     DomainController + CertificateAuthority
    # CM01     SqlServer + SiteServer + ManagementPoint + DistributionPoint + SoftwareUpdatePoint
    # CLIENT01 Client
    #
    # This is the simplest fully-functional MECM lab. Mirrors the
    # standard DC/CM/Client triple.

    LabName        = 'HomeLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Home Lab Primary Site'
    Network        = '192.168.50'

    # Lab admin identity. Password is NOT stored here -- supply at deploy
    # time via Install-HomeLab -LabPassword <SecureString>, or accept the
    # interactive Read-Host -AsSecureString prompt. The same password is
    # applied to AdminPass + all ServiceAccounts.*.Password fields below.
    #
    # LabAdmin is the orchestrator/admin identity. It runs CM setup and is
    # auto-added to the CM 'Full Administrator' role at install time, so
    # the engine never has to call New-CMAdministrativeUser explicitly.
    AdminUser      = 'LabAdmin'

    ServerOSFilter = 'Windows Server 2025*Desktop Experience*'
    ClientOSFilter = 'Windows 11*Enterprise*'

    AutoStartAction = 'Start'
    AutoStopAction  = 'ShutDown'

    VMs = @(
        @{
            Name           = 'DC01'
            Roles          = @('DomainController','CertificateAuthority')
            IP             = '192.168.50.10'
            Memory         = 2GB
            MinMemory      = 1GB
            MaxMemory      = 2GB
            Processors     = 2
            AutoStartDelay = 30
        }
        @{
            Name           = 'CM01'
            Roles          = @('SqlServer','SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint')
            IP             = '192.168.50.20'
            Memory         = 10GB
            MinMemory      = 4GB
            MaxMemory      = 12GB
            Processors     = 4
            OSDiskSize     = 150
            AutoStartDelay = 90
        }
        @{
            Name           = 'CLIENT01'
            Roles          = @('Client')
            IP             = '192.168.50.100'
            Memory         = 4GB
            MinMemory      = 2GB
            MaxMemory      = 4GB
            Processors     = 2
            OSDiskSize     = 150
            AutoStartDelay = 180
        }
    )

    # Passwords intentionally omitted -- Install-HomeLab fills them from
    # -LabPassword / interactive prompt. Same password used for all four
    # accounts (AdminPass + 3 service accounts) by design (homelab scope).
    #
    # Three functional service accounts; LabAdmin (above) is the
    # orchestrator/admin separately. Each service account has one purpose:
    #   ClientPush  -- CM client push installation
    #   NAA         -- Network Access Account (boot images, content)
    #   Join        -- OSD task sequence domain-join account
    ServiceAccounts = @{
        ClientPush = @{
            Name     = 'svc-CMPush'
            Desc     = 'MECM Client Push Installation Account'
            Group    = 'Domain Admins'
        }
        NAA = @{
            Name     = 'svc-CMNAA'
            Desc     = 'MECM Network Access Account'
            Group    = $null
        }
        Join = @{
            Name     = 'svc-CMJoin'
            Desc     = 'MECM OSD task sequence domain-join account'
            Group    = 'Domain Admins'
        }
    }

    ODBCVersion    = '18.5.2.1'
    ODBCURL        = 'https://go.microsoft.com/fwlink/?linkid=2335671'
    VCRedistX64URL = 'https://aka.ms/vs/18/release/vc_redist.x64.exe'
    VCRedistX86URL = 'https://aka.ms/vs/18/release/vc_redist.x86.exe'
    SQLCollation   = 'SQL_Latin1_General_CP1_CI_AS'
}
