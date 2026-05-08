function Start-HomeLab {
    <#
    .SYNOPSIS
        Start the lab VMs in dependency order: DC -> CM -> CLIENT, with
        configurable inter-VM delays so dependencies settle.

    .DESCRIPTION
        AL's Start-Lab boots everything at once and lets the auto-start
        delay do the sequencing. Our version is explicit: each VM is
        started, then we wait for WinRM-ready before starting the next.
        Net effect on a typical lab is 2-4 min total instead of relying
        on the 30/90/180s host-boot delays.

        -NoWait skips the Wait-LabVM gate; returns immediately after
        all three Start-VM calls (matches AL's behavior).

    .PARAMETER Config
        Pre-loaded config hashtable. Defaults to Get-LabConfig.

    .PARAMETER NoWait
        Skip Wait-LabVM gates between VMs.

    .EXAMPLE
        Start-HomeLab
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [hashtable]$Config,

        [Parameter()]
        [switch]$NoWait,

        [Parameter()]
        [securestring]$LabPassword
    )

    if (-not $Config) { $Config = Get-LabConfig }

    # Defer credential resolution: -NoWait skips Wait-LabVM entirely, so
    # Start-HomeLab -NoWait against a passwordless config should just
    # start the VMs without prompting. Resolve lazily on first wait.
    $cred = $null

    $order = @(
        @{ Name = $Config.DC.Name;     Fqdn = "$($Config.DC.Name).$($Config.DomainName)" }
        @{ Name = $Config.CM.Name;     Fqdn = "$($Config.CM.Name).$($Config.DomainName)" }
        @{ Name = $Config.Client.Name; Fqdn = "$($Config.Client.Name).$($Config.DomainName)" }
    )

    foreach ($entry in $order) {
        $vm = Get-VM -Name $entry.Name -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-LabLog "[$($entry.Name)] VM not found; skipping" -Status WARN
            continue
        }
        if ($vm.State -eq 'Running') {
            Write-LabLog "[$($entry.Name)] already running" -Status SKIP
            continue
        }

        Write-LabLog "[$($entry.Name)] Start-VM" -Status RUN
        Start-VM -Name $entry.Name -ErrorAction Stop

        if (-not $NoWait) {
            if (-not $cred) {
                $cred = Get-LabCredential -Identity Admin -Config $Config -LabPassword $LabPassword
            }
            $ok = Wait-LabVM -ComputerName $entry.Fqdn -Credential $cred -TimeoutSeconds 600
            if (-not $ok) {
                Write-LabLog "[$($entry.Name)] WinRM not ready within 10m; continuing" -Status WARN
            }
        }
    }
}
