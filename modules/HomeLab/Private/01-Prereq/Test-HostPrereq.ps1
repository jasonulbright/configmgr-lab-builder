function Test-HostPrereq {
    <#
    .SYNOPSIS
        Verify the Hyper-V host meets HomeLab prerequisites.

    .DESCRIPTION
        Runs a battery of cheap checks against the local machine and returns
        a structured result. Does not modify host state. Logs each check via
        Write-LabLog.

        Checks:
          1. PowerShell version >= 7.6 LTS (orchestrator floor; see
             Install-HomeLab for the same hard throw -- ForEach-Object
             -Parallel and -ThrottleLimit are PS 7-only)
          2. Hyper-V is active. Fast path: HypervisorPresent / vmms
             running. Slow path: Get-WindowsFeature (Server) /
             Get-WindowsOptionalFeature (Client). DISM is only consulted
             when the hypervisor is not already loaded.
          3. Hyper-V module importable
          4. Total physical RAM >= MinRamGB (default 32)
          5. Free disk space on the volume holding LabImagePath >= MinFreeGB
             (default 100)
          6. CPU virtualization extensions enabled. Fast path:
             HypervisorPresent (the hypervisor cannot load without
             firmware virt). Fallback: Win32_Processor.VirtualizationFirmwareEnabled
             (only consulted when no hypervisor is loaded; this flag
             becomes unreliable once Hyper-V root partition is up).
          7. Process is elevated when -RequireElevation is set (Hyper-V ops need it)

        Returns [pscustomobject] with Pass=[bool] and Checks=[ordered]@{...}.

    .PARAMETER MinRamGB
        Minimum total physical RAM in GB. Default 32.

    .PARAMETER MinFreeGB
        Minimum free disk space on $LabImagePath volume. Default 100.

    .PARAMETER LabImagePath
        Folder where base images and lab VHDXs will be cached. Default
        C:\LabImages. Used only for the disk-space check; not created here.

    .PARAMETER RequireElevation
        Fail if the current process is not elevated.

    .PARAMETER WinRMProbeNames
        Lab VM names (short + FQDN) the engine will connect to over
        WinRM/NTLM. When provided, adds a check that the WinRM client's
        TrustedHosts covers every one of them (the host is not in the
        lab domain, so Negotiate falls back to NTLM and WinRM refuses
        the connection unless the target is trusted). Skipped when
        omitted. Found as real-host drift 2026-07-16: the engine
        depended on TrustedHosts without ever checking or documenting
        it; the host happened to have '*'.

    .EXAMPLE
        $r = Test-HostPrereq
        if (-not $r.Pass) { $r.Checks.GetEnumerator() | Where-Object { -not $_.Value.Pass } }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [int]$MinRamGB = 32,

        [Parameter()]
        [int]$MinFreeGB = 100,

        [Parameter()]
        [string]$LabImagePath = 'C:\LabImages',

        [Parameter()]
        [switch]$RequireElevation,

        [Parameter()]
        [string[]]$WinRMProbeNames,

        # Sum of the topology's VM startup memory. When provided, adds a
        # check that the host can actually allocate it RIGHT NOW:
        # available = free physical memory + memory currently assigned
        # to VMs named in the config (they get clobbered and re-created
        # by Phase 04, so their allocation comes back). Total-RAM >= 32GB
        # says nothing about a host whose desktop session holds 15GB --
        # the first two-clients deploy died at Phase 04 with 0x800705AA
        # "unable to allocate 4096 MB" (2026-07-17).
        [Parameter()]
        [long]$VMStartupMemoryBytes,

        [Parameter()]
        [string[]]$ConfigVMNames
    )

    $checks = [ordered]@{}

    # 1. PowerShell version -- orchestrator floor is 7.6 LTS.
    # ForEach-Object -Parallel (Install-HomeLab Phases 04 + 05) is PS 7-only,
    # so a 5.1 host will fail at runtime with a parameter-not-found error.
    # Fail the prereq early with a clear message instead.
    $psv = $PSVersionTable.PSVersion
    $psPass = $psv -ge [version]'7.6'
    $checks['PSVersion'] = [pscustomobject]@{
        Pass    = $psPass
        Value   = "$psv"
        Message = if ($psPass) { "PowerShell $psv" } else { "PowerShell $psv is below required 7.6 LTS (orchestrator uses ForEach-Object -Parallel)" }
    }

    # 2. Hyper-V feature. Fast paths first (instant) before falling
    # through to DISM (Get-WindowsOptionalFeature -Online is a 30-90s
    # cold call and on some client SKUs returns "Class not registered"
    # even when Hyper-V is healthy and running).
    $hvPass = $false
    $hvDetail = 'unknown'

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.HypervisorPresent) {
            $hvPass = $true
            $hvDetail = 'Hyper-V running (HypervisorPresent=True)'
        }
    } catch { }

    if (-not $hvPass) {
        try {
            $vmms = Get-Service -Name vmms -ErrorAction Stop
            if ($vmms.Status -in 'Running','StartPending') {
                $hvPass = $true
                $hvDetail = "Hyper-V Virtual Machine Management service is $($vmms.Status)"
            }
        } catch { }
    }

    if (-not $hvPass -and (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {
        try {
            $serverHv = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
            if ($serverHv -and $serverHv.InstallState -eq 'Installed') {
                $hvPass = $true
                $hvDetail = 'Hyper-V (Server feature) Installed'
            }
        } catch { }
    }

    if (-not $hvPass) {
        try {
            $clientHv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop
            if ($clientHv.State -eq 'Enabled') {
                $hvPass = $true
                $hvDetail = 'Microsoft-Hyper-V (Client feature) Enabled'
            } else {
                $hvDetail = "Microsoft-Hyper-V state: $($clientHv.State)"
            }
        } catch {
            $hvDetail = "Hyper-V probe failed: $($_.Exception.Message)"
        }
    }
    $checks['HyperVFeature'] = [pscustomobject]@{
        Pass    = $hvPass
        Value   = $hvDetail
        Message = $hvDetail
    }

    # 3. Hyper-V module importable
    $modPass = $false
    $modDetail = 'not available'
    try {
        $hvMod = Get-Module -Name Hyper-V -ListAvailable -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($hvMod) {
            $modPass = $true
            $modDetail = "Hyper-V module v$($hvMod.Version)"
        }
    } catch { }
    $checks['HyperVModule'] = [pscustomobject]@{
        Pass    = $modPass
        Value   = $modDetail
        Message = $modDetail
    }

    # 4. Physical RAM
    $ramBytes = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue |
        Measure-Object Capacity -Sum).Sum
    $ramGB = if ($ramBytes) { [math]::Round($ramBytes / 1GB, 0) } else { 0 }
    $ramPass = $ramGB -ge $MinRamGB
    $checks['RAM'] = [pscustomobject]@{
        Pass    = $ramPass
        Value   = "${ramGB}GB"
        Message = if ($ramPass) { "RAM ${ramGB}GB (>= ${MinRamGB}GB required)" } else { "RAM ${ramGB}GB below required ${MinRamGB}GB" }
    }

    # 5. Free disk on LabImagePath volume
    $imgRoot = if ([System.IO.Path]::IsPathRooted($LabImagePath)) {
        [System.IO.Path]::GetPathRoot($LabImagePath)
    } else { 'C:\' }
    $imgRoot = $imgRoot.TrimEnd('\')
    $imgDrive = $imgRoot.Substring(0, 1)
    $freeGB = 0
    try {
        $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${imgDrive}:'" -ErrorAction Stop
        $freeGB = [math]::Round($vol.FreeSpace / 1GB, 0)
    } catch { }
    $diskPass = $freeGB -ge $MinFreeGB
    $checks['FreeDisk'] = [pscustomobject]@{
        Pass    = $diskPass
        Value   = "${freeGB}GB free on ${imgDrive}:"
        Message = if ($diskPass) { "${freeGB}GB free on ${imgDrive}: (>= ${MinFreeGB}GB required)" } else { "${freeGB}GB free on ${imgDrive}: below required ${MinFreeGB}GB" }
    }

    # 6. CPU virt extensions. Fast path: a loaded hypervisor is
    # dispositive proof that firmware virt is enabled (the hypervisor
    # cannot start without it). Once Hyper-V is loaded, the
    # Win32_Processor.VirtualizationFirmwareEnabled flag becomes
    # unreliable -- the hypervisor virtualizes its own firmware-flag
    # fields away from non-root queries and the field often reads
    # False even on a healthy box. Only fall back to the CIM flag
    # when no hypervisor is loaded.
    $virtPass = $false
    $virtDetail = 'unknown'
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $cpuName = if ($cpu) { $cpu.Name } else { 'CPU' }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.HypervisorPresent) {
            $virtPass = $true
            $virtDetail = "$cpuName (hypervisor running, firmware virt enabled)"
        }
    } catch { }

    if (-not $virtPass) {
        if ($cpu) {
            $virtPass = [bool]$cpu.VirtualizationFirmwareEnabled
            $virtDetail = if ($virtPass) {
                "$cpuName (virt enabled)"
            } else {
                "$cpuName (virt extensions not enabled in firmware)"
            }
        } else {
            $virtDetail = 'CPU probe failed: Win32_Processor unavailable'
        }
    }
    $checks['VirtExtensions'] = [pscustomobject]@{
        Pass    = $virtPass
        Value   = $virtDetail
        Message = $virtDetail
    }

    # 7. Startup-memory budget (only checked when the caller passes the
    # topology's demand).
    if ($VMStartupMemoryBytes -gt 0) {
        $freeBytes = 0
        try {
            $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $freeBytes = [long]$osInfo.FreePhysicalMemory * 1KB
        } catch { }
        $reclaimBytes = 0
        if ($ConfigVMNames -and (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
            try {
                $reclaimBytes = (@(Get-VM -Name $ConfigVMNames -ErrorAction SilentlyContinue) |
                    Measure-Object MemoryAssigned -Sum).Sum
                if (-not $reclaimBytes) { $reclaimBytes = 0 }
            } catch { }
        }
        $availGB  = [math]::Round(($freeBytes + $reclaimBytes) / 1GB, 1)
        $demandGB = [math]::Round($VMStartupMemoryBytes / 1GB, 1)
        # 1GB margin: Hyper-V worker processes + host churn during a
        # 4-way parallel VM start.
        $memPass = ($freeBytes + $reclaimBytes) -ge ($VMStartupMemoryBytes + 1GB)
        $checks['MemoryBudget'] = [pscustomobject]@{
            Pass    = $memPass
            Value   = "${demandGB}GB demand / ${availGB}GB available"
            Message = if ($memPass) {
                "Topology startup memory ${demandGB}GB fits available ${availGB}GB (free + reclaimable lab VM memory)"
            } else {
                "Topology needs ${demandGB}GB startup memory but only ${availGB}GB is available (free + reclaimable lab VM memory). Close host applications or reduce VM Memory values in the config/template."
            }
        }
    }

    # 8. WinRM client TrustedHosts (only checked when probe names given).
    # The engine authenticates to lab VMs with NTLM from a non-domain
    # host; WinRM refuses that unless the target name is in TrustedHosts.
    # This dependency was previously implicit -- deploys only worked on
    # hosts where someone had set TrustedHosts by hand.
    if ($WinRMProbeNames) {
        $thPass = $false
        $thValue = ''
        $thMessage = ''
        try {
            $thValue = [string](Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
            if ($thValue -eq '*') {
                $thPass = $true
                $thMessage = "TrustedHosts is '*' (covers all lab VMs)"
            } else {
                $patterns = @($thValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $uncovered = @($WinRMProbeNames | Where-Object {
                    $name = $_
                    -not (@($patterns | Where-Object { $name -like $_ }).Count -gt 0)
                })
                $thPass = $uncovered.Count -eq 0
                $thMessage = if ($thPass) {
                    "TrustedHosts ('$thValue') covers all lab VM names"
                } else {
                    "TrustedHosts ('$thValue') does not cover: $($uncovered -join ', '). Fix (elevated): Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$(($patterns + $uncovered) -join ',')' -Force"
                }
            }
        } catch {
            $thMessage = "TrustedHosts unreadable ($($_.Exception.Message.Split([char]10)[0])). Fix (elevated): Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$($WinRMProbeNames -join ',')' -Force"
        }
        $checks['WinRMTrustedHosts'] = [pscustomobject]@{
            Pass    = $thPass
            Value   = $thValue
            Message = $thMessage
        }
    }

    # 9. Elevation (only checked when requested)
    if ($RequireElevation) {
        $elevPass = $false
        try {
            $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
            $elevPass = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { }
        $checks['Elevation'] = [pscustomobject]@{
            Pass    = $elevPass
            Value   = if ($elevPass) { 'elevated' } else { 'not elevated' }
            Message = if ($elevPass) { 'Process is elevated' } else { 'Process is NOT elevated; Hyper-V cmdlets will fail' }
        }
    }

    foreach ($k in $checks.Keys) {
        $c = $checks[$k]
        $status = if ($c.Pass) { 'OK' } else { 'FAIL' }
        Write-LabLog ("$k`: $($c.Message)") -Status $status -NoConsole:$false
    }

    [pscustomobject]@{
        Pass   = -not ($checks.Values | Where-Object { -not $_.Pass })
        Checks = $checks
    }
}
