@{
    # 7-VM role-per-server topology (enterprise tier-1 mirror).
    #
    # DC01     DomainController + CertificateAuthority
    # SQL01    SqlServer
    # CM01     SiteServer (site server only; MP / DP / SUP are separate)
    # MP01     ManagementPoint
    # DP01     DistributionPoint
    # SUP01    SoftwareUpdatePoint  (see "Engine support" below)
    # CLIENT01 Client
    #
    # Engine support (S15+):
    #   - MP / DP roles attach via Add-CMRoleManagementPoint /
    #     Add-CMRoleDistributionPoint after Install-CMSite.
    #   - SUP on a separate VM is currently NOT plumbed end-to-end:
    #     Phase 07-CMPrereqs installs WSUS on the SiteServer, and
    #     Install-CMSoftwareUpdatePoint falls back to the site server
    #     with a WARN. SUP01 will exist as a domain-joined VM but
    #     will not host the WSUS / SUP role until a future tag.
    #   - For a fully-distributed lab today, set SUP01.Roles to
    #     @() and merge SoftwareUpdatePoint onto CM01.

    LabName        = 'HomeLab-RolePerServer'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Home Lab Role-per-Server Primary'
    Network        = '192.168.50'

    AdminUser      = 'LabAdmin'

    ServerOSFilter = 'Windows Server 2025*Desktop Experience*'
    ClientOSFilter = 'Windows 11*Enterprise*'

    AutoStartAction = 'Start'
    AutoStopAction  = 'ShutDown'

    VMs = @(
        @{ Name='DC01'    ; Roles=@('DomainController','CertificateAuthority') ; IP='192.168.50.10'  ; Memory=2GB ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=30  }
        @{ Name='SQL01'   ; Roles=@('SqlServer')             ; IP='192.168.50.15'  ; Memory=8GB ; MinMemory=4GB ; MaxMemory=8GB  ; Processors=4 ; OSDiskSize=150 ; AutoStartDelay=60  }
        @{ Name='CM01'    ; Roles=@('SiteServer')            ; IP='192.168.50.20'  ; Memory=6GB ; MinMemory=4GB ; MaxMemory=8GB  ; Processors=4 ; OSDiskSize=150 ; AutoStartDelay=90  }
        @{ Name='MP01'    ; Roles=@('ManagementPoint')       ; IP='192.168.50.30'  ; Memory=2GB ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=120 }
        @{ Name='DP01'    ; Roles=@('DistributionPoint')     ; IP='192.168.50.31'  ; Memory=2GB ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=120 }
        @{ Name='SUP01'   ; Roles=@('SoftwareUpdatePoint')   ; IP='192.168.50.32'  ; Memory=2GB ; MinMemory=1GB ; MaxMemory=2GB  ; Processors=2 ; AutoStartDelay=150 }
        @{ Name='CLIENT01'; Roles=@('Client')                ; IP='192.168.50.100' ; Memory=4GB ; MinMemory=2GB ; MaxMemory=4GB  ; Processors=2 ; OSDiskSize=150 ; AutoStartDelay=180 }
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
