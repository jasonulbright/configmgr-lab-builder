#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for schema v2: VMs[] + per-VM Roles, backwards-compat
    projection from legacy DC/CM/Client blocks, RoleIndex / Get-LabVMByRole
    queries, topology validation.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    . (Join-Path $script:helpersRoot 'Get-LabConfig.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabVMByRole.ps1')

    $script:fixtureDir = Join-Path $TestDrive 'schema-v2-fixtures'
    New-Item -Path $script:fixtureDir -ItemType Directory -Force | Out-Null

    function New-V2ConfigFile {
        param(
            [Parameter(Mandatory)] [string]$Path,
            [string]$Body = $null
        )
        if (-not $Body) {
            $Body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01'    ; Roles=@('DomainController','CertificateAuthority') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01'    ; Roles=@('SqlServer','SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
        @{ Name='CLIENT01'; Roles=@('Client') ; IP='192.168.50.100' ; Memory=4GB; MinMemory=2GB; MaxMemory=4GB; Processors=2 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        }
        Set-Content -Path $Path -Value $Body -Encoding UTF8
    }

    function New-V1ConfigFile {
        param(
            [Parameter(Mandatory)] [string]$Path,
            [string]$Body = $null
        )
        if (-not $Body) {
            $Body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    DC     = @{ Name='DC01'    ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
    CM     = @{ Name='CM01'    ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    Client = @{ Name='CLIENT01'; IP='192.168.50.100'; Memory=4GB; MinMemory=2GB; MaxMemory=4GB; Processors=2 }
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        }
        Set-Content -Path $Path -Value $Body -Encoding UTF8
    }
}

Describe 'Schema v2 native shape (VMs[] + per-VM Roles)' {

    It 'loads a native v2 config without error' {
        $p = Join-Path $script:fixtureDir 'v2-native.psd1'
        New-V2ConfigFile -Path $p
        { Get-LabConfig -Path $p } | Should -Not -Throw
    }

    It 'returns VMs as an ordered array of 3' {
        $p = Join-Path $script:fixtureDir 'v2-native-array.psd1'
        New-V2ConfigFile -Path $p
        $cfg = Get-LabConfig -Path $p
        @($cfg.VMs).Count | Should -Be 3
        $cfg.VMs[0].Name | Should -Be 'DC01'
        $cfg.VMs[2].Name | Should -Be 'CLIENT01'
    }

    It 'preserves Roles per VM' {
        $p = Join-Path $script:fixtureDir 'v2-roles.psd1'
        New-V2ConfigFile -Path $p
        $cfg = Get-LabConfig -Path $p
        $cfg.VMs[0].Roles | Should -Contain 'DomainController'
        $cfg.VMs[0].Roles | Should -Contain 'CertificateAuthority'
        $cfg.VMs[1].Roles | Should -Contain 'SiteServer'
        $cfg.VMs[1].Roles | Should -Contain 'SqlServer'
        $cfg.VMs[2].Roles | Should -Be @('Client')
    }

    It 'derives DC / CM / Client aliases from RoleIndex' {
        $p = Join-Path $script:fixtureDir 'v2-aliases.psd1'
        New-V2ConfigFile -Path $p
        $cfg = Get-LabConfig -Path $p
        $cfg.DC.Name     | Should -Be 'DC01'
        $cfg.CM.Name     | Should -Be 'CM01'
        $cfg.Client.Name | Should -Be 'CLIENT01'
    }

    It 'derives aliases as same-reference VMs (not copies)' {
        $p = Join-Path $script:fixtureDir 'v2-refs.psd1'
        New-V2ConfigFile -Path $p
        $cfg = Get-LabConfig -Path $p
        # Reference identity: mutating the alias changes the VMs entry.
        $cfg.DC['Memory'] = 3GB
        $cfg.VMs[0].Memory | Should -Be 3GB
        # Reverse direction: mutating the VMs entry changes the alias.
        $cfg.VMs[1]['Processors'] = 6
        $cfg.CM.Processors | Should -Be 6
        $cfg.VMs[2]['Memory'] = 6GB
        $cfg.Client.Memory | Should -Be 6GB
    }
}

Describe 'Schema v1 -> v2 projection (legacy DC/CM/Client blocks)' {

    It 'loads a legacy v1 config without error' {
        $p = Join-Path $script:fixtureDir 'v1-legacy.psd1'
        New-V1ConfigFile -Path $p
        { Get-LabConfig -Path $p } | Should -Not -Throw
    }

    It 'projects DC/CM/Client into VMs[]' {
        $p = Join-Path $script:fixtureDir 'v1-projected.psd1'
        New-V1ConfigFile -Path $p
        $cfg = Get-LabConfig -Path $p
        @($cfg.VMs).Count | Should -Be 3
        $cfg.VMs[0].Name | Should -Be 'DC01'
        $cfg.VMs[1].Name | Should -Be 'CM01'
        $cfg.VMs[2].Name | Should -Be 'CLIENT01'
    }

    It 'assigns DomainController + CertificateAuthority to the DC block' {
        $p = Join-Path $script:fixtureDir 'v1-dc-roles.psd1'
        New-V1ConfigFile -Path $p
        $cfg = Get-LabConfig -Path $p
        $cfg.VMs[0].Roles | Should -Contain 'DomainController'
        $cfg.VMs[0].Roles | Should -Contain 'CertificateAuthority'
    }

    It 'assigns the full CM role bundle to the CM block' {
        $p = Join-Path $script:fixtureDir 'v1-cm-roles.psd1'
        New-V1ConfigFile -Path $p
        $cfg = Get-LabConfig -Path $p
        foreach ($r in 'SqlServer','SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint') {
            $cfg.VMs[1].Roles | Should -Contain $r
        }
    }

    It 'assigns Client to the Client block' {
        $p = Join-Path $script:fixtureDir 'v1-client-role.psd1'
        New-V1ConfigFile -Path $p
        $cfg = Get-LabConfig -Path $p
        $cfg.VMs[2].Roles | Should -Be @('Client')
    }

    It 'projects with reference identity (DC alias and VMs[0] are same hashtable)' {
        $p = Join-Path $script:fixtureDir 'v1-refs.psd1'
        New-V1ConfigFile -Path $p
        $cfg = Get-LabConfig -Path $p
        # Mutate via the alias; the projected VM should see it.
        $cfg.DC['Memory'] = 5GB
        $cfg.VMs[0].Memory | Should -Be 5GB
        # Reverse direction on the projected VMs array.
        $cfg.VMs[1]['Processors'] = 8
        $cfg.CM.Processors | Should -Be 8
        $cfg.VMs[2]['Memory'] = 7GB
        $cfg.Client.Memory | Should -Be 7GB
    }
}

Describe 'RoleIndex and Get-LabVMByRole' {

    BeforeAll {
        $script:p = Join-Path $script:fixtureDir 'roleindex.psd1'
        New-V2ConfigFile -Path $script:p
        $script:cfg = Get-LabConfig -Path $script:p
    }

    It 'attaches a RoleIndex hashtable to the config' {
        $script:cfg.ContainsKey('RoleIndex') | Should -BeTrue
        $script:cfg.RoleIndex | Should -BeOfType [hashtable]
    }

    It 'indexes DomainController to the DC VM' {
        @($script:cfg.RoleIndex['DomainController']).Count | Should -Be 1
        @($script:cfg.RoleIndex['DomainController'])[0].Name | Should -Be 'DC01'
    }

    It 'indexes SiteServer to the CM VM' {
        @($script:cfg.RoleIndex['SiteServer'])[0].Name | Should -Be 'CM01'
    }

    It 'indexes SqlServer to the CM VM' {
        @($script:cfg.RoleIndex['SqlServer'])[0].Name | Should -Be 'CM01'
    }

    It 'indexes Client to the CLIENT01 VM' {
        @($script:cfg.RoleIndex['Client'])[0].Name | Should -Be 'CLIENT01'
    }

    It 'has empty entries for unassigned roles in the catalog' {
        # All catalog roles ARE assigned in the default v2 fixture, so
        # we exercise an empty case via a custom fixture (no CA, no Client,
        # all CM roles co-located on CM01 to satisfy topology validation).
        $custom = Join-Path $script:fixtureDir 'no-ca.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SqlServer','SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $custom -Value $body -Encoding UTF8
        $cfg = Get-LabConfig -Path $custom
        @($cfg.RoleIndex['CertificateAuthority']).Count | Should -Be 0
        @($cfg.RoleIndex['Client']).Count | Should -Be 0
    }

    It 'Get-LabVMByRole returns the right VM for DomainController' {
        $vms = Get-LabVMByRole -Config $script:cfg -Role DomainController
        @($vms).Count | Should -Be 1
        @($vms)[0].Name | Should -Be 'DC01'
    }

    It 'Get-LabVMByRole returns the right VM for SoftwareUpdatePoint' {
        $vms = Get-LabVMByRole -Config $script:cfg -Role SoftwareUpdatePoint
        @($vms)[0].Name | Should -Be 'CM01'
    }

    It 'Get-LabVMByRole returns an empty array for an unassigned-but-valid role' {
        # Build a fixture where no VM carries CertificateAuthority but
        # all required CM roles are present on CM01.
        $custom = Join-Path $script:fixtureDir 'no-ca-empty.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SqlServer','SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $custom -Value $body -Encoding UTF8
        $cfg = Get-LabConfig -Path $custom
        $vms = @(Get-LabVMByRole -Config $cfg -Role CertificateAuthority)
        @($vms).Count | Should -Be 0
    }

    It 'Get-LabVMByRole throws on an unknown role' {
        { Get-LabVMByRole -Config $script:cfg -Role 'NotARole' } |
            Should -Throw "*unknown role 'NotARole'*"
    }

    It 'Get-LabVMByRole throws when Config has no RoleIndex' {
        { Get-LabVMByRole -Config @{} -Role DomainController } |
            Should -Throw "*does not have a RoleIndex*"
    }
}

Describe 'Schema v2 validation failures' {

    It 'throws when neither VMs nor DC/CM/Client are present' {
        $p = Join-Path $script:fixtureDir 'no-vms.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*must define either 'VMs'*or 'DC'/'CM'/'Client'*"
    }

    It 'throws when a VM has an unknown role' {
        $p = Join-Path $script:fixtureDir 'bad-role.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController','BogusRole') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SiteServer') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*unknown role 'BogusRole'*"
    }

    It 'throws when a VM has no Roles' {
        $p = Join-Path $script:fixtureDir 'no-roles.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@() ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SiteServer','DomainController') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*has no Roles*"
    }

    It 'throws on duplicate VM names' {
        $p = Join-Path $script:fixtureDir 'dup-names.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='DC01' ; Roles=@('SiteServer') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*duplicate VM names*"
    }

    It 'throws on duplicate VM IPs' {
        $p = Join-Path $script:fixtureDir 'dup-ips.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SiteServer') ; IP='192.168.50.10' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*duplicate VM IPs*"
    }

    It 'throws when zero VMs carry DomainController' {
        $p = Join-Path $script:fixtureDir 'zero-dc.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='CM01' ; Roles=@('SiteServer','SqlServer') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*expected exactly 1 VM with role 'DomainController', got 0*"
    }

    It 'throws when more than one VM carries DomainController' {
        $p = Join-Path $script:fixtureDir 'two-dc.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='DC02' ; Roles=@('DomainController') ; IP='192.168.50.11' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SiteServer') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*expected exactly 1 VM with role 'DomainController', got 2*"
    }

    It 'throws when no VM carries SqlServer' {
        $p = Join-Path $script:fixtureDir 'no-sql.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*at least 1 VM with role 'SqlServer'*"
    }

    It 'throws when no VM carries ManagementPoint' {
        $p = Join-Path $script:fixtureDir 'no-mp.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SqlServer','SiteServer','DistributionPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*at least 1 VM with role 'ManagementPoint'*"
    }

    It 'throws when no VM carries DistributionPoint' {
        $p = Join-Path $script:fixtureDir 'no-dp.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SqlServer','SiteServer','ManagementPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*at least 1 VM with role 'DistributionPoint'*"
    }

    It 'throws when no VM carries SoftwareUpdatePoint' {
        $p = Join-Path $script:fixtureDir 'no-sup.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SqlServer','SiteServer','ManagementPoint','DistributionPoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*at least 1 VM with role 'SoftwareUpdatePoint'*"
    }

    It 'accepts a CAS topology in the schema (orchestration deferred)' {
        # CAS is recognised by the schema (CentralAdministrationSite is
        # a valid role) but only at-most-one is allowed and Install-HomeLab
        # rejects it. Get-LabConfig itself accepts.
        $p = Join-Path $script:fixtureDir 'cas-topology.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CAS01'; Roles=@('CentralAdministrationSite','SqlServer') ; IP='192.168.50.15' ; Memory=8GB; MinMemory=4GB; MaxMemory=8GB; Processors=4 }
        @{ Name='CM01' ; Roles=@('SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        $cfg = Get-LabConfig -Path $p
        @($cfg.RoleIndex['CentralAdministrationSite'])[0].Name | Should -Be 'CAS01'
    }

    It 'rejects more than one CAS VM' {
        $p = Join-Path $script:fixtureDir 'two-cas.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01'  ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CAS01' ; Roles=@('CentralAdministrationSite','SqlServer') ; IP='192.168.50.15' ; Memory=8GB; MinMemory=4GB; MaxMemory=8GB; Processors=4 }
        @{ Name='CAS02' ; Roles=@('CentralAdministrationSite') ; IP='192.168.50.16' ; Memory=8GB; MinMemory=4GB; MaxMemory=8GB; Processors=4 }
        @{ Name='CM01'  ; Roles=@('SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } |
            Should -Throw "*expected at most 1 VM with role 'CentralAdministrationSite', got 2*"
    }

    It 'accepts a role-per-server topology with each CM role on its own VM' {
        $p = Join-Path $script:fixtureDir 'role-per-server.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01'  ; Roles=@('DomainController','CertificateAuthority') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='SQL01' ; Roles=@('SqlServer') ; IP='192.168.50.15' ; Memory=8GB; MinMemory=4GB; MaxMemory=8GB; Processors=4 }
        @{ Name='CM01'  ; Roles=@('SiteServer') ; IP='192.168.50.20' ; Memory=8GB; MinMemory=4GB; MaxMemory=8GB; Processors=4 }
        @{ Name='MP01'  ; Roles=@('ManagementPoint') ; IP='192.168.50.30' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='DP01'  ; Roles=@('DistributionPoint') ; IP='192.168.50.31' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='SUP01' ; Roles=@('SoftwareUpdatePoint') ; IP='192.168.50.32' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        $cfg = Get-LabConfig -Path $p
        @($cfg.VMs).Count | Should -Be 6
        @($cfg.RoleIndex['SqlServer'])[0].Name           | Should -Be 'SQL01'
        @($cfg.RoleIndex['SiteServer'])[0].Name          | Should -Be 'CM01'
        @($cfg.RoleIndex['ManagementPoint'])[0].Name     | Should -Be 'MP01'
        @($cfg.RoleIndex['DistributionPoint'])[0].Name   | Should -Be 'DP01'
        @($cfg.RoleIndex['SoftwareUpdatePoint'])[0].Name | Should -Be 'SUP01'
    }

    It 'throws when zero VMs carry SiteServer' {
        $p = Join-Path $script:fixtureDir 'zero-site.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*expected at least 1 VM with role 'SiteServer'*"
    }

    It 'throws when a VM is missing a required property' {
        $p = Join-Path $script:fixtureDir 'missing-ip.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SiteServer') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*missing required property 'IP'*"
    }

    It 'throws when a VM IP is outside the network prefix' {
        $p = Join-Path $script:fixtureDir 'bad-ip.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='10.0.0.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SiteServer') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*not in network prefix*"
    }

    It 'throws when MinMemory exceeds MaxMemory on a v2 VM' {
        $p = Join-Path $script:fixtureDir 'bad-mem.psd1'
        $body = @'
@{
    LabName        = 'TestLab'
    DomainName     = 'contoso.com'
    SiteCode       = 'MCM'
    SiteName       = 'Test Lab Primary'
    Network        = '192.168.50'
    AdminUser      = 'LabAdmin'
    AdminPass      = 'P@ssw0rd!'
    ServerOSFilter = 'Windows Server 2025*'
    ClientOSFilter = 'Windows 11*'
    VMs = @(
        @{ Name='DC01' ; Roles=@('DomainController') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=8GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SiteServer') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
        Set-Content -Path $p -Value $body -Encoding UTF8
        { Get-LabConfig -Path $p } | Should -Throw "*MinMemory*exceeds MaxMemory*"
    }
}

Describe 'Live config.psd1 still loads under v2' {

    BeforeAll {
        $script:liveConfig = Resolve-Path "$PSScriptRoot\..\..\config.psd1"
    }

    It 'loads the live legacy config without error' {
        { Get-LabConfig -Path $script:liveConfig } | Should -Not -Throw
    }

    It 'projects the live DC block to a DomainController VM' {
        $cfg = Get-LabConfig -Path $script:liveConfig
        $dc = @($cfg.RoleIndex['DomainController'])[0]
        $dc.Name | Should -Be 'DC01'
        $dc.Roles | Should -Contain 'DomainController'
        $dc.Roles | Should -Contain 'CertificateAuthority'
    }

    It 'projects the live CM block to a SiteServer VM' {
        $cfg = Get-LabConfig -Path $script:liveConfig
        $cm = @($cfg.RoleIndex['SiteServer'])[0]
        $cm.Name | Should -Be 'CM01'
    }

    It 'keeps DC / CM / Client legacy aliases pointed at the right VMs' {
        $cfg = Get-LabConfig -Path $script:liveConfig
        $cfg.DC.Name     | Should -Be 'DC01'
        $cfg.CM.Name     | Should -Be 'CM01'
        $cfg.Client.Name | Should -Be 'CLIENT01'
    }

    It 'gives DC alias and VMs[0] the same hashtable reference' {
        $cfg = Get-LabConfig -Path $script:liveConfig
        # Reference identity test via in-place mutation. A tag only
        # the alias sets must show up on the array element too.
        $cfg.DC['__SchemaV2RefTag'] = 'tag'
        $cfg.VMs[0]['__SchemaV2RefTag'] | Should -Be 'tag'
    }
}
