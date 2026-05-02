function Stop-HomeLab {
    <#
    .SYNOPSIS
        Stop the lab VMs in reverse-dependency order: CLIENT -> CM -> DC.

    .DESCRIPTION
        Tries graceful Stop-VM first; falls back to Stop-VM -TurnOff
        after -GracefulTimeoutSeconds. Reverse order matters because
        CM01 logs domain-controller chatter on shutdown; if DC01 is
        already off, those writes time out and add to shutdown
        latency.

    .PARAMETER Config
        Pre-loaded config hashtable. Defaults to Get-LabConfig.

    .PARAMETER GracefulTimeoutSeconds
        How long to wait for a clean Stop-VM before -TurnOff. Default
        120.

    .PARAMETER TurnOff
        Skip the graceful path; -TurnOff immediately.

    .EXAMPLE
        Stop-HomeLab
        Stop-HomeLab -TurnOff   # crash-stop everything
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [hashtable]$Config,

        [Parameter()]
        [ValidateRange(10, 1800)]
        [int]$GracefulTimeoutSeconds = 120,

        [Parameter()]
        [switch]$TurnOff
    )

    if (-not $Config) { $Config = Get-LabConfig }

    $reverse = @($Config.Client.Name, $Config.CM.Name, $Config.DC.Name)

    foreach ($name in $reverse) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { continue }
        if ($vm.State -eq 'Off') {
            Write-LabLog "[$name] already off" -Status SKIP
            continue
        }

        if ($TurnOff) {
            Write-LabLog "[$name] Stop-VM -TurnOff -Force" -Status RUN
            Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue
            continue
        }

        Write-LabLog "[$name] Stop-VM (graceful, ${GracefulTimeoutSeconds}s)" -Status RUN
        Stop-VM -Name $name -Force -ErrorAction SilentlyContinue

        $deadline = (Get-Date).AddSeconds($GracefulTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if (-not $vm -or $vm.State -eq 'Off') { break }
            Start-Sleep -Seconds 5
        }
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -ne 'Off') {
            Write-LabLog "[$name] graceful stop timed out; forcing TurnOff" -Status WARN
            Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue
        }
    }
}
