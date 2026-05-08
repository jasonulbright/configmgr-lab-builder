function Install-LabAdk {
    <#
    .SYNOPSIS
        Install the Windows ADK from an offline layout inside a lab VM.

    .DESCRIPTION
        CM 2509 needs the Windows Assessment and Deployment Kit for
        OSD task sequences and boot media. The ADK is normally a small
        bootstrapper (adksetup.exe) that downloads ~1.5 GB of feature
        bits at install time -- which fails on internal-only lab VMs.

        Uses adksetup.exe /layout to pre-stage the bits
        on the host into LabSources\SoftwarePackages\ADK\Offline.
        This function pushes that layout to the VM and runs the
        installer in offline mode against it.

        Default features: Deployment Tools + USMT (the CM minimum).
        Pass -Features to override.

    .PARAMETER ComputerName
        Target VM.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER OfflineLayoutPath
        HOST path to the ADK offline layout folder (must contain
        Installers\ + adksetup.exe at the root).

    .PARAMETER InstallPath
        Target install path on the VM. Default
        'C:\Program Files (x86)\Windows Kits\10'.

    .PARAMETER Features
        Adksetup OptionId tokens. Default Deployment Tools + USMT.

    .EXAMPLE
        Install-LabAdk -ComputerName CM01 -DomainCredential $cred `
                       -OfflineLayoutPath C:\LabSources\SoftwarePackages\ADK\Offline
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
        [string]$InstallPath = 'C:\Program Files (x86)\Windows Kits\10',

        [Parameter()]
        [string[]]$Features = @(
            'OptionId.DeploymentTools'
            'OptionId.UserStateMigrationTool'
        )
    )

    if (-not (Test-Path -Path $OfflineLayoutPath -PathType Container)) {
        throw "Install-LabAdk: offline layout not found: $OfflineLayoutPath"
    }
    $hostSetup = Join-Path $OfflineLayoutPath 'adksetup.exe'
    if (-not (Test-Path -Path $hostSetup -PathType Leaf)) {
        throw "Install-LabAdk: adksetup.exe missing from layout: $hostSetup"
    }

    $remoteLayout = 'C:\Install\ADK'
    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
        param($d)
        if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $d -ItemType Directory -Force | Out-Null
    } -ArgumentList $remoteLayout | Out-Null

    Write-LabLog "[$ComputerName] Pushing ADK offline layout (this may take several minutes)" -Status RUN
    Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                 -Path $OfflineLayoutPath -Destination $remoteLayout -Recurse `
                 -Activity 'Push ADK offline layout'

    Write-LabLog "[$ComputerName] Running adksetup.exe (features: $($Features -join ', '))" -Status RUN
    $exit = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            param($Layout, $InstallPath, $Features)
            $setup = Get-ChildItem -Path $Layout -Filter 'adksetup.exe' -Recurse -ErrorAction Stop |
                Select-Object -First 1
            if (-not $setup) { throw 'adksetup.exe not found in pushed layout' }

            $args = @(
                '/quiet', '/norestart',
                '/installpath', "`"$InstallPath`"",
                '/features'
            ) + $Features

            $p = Start-Process -FilePath $setup.FullName -ArgumentList $args -Wait -PassThru -NoNewWindow
            return $p.ExitCode
        } -ArgumentList $remoteLayout, $InstallPath, $Features

    $tag = switch ($exit) { 0 { 'OK' } 3010 { 'WARN' } default { 'FAIL' } }
    Write-LabLog "[$ComputerName] ADK exit $exit" -Status $tag

    if ($exit -notin 0, 3010) {
        throw "Install-LabAdk: adksetup returned $exit on $ComputerName"
    }

    return [pscustomobject]@{
        ExitCode       = $exit
        RebootRequired = ($exit -eq 3010)
        InstallPath    = $InstallPath
        Features       = $Features
    }
}
