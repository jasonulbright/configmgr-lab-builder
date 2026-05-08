#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the per-VM Unattend.xml builder (New-Unattend). These
    tests are functional gates: a malformed Unattend means the VM never
    gets its IP / never joins the network / DC promotion fails.
#>

BeforeAll {
    $script:vmRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\04-VM"
    . (Join-Path $script:vmRoot 'Format-LabMacAddress.ps1')
    . (Join-Path $script:vmRoot 'New-Unattend.ps1')

    function Get-Settings {
        param([xml]$Doc, [string]$Pass)
        return @($Doc.unattend.settings | Where-Object { $_.pass -eq $Pass })
    }

    function Get-Component {
        param([xml]$Doc, [string]$Pass, [string]$Name)
        $s = Get-Settings -Doc $Doc -Pass $Pass
        return @($s.component | Where-Object { $_.name -eq $Name })[0]
    }

    function Build-Unattend {
        param(
            [string]$ComputerName = 'CM01',
            [string]$LabNicMac    = '00-15-5D-AB-50-20',
            [string]$IPAddress    = '192.168.50.20/24',
            [string]$Gateway      = '192.168.50.1',
            [string]$DnsServer    = '192.168.50.10',
            [string]$Pass         = 'P@ssw0rd!',
            [switch]$EnableAutoLogon,
            [switch]$NoGateway
        )
        $p = Join-Path $TestDrive ('un-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        $params = @{
            ComputerName          = $ComputerName
            LabNicMac             = $LabNicMac
            IPAddress             = $IPAddress
            DnsServer             = $DnsServer
            AdministratorPassword = $Pass
            OutputPath            = $p
        }
        if ($EnableAutoLogon) { $params.EnableAutoLogon = $true }
        if (-not $NoGateway -and $Gateway) { $params.Gateway = $Gateway }
        New-Unattend @params | Out-Null
        return $p
    }
}

Describe 'New-Unattend XML structure' {

    It 'produces a parseable Unattend document with the right namespace' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $doc.unattend.xmlns | Should -Be 'urn:schemas-microsoft-com:unattend'
    }

    It 'sets the computer name in specialize' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $shell = Get-Component -Doc $doc -Pass specialize -Name 'Microsoft-Windows-Shell-Setup'
        $shell.ComputerName | Should -Be 'CM01'
    }

    It 'sets the time zone' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $shell = Get-Component -Doc $doc -Pass specialize -Name 'Microsoft-Windows-Shell-Setup'
        $shell.TimeZone | Should -Be 'UTC'
    }

    It 'targets the lab NIC by dashed MAC in TCPIP component' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $tcp = Get-Component -Doc $doc -Pass specialize -Name 'Microsoft-Windows-TCPIP'
        $tcp.Interfaces.Interface.Identifier | Should -Be '00-15-5D-AB-50-20'
    }

    It 'normalizes a plain-12-hex MAC to dashed for the Unattend Identifier' {
        $p = Build-Unattend -LabNicMac '00155D505020' -ComputerName 'X1' -IPAddress '192.168.50.50/24'
        [xml]$doc = Get-Content $p -Raw
        $tcp = Get-Component -Doc $doc -Pass specialize -Name 'Microsoft-Windows-TCPIP'
        $tcp.Interfaces.Interface.Identifier | Should -Be '00-15-5D-50-50-20'
    }

    It 'sets static IP in CIDR form' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $tcp = Get-Component -Doc $doc -Pass specialize -Name 'Microsoft-Windows-TCPIP'
        $tcp.Interfaces.Interface.UnicastIpAddresses.IpAddress.'#text' | Should -Be '192.168.50.20/24'
    }

    It 'disables DHCP for the lab NIC' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $tcp = Get-Component -Doc $doc -Pass specialize -Name 'Microsoft-Windows-TCPIP'
        $tcp.Interfaces.Interface.Ipv4Settings.DhcpEnabled | Should -Be 'false'
    }

    It 'configures the default gateway when supplied' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $tcp = Get-Component -Doc $doc -Pass specialize -Name 'Microsoft-Windows-TCPIP'
        $tcp.Interfaces.Interface.Routes.Route.NextHopAddress | Should -Be '192.168.50.1'
    }

    It 'sets the DNS server' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $dns = Get-Component -Doc $doc -Pass specialize -Name 'Microsoft-Windows-DNS-Client'
        $dns.Interfaces.Interface.DNSServerSearchOrder.IpAddress.'#text' | Should -Be '192.168.50.10'
    }

    It 'sets the local Administrator password in oobeSystem' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $shell = Get-Component -Doc $doc -Pass oobeSystem -Name 'Microsoft-Windows-Shell-Setup'
        $shell.UserAccounts.AdministratorPassword.Value | Should -Be 'P@ssw0rd!'
        $shell.UserAccounts.AdministratorPassword.PlainText | Should -Be 'true'
    }

    It 'emits AutoLogon when -EnableAutoLogon is set' {
        $p = Build-Unattend -EnableAutoLogon
        [xml]$doc = Get-Content $p -Raw
        $shell = Get-Component -Doc $doc -Pass oobeSystem -Name 'Microsoft-Windows-Shell-Setup'
        $shell.AutoLogon.Enabled | Should -Be 'true'
        $shell.AutoLogon.Username | Should -Be 'Administrator'
    }

    It 'omits AutoLogon when -EnableAutoLogon is NOT set' {
        $p = Build-Unattend
        [xml]$doc = Get-Content $p -Raw
        $shell = Get-Component -Doc $doc -Pass oobeSystem -Name 'Microsoft-Windows-Shell-Setup'
        $shell.AutoLogon | Should -BeNullOrEmpty
    }

    It 'omits the Routes block when no Gateway is supplied' {
        $p = Build-Unattend -NoGateway
        [xml]$doc = Get-Content $p -Raw
        $tcp = Get-Component -Doc $doc -Pass specialize -Name 'Microsoft-Windows-TCPIP'
        $tcp.Interfaces.Interface.Routes | Should -BeNullOrEmpty
    }

    It 'XML-escapes special characters in the password' {
        $tricky = "P@`"ss<wo>rd&'!"
        $p = Build-Unattend -Pass $tricky
        [xml]$doc = Get-Content $p -Raw
        $shell = Get-Component -Doc $doc -Pass oobeSystem -Name 'Microsoft-Windows-Shell-Setup'
        $shell.UserAccounts.AdministratorPassword.Value | Should -Be $tricky
    }

    It 'writes a UTF-8 BOM' {
        $p = Build-Unattend
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }

    It 'rejects an out-of-range computer name (too long)' {
        { Build-Unattend -ComputerName ('A' * 16) } |
            Should -Throw '*length*'
    }

    It 'rejects an IP without a CIDR prefix' {
        { Build-Unattend -IPAddress '192.168.50.25' } |
            Should -Throw "*does not match*"
    }
}
