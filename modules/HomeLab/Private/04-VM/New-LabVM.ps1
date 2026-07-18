function New-LabVM {
    <#
    .SYNOPSIS
        Provision a single lab VM from a cached base image, end-to-end.

    .DESCRIPTION
        The S2 alpha exit criterion: New-LabVM -Name CLIENT01 -... boots a
        Windows VM in <5 min from a cached differencing parent, with static
        IP, WinRM-reachable, ready for follow-on phases.

        Steps:
          1. Differencing VHDX from $ParentVhdx via New-LabVhdx
          2. New-VM (Generation 2, attach VHDX, no NIC yet -- the default
             NIC is removed and replaced with explicit ones in step 4 so
             MAC pinning is deterministic)
          3. Set-VM dynamic memory + processor count + auto-start/stop
          4. Add LAB NIC (Internal switch) with pinned static MAC
             Add NAT NIC (Default Switch, DHCP)
          5. Generate per-VM Unattend.xml (New-Unattend) with the lab MAC
          6. Mount-LabUnattend injects it into Panther
          7. Start-VM
          8. Wait-LabVM blocks until WinRM round-trip succeeds

        Idempotent vs an existing VM with the same name: pass -Force to
        remove and re-create. Without -Force, throws if the VM exists.

        Requires elevation (Hyper-V cmdlets).

    .PARAMETER VMName
        15-char NetBIOS-safe name. Used as the Hyper-V VM name AND injected
        as the Windows ComputerName in Unattend.

    .PARAMETER ParentVhdx
        Path to the cached sysprepped base image VHDX. Produced by
        New-LabBaseImage.

    .PARAMETER LabSwitchName
        Internal vSwitch name for the lab subnet (e.g. 'HomeLab-Network').

    .PARAMETER DefaultSwitchName
        NAT-providing switch name. Default 'Default Switch'.

    .PARAMETER LabIP
        Static IPv4 in CIDR form (e.g. '192.168.50.20/24').

    .PARAMETER Gateway
        Optional default-gateway IPv4.

    .PARAMETER DnsServer
        DNS server IPv4 (typically the DC).

    .PARAMETER LabNicMac
        12-hex MAC for the lab NIC, any common format. Pin a deterministic
        MAC so Unattend can target the right NIC.

    .PARAMETER MemoryStartupBytes
        Hyper-V startup memory (e.g. 10GB).

    .PARAMETER MinMemoryBytes
        Dynamic memory floor.

    .PARAMETER MaxMemoryBytes
        Dynamic memory ceiling.

    .PARAMETER ProcessorCount
        vCPU count.

    .PARAMETER OSDiskSize
        Optional disk size in GB. The differencing child is resized to
        this if larger than the base.

    .PARAMETER AdministratorPassword
        Local Administrator password baked into Unattend.xml.

    .PARAMETER LabImagePath
        Folder for VM VHDXs. Default C:\LabImages.

    .PARAMETER AutoStartAction
        Hyper-V automatic-start policy. Default Start.

    .PARAMETER AutoStartDelay
        Seconds to delay autostart on host boot.

    .PARAMETER AutoStopAction
        Hyper-V automatic-stop policy. Default ShutDown.

    .PARAMETER WinRMTimeoutSeconds
        How long Wait-LabVM blocks after Start-VM. Default 600.

    .PARAMETER NoWait
        Skip the Wait-LabVM gate (returns immediately after Start-VM).

    .PARAMETER Force
        Remove an existing VM with this name first.

    .EXAMPLE
        $cfg = Get-LabConfig
        New-LabVM `
            -VMName             CM01 `
            -ParentVhdx         C:\LabImages\<key>.base.vhdx `
            -LabSwitchName      'HomeLab-Network' `
            -LabIP              '192.168.50.20/24' `
            -Gateway            '192.168.50.10' `
            -DnsServer          '192.168.50.10' `
            -LabNicMac          '00-15-5D-AB-50-20' `
            -MemoryStartupBytes 10GB `
            -MinMemoryBytes     4GB `
            -MaxMemoryBytes     12GB `
            -ProcessorCount     4 `
            -OSDiskSize         150 `
            -AdministratorPassword $cfg.AdminPass
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 15)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ParentVhdx,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LabSwitchName,

        [Parameter()]
        [string]$DefaultSwitchName = 'Default Switch',

        [Parameter(Mandatory)]
        [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
        [string]$LabIP,

        [Parameter()]
        [string]$Gateway,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')]
        [string]$DnsServer,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LabNicMac,

        [Parameter(Mandatory)]
        [long]$MemoryStartupBytes,

        [Parameter(Mandatory)]
        [long]$MinMemoryBytes,

        [Parameter(Mandatory)]
        [long]$MaxMemoryBytes,

        [Parameter(Mandatory)]
        [ValidateRange(1, 64)]
        [int]$ProcessorCount,

        [Parameter()]
        [int]$OSDiskSize,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AdministratorPassword,

        [Parameter()]
        [string]$LabImagePath = 'C:\LabImages',

        [Parameter()]
        [ValidateSet('Nothing','StartIfRunning','Start')]
        [string]$AutoStartAction = 'Start',

        [Parameter()]
        [int]$AutoStartDelay = 30,

        [Parameter()]
        [ValidateSet('TurnOff','Save','ShutDown')]
        [string]$AutoStopAction = 'ShutDown',

        [Parameter()]
        [int]$WinRMTimeoutSeconds = 600,

        [Parameter()]
        [switch]$NoWait,

        [Parameter()]
        [switch]$Force
    )

    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'New-LabVM: process must be elevated; Hyper-V cmdlets require admin'
    }

    if ($MinMemoryBytes -gt $MaxMemoryBytes) {
        throw "New-LabVM: MinMemoryBytes ($MinMemoryBytes) exceeds MaxMemoryBytes ($MaxMemoryBytes)"
    }

    # Switches must be present.
    $labSwitch = Get-VMSwitch -Name $LabSwitchName -ErrorAction SilentlyContinue
    if (-not $labSwitch) {
        throw "New-LabVM: lab vSwitch '$LabSwitchName' not found. Run New-LabSwitch first."
    }
    $natSwitch = Get-VMSwitch -Name $DefaultSwitchName -ErrorAction SilentlyContinue
    if (-not $natSwitch) {
        throw "New-LabVM: NAT vSwitch '$DefaultSwitchName' not found."
    }

    # Existing-VM handling.
    $existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($Force) {
            Write-LabLog "Removing existing VM '$VMName' (-Force)" -Status WARN
            if ($existing.State -ne 'Off') {
                Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
            }
            Remove-VM -Name $VMName -Force -ErrorAction Stop
        } else {
            throw "New-LabVM: VM '$VMName' already exists (pass -Force to recreate)"
        }
    }

    $macPlain = Format-LabMacAddress -Mac $LabNicMac -Format Plain
    $macDash  = Format-LabMacAddress -Mac $LabNicMac -Format Dash

    # 1. Differencing VHDX
    $vhdx = New-LabVhdx -VMName $VMName -ParentVhdx $ParentVhdx -LabImagePath $LabImagePath -OSDiskSize:$OSDiskSize -Force:$Force

    # 2. New-VM (Generation 2; we add NICs explicitly below so the default
    # NIC's random MAC doesn't pollute the lineup)
    Write-LabLog "Creating VM '$VMName' (Gen2)" -Status RUN
    $vm = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes `
                 -VHDPath $vhdx.Path -ErrorAction Stop -SwitchName $LabSwitchName

    # 3. Memory + CPU + auto-start/stop
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true `
                 -StartupBytes $MemoryStartupBytes `
                 -MinimumBytes $MinMemoryBytes `
                 -MaximumBytes $MaxMemoryBytes -ErrorAction Stop

    Set-VMProcessor -VMName $VMName -Count $ProcessorCount -ErrorAction Stop

    # AutomaticCheckpointsEnabled $false: Windows 11 client Hyper-V
    # defaults it ON, which takes a Standard checkpoint at first VM
    # start -- every write after provisioning lands in an .avhdx
    # stacked on the differencing chain (observed 2026-07-17: CM01's
    # auto-checkpoint diff hit 33GB while its .vhdx stayed empty).
    Set-VM -Name $VMName `
           -AutomaticStartAction $AutoStartAction `
           -AutomaticStartDelay  $AutoStartDelay `
           -AutomaticStopAction  $AutoStopAction `
           -CheckpointType Production `
           -AutomaticCheckpointsEnabled $false -ErrorAction SilentlyContinue

    # 4. Replace the auto-attached NIC with an explicit one carrying a
    # pinned MAC, then add the NAT NIC.
    Get-VMNetworkAdapter -VMName $VMName | Remove-VMNetworkAdapter -ErrorAction SilentlyContinue

    $labNic = Add-VMNetworkAdapter -VMName $VMName -Name 'Lab' -SwitchName $LabSwitchName -Passthru -ErrorAction Stop
    Set-VMNetworkAdapter -VMName $VMName -Name 'Lab' -StaticMacAddress $macPlain -ErrorAction Stop

    $null = Add-VMNetworkAdapter -VMName $VMName -Name 'NAT' -SwitchName $DefaultSwitchName -Passthru -ErrorAction Stop

    Write-LabLog "VM '$VMName' configured: $ProcessorCount vCPU, $([math]::Round($MemoryStartupBytes/1GB))GB startup memory, lab MAC $macDash" -Status INFO

    # 5. Per-VM Unattend.xml
    $unattendDir = Join-Path $env:TEMP ('homelab-unattend-{0}' -f [guid]::NewGuid().ToString('N').Substring(0,8))
    $null = New-Item -Path $unattendDir -ItemType Directory -Force
    $unattendPath = Join-Path $unattendDir ('{0}-unattend.xml' -f $VMName)

    $unattendParams = @{
        ComputerName          = $VMName
        LabNicMac             = $macDash
        IPAddress             = $LabIP
        DnsServer             = $DnsServer
        AdministratorPassword = $AdministratorPassword
        OutputPath            = $unattendPath
        EnableAutoLogon       = $true
    }
    if ($Gateway) { $unattendParams.Gateway = $Gateway }

    $null = New-Unattend @unattendParams

    # 6. Inject
    Mount-LabUnattend -VhdxPath $vhdx.Path -UnattendXmlPath $unattendPath
    Remove-Item -Path $unattendDir -Recurse -Force -ErrorAction SilentlyContinue

    # 7. Start
    Write-LabLog "Starting VM '$VMName'" -Status RUN
    Start-VM -Name $VMName -ErrorAction Stop

    # 8. Wait for WinRM (unless caller opted out). Throw on timeout so
    # downstream phases never run against an unreachable VM.
    if (-not $NoWait) {
        $sec = ConvertTo-SecureString -String $AdministratorPassword -AsPlainText -Force
        $localCred = New-Object System.Management.Automation.PSCredential('Administrator', $sec)
        $ready = Wait-LabVM -ComputerName $VMName -Credential $localCred `
                            -TimeoutSeconds $WinRMTimeoutSeconds
        if (-not $ready) {
            throw "New-LabVM: VM '$VMName' did not reach WinRM-ready within ${WinRMTimeoutSeconds}s. Check that the host vEthernet ($LabSwitchName) has an IP on the lab subnet, that the VM finished sysprep first-boot, and that the lab MAC pinned correctly."
        }
    }

    return [pscustomobject]@{
        Name          = $VMName
        VMObject      = (Get-VM -Name $VMName)
        VhdxPath      = $vhdx.Path
        ParentVhdx    = $vhdx.ParentPath
        LabIP         = $LabIP
        LabNicMac     = $macDash
        DnsServer     = $DnsServer
        Gateway       = $Gateway
        ProcessorCount = $ProcessorCount
        MemoryStartupGB = [math]::Round($MemoryStartupBytes/1GB)
    }
}
