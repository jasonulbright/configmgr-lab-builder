function Install-LabAdkPe {
    <#
    .SYNOPSIS
        Install the WinPE add-on for Windows ADK from an offline
        layout inside a lab VM.

    .DESCRIPTION
        Separate from the main ADK because Microsoft split WinPE out
        in ADK 2004+. CM 2509 needs WinPE for boot media; without it,
        OSD task sequences fail.

        Same offline-layout pattern as Install-LabAdk: pre-staged on
        the host via adkwinpesetup.exe /layout, then pushed to the VM.

    .PARAMETER ComputerName
        Target VM.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER OfflineLayoutPath
        HOST path to the WinPE offline layout folder.

    .PARAMETER InstallPath
        Default 'C:\Program Files (x86)\Windows Kits\10'.

    .EXAMPLE
        Install-LabAdkPe -ComputerName CM01 -DomainCredential $cred `
                         -OfflineLayoutPath C:\LabSources\SoftwarePackages\ADKPE\Offline
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OfflineLayoutPath,

        [Parameter()]
        [string]$InstallPath = 'C:\Program Files (x86)\Windows Kits\10'
    )

    if (-not (Test-Path -Path $OfflineLayoutPath -PathType Container)) {
        throw "Install-LabAdkPe: offline layout not found: $OfflineLayoutPath"
    }

    $remoteLayout = 'C:\Install\ADKPE'
    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
        param($d)
        if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $d -ItemType Directory -Force | Out-Null
    } -ArgumentList $remoteLayout | Out-Null

    Write-LabLog "[$ComputerName] Pushing WinPE offline layout" -Status RUN
    Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                 -Path $OfflineLayoutPath -Destination $remoteLayout -Recurse `
                 -Activity 'Push WinPE offline layout'

    Write-LabLog "[$ComputerName] Running adkwinpesetup.exe" -Status RUN
    $exit = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            param($Layout, $InstallPath)
            $setup = Get-ChildItem -Path $Layout -Filter 'adkwinpesetup.exe' -Recurse -ErrorAction Stop |
                Select-Object -First 1
            if (-not $setup) { throw 'adkwinpesetup.exe not found in pushed layout' }

            $args = @(
                '/quiet', '/norestart',
                '/installpath', "`"$InstallPath`"",
                '/features', 'OptionId.WindowsPreinstallationEnvironment'
            )

            $p = Start-Process -FilePath $setup.FullName -ArgumentList $args -Wait -PassThru -NoNewWindow
            return $p.ExitCode
        } -ArgumentList $remoteLayout, $InstallPath

    $tag = switch ($exit) { 0 { 'OK' } 3010 { 'WARN' } default { 'FAIL' } }
    Write-LabLog "[$ComputerName] WinPE add-on exit $exit" -Status $tag

    if ($exit -notin 0, 3010) {
        throw "Install-LabAdkPe: adkwinpesetup returned $exit on $ComputerName"
    }

    return [pscustomobject]@{
        ExitCode       = $exit
        RebootRequired = ($exit -eq 3010)
        InstallPath    = $InstallPath
    }
}
