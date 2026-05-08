function New-Unattend {
    <#
    .SYNOPSIS
        Generate the per-VM Unattend.xml that drives first-boot setup of a
        differencing-VHDX child of a sysprepped base image.

    .DESCRIPTION
        This is NOT the base-image Unattend (see New-LabBaseUnattend).
        That one runs sysprep /generalize /shutdown to make the parent
        suitable for differencing. THIS one is injected into each child
        VHDX before its first boot and:
          - Sets the computer name (specialize)
          - Sets static IPv4 + gateway on the lab NIC, identified by MAC
            (specialize, Microsoft-Windows-TCPIP)
          - Sets DNS server on the lab NIC (specialize,
            Microsoft-Windows-DNS-Client)
          - Sets time zone (specialize)
          - Skips OOBE pages and creates the Administrator password
            (oobeSystem)
          - Optionally enables one-shot AutoLogon so subsequent
            Invoke-Command calls succeed without an interactive logon

        Domain join is intentionally NOT done here. It lands in S5 via
        Add-Computer over WinRM after DC01 is promoted. Doing it via
        Unattend is brittle (DNS resolution must work at specialize time,
        DC must already be ADWS-ready, etc.).

        The lab NIC is identified by its MAC. Hyper-V assigns MACs
        non-deterministically by default; pin a static MAC via
        Set-VMNetworkAdapter -StaticMacAddress before calling this so the
        Unattend can target it reliably.

    .PARAMETER ComputerName
        15-char NetBIOS-safe machine name (e.g. CM01).

    .PARAMETER LabNicMac
        MAC of the lab-internal NIC. Any common format accepted; normalized
        to dashed (XX-XX-XX-XX-XX-XX) for the Unattend Identifier.

    .PARAMETER IPAddress
        Static IPv4 in CIDR form (e.g. '192.168.50.20/24'). The Unattend
        emits 'Address/PrefixLength' as a single string per Microsoft-
        Windows-TCPIP schema.

    .PARAMETER Gateway
        Optional default-gateway IPv4. Skipped from the Unattend if empty.

    .PARAMETER DnsServer
        DNS server IPv4 for the lab NIC. Required for VMs that need to
        resolve contoso.com (CM01, CLIENT01); pass DC01's IP. For DC01
        itself, pass its own IP (loopback through the lab NIC works once
        AD DS is up).

    .PARAMETER AdministratorPassword
        Local Administrator password set in oobeSystem.

    .PARAMETER TimeZone
        Standard Windows time-zone name. Default 'UTC'.

    .PARAMETER EnableAutoLogon
        Enable a one-shot Administrator AutoLogon so the VM lands at the
        desktop without a manual interactive logon. Useful when you want
        first-logon scripts to run; harmless otherwise.

    .PARAMETER Architecture
        amd64 / x86 / arm64. Default amd64.

    .PARAMETER OutputPath
        Destination file path. Written UTF-8 with BOM.

    .EXAMPLE
        New-Unattend `
            -ComputerName CM01 `
            -LabNicMac '00-15-5D-AB-50-20' `
            -IPAddress '192.168.50.20/24' `
            -Gateway '192.168.50.10' `
            -DnsServer '192.168.50.10' `
            -AdministratorPassword 'P@ssw0rd!' `
            -EnableAutoLogon `
            -OutputPath C:\Temp\CM01-unattend.xml
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidateLength(1, 15)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LabNicMac,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
        [string]$IPAddress,

        [Parameter()]
        [string]$Gateway,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')]
        [string]$DnsServer,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AdministratorPassword,

        [Parameter()]
        [string]$TimeZone = 'UTC',

        [Parameter()]
        [switch]$EnableAutoLogon,

        [Parameter()]
        [ValidateSet('amd64','x86','arm64')]
        [string]$Architecture = 'amd64',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath
    )

    $macDash = Format-LabMacAddress -Mac $LabNicMac -Format Dash
    $escPass = [System.Security.SecurityElement]::Escape($AdministratorPassword)
    $escName = [System.Security.SecurityElement]::Escape($ComputerName)
    $escTz   = [System.Security.SecurityElement]::Escape($TimeZone)

    # Build optional fragments. Keeping them as separate strings instead of
    # nested ternaries keeps the surrounding XML readable.
    $gatewayBlock = ''
    if ($Gateway) {
        $escGw = [System.Security.SecurityElement]::Escape($Gateway)
        $gatewayBlock = @"
          <Routes>
            <Route wcm:action="add">
              <Identifier>0</Identifier>
              <Prefix>0.0.0.0/0</Prefix>
              <NextHopAddress>$escGw</NextHopAddress>
              <Metric>10</Metric>
            </Route>
          </Routes>
"@
    }

    $autoLogonBlock = ''
    if ($EnableAutoLogon) {
        $autoLogonBlock = @"
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <LogonCount>5</LogonCount>
        <Password>
          <Value>$escPass</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
"@
    }

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="$Architecture"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>$escName</ComputerName>
      <TimeZone>$escTz</TimeZone>
    </component>
    <component name="Microsoft-Windows-TCPIP"
               processorArchitecture="$Architecture"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>$macDash</Identifier>
          <Ipv4Settings>
            <DhcpEnabled>false</DhcpEnabled>
            <RouterDiscoveryEnabled>false</RouterDiscoveryEnabled>
            <Metric>10</Metric>
          </Ipv4Settings>
          <UnicastIpAddresses>
            <IpAddress wcm:action="add" wcm:keyValue="1">$IPAddress</IpAddress>
          </UnicastIpAddresses>
$gatewayBlock        </Interface>
      </Interfaces>
    </component>
    <component name="Microsoft-Windows-DNS-Client"
               processorArchitecture="$Architecture"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>$macDash</Identifier>
          <DNSServerSearchOrder>
            <IpAddress wcm:action="add" wcm:keyValue="1">$DnsServer</IpAddress>
          </DNSServerSearchOrder>
          <DisableDynamicUpdate>false</DisableDynamicUpdate>
          <EnableAdapterDomainNameRegistration>true</EnableAdapterDomainNameRegistration>
        </Interface>
      </Interfaces>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="$Architecture"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="$Architecture"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$escPass</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
$autoLogonBlock      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Set every NIC profile to Private. winrm quickconfig refuses to run on Public, and Win11 client SKUs default the lab NIC to Public until manually classified.</Description>
          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>winrm quickconfig: configure the WinRM service + default HTTP listener + matching firewall rules. Server SKUs ship with this already done; Win11 client SKUs do not -- without it the engine cannot remote into the VM after first boot.</Description>
          <CommandLine>cmd.exe /c "winrm quickconfig -quiet -force"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Belt + braces: ensure WinRM is Automatic + running. winrm quickconfig usually starts it but the service can land in Manual/Stopped on some Win11 builds.</Description>
          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service -Name WinRM -ErrorAction SilentlyContinue"</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@

    $dir = Split-Path -Path $OutputPath -Parent
    if ($dir -and -not (Test-Path -Path $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }

    $utf8WithBom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($OutputPath, $xml, $utf8WithBom)
    return (Resolve-Path $OutputPath).Path
}
