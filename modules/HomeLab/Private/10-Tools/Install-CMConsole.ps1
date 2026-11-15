function Install-CMConsole {
    <#
    .SYNOPSIS
        Install the ConfigMgr console (and its PowerShell module) on a
        domain-joined VM.

    .DESCRIPTION
        The site server gets the console from site setup. Client VMs need
        it for console-based tests and tools. The installer is the
        ConsoleSetup folder that the site publishes at
        \\<site server>\SMS_<site code>\tools\ConsoleSetup. This function
        copies that folder to the VM with an explicit credential (a WinRM
        session cannot pass its identity to a second server), runs
        ConsoleSetup.exe silently, and removes the copy.

        Idempotent: when Microsoft.ConfigurationManagement.exe and
        ConfigurationManager.psd1 already exist, returns 'AlreadyInstalled'.

    .PARAMETER ComputerName
        VM that receives the console.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteServerFqdn
        FQDN of the site server, for example CM01.contoso.com.

    .PARAMETER SiteCode
        3-letter site code.

    .EXAMPLE
        Install-CMConsole -ComputerName CLIENT01 -DomainCredential $cred -SiteServerFqdn CM01.contoso.com -SiteCode MCM
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteServerFqdn,

        [Parameter(Mandatory)]
        [ValidateLength(3,3)]
        [string]$SiteCode
    )

    Write-LabLog "[$ComputerName] Installing the ConfigMgr console" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Install the ConfigMgr console' -ScriptBlock {
            param($SiteServerFqdn, $SiteCode, $Cred)

            $target = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Configuration Manager\AdminConsole'
            $exe = Join-Path $target 'bin\Microsoft.ConfigurationManagement.exe'
            $module = Join-Path $target 'bin\ConfigurationManager.psd1'
            if ((Test-Path -Path $exe) -and (Test-Path -Path $module)) {
                return [pscustomobject]@{ Status = 'AlreadyInstalled' }
            }

            $work = Join-Path $env:windir 'Temp\HomeLab-ConsoleSetup'
            $drive = 'HLConsoleSrc'
            try {
                New-Item -ItemType Directory -Path $work -Force | Out-Null
                New-PSDrive -Name $drive -PSProvider FileSystem `
                    -Root "\\$SiteServerFqdn\SMS_$SiteCode\tools\ConsoleSetup" -Credential $Cred -ErrorAction Stop | Out-Null
                Copy-Item -Path "${drive}:\*" -Destination $work -Recurse -Force -ErrorAction Stop
                $setup = Join-Path $work 'ConsoleSetup.exe'
                $p = Start-Process -FilePath $setup -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
                    '/q', "TargetDir=`"$target`"", "DefaultSiteServerName=$SiteServerFqdn", 'EnableSQM=0')
                if ($p.ExitCode -ne 0) { throw "ConsoleSetup.exe exited with code $($p.ExitCode)" }

                # ConsoleSetup returns before it finishes copying; wait for the files.
                $deadline = (Get-Date).AddMinutes(10)
                while (-not ((Test-Path -Path $exe) -and (Test-Path -Path $module)) -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 10
                }
                if (-not ((Test-Path -Path $exe) -and (Test-Path -Path $module))) {
                    throw 'ConsoleSetup finished but the console files are missing'
                }
            } finally {
                Remove-PSDrive -Name $drive -ErrorAction SilentlyContinue
                Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
            }

            # The module path variable is set by the installer; make it available
            # to later sessions without a reboot.
            [pscustomobject]@{ Status = 'Installed' }
        } -ArgumentList $SiteServerFqdn, $SiteCode, $DomainCredential

    Write-LabLog "[$ComputerName] ConfigMgr console: $($result.Status)" -Status OK
    return $result
}
