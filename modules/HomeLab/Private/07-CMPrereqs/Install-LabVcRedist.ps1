function Install-LabVcRedist {
    <#
    .SYNOPSIS
        Install the Visual C++ 14.50 redistributable (x64 + x86) inside
        a lab VM.

    .DESCRIPTION
        SQL 2022 and CM 2509 both need VC++ 14.50 (the latest VS 2015-
        2022 redist line). Older lab automation pinned the URLs to
        https://aka.ms/vs/18/release/vc_redist.x64.exe and ...x86.exe;
        we keep that.

        The CM-Prereqs reboot dance: VC++ exits 3010 (reboot required)
        whenever it actually installed. ODBC and MSOLEDB MSIs detect a
        pending-reboot state as a CRITICAL (not Warning) prereq error
        and refuse to install. So the orchestrator MUST reboot between
        VC++ and ODBC/MSOLEDB.

        This function handles the install but does NOT reboot. It
        returns RebootRequired=true when either arch reported 3010,
        and the caller (Install-CMPrereqs in S6 or the user) reboots
        before proceeding.

    .PARAMETER ComputerName
        DNS / short name of the target VM.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER X64Path
        Path on the HOST to vc_redist.x64.exe.

    .PARAMETER X86Path
        Path on the HOST to vc_redist.x86.exe. Optional -- if omitted
        only x64 is installed (CM doesn't strictly need x86, but the
        Both runtimes installed for parity.)

    .EXAMPLE
        Install-LabVcRedist -ComputerName CM01 -DomainCredential $cred `
            -X64Path C:\LabSources\SoftwarePackages\vc_redist.x64.exe `
            -X86Path C:\LabSources\SoftwarePackages\vc_redist.x86.exe
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
        [string]$X64Path,

        [Parameter()]
        [string]$X86Path
    )

    foreach ($p in @($X64Path, $X86Path) | Where-Object { $_ }) {
        if (-not (Test-Path -Path $p -PathType Leaf)) {
            throw "Install-LabVcRedist: source not found: $p"
        }
    }

    $remoteDir = 'C:\Install\VCRedist'
    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
        param($d)
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    } -ArgumentList $remoteDir | Out-Null

    $result = [pscustomobject]@{
        X64ExitCode    = $null
        X86ExitCode    = $null
        RebootRequired = $false
    }

    foreach ($entry in @(
        @{ Path = $X64Path; Arch = 'x64'; ResultProp = 'X64ExitCode' }
        @{ Path = $X86Path; Arch = 'x86'; ResultProp = 'X86ExitCode' }
    )) {
        if (-not $entry.Path) { continue }

        $remotePath = Join-Path $remoteDir (Split-Path $entry.Path -Leaf)
        Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                     -Path $entry.Path -Destination $remotePath `
                     -Activity "Push VC++ $($entry.Arch)"

        Write-LabLog "[$ComputerName] Running VC++ $($entry.Arch)" -Status RUN
        $exit = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
            -ScriptBlock {
                param($exe)
                $p = Start-Process -FilePath $exe -ArgumentList @('/quiet', '/norestart') -Wait -PassThru -NoNewWindow
                return $p.ExitCode
            } -ArgumentList $remotePath

        $result.($entry.ResultProp) = $exit
        if ($exit -eq 3010) { $result.RebootRequired = $true }

        if ($exit -notin 0, 1638, 3010) {
            # 0 = installed, 3010 = installed + reboot, 1638 = newer present.
            throw "Install-LabVcRedist: VC++ $($entry.Arch) returned $exit on $ComputerName"
        }

        $tag = switch ($exit) { 0 { 'OK' } 3010 { 'WARN' } 1638 { 'SKIP' } default { 'WARN' } }
        Write-LabLog "[$ComputerName] VC++ $($entry.Arch) exit $exit" -Status $tag
    }

    # Belt-and-suspenders: VC++ usually returns 3010 when a reboot is needed,
    # but a host with pre-existing pending-reboot state (e.g. recent Windows
    # Update) can leave the standard CBS / WindowsUpdate keys set without any
    # of our installers returning 3010. ODBC + MSOLEDB MSIs detect that as a
    # CRITICAL prereq error and refuse to install. So check the well-known
    # registry locations and force RebootRequired if either is present.
    if (-not $result.RebootRequired) {
        $pending = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
            $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            $wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
            $pfr = $false
            try {
                $pfr = [bool](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop)
            } catch { }
            [pscustomobject]@{ CBS = $cbs; WU = $wu; PFR = $pfr; Any = ($cbs -or $wu -or $pfr) }
        }
        if ($pending.Any) {
            Write-LabLog "[$ComputerName] VC++ exit codes were clean but pending-reboot detected (CBS=$($pending.CBS) WU=$($pending.WU) PFR=$($pending.PFR)); flagging for reboot before next prereq" -Status WARN
            $result.RebootRequired = $true
        }
    }

    return $result
}
