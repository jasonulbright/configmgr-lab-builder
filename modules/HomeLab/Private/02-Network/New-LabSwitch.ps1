function New-LabSwitch {
    <#
    .SYNOPSIS
        Idempotently ensure a Hyper-V virtual switch exists for the lab.

    .DESCRIPTION
        Creates an Internal-type vSwitch named $Name if it does not already
        exist. Returns the switch object either way. Also verifies the
        built-in 'Default Switch' is present (Hyper-V always provides it on
        Windows 10/11 and Server 2025+); throws if it is missing because
        the lab depends on Default Switch NAT for VM internet access
        and Eval activation.

        Internal type (no External binding to the host NIC) keeps the lab
        subnet isolated. Activation traffic flows over the Default Switch
        NIC each VM also has attached.

    .PARAMETER Name
        Switch name (e.g. 'HomeLab-Network').

    .PARAMETER NotesText
        Optional Notes string set on the switch for traceability.

    .PARAMETER HostIPAddress
        Static IPv4 + prefix to assign to the host's auto-created
        vEthernet (<Name>) NIC. Without this, the host's NIC stays at
        APIPA (169.254.x.x/16) and the host cannot route to lab VMs --
        Test-NetConnection / WinRM / Invoke-Command all fail at the
        network layer regardless of how the VMs are configured. The
        homelab convention is 192.168.50.1/24 (matching the .50 subnet
        the default config.psd1 uses; the DC sits at .10 and is the
        gateway for VMs, but the host needs its own .1 to participate).
        Pass empty string to skip (e.g. when re-running after manual
        host networking).

    .EXAMPLE
        New-LabSwitch -Name 'HomeLab-Network'
    #>
    [CmdletBinding()]
    # String form, not a type literal: attribute type literals resolve at
    # first invocation and do NOT auto-load the Hyper-V module, so on a
    # fresh session [Microsoft.HyperV.PowerShell.VMSwitch] throws
    # "Unable to find type" before the function body ever runs.
    [OutputType('Microsoft.HyperV.PowerShell.VMSwitch')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter()]
        [string]$NotesText = 'HomeLab lab-internal switch',

        [Parameter()]
        [AllowEmptyString()]
        [string]$HostIPAddress = '192.168.50.1/24'
    )

    $defaultSwitch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if (-not $defaultSwitch) {
        throw "New-LabSwitch: 'Default Switch' is missing. Hyper-V should provide this automatically on Windows 10/11 and Server 2025+. Reinstall the Hyper-V feature."
    }

    $existing = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LabLog "Switch '$Name' already present (id $($existing.Id))" -Status SKIP
        # Stamp the Notes marker on pre-existing switches (e.g. created
        # by hand or by an older engine version). Remove-HomeLab and
        # tools/Audit-HomeLabArtifacts.ps1 use this marker to recognize
        # lab switches even after a LabName rename; a switch without it
        # can only be found by its current name. Observed on the real
        # host 2026-07-16: HomeLab-Network existed with empty Notes.
        if ($NotesText -and $existing.Notes -ne $NotesText) {
            try {
                Set-VMSwitch -Name $Name -Notes $NotesText -ErrorAction Stop
                Write-LabLog "Switch '$Name' Notes marker stamped" -Status OK
            } catch {
                Write-LabLog "Switch '$Name' Notes stamp failed (detection falls back to name): $($_.Exception.Message)" -Status WARN
            }
        }
        $sw = $existing
    } else {
        Write-LabLog "Creating Internal vSwitch '$Name'" -Status RUN
        $sw = New-VMSwitch -Name $Name -SwitchType Internal -Notes $NotesText -ErrorAction Stop
        Write-LabLog "Switch '$Name' created (id $($sw.Id))" -Status OK
    }

    if ($HostIPAddress) {
        # Internal vSwitches auto-create a host vEthernet adapter named
        # "vEthernet (<switch>)". Assign it a lab-subnet IP so the host
        # can route to VMs.
        if ($HostIPAddress -notmatch '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$') {
            throw "New-LabSwitch: HostIPAddress must be CIDR (e.g. '192.168.50.1/24'); got '$HostIPAddress'"
        }
        $ip,$prefix = $HostIPAddress -split '/'
        $hostAlias = "vEthernet ($Name)"

        # Wait briefly for the auto-created host adapter to appear.
        $deadline = (Get-Date).AddSeconds(15)
        do {
            $hostAdapter = Get-NetAdapter -Name $hostAlias -ErrorAction SilentlyContinue
            if ($hostAdapter) { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)

        if (-not $hostAdapter) {
            Write-LabLog "Host vEthernet '$hostAlias' did not appear within 15s; skipping IP assign" -Status WARN
        } else {
            $existing = Get-NetIPAddress -InterfaceAlias $hostAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.PrefixOrigin -ne 'WellKnown' }
            $alreadyOk = @($existing | Where-Object { $_.IPAddress -eq $ip -and $_.PrefixLength -eq [int]$prefix }).Count -gt 0

            if ($alreadyOk) {
                Write-LabLog "Host '$hostAlias' already at $HostIPAddress" -Status SKIP
            } else {
                # Drop any prior non-APIPA IPs first (avoid stacking).
                foreach ($old in @($existing)) {
                    Remove-NetIPAddress -InterfaceAlias $hostAlias -IPAddress $old.IPAddress `
                        -Confirm:$false -ErrorAction SilentlyContinue
                }
                New-NetIPAddress -InterfaceAlias $hostAlias `
                    -IPAddress $ip -PrefixLength ([int]$prefix) `
                    -AddressFamily IPv4 -ErrorAction Stop | Out-Null
                Write-LabLog "Host '$hostAlias' assigned $HostIPAddress" -Status OK
            }
        }
    }

    return $sw
}
