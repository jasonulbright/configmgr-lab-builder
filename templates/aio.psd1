@{
    # 1-VM all-in-one topology.
    #
    # LAB01    DomainController + CertificateAuthority + SqlServer +
    #          SiteServer + ManagementPoint + DistributionPoint +
    #          SoftwareUpdatePoint
    # CLIENT01 Client
    #
    # Footprint reference. Microsoft's CM 2509 setup.exe rejects
    # installation when the target server is a domain controller, so
    # this template DOES NOT produce a working install with the
    # current engine -- setup.exe will fail with a CRITICAL prereq
    # error during Phase 08-CM. The template is shipped as a
    # documented design intent, not a working blueprint.
    #
    # For the smallest WORKING lab use 'default.psd1' (3 VMs:
    # DC01 + CM01 + CLIENT01).

    LabName        = 'HomeLab-AIO'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Home Lab AIO Primary'
    Network        = '192.168.50'

    AdminUser      = 'LabAdmin'

    ServerOSFilter = 'Windows Server 2025*Desktop Experience*'
    ClientOSFilter = 'Windows 11*Enterprise*'

    AutoStartAction = 'Start'
    AutoStopAction  = 'ShutDown'

    VMs = @(
        @{
            Name           = 'LAB01'
            Roles          = @('DomainController','CertificateAuthority','SqlServer','SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint')
            IP             = '192.168.50.10'
            Memory         = 16GB
            MinMemory      = 8GB
            MaxMemory      = 16GB
            Processors     = 4
            OSDiskSize     = 200
            AutoStartDelay = 30
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
