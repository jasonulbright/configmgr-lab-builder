function New-LabVhdx {
    <#
    .SYNOPSIS
        Create a per-VM differencing VHDX whose parent is a cached base image.

    .DESCRIPTION
        Each lab VM gets a thin differencing VHDX that points at a shared
        sysprepped base image built by New-LabBaseImage. Provisioning a
        new VM is then ~seconds (just New-VHD -Differencing) instead of
        the ~10 min Apply-Image pass AutomatedLab paid every time.

        The parent VHDX MUST be sysprepped (the New-LabBaseImage default).
        Booting differencing children of a non-generalized parent will
        give every VM the same Windows SID.

        OSDiskSize allows the differencing child to expose a larger disk
        than the parent; the partition is auto-extended on the VM's first
        boot via DiskPart in the per-VM Unattend FirstLogonCommands.

    .PARAMETER VMName
        Used in the output filename: $LabImagePath\<VMName>.vhdx.

    .PARAMETER ParentVhdx
        Absolute path to the cached base image. Must exist.

    .PARAMETER LabImagePath
        Folder for VM VHDXs. Default C:\LabImages.

    .PARAMETER OSDiskSize
        Optional logical-size override (in GB). When > parent size, the
        differencing VHDX is resized after creation. Default: parent size.

    .PARAMETER Force
        Overwrite an existing $LabImagePath\$VMName.vhdx.

    .EXAMPLE
        New-LabVhdx -VMName CM01 `
                    -ParentVhdx C:\LabImages\<key>.base.vhdx `
                    -OSDiskSize 150
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$ParentVhdx,

        [Parameter()]
        [string]$LabImagePath = 'C:\LabImages',

        [Parameter()]
        [int]$OSDiskSize,

        [Parameter()]
        [switch]$Force
    )

    if (-not (Test-Path -Path $ParentVhdx -PathType Leaf)) {
        throw "New-LabVhdx: parent VHDX not found: $ParentVhdx"
    }
    if (-not (Test-Path -Path $LabImagePath -PathType Container)) {
        $null = New-Item -Path $LabImagePath -ItemType Directory -Force
    }

    $childPath = Join-Path $LabImagePath ('{0}.vhdx' -f $VMName)
    if (Test-Path $childPath) {
        if ($Force) {
            Write-LabLog "Removing existing child VHDX: $childPath" -Status WARN
            Remove-Item $childPath -Force -ErrorAction Stop
        } else {
            throw "New-LabVhdx: child VHDX already exists: $childPath (pass -Force to overwrite)"
        }
    }

    Write-LabLog "Creating differencing VHDX '$childPath' (parent: $ParentVhdx)" -Status RUN
    $vhd = New-VHD -Path $childPath -ParentPath $ParentVhdx -Differencing -ErrorAction Stop

    $finalSizeGB = [math]::Round($vhd.Size / 1GB, 0)

    if ($OSDiskSize -and $OSDiskSize -gt $finalSizeGB) {
        Write-LabLog "Resizing child to ${OSDiskSize}GB" -Status RUN
        Resize-VHD -Path $childPath -SizeBytes ($OSDiskSize * 1GB) -ErrorAction Stop
        $finalSizeGB = $OSDiskSize
    }

    Write-LabLog "Differencing VHDX ready: $childPath (${finalSizeGB}GB logical)" -Status OK
    return [pscustomobject]@{
        Path       = $childPath
        ParentPath = (Resolve-Path $ParentVhdx).Path
        SizeGB     = $finalSizeGB
        VMName     = $VMName
    }
}
