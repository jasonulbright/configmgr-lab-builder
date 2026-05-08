function Import-CMRoleOsImage {
    <#
    .SYNOPSIS
        End-to-end import of a Windows install.wim from a host-side ISO
        into CM as an OS install image, then distribute to the DP group.
        Idempotent.

    .DESCRIPTION
        Pipeline (host -> SMB -> CM):
          1. Mount the ISO on the host (Mount-DiskImage; admin required).
          2. Pick the matching Windows edition via Get-WindowsImage
             against `sources\install.wim` (or install.esd) inside the
             mount.
          3. Derive a deterministic per-build folder name from the OS
             version, e.g. `W11_26200.6584`, plus a human-friendly CM
             image name with the build number embedded.
          4. Stage `install.wim` to
             `\\<CmServer>\<Share>\OSD\<folder>\install.wim` via an
             SMB PSDrive opened with the supplied DomainCredential.
          5. Dismount the host ISO.
          6. On the CM site server: Import-CMOperatingSystemImage
             pointing at the UNC, then Start-CMContentDistribution to
             the named DP group.

        Idempotent at every layer:
          - Existing folder + WIM on the share skip the file copy.
          - Existing CM OS image with the same Name short-circuits the
            Import-CMOperatingSystemImage call.
          - "Already targeted" distribution returns AlreadyDistributed
            instead of throwing.

        Returns a result object with the resolved ImageName so the
        caller can feed it directly into New-CMRoleTaskSequenceStub.

    .PARAMETER ComputerName
        DNS / short name of the CM site server. The site server hosts
        the ContentShare and runs the CM cmdlets.

    .PARAMETER DomainCredential
        Domain admin credential. Used both for the SMB drive map and
        for Invoke-LabCommand on the site server.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER IsoPath
        Local path on the host machine to the Windows install ISO.
        Typically resolved via Find-LabIsoPath against C:\LabSources\ISOs.

    .PARAMETER NameFilter
        Wildcard pattern matched against ImageName. Default
        'Windows 11*Enterprise*'. Highest matching ImageIndex wins.

    .PARAMETER ShareName
        SMB share on the site server. Default 'ContentShare$' (matches
        New-CMContentShare default).

    .PARAMETER DistributionPointGroupName
        DP group to distribute the imported image to. Default 'All DPs'
        (matches New-CMDistributionPointGroup default).

    .EXAMPLE
        Import-CMRoleOsImage -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM `
            -IsoPath 'C:\LabSources\ISOs\26200.CLIENTENTERPRISEEVAL.iso'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidateLength(3,3)]
        [string]$SiteCode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IsoPath,

        [Parameter()]
        [string]$NameFilter = 'Windows 11*Enterprise*',

        [Parameter()]
        [string]$ShareName = 'ContentShare$',

        [Parameter()]
        [string]$DistributionPointGroupName = 'All DPs'
    )

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "Import-CMRoleOsImage: ISO not found: $IsoPath"
    }

    $mount = $null
    $driveName = $null
    try {
        Write-LabLog "Mounting OS ISO: $IsoPath" -Status RUN
        $mount = Mount-LabIso -IsoPath $IsoPath
        $drive = $mount.DriveRoot

        # IO.Path.Combine instead of Join-Path: PS 7.6 Join-Path
        # validates that the parent drive exists in the current
        # PSProvider, which trips on freshly-mounted ISO drives in
        # some sessions. String concat is fine here.
        $sourceWim = [IO.Path]::Combine($drive, 'sources\install.wim')
        $sourceEsd = [IO.Path]::Combine($drive, 'sources\install.esd')
        $sourceImage = if (Test-Path -LiteralPath $sourceWim) { $sourceWim }
                       elseif (Test-Path -LiteralPath $sourceEsd) { $sourceEsd }
                       else { throw "Import-CMRoleOsImage: no sources\install.wim or install.esd inside $IsoPath" }

        $images = Get-WindowsImage -ImagePath $sourceImage -ErrorAction Stop
        $picked = @($images | Where-Object { $_.ImageName -like $NameFilter })
        if ($picked.Count -eq 0) {
            $available = ($images | ForEach-Object { "  [$($_.ImageIndex)] $($_.ImageName)" }) -join "`n"
            throw "Import-CMRoleOsImage: no image in '$IsoPath' matches '$NameFilter'. Available:`n$available"
        }
        $pick = $picked | Sort-Object ImageIndex -Descending | Select-Object -First 1
        $detail = Get-WindowsImage -ImagePath $sourceImage -Index $pick.ImageIndex -ErrorAction Stop

        $verParts = ($detail.Version -split '\.')
        $folderName = if ($verParts.Count -ge 4) {
            'W11_{0}.{1}' -f $verParts[2], $verParts[3]
        } else {
            'W11_' + ($detail.Version -replace '\.','_')
        }
        $cmImageName = "{0} (build {1})" -f $pick.ImageName, $detail.Version
        $wimUnc = "\\$ComputerName\$ShareName\OSD\$folderName\install.wim"

        Write-LabLog ("Resolved OS image: [{0}] {1} (build {2}); folder=$folderName" -f $pick.ImageIndex, $pick.ImageName, $detail.Version) -Status OK

        $driveName = 'homelabosd' + ([guid]::NewGuid().ToString('N').Substring(0,6))
        New-PSDrive -Name $driveName -PSProvider FileSystem `
            -Root "\\$ComputerName\$ShareName" `
            -Credential $DomainCredential -ErrorAction Stop | Out-Null

        $localShareRoot = "${driveName}:\OSD\$folderName"
        if (-not (Test-Path -LiteralPath $localShareRoot)) {
            New-Item -Path $localShareRoot -ItemType Directory -Force | Out-Null
        }

        $localTargetWim = [IO.Path]::Combine($localShareRoot, 'install.wim')
        $copied = $false
        if (Test-Path -LiteralPath $localTargetWim) {
            Write-LabLog "OS image WIM already present at $wimUnc, skipping copy" -Status SKIP
        } else {
            Write-LabLog "Copying $sourceImage -> $wimUnc (~5GB, will take a few minutes)" -Status RUN
            Copy-Item -LiteralPath $sourceImage -Destination $localTargetWim -Force -ErrorAction Stop
            $copied = $true
            Write-LabLog "WIM copy complete" -Status OK
        }

        $importResult = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
            -Activity "Import OS image $cmImageName" -ScriptBlock {
                param($SiteCode, $Name, $WimUnc, $DpGroup)

                # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
                # our PSSession was created; the WinRM listener inherited a stale env block.
                if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
                $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
                Import-Module $cmModule -Force -ErrorAction Stop
                if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                    $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
                }
                Set-Location "${SiteCode}:"

                # Skip Test-Path; loopback access from CM01 to its own
                # \\CM01\ShareName paths is blocked from inside the WinRM
                # session. The CM cmdlet runs as the SMS_PROVIDER service
                # (different identity) and can reach the share fine.

                # New-CMOperatingSystemImage rejects UNC self-references
                # like \\$env:COMPUTERNAME\ContentShare$\... with "Not found"
                # via WqlQueryException. Resolve to a local path when the
                # UNC points at this computer.
                $localPath = $WimUnc
                if ($WimUnc -match "^\\\\$([regex]::Escape($env:COMPUTERNAME))\\([^\\]+)\\(.+)$") {
                    $shareName = $matches[1]
                    $rest = $matches[2]
                    $share = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
                    if ($share -and $share.Path) {
                        $localPath = Join-Path $share.Path $rest
                    }
                }

                $existing = Get-CMOperatingSystemImage -Name $Name -ErrorAction SilentlyContinue
                if ($existing) {
                    $imgStatus = 'AlreadyExists'
                    $packageId = $existing.PackageID
                } else {
                    $img = New-CMOperatingSystemImage -Name $Name -Path $localPath -ErrorAction Stop
                    $imgStatus = 'Imported'
                    $packageId = $img.PackageID
                }

                $distStatus = 'Distributed'
                try {
                    Start-CMContentDistribution -OperatingSystemImageName $Name `
                        -DistributionPointGroupName $DpGroup -ErrorAction Stop
                } catch {
                    if ($_.Exception.Message -match 'already been targeted|already targeted|already been distributed|No content destination was found') {
                        $distStatus = 'AlreadyDistributed'
                    } else {
                        throw
                    }
                }

                return [pscustomobject]@{
                    Name        = $Name
                    PackageId   = $packageId
                    ImageStatus = $imgStatus
                    DistStatus  = $distStatus
                }
            } -ArgumentList $SiteCode, $cmImageName, $wimUnc, $DistributionPointGroupName

        Write-LabLog ("OS image '$cmImageName' $($importResult.ImageStatus); distribution=$($importResult.DistStatus)") -Status OK

        return [pscustomobject]@{
            ImageName   = $cmImageName
            ImageIndex  = [int]$pick.ImageIndex
            FolderName  = $folderName
            WimUncPath  = $wimUnc
            PackageId   = $importResult.PackageId
            ImageStatus = $importResult.ImageStatus
            DistStatus  = $importResult.DistStatus
            FilesCopied = $copied
        }

    } finally {
        if ($driveName -and (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue)) {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
        if ($mount) { Dismount-LabIso -IsoPath $IsoPath }
    }
}
