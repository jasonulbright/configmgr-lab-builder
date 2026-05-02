function Install-LabVcLatest {
    <#
    .SYNOPSIS
        Ensure every VM in the lab has the LATEST Microsoft Visual C++ v14
        Redistributable (x64 + x86) installed before anything else runs.

    .DESCRIPTION
        Pattern lifted from app-packager/Packagers/package-msvcruntimes.ps1.

        Why this runs in Phase 04 and not Phase 07:
          C++ runtime is foundational on Windows. SQL Server, MSOLEDBSQL19,
          ConfigMgr setup, ADK, WSUS -- almost every Microsoft installer
          probes for a minimum VC++ version and fails (silently or with
          MSI 1603) if it's older than required. Installing the latest
          Microsoft-served release on every VM at provision time means
          every downstream installer finds a recent-enough runtime, no
          version-dependency math required.

        Source URLs are Microsoft permalinks that always serve the
        current GA release:
          https://aka.ms/vc14/vc_redist.x64.exe
          https://aka.ms/vc14/vc_redist.x86.exe

        Detection: HKLM\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\
        VC\Runtimes\{X64,X86} -> Version (REG_SZ, format 'vMAJ.MIN.BUILD.00').
        The function compares the running version inside each VM against
        the host-staged installer's FileVersion and skips per-VM if the
        target is already up to date.

    .PARAMETER ComputerNames
        Short / FQDN names of the target VMs. Hits each in parallel.

    .PARAMETER Credential
        PSCredential the WinRM session uses to reach each VM.

    .PARAMETER StageRoot
        Host-side cache for the downloaded installers. Default
        '$env:TEMP\HomeLab-VcStage'. Re-runs of Install-LabVcLatest reuse
        the cached files unless StageRoot is empty.

    .PARAMETER ThrottleLimit
        Per-VM parallel install fan-out. Default 3.

    .PARAMETER ForceRefresh
        Always re-download from aka.ms (skip the StageRoot cache).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerNames,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [string]$StageRoot,

        [Parameter()]
        [int]$ThrottleLimit = 3,

        [Parameter()]
        [switch]$ForceRefresh
    )

    if (-not $StageRoot) { $StageRoot = Join-Path $env:TEMP 'HomeLab-VcStage' }
    if (-not (Test-Path $StageRoot)) {
        New-Item -Path $StageRoot -ItemType Directory -Force | Out-Null
    }

    $urlX64 = 'https://aka.ms/vc14/vc_redist.x64.exe'
    $urlX86 = 'https://aka.ms/vc14/vc_redist.x86.exe'
    $hostX64 = Join-Path $StageRoot 'vc_redist.x64.exe'
    $hostX86 = Join-Path $StageRoot 'vc_redist.x86.exe'

    # Always re-download if forced or missing. Cache on success.
    foreach ($pair in @(@{Url=$urlX64; Path=$hostX64}, @{Url=$urlX86; Path=$hostX86})) {
        if ($ForceRefresh -or -not (Test-Path $pair.Path)) {
            Write-LabLog "Downloading latest VC++ runtime: $($pair.Url)" -Status RUN
            try {
                $oldPP = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $pair.Url -OutFile $pair.Path -UseBasicParsing -ErrorAction Stop
            } finally { $ProgressPreference = $oldPP }
        }
    }

    $latestQuad = (Get-Item $hostX64).VersionInfo.FileVersion
    if (-not $latestQuad) { throw "Install-LabVcLatest: could not read FileVersion from $hostX64" }
    Write-LabLog "VC++ latest from MS: $latestQuad" -Status INFO

    # Per-VM install. Each VM checks its own installed version, skips if
    # already current, otherwise pushes both installers and runs them.
    $modulePath = (Get-Module HomeLab).Path
    $results = $ComputerNames | ForEach-Object -Parallel {
        Import-Module $using:modulePath -Force
        $cn        = $_
        $cred      = $using:Credential
        $hostX64   = $using:hostX64
        $hostX86   = $using:hostX86
        $expected  = $using:latestQuad

        Write-LabLog "[$cn] Probing installed VC++ runtime" -Status RUN
        $installed = Invoke-LabCommand -ComputerName $cn -Credential $cred -ScriptBlock {
            $key64 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64'
            $key86 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X86'
            $v64 = if (Test-Path $key64) { [string](Get-ItemProperty -Path $key64).Version } else { '' }
            $v86 = if (Test-Path $key86) { [string](Get-ItemProperty -Path $key86).Version } else { '' }
            "${v64}|${v86}"
        }
        $parts = ($installed -split '\|')
        $instX64 = if ($parts.Count -ge 1) { $parts[0] } else { '' }
        $instX86 = if ($parts.Count -ge 2) { $parts[1] } else { '' }

        # Registry value is 'vMAJ.MIN.BUILD.00'; expected version is quad
        # 'MAJ.MIN.BUILD.qfe'. Compare on (MAJ.MIN.BUILD).
        $expShort = ($expected -split '\.')[0..2] -join '.'
        $instShort = if ($instX64 -match '^v(\d+\.\d+\.\d+)') { $matches[1] } else { '' }

        if ($instShort -eq $expShort -and $instX86 -match $expShort) {
            Write-LabLog "[$cn] VC++ runtime current ($instShort) -- skipping" -Status SKIP
            return [pscustomobject]@{ ComputerName = $cn; Status = 'AlreadyCurrent'; Version = $instShort }
        }

        Write-LabLog "[$cn] VC++ runtime needs update: installed='$instShort' target='$expShort'" -Status RUN

        $session = New-PSSession -ComputerName $cn -Credential $cred -ErrorAction Stop
        try {
            # Fresh-VM safety: C:\Install does not exist on a sysprepped image.
            Invoke-Command -Session $session -ScriptBlock {
                if (-not (Test-Path 'C:\Install')) {
                    New-Item -Path 'C:\Install' -ItemType Directory -Force | Out-Null
                }
            } | Out-Null
            Copy-Item -ToSession $session -Path $hostX64 -Destination 'C:\Install\vc_redist.x64.exe' -Force
            Copy-Item -ToSession $session -Path $hostX86 -Destination 'C:\Install\vc_redist.x86.exe' -Force

            $exitCodes = Invoke-Command -Session $session -ScriptBlock {
                $r64 = Start-Process 'C:\Install\vc_redist.x64.exe' -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
                $r86 = Start-Process 'C:\Install\vc_redist.x86.exe' -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
                "$($r64.ExitCode)|$($r86.ExitCode)"
            }
            $codes = $exitCodes -split '\|'
            $okCodes = @('0','3010','1638')   # 1638 = newer version already installed
            if (($codes[0] -notin $okCodes) -or ($codes[1] -notin $okCodes)) {
                throw "[$cn] VC++ install failed: x64=$($codes[0]) x86=$($codes[1])"
            }
            $needsReboot = ($codes -contains '3010')
            Write-LabLog "[$cn] VC++ runtime updated to $expShort (rebootNeeded=$needsReboot)" -Status OK
            return [pscustomobject]@{ ComputerName = $cn; Status = 'Updated'; Version = $expShort; RebootNeeded = $needsReboot }
        } finally {
            Remove-PSSession $session -ErrorAction SilentlyContinue
        }
    } -ThrottleLimit $ThrottleLimit

    return $results
}
