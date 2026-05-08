function Install-LabHyperV {
    <#
    .SYNOPSIS
        Enable the Hyper-V Windows feature on the local host.

    .DESCRIPTION
        Bare-metal start. The engine assumes Hyper-V is NOT
        installed when integration testing begins, and stands it up
        itself. This function detects the host SKU (Server vs Client),
        invokes the appropriate feature-install API, and reports
        whether a reboot is required.

        Status values:
          NotRequired        - already enabled, no action taken
          EnabledRebootRequired - feature install succeeded, reboot pending
          EnabledNoReboot    - feature install succeeded, no reboot needed
                               (rare; usually a reboot IS required)

        Requires elevation.

    .PARAMETER RebootIfRequired
        Trigger a host reboot via Restart-Computer when the feature
        install reports a pending restart. Default: false (caller
        decides; the orchestrator typically handles reboots).

    .PARAMETER IncludeManagementTools
        On Server SKUs, request the management tools (Hyper-V Manager,
        Hyper-V PS module). Default: true. No-op on Client SKUs (the
        management tools are part of Microsoft-Hyper-V-All).

    .EXAMPLE
        $r = Install-LabHyperV
        if ($r.Status -eq 'EnabledRebootRequired') {
            Restart-Computer -Force
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [switch]$RebootIfRequired,

        [Parameter()]
        [bool]$IncludeManagementTools = $true
    )

    if (-not (Test-LabIsElevated)) {
        throw 'Install-LabHyperV: process must be elevated'
    }

    # SKU detection. ProductType: 1=Workstation, 2=DC, 3=Server.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $isServer = ($os.ProductType -ne 1)

    Write-LabLog "Detected SKU: $($os.Caption) (ProductType=$($os.ProductType))" -Level Verbose

    # Fast paths: a running hypervisor or the vmms service in Running
    # state is dispositive proof Hyper-V is already enabled. Skip the
    # DISM probe entirely -- on some client SKUs Get-WindowsOptionalFeature
    # -Online raises a terminating "Class not registered" COM error
    # even when Hyper-V is healthy and running.
    $skuLabel = if ($isServer) { 'Server' } else { 'Client' }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.HypervisorPresent) {
            Write-LabLog 'Hyper-V already running (HypervisorPresent=True)' -Status SKIP
            return [pscustomobject]@{
                Status = 'NotRequired'
                SKU = $skuLabel
                RebootRequired = $false
            }
        }
    } catch { }

    try {
        $vmms = Get-Service -Name vmms -ErrorAction Stop
        if ($vmms.Status -in 'Running','StartPending') {
            Write-LabLog "Hyper-V Virtual Machine Management service is $($vmms.Status); treating as installed" -Status SKIP
            return [pscustomobject]@{
                Status = 'NotRequired'
                SKU = $skuLabel
                RebootRequired = $false
            }
        }
    } catch { }

    if ($isServer) {
        $existing = if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
        }
        if ($existing -and $existing.InstallState -eq 'Installed') {
            Write-LabLog 'Hyper-V already installed' -Status SKIP
            return [pscustomobject]@{ Status = 'NotRequired'; SKU = 'Server'; RebootRequired = $false }
        }

        Write-LabLog 'Installing Hyper-V (Server feature) + management tools' -Status RUN
        $r = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools:$IncludeManagementTools -ErrorAction Stop
        if (-not $r.Success) {
            throw "Install-WindowsFeature Hyper-V failed: $($r | Out-String)"
        }

        $rebootRequired = [bool]$r.RestartNeeded -or $r.RestartNeeded -eq 'Yes'
        $status = if ($rebootRequired) { 'EnabledRebootRequired' } else { 'EnabledNoReboot' }

        Write-LabLog "Hyper-V installed; reboot required: $rebootRequired" -Status OK
        if ($rebootRequired -and $RebootIfRequired) {
            Write-LabLog 'Restarting host (caller requested -RebootIfRequired)' -Status WARN
            Restart-Computer -Force
        }
        return [pscustomobject]@{ Status = $status; SKU = 'Server'; RebootRequired = $rebootRequired }
    }

    # Client SKU (Windows 10 / 11 Pro / Enterprise / Education). The
    # fast paths above already short-circuited if Hyper-V is running;
    # only reach this DISM probe if the host genuinely has Hyper-V
    # disabled (or in a transitional state). Wrap defensively because
    # the COM provider can throw "Class not registered" on some SKUs.
    $existing = $null
    try {
        $existing = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop
    } catch {
        Write-LabLog "Get-WindowsOptionalFeature failed ($($_.Exception.Message)); falling through to Enable-WindowsOptionalFeature" -Status WARN
    }
    if ($existing -and $existing.State -eq 'Enabled') {
        Write-LabLog 'Microsoft-Hyper-V already enabled' -Status SKIP
        return [pscustomobject]@{ Status = 'NotRequired'; SKU = 'Client'; RebootRequired = $false }
    }

    Write-LabLog 'Enabling Microsoft-Hyper-V (Client feature, all sub-features)' -Status RUN
    $r = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -ErrorAction Stop
    $rebootRequired = [bool]$r.RestartNeeded
    $status = if ($rebootRequired) { 'EnabledRebootRequired' } else { 'EnabledNoReboot' }

    Write-LabLog "Microsoft-Hyper-V enabled; reboot required: $rebootRequired" -Status OK
    if ($rebootRequired -and $RebootIfRequired) {
        Write-LabLog 'Restarting host (caller requested -RebootIfRequired)' -Status WARN
        Restart-Computer -Force
    }
    return [pscustomobject]@{ Status = $status; SKU = 'Client'; RebootRequired = $rebootRequired }
}
