function Remove-HomeLab {
    <#
    .SYNOPSIS
        Bare-metal cleanup. Stops + removes all lab VMs, deletes their
        VHDX chains, removes the lab vSwitch, and (optionally) the
        cached base images.

    .DESCRIPTION
        The bare-metal-build mission (feedback_homelab_build_from_bare_metal.md)
        says recovery is "re-run Install-HomeLab", which only works
        when the prior state is GONE. This is the GONE function.

        Steps:
          1. Stop + Remove-VM each VM (DC / CM / CLIENT)
          2. Walk each VM's VHDX differencing chain and delete every
             .vhdx + .avhdx file (includes parent base images unless
             -KeepBaseImages is set)
          3. Sweep the per-VM folders for leftover .xml/.vmcx/.vmrs
             config files and remove the empty folders
          4. Remove the lab vSwitch (Internal-type with the configured
             $LabName-Network name; Default Switch is left alone)
          5. Optionally remove the LabImagePath cache directory
             (-RemoveBaseImageCache)

        Requires elevation.

    .PARAMETER Config
        Pre-loaded config hashtable. Defaults to Get-LabConfig.

    .PARAMETER KeepBaseImages
        Do NOT walk into base-image parents during the VHDX delete
        sweep. The next Install-HomeLab will re-use the cache.

    .PARAMETER RemoveBaseImageCache
        Also remove the entire $LabImagePath folder (default
        C:\LabImages). Forces a full rebuild on the next deploy.

    .PARAMETER LabImagePath
        Override the cache folder. Default 'C:\LabImages'.

    .PARAMETER VMRoot
        Override the per-VM folder root. Default 'C:\AutomatedLab-VMs'
        compat shim; the engine uses $LabImagePath for VM
        VHDXs and the per-VM Hyper-V config folder defaults to wherever
        New-VM placed it.

    .EXAMPLE
        Remove-HomeLab
        Remove-HomeLab -RemoveBaseImageCache    # nuke everything
        Remove-HomeLab -KeepBaseImages          # rebuild VMs only
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter()]
        [hashtable]$Config,

        [Parameter()]
        [switch]$KeepBaseImages,

        [Parameter()]
        [switch]$RemoveBaseImageCache,

        [Parameter()]
        [string]$LabImagePath = 'C:\LabImages',

        [Parameter()]
        [string]$VMRoot
    )

    if (-not (Test-LabIsElevated)) {
        throw 'Remove-HomeLab: process must be elevated; Hyper-V cmdlets require admin'
    }

    if (-not $Config) { $Config = Get-LabConfig }

    $vmNames = @($Config.DC.Name, $Config.CM.Name, $Config.Client.Name)
    $networkName = "$($Config.LabName)-Network"

    $vhdxToDelete = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $folderHints  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $preserveSet  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($name in $vmNames) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { continue }

        Write-LabLog "[$name] state=$($vm.State); harvesting VHDX chain" -Status RUN
        $folderHints.Add($vm.Path) | Out-Null
        $folderHints.Add($vm.ConfigurationLocation) | Out-Null

        foreach ($d in (Get-VMHardDiskDrive -VMName $name -ErrorAction SilentlyContinue)) {
            $vhdxToDelete.Add($d.Path) | Out-Null
            $folderHints.Add((Split-Path $d.Path -Parent)) | Out-Null

            try {
                $cur = Get-VHD -Path $d.Path -ErrorAction Stop
                $lastParent = $null
                while ($cur.ParentPath) {
                    $lastParent = $cur.ParentPath
                    if (-not $KeepBaseImages) {
                        $vhdxToDelete.Add($cur.ParentPath) | Out-Null
                        $folderHints.Add((Split-Path $cur.ParentPath -Parent)) | Out-Null
                    }
                    $cur = Get-VHD -Path $cur.ParentPath -ErrorAction SilentlyContinue
                    if (-not $cur) { break }
                }
                # When -KeepBaseImages, preserve ONLY the ultimate base
                # (the topmost parent of the chain). Intermediate differencing
                # children are runtime VM disks and must still be cleaned up.
                if ($KeepBaseImages -and $lastParent) {
                    $preserveSet.Add($lastParent) | Out-Null
                }
            } catch { }
        }

        # Snapshots get nuked when Remove-VM runs; their .avhdx files
        # also live in the VM folder so the straggler sweep below
        # cleans them.
    }

    foreach ($name in $vmNames) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { continue }

        if (-not $PSCmdlet.ShouldProcess($name, 'Stop-VM -TurnOff + Remove-VM')) { continue }

        if ($vm.State -ne 'Off') {
            Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue
        }
        Remove-VM -Name $name -Force -ErrorAction Stop
        Write-LabLog "[$name] Remove-VM" -Status OK
    }

    foreach ($p in $vhdxToDelete) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if (-not $PSCmdlet.ShouldProcess($p, 'Remove-Item')) { continue }
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }

    foreach ($folder in $folderHints) {
        if ([string]::IsNullOrEmpty($folder)) { continue }
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $stragglers = Get-ChildItem -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.PSIsContainer -and
                $_.Extension -in '.vhdx','.avhdx','.avhd','.vhd','.xml','.vmcx','.vmrs' -and
                -not $preserveSet.Contains($_.FullName)
            }
        foreach ($item in $stragglers) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
        # Try to remove the now-empty folder, but only if no preserved
        # base images live underneath it. Ignore failures.
        $folderHasPreserved = $false
        foreach ($p in $preserveSet) {
            if ($p -like (Join-Path $folder '*')) { $folderHasPreserved = $true; break }
        }
        if (-not $folderHasPreserved) {
            try { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop } catch { }
        }
    }

    # Lab vSwitch (the configured Internal one, NOT 'Default Switch').
    $sw = Get-VMSwitch -Name $networkName -ErrorAction SilentlyContinue
    if ($sw) {
        if ($PSCmdlet.ShouldProcess($networkName, 'Remove-VMSwitch')) {
            Remove-VMSwitch -Name $networkName -Force -ErrorAction SilentlyContinue
            Write-LabLog "Removed vSwitch '$networkName'" -Status OK
        }
    }

    if ($RemoveBaseImageCache -and (Test-Path $LabImagePath)) {
        if ($PSCmdlet.ShouldProcess($LabImagePath, 'Remove base-image cache')) {
            Remove-Item -Path $LabImagePath -Recurse -Force -ErrorAction SilentlyContinue
            Write-LabLog "Removed base-image cache: $LabImagePath" -Status OK
        }
    }

    $remainingVMs = @(Get-VM -Name $vmNames -ErrorAction SilentlyContinue)
    Write-LabLog "Remove-HomeLab complete; VMs remaining: $($remainingVMs.Count)" -Status OK
}
