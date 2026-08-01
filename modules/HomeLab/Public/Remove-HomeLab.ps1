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

        Teardown is provable: after Remove-HomeLab (without
        -KeepBaseImages), tools/Audit-HomeLabArtifacts.ps1 must exit 0.
        The 2026-04 E2E was invalidated because teardown missed cached
        base images and a stray VM from an older config -- every gap
        that allowed that is closed here:

          - VM discovery is not limited to the current config's names.
            The removal set also includes temp sysprep VMs
            (HomeLabBaseSysprep-*) and ANY VM whose virtual disk lives
            under $LabImagePath (covers VMs deployed from older or
            renamed configs).
          - Orphaned files are harvested even when the VM object is
            already gone: the $LabImagePath sweep runs unconditionally,
            catching per-VM .vhdx, .avhdx, failed build-*.vhdx temp
            images, and stray VM config files.
          - Attached images are dismounted before deletion (a leaked
            Mount-VHD / Mount-DiskImage otherwise makes Remove-Item
            fail silently).
          - Lab ISOs still mounted on the host are dismounted.
          - %TEMP% debris is removed (homelab-unattend-* folders,
            homelab-base-unattend-*.xml, HomeLab-VcStage).
          - Lab switches are found by the current config's name AND by
            the Notes marker New-LabSwitch stamps on every switch it
            creates, so renamed labs still get cleaned up.

        Steps:
          1. Discover the lab VM set (config names + sysprep pattern +
             disk-location match)
          2. Harvest each VM's VHDX differencing chain
          3. Stop-VM -TurnOff + Remove-VM each
          4. Dismount + delete every harvested .vhdx/.avhdx (base-image
             parents included unless -KeepBaseImages)
          5. Sweep $LabImagePath + per-VM folders for leftover disk and
             VM-config files; remove emptied folders
          6. Remove lab vSwitches (config name + Notes marker; Default
             Switch is never touched)
          7. Dismount lab ISOs; clean %TEMP% debris
          8. Optionally remove the whole $LabImagePath cache directory
             (-RemoveBaseImageCache)
          9. Verify: log every artifact still present, WARN if any

        Requires elevation.

    .PARAMETER Config
        Pre-loaded config hashtable. Defaults to Get-LabConfig.

    .PARAMETER KeepBaseImages
        Preserve cached base images (*.base.vhdx in $LabImagePath). The
        next Install-HomeLab will re-use the cache. NOT valid for a
        from-scratch E2E validation.

    .PARAMETER RemoveBaseImageCache
        Also remove the entire $LabImagePath folder (default
        C:\LabImages). Forces a full rebuild on the next deploy.

    .PARAMETER LabImagePath
        Override the cache folder. Default 'C:\LabImages'.

    .PARAMETER LabSourcesRoot
        ISO / sources folder; used to find lab ISOs left mounted on the
        host. Default 'C:\LabSources'.

    .EXAMPLE
        Remove-HomeLab -RemoveBaseImageCache    # full clean slate
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
        [string]$LabSourcesRoot = 'C:\LabSources'
    )

    if (-not (Test-LabIsElevated)) {
        throw 'Remove-HomeLab: process must be elevated; Hyper-V cmdlets require admin'
    }

    if ($KeepBaseImages -and $RemoveBaseImageCache) {
        throw 'Remove-HomeLab: -KeepBaseImages and -RemoveBaseImageCache are mutually exclusive'
    }

    if (-not $Config) { $Config = Get-LabConfig }

    $configVmNames = @($Config.VMs | ForEach-Object { $_.Name })
    $networkName   = "$($Config.LabName)-Network"
    $switchMarker  = 'HomeLab lab-internal switch'   # Notes New-LabSwitch stamps

    $imageRootFull = [System.IO.Path]::GetFullPath($LabImagePath).TrimEnd('\') + '\'
    $underImageRoot = {
        param([string]$p)
        if ([string]::IsNullOrEmpty($p)) { return $false }
        try { $f = [System.IO.Path]::GetFullPath($p) } catch { return $false }
        return $f.StartsWith($imageRootFull, [System.StringComparison]::OrdinalIgnoreCase)
    }
    $isPreservedBase = {
        param([string]$p)
        return ($KeepBaseImages -and $p -like '*.base.vhdx')
    }

    # ---- 1. Discover the removal set --------------------------------
    # Config names alone are NOT enough: a stray VM from an older or
    # renamed config (its disk still under $LabImagePath) must die too,
    # as must interrupted base-image sysprep VMs.
    $removeVmNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $configVmNames) { $null = $removeVmNames.Add($n) }

    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        if ($removeVmNames.Contains($vm.Name)) { continue }
        if ($vm.Name -like 'HomeLabBaseSysprep-*') {
            Write-LabLog "[$($vm.Name)] temp sysprep VM found; adding to removal set" -Status WARN
            $null = $removeVmNames.Add($vm.Name)
            continue
        }
        $disks = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue)
        $labDisks = @($disks | Where-Object { & $underImageRoot $_.Path })
        if ($labDisks.Count -gt 0) {
            Write-LabLog "[$($vm.Name)] not in current config but its disk lives under $LabImagePath; adding to removal set" -Status WARN
            $null = $removeVmNames.Add($vm.Name)
        }
    }

    $vhdxToDelete = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $folderHints  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $null = $folderHints.Add($LabImagePath)   # sweep unconditionally: orphans exist even when no VM does

    # ---- 2. Harvest VHDX chains -------------------------------------
    foreach ($name in $removeVmNames) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { continue }

        Write-LabLog "[$name] state=$($vm.State); harvesting VHDX chain" -Status RUN
        $null = $folderHints.Add($vm.Path)
        $null = $folderHints.Add($vm.ConfigurationLocation)

        foreach ($d in (Get-VMHardDiskDrive -VMName $name -ErrorAction SilentlyContinue)) {
            $null = $vhdxToDelete.Add($d.Path)
            $null = $folderHints.Add((Split-Path $d.Path -Parent))

            try {
                $cur = Get-VHD -Path $d.Path -ErrorAction Stop
                while ($cur.ParentPath) {
                    $null = $vhdxToDelete.Add($cur.ParentPath)
                    $null = $folderHints.Add((Split-Path $cur.ParentPath -Parent))
                    $cur = Get-VHD -Path $cur.ParentPath -ErrorAction SilentlyContinue
                    if (-not $cur) { break }
                }
            } catch { }
        }

        # Snapshots get nuked when Remove-VM runs; their .avhdx files
        # also live in the VM folder so the straggler sweep below
        # cleans them.
    }

    # ---- 3. Stop + remove VMs ---------------------------------------
    foreach ($name in $removeVmNames) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { continue }

        if (-not $PSCmdlet.ShouldProcess($name, 'Stop-VM -TurnOff + Remove-VM')) { continue }

        if ($vm.State -ne 'Off') {
            Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue
        }
        Remove-VM -Name $name -Force -ErrorAction Stop
        Write-LabLog "[$name] Remove-VM" -Status OK
    }

    # ---- 4. Delete harvested chains (dismount first, retry merges) --
    # Children before parents: probing a differencing child whose base
    # was already deleted makes Get-DiskImage throw "chain is broken"
    # (caught, but it pollutes the evidence transcript). Base images
    # sort last.
    #
    # Retry on a deadline: removing a VM that carries an automatic
    # checkpoint kicks off an ASYNC .avhdx->parent merge in vmms, and
    # the chain files stay locked until it completes (observed
    # 2026-07-17 after a host reboot left auto-checkpoints on every
    # VM). A single silent Remove-Item pass would leave them behind
    # and fail the audit gate.
    $pendingDelete = [System.Collections.Generic.List[string]]::new()
    $orderedVhdx = @($vhdxToDelete | Sort-Object { $_ -like '*.base.vhdx' })
    foreach ($p in $orderedVhdx) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if (& $isPreservedBase $p) {
            Write-LabLog "Preserving base image (-KeepBaseImages): $p" -Status SKIP
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($p, 'Remove-Item')) { continue }
        $pendingDelete.Add($p)
    }

    $deleteDeadline = (Get-Date).AddMinutes(15)
    while ($pendingDelete.Count -gt 0 -and (Get-Date) -lt $deleteDeadline) {
        $stillPending = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $pendingDelete) {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            # A leaked Mount-VHD leaves the file attached; Remove-Item
            # then fails (and SilentlyContinue would hide it).
            try {
                $img = Get-DiskImage -ImagePath $p -ErrorAction Stop
                if ($img.Attached) {
                    Write-LabLog "Dismounting attached image before delete: $p" -Status WARN
                    Dismount-VHD -Path $p -ErrorAction SilentlyContinue
                }
            } catch { }
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $p) { $stillPending.Add($p) }
        }
        $pendingDelete = $stillPending
        if ($pendingDelete.Count -gt 0) {
            Write-LabLog "$($pendingDelete.Count) disk file(s) still locked (checkpoint merge in progress?); retrying in 10s" -Status RUN
            Start-Sleep -Seconds 10
        }
    }
    foreach ($p in $pendingDelete) {
        Write-LabLog "Could not delete after retries: $p" -Status WARN
    }

    # ---- 5. Straggler sweep -----------------------------------------
    # Covers: orphaned per-VM .vhdx whose VM object no longer exists,
    # failed build-*.vhdx temp images, checkpoint .avhdx, VM config
    # files (.vmcx/.vmrs/.vmgs/.xml). $LabImagePath is always in
    # $folderHints, so orphans are swept even when zero VMs existed.
    #
    # SAFETY: never sweep a shared folder. VMs created at the Hyper-V
    # default VirtualMachinePath put C:\ProgramData\Microsoft\Windows\
    # Hyper-V into $folderHints, and a recursive delete of .vmcx/.vmrs
    # there would destroy NON-lab VMs' configuration. A hint folder is
    # sweepable only when it is under $LabImagePath or is a per-VM
    # folder named after a lab VM; everywhere else, Remove-VM has
    # already deleted the lab VM's own config files.
    $sweepable = foreach ($folder in $folderHints) {
        if ([string]::IsNullOrEmpty($folder)) { continue }
        $leaf = Split-Path $folder -Leaf
        if ((& $underImageRoot $folder) -or ([System.IO.Path]::GetFullPath($folder).TrimEnd('\') -eq $imageRootFull.TrimEnd('\')) -or $removeVmNames.Contains($leaf)) {
            $folder
        } else {
            Write-LabLog "Skipping straggler sweep of shared folder: $folder (not lab-exclusive)" -Level Verbose
        }
    }
    foreach ($folder in $sweepable) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $stragglers = Get-ChildItem -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.PSIsContainer -and
                $_.Extension -in '.vhdx','.avhdx','.avhd','.vhd','.xml','.vmcx','.vmrs','.vmgs' -and
                -not (& $isPreservedBase $_.FullName)
            }
        foreach ($item in $stragglers) {
            if (-not $PSCmdlet.ShouldProcess($item.FullName, 'Remove-Item (straggler sweep)')) { continue }
            try {
                $img = Get-DiskImage -ImagePath $item.FullName -ErrorAction Stop
                if ($img.Attached) {
                    Write-LabLog "Dismounting attached image before delete: $($item.FullName)" -Status WARN
                    Dismount-VHD -Path $item.FullName -ErrorAction SilentlyContinue
                }
            } catch { }
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
        # Remove the now-empty folder tree, but never a folder that
        # still holds preserved base images (or anything else).
        $remaining = @(Get-ChildItem -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer })
        if ($remaining.Count -eq 0) {
            try { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop } catch { }
        }
    }

    # ---- 6. Lab vSwitches -------------------------------------------
    # The current config's switch by name, plus every switch stamped
    # with New-LabSwitch's Notes marker (covers renamed labs). The
    # Default Switch never carries the marker and is never touched.
    $labSwitches = @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq $networkName -or $_.Notes -eq $switchMarker
    })
    foreach ($sw in $labSwitches) {
        if ($PSCmdlet.ShouldProcess($sw.Name, 'Remove-VMSwitch')) {
            Remove-VMSwitch -Name $sw.Name -Force -ErrorAction SilentlyContinue
            Write-LabLog "Removed vSwitch '$($sw.Name)'" -Status OK
        }
    }

    # ---- 7. Mounted lab ISOs + %TEMP% debris ------------------------
    $isoDir = Join-Path $LabSourcesRoot 'ISOs'
    if (Test-Path $isoDir) {
        foreach ($iso in @(Get-ChildItem -Path $isoDir -Filter '*.iso' -ErrorAction SilentlyContinue)) {
            try {
                $img = Get-DiskImage -ImagePath $iso.FullName -ErrorAction Stop
                if ($img.Attached -and $PSCmdlet.ShouldProcess($iso.FullName, 'Dismount-DiskImage')) {
                    Dismount-DiskImage -ImagePath $iso.FullName -ErrorAction SilentlyContinue | Out-Null
                    Write-LabLog "Dismounted leaked ISO mount: $($iso.Name)" -Status OK
                }
            } catch { }
        }
    }

    # Hosts entries: every HomeLab-managed line, plus hand-made lines
    # that resolve a lab VM name (pre-engine drift). Look before asking --
    # a repeat teardown on an already-clean hosts file should neither
    # prompt for confirmation nor report work it did not do.
    $hostsNames = @(
        foreach ($n in $removeVmNames) {
            $n
            "$n.$($Config.DomainName)"
        }
    )
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $hostsLines = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue)
    $namePattern = if ($hostsNames.Count) {
        '(?i)(^|\s)(' + (($hostsNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(\s|$)'
    } else { $null }
    $hostsHasLabEntries = @(
        $hostsLines | Where-Object {
            $_ -notmatch '^\s*#' -and (
                $_ -match '#\s*HomeLab-managed' -or ($namePattern -and $_ -match $namePattern)
            )
        }
    ).Count -gt 0

    if ($hostsHasLabEntries -and $PSCmdlet.ShouldProcess('hosts file', 'Remove lab entries')) {
        $null = Remove-LabHostsEntries -Names $hostsNames
    }

    $tempDebris = @(
        Join-Path $env:TEMP 'homelab-base-unattend-*.xml'
        Join-Path $env:TEMP 'homelab-unattend-*'
        Join-Path $env:TEMP 'HomeLab-VcStage'
    )
    foreach ($pattern in $tempDebris) {
        foreach ($hit in @(Get-Item -Path $pattern -ErrorAction SilentlyContinue)) {
            if (-not $PSCmdlet.ShouldProcess($hit.FullName, 'Remove-Item (temp debris)')) { continue }
            Remove-Item -LiteralPath $hit.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ---- 8. Base-image cache ----------------------------------------
    if ($RemoveBaseImageCache -and (Test-Path $LabImagePath)) {
        if ($PSCmdlet.ShouldProcess($LabImagePath, 'Remove base-image cache')) {
            Remove-Item -Path $LabImagePath -Recurse -Force -ErrorAction SilentlyContinue
            Write-LabLog "Removed base-image cache: $LabImagePath" -Status OK
        }
    }

    # ---- 9. Verify ---------------------------------------------------
    $leftoverVMs = @(Get-VM -ErrorAction SilentlyContinue | Where-Object {
        $removeVmNames.Contains($_.Name)
    })
    $leftoverFiles = @()
    if (Test-Path -LiteralPath $LabImagePath) {
        $leftoverFiles = @(Get-ChildItem -LiteralPath $LabImagePath -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and -not (& $isPreservedBase $_.FullName) })
    }
    $leftoverSwitches = @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq $networkName -or $_.Notes -eq $switchMarker
    })

    $leftoverTotal = $leftoverVMs.Count + $leftoverFiles.Count + $leftoverSwitches.Count
    if ($leftoverTotal -gt 0) {
        foreach ($vm in $leftoverVMs)      { Write-LabLog "LEFTOVER VM: $($vm.Name)" -Status WARN }
        foreach ($f in $leftoverFiles)     { Write-LabLog "LEFTOVER file: $($f.FullName)" -Status WARN }
        foreach ($sw in $leftoverSwitches) { Write-LabLog "LEFTOVER switch: $($sw.Name)" -Status WARN }
        Write-LabLog "Remove-HomeLab finished with $leftoverTotal leftover artifact(s) -- run tools/Audit-HomeLabArtifacts.ps1 and remove manually" -Status WARN
    } else {
        Write-LabLog 'Remove-HomeLab complete; no lab VMs, files, or switches remain (verify with tools/Audit-HomeLabArtifacts.ps1)' -Status OK
    }
}
