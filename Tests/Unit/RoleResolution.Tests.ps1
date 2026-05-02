#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Resolve-LabVM (S13 role decoupling helper).
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    . (Join-Path $script:helpersRoot 'Get-LabConfig.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabVMByRole.ps1')
    . (Join-Path $script:helpersRoot 'Resolve-LabVM.ps1')

    $script:fixtureDir = Join-Path $TestDrive 'role-resolution-fixtures'
    New-Item -Path $script:fixtureDir -ItemType Directory -Force | Out-Null

    $script:defaultPath = Join-Path $script:fixtureDir 'default.psd1'
    Set-Content -Path $script:defaultPath -Encoding UTF8 -Value @'
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

    $script:multiDpPath = Join-Path $script:fixtureDir 'multi-dp.psd1'
    Set-Content -Path $script:multiDpPath -Encoding UTF8 -Value @'
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
        @{ Name='DC01' ; Roles=@('DomainController','CertificateAuthority') ; IP='192.168.50.10' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='CM01' ; Roles=@('SqlServer','SiteServer','ManagementPoint','SoftwareUpdatePoint') ; IP='192.168.50.20' ; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
        @{ Name='DP01' ; Roles=@('DistributionPoint') ; IP='192.168.50.30' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
        @{ Name='DP02' ; Roles=@('DistributionPoint') ; IP='192.168.50.31' ; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
    )
    ServiceAccounts = @{
        ClientPush = @{ Name='svc-CMPush'; Password='p1' }
        NAA        = @{ Name='svc-CMNAA'; Password='p2' }
        Join       = @{ Name='svc-CMJoin'; Password='p3' }
    }
}
'@
}

Describe 'Resolve-LabVM happy path' {

    BeforeAll {
        $script:cfg = Get-LabConfig -Path $script:defaultPath
    }

    It 'returns the DC for DomainController' {
        $vm = Resolve-LabVM -Config $script:cfg -Role DomainController
        $vm.Name | Should -Be 'DC01'
    }

    It 'returns the same VM for SiteServer and SqlServer in the default topology' {
        $site = Resolve-LabVM -Config $script:cfg -Role SiteServer
        $sql  = Resolve-LabVM -Config $script:cfg -Role SqlServer
        $site.Name | Should -Be 'CM01'
        $sql.Name  | Should -Be 'CM01'
    }

    It 'returns the Client for Client' {
        $vm = Resolve-LabVM -Config $script:cfg -Role Client
        $vm.Name | Should -Be 'CLIENT01'
    }

    It 'returns a hashtable with reference identity to the VMs[] entry' {
        $vm = Resolve-LabVM -Config $script:cfg -Role DomainController
        $vm | Should -BeOfType [hashtable]
        # Reference identity: mutating the returned VM mutates VMs[0].
        $vm['__ResolveTag'] = 'tag'
        $script:cfg.VMs[0]['__ResolveTag'] | Should -Be 'tag'
    }
}

Describe 'Resolve-LabVM with multi-DP topology' {

    BeforeAll {
        $script:cfg = Get-LabConfig -Path $script:multiDpPath
    }

    It 'returns the first DP by default' {
        $vm = Resolve-LabVM -Config $script:cfg -Role DistributionPoint
        $vm.Name | Should -Be 'DP01'
    }

    It 'returns DP02 with -Index 1' {
        $vm = Resolve-LabVM -Config $script:cfg -Role DistributionPoint -Index 1
        $vm.Name | Should -Be 'DP02'
    }

    It 'throws when -Index exceeds the role count' {
        { Resolve-LabVM -Config $script:cfg -Role DistributionPoint -Index 5 } |
            Should -Throw "*requested index 5 for role 'DistributionPoint'*"
    }

    It 'throws on a negative -Index' {
        { Resolve-LabVM -Config $script:cfg -Role DistributionPoint -Index -1 } |
            Should -Throw "*requested index -1 for role 'DistributionPoint'*"
    }
}

Describe 'Resolve-LabVM error paths' {

    BeforeAll {
        $script:cfg = Get-LabConfig -Path $script:defaultPath
    }

    It 'throws when no VM carries the requested role' {
        # Build a config with no CertificateAuthority anywhere; all
        # required CM roles co-located on CM01 to satisfy topology
        # validation.
        $p = Join-Path $script:fixtureDir 'no-ca.psd1'
        Set-Content -Path $p -Encoding UTF8 -Value @'
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
        $cfg = Get-LabConfig -Path $p
        { Resolve-LabVM -Config $cfg -Role CertificateAuthority } |
            Should -Throw "*no VM carries role 'CertificateAuthority'*"
    }

    It 'throws on an unknown role (forwards Get-LabVMByRole error)' {
        { Resolve-LabVM -Config $script:cfg -Role 'NotARole' } |
            Should -Throw "*unknown role 'NotARole'*"
    }
}
