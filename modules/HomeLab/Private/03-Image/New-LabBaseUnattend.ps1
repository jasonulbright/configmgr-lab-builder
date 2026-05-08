function New-LabBaseUnattend {
    <#
    .SYNOPSIS
        Generate the Unattend.xml injected into a base image VHDX before
        first boot.

    .DESCRIPTION
        Produces an Unattend.xml whose only job is to drive a sysprep
        /generalize /shutdown on first boot, leaving a generalized image
        suitable as a differencing-VHDX parent.

        Three settings passes are emitted:
          - oobeSystem: skip every OOBE prompt, set en-US locale, set the
            local Administrator password, enable a one-shot AutoLogon
          - oobeSystem FirstLogonCommands: run sysprep.exe /generalize /oobe
            /shutdown /quiet so the VM powers itself down sysprepped
          - specialize: bare minimum (just so the schema is happy)

        The Unattend is meant for the BASE image only. Each per-VM unattend
        (computer name, domain join, IP) is generated separately by
        New-Unattend.ps1 in S2.

    .PARAMETER Architecture
        amd64 / x86 / arm64. Default amd64.

    .PARAMETER AdministratorPassword
        Plain-text password for the local Administrator. The Unattend.xml
        embeds this in the AdministratorPassword/AutoLogon Plain text fields.

    .PARAMETER OutputPath
        File path to write. Encoding is UTF-8 with BOM (Windows Setup
        requirement; setup.exe rejects no-BOM UTF-8 in unattend.xml).

    .EXAMPLE
        New-LabBaseUnattend -AdministratorPassword 'P@ssw0rd!' -OutputPath C:\Temp\base-unattend.xml
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateSet('amd64','x86','arm64')]
        [string]$Architecture = 'amd64',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AdministratorPassword,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath
    )

    # XML-escape the password (passwords with & < > " ' would otherwise break
    # the Unattend parser). Using SecurityElement.Escape covers all 5 entities.
    $escPass = [System.Security.SecurityElement]::Escape($AdministratorPassword)

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
      <TimeZone>UTC</TimeZone>
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
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <LogonCount>1</LogonCount>
        <Password>
          <Value>$escPass</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Sysprep generalize and shutdown for base image</Description>
          <CommandLine>cmd /c %SystemRoot%\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
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

    # Windows Setup REQUIRES a UTF-8 BOM in unattend.xml. PS 7's
    # Set-Content -Encoding UTF8 is BOM-less; use the explicit encoding
    # constructor so behavior is identical across 5.1 / 7.x.
    $utf8WithBom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($OutputPath, $xml, $utf8WithBom)
    return (Resolve-Path $OutputPath).Path
}
