@{
    # CAS hierarchy with full role-per-server split (10 VMs).
    #
    # DC01     DomainController + CertificateAuthority
    # CAS01    CentralAdministrationSite
    # SQL01    SqlServer (shared between CAS and child primary, simplified)
    # CM01     SiteServer (child primary)
    # MP01     ManagementPoint
    # DP01     DistributionPoint  (region A)
    # DP02     DistributionPoint  (region B)
    # SUP01    SoftwareUpdatePoint
    # CLIENT01 Client (lab clients in the child primary's boundary)
    #
    # The full enterprise picture: a parent CAS, a child primary,
    # dedicated SQL, dedicated MP / SUP, multi-DP for regional
    # content distribution. Mirrors what a global-scale CM
    # deployment looks like.
    #
    # Engine support (S16): same as cas-2-dps -- schema accepted,
    # orchestrator currently rejects CAS topologies. See
    # cas-2-dps.psd1 for details.

    LabName        = 'HomeLab-CAS-RolePerServer'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Home Lab CAS Role-per-Server'
    Network        = '192.168.50'

    AdminUser      = 'LabAdmin'

    ServerOSFilter = 'Windows Server 2025*Desktop Experience*'
    ClientOSFilter = 'Windows 11*Enterprise*'

    AutoStartAction = 'Start'
    AutoStopAction  = 'ShutDown'

    VMs = @(
        @{ Name='DC01'    ; Roles=@('DomainController','CertificateAuthority') ; IP='192.168.50.10'  ; Memory=2GB  ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=30  }
        @{ Name='CAS01'   ; Roles=@('CentralAdministrationSite')               ; IP='192.168.50.14'  ; Memory=8GB  ; MinMemory=4GB ; MaxMemory=8GB  ; Processors=4 ; OSDiskSize=150 ; AutoStartDelay=60  }
        @{ Name='SQL01'   ; Roles=@('SqlServer')                               ; IP='192.168.50.15'  ; Memory=12GB ; MinMemory=4GB ; MaxMemory=12GB ; Processors=4 ; OSDiskSize=200 ; AutoStartDelay=60  }
        @{ Name='CM01'    ; Roles=@('SiteServer')                              ; IP='192.168.50.20'  ; Memory=6GB  ; MinMemory=4GB ; MaxMemory=8GB  ; Processors=4 ; OSDiskSize=150 ; AutoStartDelay=120 }
        @{ Name='MP01'    ; Roles=@('ManagementPoint')                         ; IP='192.168.50.30'  ; Memory=2GB  ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=150 }
        @{ Name='DP01'    ; Roles=@('DistributionPoint')                       ; IP='192.168.50.31'  ; Memory=2GB  ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=150 }
        @{ Name='DP02'    ; Roles=@('DistributionPoint')                       ; IP='192.168.50.32'  ; Memory=2GB  ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=150 }
        @{ Name='SUP01'   ; Roles=@('SoftwareUpdatePoint')                     ; IP='192.168.50.33'  ; Memory=2GB  ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=150 }
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
