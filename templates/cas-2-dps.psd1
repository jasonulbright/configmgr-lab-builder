@{
    # CAS hierarchy with 2 distribution points (5 VMs).
    #
    # DC01     DomainController + CertificateAuthority
    # CAS01    CentralAdministrationSite + SqlServer  (parent CAS, regional)
    # CM01     SiteServer + ManagementPoint + SoftwareUpdatePoint  (child primary)
    # DP01     DistributionPoint  (region A)
    # DP02     DistributionPoint  (region B)
    # CLIENT01 Client
    #
    # CAS hierarchies mirror multi-region enterprises with a parent
    # CAS that aggregates child primary sites + regional DPs.
    #
    # Engine support (S16):
    #   - The schema accepts CAS topologies (CentralAdministrationSite
    #     is a recognised role; at-most-one validation enforced).
    #   - Install-HomeLab REJECTS this template at orchestrator entry
    #     with a "CAS hierarchy not yet implemented" error.
    #   - The CAS install (parent setup.exe + HierarchyExpansionOption
    #     pointing the child primary at the parent) is deferred to a
    #     future tag with helpers under Private/08-CM/CAS/.
    #
    # This template documents the topology for a future tag; it does
    # not provision a working lab today.

    LabName        = 'HomeLab-CAS-2DPs'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Home Lab CAS Hierarchy'
    Network        = '192.168.50'

    AdminUser      = 'LabAdmin'

    ServerOSFilter = 'Windows Server 2025*Desktop Experience*'
    ClientOSFilter = 'Windows 11*Enterprise*'

    AutoStartAction = 'Start'
    AutoStopAction  = 'ShutDown'

    VMs = @(
        @{ Name='DC01'    ; Roles=@('DomainController','CertificateAuthority') ; IP='192.168.50.10'  ; Memory=2GB  ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=30  }
        @{ Name='CAS01'   ; Roles=@('CentralAdministrationSite','SqlServer')   ; IP='192.168.50.15'  ; Memory=10GB ; MinMemory=4GB ; MaxMemory=12GB ; Processors=4 ; OSDiskSize=150 ; AutoStartDelay=60  }
        @{ Name='CM01'    ; Roles=@('SiteServer','ManagementPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=8GB ; MinMemory=4GB ; MaxMemory=8GB ; Processors=4 ; OSDiskSize=150 ; AutoStartDelay=120 }
        @{ Name='DP01'    ; Roles=@('DistributionPoint')                       ; IP='192.168.50.30'  ; Memory=2GB  ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=150 }
        @{ Name='DP02'    ; Roles=@('DistributionPoint')                       ; IP='192.168.50.31'  ; Memory=2GB  ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=150 }
        @{ Name='CLIENT01'; Roles=@('Client')                                  ; IP='192.168.50.100' ; Memory=4GB  ; MinMemory=2GB ; MaxMemory=4GB  ; Processors=2 ; OSDiskSize=150 ; AutoStartDelay=180 }
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
