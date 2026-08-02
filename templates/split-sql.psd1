@{
    # 4-VM split-SQL topology.
    #
    # DC01     DomainController + CertificateAuthority
    # SQL01    SqlServer (dedicated)
    # CM01     SiteServer + ManagementPoint + DistributionPoint + SoftwareUpdatePoint
    # CLIENT01 Client
    #
    # SQL on a separate VM mirrors enterprise tier-2 layouts where
    # a SQL DBA team owns the database server and CM admins consume
    # it. Install-CMSite passes -SqlServerFqdn so the unattend INI
    # points the site database at SQL01.contoso.com.

    LabName        = 'HomeLab-SplitSql'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Home Lab Split-SQL Primary'
    Network        = '192.168.50'

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
            Name           = 'SQL01'
            Roles          = @('SqlServer')
            IP             = '192.168.50.15'
            Memory         = 8GB
            MinMemory      = 4GB
            MaxMemory      = 8GB
            Processors     = 4
            OSDiskSize     = 150
            AutoStartDelay = 60
        }
        @{
            Name           = 'CM01'
            Roles          = @('SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint')
            IP             = '192.168.50.20'
            Memory         = 8GB
            MinMemory      = 4GB
            MaxMemory      = 8GB
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

    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'  ; Desc='ConfigMgr Client Push'   ; Group='Domain Admins' }
        NAA        = @{ Name='svc-CMNAA'   ; Desc='ConfigMgr NAA'           ; Group=$null }
        Join       = @{ Name='svc-CMJoin' ; Desc='ConfigMgr OSD task sequence domain-join account' ; Group='Domain Admins' }
    }

    ODBCVersion    = '18.5.2.1'
    ODBCURL        = 'https://go.microsoft.com/fwlink/?linkid=2335671'
    VCRedistX64URL = 'https://aka.ms/vs/18/release/vc_redist.x64.exe'
    VCRedistX86URL = 'https://aka.ms/vs/18/release/vc_redist.x86.exe'
    SQLCollation   = 'SQL_Latin1_General_CP1_CI_AS'
}
