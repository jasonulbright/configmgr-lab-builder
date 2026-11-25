function Install-LabWsusConsole {
    <#
    .SYNOPSIS
        Install the WSUS administration console and API on a lab VM, so
        the VM can publish updates to the WSUS server.

    .DESCRIPTION
        A tool that publishes local or third-party updates uses the WSUS
        administration API (Microsoft.UpdateServices.Administration.dll).
        The API comes with the WSUS console. The site server gets it from
        the WSUS role (Install-LabWsus, -IncludeManagementTools). Other VMs
        need it added:
          - Windows Server: Install-WindowsFeature UpdateServices-UI
            (Learn: troubleshoot-software-update-synchronization,
            "Verify prerequisites").
          - Windows client: the RSAT capability Rsat.WSUS.Tools~~~~0.0.1.0
            (Learn: install-remote-server-administration-tools).

        Idempotent: returns 'AlreadyInstalled' when the API assembly is
        already registered. Throws when the assembly is missing after the
        install.

    .PARAMETER ComputerName
        VM that receives the console.

    .PARAMETER DomainCredential
        Domain admin credential.

    .EXAMPLE
        Install-LabWsusConsole -ComputerName CLIENT01 -DomainCredential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential
    )

    Write-LabLog "[$ComputerName] Installing the WSUS administration console" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Install the WSUS administration console' -ScriptBlock {
            $capability = 'Rsat.WSUS.Tools~~~~0.0.1.0'
            $gac = Join-Path $env:windir 'Microsoft.NET\assembly\GAC_MSIL\Microsoft.UpdateServices.Administration'

            if (Test-Path -Path $gac) {
                return [pscustomobject]@{ Status = 'AlreadyInstalled' }
            }

            $isServer = ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1)
            if ($isServer) {
                $feat = Install-WindowsFeature -Name UpdateServices-UI -ErrorAction Stop
                if (-not $feat.Success) { throw "Install-WindowsFeature UpdateServices-UI failed: $($feat | Out-String)" }
            } else {
                $cap = Add-WindowsCapability -Online -Name $capability -ErrorAction Stop
                if ($cap.RestartNeeded) { Write-Warning 'The WSUS console install asks for a restart.' }
            }

            if (-not (Test-Path -Path $gac)) {
                throw 'The WSUS administration API (Microsoft.UpdateServices.Administration) is missing after the install'
            }
            [pscustomobject]@{ Status = 'Installed' }
        }

    Write-LabLog "[$ComputerName] WSUS console: $($result.Status)" -Status OK
    return $result
}
