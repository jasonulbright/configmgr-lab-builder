function Set-LabAutoStartStop {
    <#
    .SYNOPSIS
        Set Hyper-V automatic-start / -stop policy on each lab VM.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 8 (lines 1037-1045). Runs on
        the HOST (Set-VM is a Hyper-V cmdlet). Per-VM start delays
        let the dependency chain settle:

          DC01:     30s  (AD/DNS up first)
          CM01:     90s  (after DC)
          CLIENT01: 180s (after DC + CM)

        Default actions: Start on host boot, ShutDown on host stop.

        NO snapshot is taken here. An earlier approach captured a
        Deployment-Complete snapshot per VM; per the bare-metal-build
        rule (feedback_homelab_build_from_bare_metal.md) snapshots
        are not part of this engine's responsibility.

        Requires elevation (Hyper-V cmdlets).

    .PARAMETER VMs
        Array of [pscustomobject]@{ Name; AutoStartDelay } entries.
        Pass the parsed config.psd1 DC/CM/Client triples.

    .PARAMETER AutoStartAction
        Default 'Start'. Other valid: 'Nothing', 'StartIfRunning'.

    .PARAMETER AutoStopAction
        Default 'ShutDown'. Other valid: 'TurnOff', 'Save'.

    .EXAMPLE
        $cfg = Get-LabConfig
        Set-LabAutoStartStop -VMs @(
            [pscustomobject]@{ Name = $cfg.DC.Name;     AutoStartDelay = $cfg.DC.AutoStartDelay }
            [pscustomobject]@{ Name = $cfg.CM.Name;     AutoStartDelay = $cfg.CM.AutoStartDelay }
            [pscustomobject]@{ Name = $cfg.Client.Name; AutoStartDelay = $cfg.Client.AutoStartDelay }
        )
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object[]]$VMs,

        [Parameter()]
        [ValidateSet('Nothing','StartIfRunning','Start')]
        [string]$AutoStartAction = 'Start',

        [Parameter()]
        [ValidateSet('TurnOff','Save','ShutDown')]
        [string]$AutoStopAction = 'ShutDown'
    )

    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Set-LabAutoStartStop: process must be elevated; Set-VM requires admin'
    }

    foreach ($vm in $VMs) {
        $name  = [string]$vm.Name
        $delay = if ($vm.AutoStartDelay) { [int]$vm.AutoStartDelay } else { 30 }

        $live = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $live) {
            Write-LabLog "Set-LabAutoStartStop: VM '$name' not found; skipping" -Status WARN
            continue
        }

        Set-VM -Name $name `
               -AutomaticStartAction $AutoStartAction `
               -AutomaticStartDelay  $delay `
               -AutomaticStopAction  $AutoStopAction `
               -ErrorAction Stop

        Write-LabLog "[$name] auto-start=$AutoStartAction (${delay}s); auto-stop=$AutoStopAction" -Status OK
    }
}
