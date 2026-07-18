function New-LabBaseImage {
    <#
    .SYNOPSIS
        Build a sysprepped base VHDX from a Windows installer ISO, caching by
        ISO+edition hash.

    .DESCRIPTION
        Image-prep helper. Replaces per-VM WIM-apply with
        gives us the <90s VM provisioning loop because every per-VM VHDX is a
        differencing child of one cached parent.

        Flow:
          1. Resolve-IsoEdition -> ImageIndex + ImageName + ImagePath
          2. Compute SHA-256 cache key over ISO size+mtime+index+name (+LCU)
          3. If $LabImagePath\<key>.base.vhdx exists, return it (cache hit)
          4. Else build:
             a. New-VHD -Dynamic -SizeBytes $SizeGB GB
             b. Mount-VHD; Initialize-Disk GPT; create EFI + MSR + Windows
                partitions; format
             c. Expand-WindowsImage -ApplyPath W:\ -ImagePath ... -Index ...
             d. bcdboot W:\Windows /s S: /f UEFI
             e. Inject Unattend.xml in W:\Windows\Panther\Unattend.xml
             f. Dismount-VHD
          5. If -NoSysprep is NOT set:
             a. Create temp Hyper-V VM, attach the VHDX
             b. Start-VM and wait for VM state -> Off (sysprep ran via
                FirstLogonCommands and shut down)
             c. Remove-VM (keep the VHDX)
          6. Rename VHDX to <key>.base.vhdx and return its path

        REQUIRES:
          - Elevated PowerShell (Mount-DiskImage / Mount-VHD / Hyper-V cmdlets)
          - Hyper-V module
          - $SizeGB free disk on $LabImagePath volume
          - The ISO available at $IsoPath

    .PARAMETER IsoPath
        Path to the Windows installer ISO.

    .PARAMETER NameFilter
        Wildcard against ImageName, e.g. 'Windows Server 2025*Datacenter*Desktop Experience*'.

    .PARAMETER LabImagePath
        Cache directory. Default C:\LabImages. Created if missing.

    .PARAMETER SizeGB
        VHDX max size in GB. Default 100.

    .PARAMETER AdministratorPassword
        Local Administrator password baked into the Unattend.xml. Used by
        sysprep on first boot, then erased by /generalize. Each per-VM
        Unattend in S2 sets the real password.

    .PARAMETER LcuLevel
        Optional cumulative-update identifier added to the cache key.

    .PARAMETER SyspreepTimeoutMinutes
        How long to wait for the VM to power itself off after sysprep.
        Default 30.

    .PARAMETER NoSysprep
        Skip the boot+sysprep step. Returns a non-generalized image, useful
        for testing the WIM-apply path without paying the sysprep cost. The
        result is NOT suitable as a multi-VM differencing parent.

    .PARAMETER Force
        Rebuild even if a cached image with the same key exists.

    .EXAMPLE
        New-LabBaseImage -IsoPath C:\LabSources\ISOs\WS2025.iso `
                         -NameFilter 'Windows Server 2025*Datacenter*Desktop Experience*' `
                         -AdministratorPassword 'P@ssw0rd!' `
                         -SizeGB 100
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$IsoPath,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$NameFilter,

        [Parameter()]
        [string]$LabImagePath = 'C:\LabImages',

        [Parameter()]
        [ValidateRange(20, 2048)]
        [int]$SizeGB = 100,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AdministratorPassword,

        [Parameter()]
        [string]$LcuLevel = '',

        [Parameter()]
        [ValidateRange(5, 120)]
        [int]$SyspreepTimeoutMinutes = 30,

        [Parameter()]
        [switch]$NoSysprep,

        [Parameter()]
        [switch]$Force
    )

    # Elevation gate. Mount-VHD and Hyper-V cmdlets fail without admin and
    # leave half-built artifacts. Fail fast with a clear message.
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'New-LabBaseImage: process must be elevated'
    }

    # 1. Resolve edition (this mounts/dismounts the ISO once, just to read DISM)
    $edition = Resolve-IsoEdition -IsoPath $IsoPath -NameFilter $NameFilter

    # 2. Cache key
    $key = Get-LabBaseImageCacheKey `
        -IsoPath $IsoPath `
        -ImageIndex $edition.ImageIndex `
        -ImageName $edition.ImageName `
        -LcuLevel $LcuLevel

    if (-not (Test-Path $LabImagePath)) {
        $null = New-Item -Path $LabImagePath -ItemType Directory -Force
    }
    $cachedVhdx = Join-Path $LabImagePath ('{0}.base.vhdx' -f $key)

    if ((Test-Path $cachedVhdx) -and -not $Force) {
        Write-LabLog "Cache hit: $cachedVhdx" -Status SKIP
        return [pscustomobject]@{
            Path        = $cachedVhdx
            CacheKey    = $key
            CacheHit    = $true
            Edition     = $edition
            Sysprepped  = $true
            SizeGB      = $SizeGB
        }
    }

    # 3. Build
    $tempVhdx = Join-Path $LabImagePath ('build-{0}.vhdx' -f $key)
    if (Test-Path $tempVhdx) { Remove-Item $tempVhdx -Force }

    $tempUnattend = Join-Path $env:TEMP ('homelab-base-unattend-{0}.xml' -f $key)

    $disk = $null
    $vmName = "HomeLabBaseSysprep-$key"

    try {
        # 3a. Create VHDX
        Write-LabLog "Creating ${SizeGB}GB dynamic VHDX: $tempVhdx" -Status RUN
        New-VHD -Path $tempVhdx -SizeBytes ($SizeGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null

        # 3b. Mount + partition
        Write-LabLog '  mounting VHDX' -Level Verbose
        $disk = Mount-VHD -Path $tempVhdx -Passthru -ErrorAction Stop |
            Get-Disk

        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop

        Write-LabLog '  creating EFI + MSR + Windows partitions' -Level Verbose
        $efi = New-Partition -DiskNumber $disk.Number -Size 100MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
        Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false -ErrorAction Stop | Out-Null

        $null = New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

        $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
        Format-Volume -Partition $os -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false -ErrorAction Stop | Out-Null

        $efiDrive = "$($efi.DriveLetter):"
        $osDrive  = "$($os.DriveLetter):"

        # 3c. Apply image. Resolve-IsoEdition has dismounted by now; remount.
        Write-LabLog "Mounting ISO for image apply: $IsoPath" -Status RUN
        $isoDisk = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $isoVol = Get-Volume -DiskImage $isoDisk
        $isoDrive = "$($isoVol.DriveLetter):"
        $applyImagePath = Join-Path $isoDrive 'sources\install.wim'
        if (-not (Test-Path $applyImagePath)) {
            $applyImagePath = Join-Path $isoDrive 'sources\install.esd'
        }

        try {
            Write-LabLog "Applying image [$($edition.ImageIndex)] $($edition.ImageName) to $osDrive\" -Status RUN
            Expand-WindowsImage -ApplyPath "$osDrive\" -ImagePath $applyImagePath -Index $edition.ImageIndex -ErrorAction Stop | Out-Null
            Write-LabLog '  image applied' -Status OK
        } finally {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
        }

        # 3d. Boot files via bcdboot
        Write-LabLog "Writing UEFI boot files to $efiDrive" -Status RUN
        $bcdArgs = @("$osDrive\Windows", '/s', $efiDrive, '/f', 'UEFI')
        $bcd = Start-Process -FilePath 'bcdboot.exe' -ArgumentList $bcdArgs -NoNewWindow -Wait -PassThru
        if ($bcd.ExitCode -ne 0) {
            throw "bcdboot failed with exit code $($bcd.ExitCode)"
        }

        # 3e. Inject Unattend.xml
        $unattendArch = switch ($edition.Architecture) {
            'x86'   { 'x86' }
            'ARM64' { 'arm64' }
            default { 'amd64' }
        }
        $null = New-LabBaseUnattend `
            -Architecture $unattendArch `
            -AdministratorPassword $AdministratorPassword `
            -OutputPath $tempUnattend

        $pantherDir = Join-Path "$osDrive\" 'Windows\Panther'
        if (-not (Test-Path $pantherDir)) {
            $null = New-Item -Path $pantherDir -ItemType Directory -Force
        }
        Copy-Item -Path $tempUnattend -Destination (Join-Path $pantherDir 'Unattend.xml') -Force

        # 3f. Dismount
        Write-LabLog '  dismounting VHDX' -Level Verbose
        Dismount-VHD -Path $tempVhdx -ErrorAction Stop
        $disk = $null

        if ($NoSysprep) {
            Write-LabLog 'Skipping sysprep (-NoSysprep). Image is NOT generalized.' -Status WARN
            Move-Item -Path $tempVhdx -Destination $cachedVhdx -Force
            return [pscustomobject]@{
                Path       = $cachedVhdx
                CacheKey   = $key
                CacheHit   = $false
                Edition    = $edition
                Sysprepped = $false
                SizeGB     = $SizeGB
            }
        }

        # 4. Sysprep via temp VM. The Unattend's FirstLogonCommands runs
        # sysprep /generalize /shutdown, so the VM powers itself off.
        Write-LabLog "Booting temp VM '$vmName' to run sysprep" -Status RUN
        $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 2GB -VHDPath $tempVhdx -SwitchName ((Get-VMSwitch | Select-Object -First 1).Name) -ErrorAction Stop
        # No automatic checkpoint on the sysprep boot: client Hyper-V
        # defaults it on, which would divert sysprep's writes into an
        # .avhdx that only merges back on checkpoint deletion.
        Set-VM -Name $vmName -AutomaticCheckpointsEnabled $false -ErrorAction SilentlyContinue
        # Disable Secure Boot only if needed for the OS; Win11/WS2025 on Gen2 prefers Secure Boot ON.
        Set-VMProcessor -VMName $vmName -Count 2 -ErrorAction SilentlyContinue
        Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -MinimumBytes 1GB -MaximumBytes 4GB -ErrorAction SilentlyContinue
        Start-VM -Name $vmName -ErrorAction Stop

        $deadline = (Get-Date).AddMinutes($SyspreepTimeoutMinutes)
        $shutDown = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 15
            $state = (Get-VM -Name $vmName -ErrorAction SilentlyContinue).State
            if ($state -eq 'Off') { $shutDown = $true; break }
        }

        if (-not $shutDown) {
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
            Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
            throw "New-LabBaseImage: sysprep did not shut down VM within ${SyspreepTimeoutMinutes} minutes"
        }

        Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue

        # 5. Rename to cache name
        Move-Item -Path $tempVhdx -Destination $cachedVhdx -Force
        Write-LabLog "Base image ready: $cachedVhdx" -Status OK

        return [pscustomobject]@{
            Path       = $cachedVhdx
            CacheKey   = $key
            CacheHit   = $false
            Edition    = $edition
            Sysprepped = $true
            SizeGB     = $SizeGB
        }

    } finally {
        # Best-effort cleanup. Each step is wrapped because partial failures
        # (e.g. ISO dismount fails because nothing was mounted) shouldn't
        # mask the real error.
        if ($disk) {
            try { Dismount-VHD -Path $tempVhdx -ErrorAction SilentlyContinue } catch { }
        }
        try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue } catch { }
        if (Test-Path $tempUnattend) {
            Remove-Item $tempUnattend -Force -ErrorAction SilentlyContinue
        }
        # If we threw mid-build, leave the temp VHDX around for forensics
        # rather than auto-deleting; user can inspect or rm it manually.
        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
            Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
        }
    }
}
