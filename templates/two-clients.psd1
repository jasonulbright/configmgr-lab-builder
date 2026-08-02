@{
    # 4-VM HomeLab topology: default + a second client.
    #
    # DC01     DomainController + CertificateAuthority
    # CM01     SqlServer + SiteServer + ManagementPoint + DistributionPoint + SoftwareUpdatePoint
    # CLIENT01 Client
    # CLIENT02 Client
    #
    # Two clients make app-deployment testing honest: one machine takes
    # the install while the other stays clean for the uninstall /
    # supersedence / required-vs-available comparisons, instead of
    # living off checkpoints and rollbacks on a single client. (This
    # codifies the hand-built CLIENT02 that existed on the lab host
    # May-July 2026.)

    LabName        = 'HomeLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Home Lab Primary Site'
    Network        = '192.168.50'

    # Lab admin identity. Password is NOT stored here -- supply at deploy
    # time via Install-HomeLab -LabPassword <SecureString>, or accept the
    # interactive Read-Host -AsSecureString prompt. The same password is
    # applied to AdminPass + all ServiceAccounts.*.Password fields below.
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
        # Clients start at 2GB (dynamic 1-4GB), NOT 4GB: total startup
        # demand is what matters on a 32GB host. 2+10+2+2 = 16GB leaves
        # room for the host OS + desktop apps; 2+10+4+4 = 20GB does not
        # -- CLIENT02 failed to start with 0x800705AA "unable to
        # allocate 4096 MB" on the first two-clients deploy (2026-07-17)
        # while a desktop session held the balance. Dynamic memory grows
        # them to 4GB when the guest actually needs it.
        @{
            Name           = 'CLIENT01'
            Roles          = @('Client')
            IP             = '192.168.50.100'
            Memory         = 2GB
            MinMemory      = 1GB
            MaxMemory      = 4GB
            Processors     = 2
            OSDiskSize     = 150
            AutoStartDelay = 180
        }
        @{
            Name           = 'CLIENT02'
            Roles          = @('Client')
            IP             = '192.168.50.101'
            Memory         = 2GB
            MinMemory      = 1GB
            MaxMemory      = 4GB
            Processors     = 2
            OSDiskSize     = 150
            AutoStartDelay = 210
        }
    )

    # Passwords intentionally omitted -- Install-HomeLab fills them from
    # -LabPassword / interactive prompt.
    ServiceAccounts = @{
        ClientPush = @{
            Name     = 'svc-CMPush'
            Desc     = 'ConfigMgr Client Push Installation Account'
            Group    = 'Domain Admins'
        }
        NAA = @{
            Name     = 'svc-CMNAA'
            Desc     = 'ConfigMgr Network Access Account'
            Group    = $null
        }
        Join = @{
            Name     = 'svc-CMJoin'
            Desc     = 'ConfigMgr OSD task sequence domain-join account'
            Group    = 'Domain Admins'
        }
    }

    ODBCVersion    = '18.5.2.1'
    ODBCURL        = 'https://go.microsoft.com/fwlink/?linkid=2335671'
    VCRedistX64URL = 'https://aka.ms/vs/18/release/vc_redist.x64.exe'
    VCRedistX86URL = 'https://aka.ms/vs/18/release/vc_redist.x86.exe'
    SQLCollation   = 'SQL_Latin1_General_CP1_CI_AS'
}
