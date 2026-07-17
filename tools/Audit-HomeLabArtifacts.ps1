#Requires -Version 7.0
<#
.SYNOPSIS
    Audit the host for HomeLab artifacts. Exit 0 only when the host is
    provably clean.

.DESCRIPTION
    The last E2E attempt was invalidated because a prior run's cached
    base image survived "teardown" and got silently consumed by the next
    build. This script is the referee: after Remove-HomeLab, it must
    find ZERO lab artifacts, or the next run does not count as
    from-scratch.

    Standalone by design -- it does NOT import the HomeLab module, so it
    still works when the module is broken or mid-refactor. It harvests
    lab identity (VM names, lab names, subnets) from config.psd1 plus
    every templates/*.psd1 so renamed topologies can't hide artifacts.

    Artifact classes checked (complete inventory of everything a lab run
    creates on the host, per module code review 2026-07-16):

      Hyper-V objects (require elevation to enumerate):
        VM               Lab VMs: any known lab VM name from configs or
                         templates, the temp sysprep VM pattern
                         HomeLabBaseSysprep-*, or ANY VM with a virtual
                         disk stored under -LabImagePath (catches VMs
                         created by older/renamed configs, e.g. a stray
                         CLIENT02).
        Checkpoint       Checkpoints/.avhdx on flagged VMs.
        DvdLeak          A DVD drive on a NON-lab VM mounting an ISO from
                         -LabSourcesRoot (leaked Add-VMDvdDrive).
        Switch           Lab vSwitches: '<LabName>-Network' for every
                         LabName seen in configs/templates.
        HostNic          Host vEthernet adapters/IPs left on a lab subnet.

      Filesystem (work without elevation):
        BaseImage        <hash>.base.vhdx cached base images in -LabImagePath.
                         Dirty by default; -AllowBaseImageCache exempts them
                         (for -KeepBaseImages workflows).
        BuildTemp        build-*.vhdx failed/interrupted base-image builds.
        VmDisk           Per-VM .vhdx/.avhdx files in -LabImagePath
                         (orphaned when a VM was deleted but files kept).
        VmConfig         Orphaned .vmcx/.vmrs/.vmgs/.xml VM config files
                         under -LabImagePath.
        OtherFile        Anything else in -LabImagePath. A clean host has
                         NO -LabImagePath directory at all (or an empty one).
        MountedIso       ISOs under -LabSourcesRoot currently attached on
                         the host (leaked Mount-DiskImage).
        MountedVhd       VHDX under -LabImagePath currently attached
                         (leaked Mount-VHD).
        TempFile         %TEMP%\homelab-base-unattend-*.xml,
                         %TEMP%\homelab-unattend-*\ ,
                         %TEMP%\HomeLab-VcStage\ .

      Report-only (never counted dirty):
        Logs             %ProgramData%\HomeLab\Logs -- evidence, keep.
        Sources          -LabSourcesRoot -- consumed input, keep.

    Exit codes:
      0  clean (no dirty findings; Hyper-V checks ran)
      1  dirty (at least one finding)
      3  incomplete (filesystem clean or dirty, but Hyper-V could not be
         enumerated -- typically not elevated. NEVER certify clean on 3.)

.PARAMETER LabImagePath
    Base-image + VM VHDX cache folder. Default C:\LabImages.

.PARAMETER LabSourcesRoot
    ISO / software sources folder. Default C:\LabSources.

.PARAMETER RepoRoot
    Repo root containing config.psd1 + templates\. Default: parent of
    this script's folder.

.PARAMETER AllowBaseImageCache
    Do not count cached base images (*.base.vhdx) as dirty. Use when the
    intended state is "VMs gone, cache kept" (Remove-HomeLab -KeepBaseImages).
    A from-scratch E2E validation must NOT pass this switch.

.PARAMETER AsJson
    Emit the findings as JSON (one object per finding) instead of a table.

.EXAMPLE
    .\Audit-HomeLabArtifacts.ps1
    # full clean-slate audit; exit 0 == provably clean

.EXAMPLE
    .\Audit-HomeLabArtifacts.ps1 -AllowBaseImageCache
    # after Remove-HomeLab -KeepBaseImages
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$LabImagePath = 'C:\LabImages',

    [Parameter()]
    [string]$LabSourcesRoot = 'C:\LabSources',

    [Parameter()]
    [string]$RepoRoot,

    [Parameter()]
    [switch]$AllowBaseImageCache,

    [Parameter()]
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}

# ---------------------------------------------------------------- helpers

$findings = [System.Collections.Generic.List[pscustomobject]]::new()
$notes    = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Finding {
    param([string]$Class, [string]$Item, [string]$Detail)
    $findings.Add([pscustomobject]@{ Class = $Class; Item = $Item; Detail = $Detail })
}
function Add-Note {
    param([string]$Class, [string]$Item, [string]$Detail)
    $notes.Add([pscustomobject]@{ Class = $Class; Item = $Item; Detail = $Detail })
}

# ------------------------------------------------- harvest lab identity

# Every VM name, LabName, and network prefix that any config/template in
# the repo could have deployed. Import-PowerShellDataFile does not
# execute code, so loading every .psd1 is safe.
$labVmNames  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$labNames    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$labSubnets  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

$psd1Files = @(
    Join-Path $RepoRoot 'config.psd1'
    Get-ChildItem -Path (Join-Path $RepoRoot 'templates') -Filter '*.psd1' -ErrorAction SilentlyContinue |
        ForEach-Object FullName
) | Where-Object { $_ -and (Test-Path $_) }

foreach ($file in $psd1Files) {
    try {
        $cfg = Import-PowerShellDataFile -Path $file
    } catch {
        Write-Warning "Audit: cannot parse $file ($($_.Exception.Message)); its VM names are not covered"
        continue
    }
    if ($cfg.LabName) { $null = $labNames.Add([string]$cfg.LabName) }
    if ($cfg.Network) { $null = $labSubnets.Add([string]$cfg.Network) }
    if ($cfg.VMs) {
        foreach ($vm in @($cfg.VMs)) { if ($vm.Name) { $null = $labVmNames.Add([string]$vm.Name) } }
    }
    foreach ($legacy in 'DC','CM','Client') {
        if ($cfg[$legacy] -is [hashtable] -and $cfg[$legacy].Name) {
            $null = $labVmNames.Add([string]$cfg[$legacy].Name)
        }
    }
}

if ($labVmNames.Count -eq 0) {
    Write-Warning "Audit: no VM names harvested from $RepoRoot -- name-based VM detection is running blind (disk-location detection still applies)"
}

$labSwitchNames = @($labNames | ForEach-Object { "$_-Network" })

# Normalized prefix-match helper for "is this path under LabImagePath".
$imageRootFull = [System.IO.Path]::GetFullPath($LabImagePath).TrimEnd('\') + '\'
function Test-UnderImageRoot {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    return $full.StartsWith($imageRootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

# ------------------------------------------------------- Hyper-V checks

$hyperVComplete = $false
try {
    # Elevation probe: Get-VM without admin (or Hyper-V Administrators
    # membership) throws. Any other failure (module missing because the
    # Hyper-V feature is off) means there is nothing to audit -- that IS
    # clean from the Hyper-V side.
    $allVms = @(Get-VM -ErrorAction Stop)
    $hyperVComplete = $true
} catch [Microsoft.HyperV.PowerShell.VirtualizationException] {
    Write-Warning "Audit: cannot enumerate Hyper-V ($($_.Exception.Message)). Run elevated. Hyper-V state is UNVERIFIED."
    $allVms = @()
} catch {
    if ($_.Exception.Message -match 'required permission|Zugriff|access') {
        Write-Warning "Audit: cannot enumerate Hyper-V ($($_.Exception.Message)). Run elevated. Hyper-V state is UNVERIFIED."
        $allVms = @()
    } elseif (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        Write-Warning "Audit: Get-VM failed unexpectedly: $($_.Exception.Message). Hyper-V state is UNVERIFIED."
        $allVms = @()
    } else {
        # No Hyper-V cmdlets at all: feature not installed, no VMs possible.
        Add-Note -Class 'HyperV' -Item 'feature' -Detail 'Hyper-V PowerShell module not present; no VM state to audit'
        $allVms = @()
        $hyperVComplete = $true
    }
}

if ($hyperVComplete -and $allVms.Count -ge 0 -and (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    $labVms = [System.Collections.Generic.List[object]]::new()

    foreach ($vm in $allVms) {
        $reasons = [System.Collections.Generic.List[string]]::new()

        if ($labVmNames.Contains($vm.Name))            { $reasons.Add('name matches a config/template VM') }
        if ($vm.Name -like 'HomeLabBaseSysprep-*')     { $reasons.Add('temp sysprep VM pattern') }

        $disks = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue)
        $labDisks = @($disks | Where-Object { Test-UnderImageRoot $_.Path })
        if ($labDisks.Count -gt 0) { $reasons.Add("disk(s) under ${LabImagePath}: $($labDisks.Path -join ', ')") }

        $nics = @(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue)
        $labNics = @($nics | Where-Object { $_.SwitchName -in $labSwitchNames })
        if ($labNics.Count -gt 0) { $reasons.Add("NIC on lab switch '$($labNics[0].SwitchName)'") }

        if ($reasons.Count -gt 0) {
            $labVms.Add($vm)
            Add-Finding -Class 'VM' -Item $vm.Name -Detail "state=$($vm.State); $($reasons -join '; ')"

            foreach ($cp in @(Get-VMSnapshot -VMName $vm.Name -ErrorAction SilentlyContinue)) {
                Add-Finding -Class 'Checkpoint' -Item "$($vm.Name)\$($cp.Name)" -Detail "created $($cp.CreationTime)"
            }
        } else {
            # Non-lab VM: still check for a leaked lab ISO in its DVD drive.
            foreach ($dvd in @(Get-VMDvdDrive -VMName $vm.Name -ErrorAction SilentlyContinue)) {
                if ($dvd.Path -and $dvd.Path -like (Join-Path $LabSourcesRoot '*')) {
                    Add-Finding -Class 'DvdLeak' -Item $vm.Name -Detail "non-lab VM has lab ISO attached: $($dvd.Path)"
                }
            }
        }
    }

    # By name (every LabName seen in configs/templates) OR by the Notes
    # marker New-LabSwitch stamps on every switch it creates -- so a lab
    # deployed under a name this repo no longer knows still gets flagged.
    foreach ($sw in @(Get-VMSwitch -ErrorAction SilentlyContinue)) {
        if ($sw.Name -in $labSwitchNames -or $sw.Notes -eq 'HomeLab lab-internal switch') {
            Add-Finding -Class 'Switch' -Item $sw.Name -Detail "type=$($sw.SwitchType) id=$($sw.Id)"
        }
    }
}

# Host NICs / IPs on a lab subnet. Works without elevation. The vEthernet
# adapter dies with its switch, so any surviving lab-subnet host IP is an
# orphan (or the switch itself survived).
foreach ($prefix in $labSubnets) {
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$prefix.*" })
    foreach ($ip in $ips) {
        Add-Finding -Class 'HostNic' -Item "$($ip.InterfaceAlias)" -Detail "host IP $($ip.IPAddress)/$($ip.PrefixLength) on lab subnet $prefix.0"
    }
}

# ---------------------------------------------------- filesystem checks

if (Test-Path -LiteralPath $LabImagePath) {
    $items = @(Get-ChildItem -LiteralPath $LabImagePath -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        if ($item.PSIsContainer) { continue }
        $rel = $item.FullName.Substring($imageRootFull.Length)
        $sizeGB = [math]::Round($item.Length / 1GB, 2)

        # break matters: without it, switch -Wildcard collects EVERY
        # matching case ('x.base.vhdx' matches '*.base.vhdx' AND '*.vhdx').
        $class = switch -Wildcard ($item.Name) {
            '*.base.vhdx' { 'BaseImage'; break }
            'build-*.vhdx' { 'BuildTemp'; break }
            '*.avhdx'     { 'VmDisk'; break }
            '*.avhd'      { 'VmDisk'; break }
            '*.vhdx'      { 'VmDisk'; break }
            '*.vhd'       { 'VmDisk'; break }
            '*.vmcx'      { 'VmConfig'; break }
            '*.vmrs'      { 'VmConfig'; break }
            '*.vmgs'      { 'VmConfig'; break }
            '*.xml'       { 'VmConfig'; break }
            default       { 'OtherFile' }
        }

        if ($class -eq 'BaseImage' -and $AllowBaseImageCache) {
            Add-Note -Class 'BaseImage' -Item $rel -Detail "${sizeGB}GB (exempted by -AllowBaseImageCache)"
            continue
        }
        Add-Finding -Class $class -Item $rel -Detail "${sizeGB}GB, modified $($item.LastWriteTime)"
    }
    if ($items.Count -eq 0) {
        Add-Note -Class 'ImageRoot' -Item $LabImagePath -Detail 'directory exists but is empty (acceptable; delete for a perfect zero)'
    }
}

# Mounted lab ISOs (leaked Mount-DiskImage). Get-DiskImage is a read
# operation and works without elevation.
$isoDir = Join-Path $LabSourcesRoot 'ISOs'
if (Test-Path $isoDir) {
    foreach ($iso in @(Get-ChildItem -Path $isoDir -Filter '*.iso' -ErrorAction SilentlyContinue)) {
        try {
            $img = Get-DiskImage -ImagePath $iso.FullName -ErrorAction Stop
            if ($img.Attached) {
                Add-Finding -Class 'MountedIso' -Item $iso.Name -Detail 'ISO is currently attached on the host'
            }
        } catch { }
    }
}

# Mounted lab VHDs (leaked Mount-VHD).
if (Test-Path -LiteralPath $LabImagePath) {
    foreach ($vhdx in @(Get-ChildItem -LiteralPath $LabImagePath -Recurse -Include '*.vhdx','*.vhd','*.avhdx' -Force -ErrorAction SilentlyContinue)) {
        try {
            $img = Get-DiskImage -ImagePath $vhdx.FullName -ErrorAction Stop
            if ($img.Attached) {
                Add-Finding -Class 'MountedVhd' -Item $vhdx.Name -Detail 'VHDX is currently attached on the host'
            }
        } catch { }
    }
}

# Hosts-file entries: HomeLab-managed lines, or any line resolving a
# known lab VM name / pointing into a lab subnet.
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
if (Test-Path $hostsPath) {
    foreach ($line in @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue)) {
        $isManaged = $line -match '# HomeLab-managed'
        $content = ($line -split '#', 2)[0].Trim()
        $hit = $isManaged
        if (-not $hit -and $content) {
            $tokens = $content -split '\s+'
            $ip = $tokens[0]
            $names = @($tokens | Select-Object -Skip 1)
            if (@($names | Where-Object { $labVmNames.Contains(($_ -split '\.')[0]) }).Count -gt 0) { $hit = $true }
            if (-not $hit) {
                foreach ($prefix in $labSubnets) { if ($ip -like "$prefix.*") { $hit = $true; break } }
            }
        }
        if ($hit) {
            Add-Finding -Class 'HostsFile' -Item $line.Trim() -Detail "lab entry in $hostsPath"
        }
    }
}

# Temp artifacts.
$tempPatterns = @(
    @{ Path = Join-Path $env:TEMP 'homelab-base-unattend-*.xml'; Detail = 'base-image unattend temp file' }
    @{ Path = Join-Path $env:TEMP 'homelab-unattend-*';          Detail = 'per-VM unattend temp folder' }
    @{ Path = Join-Path $env:TEMP 'HomeLab-VcStage';             Detail = 'VC++ redistributable staging folder' }
)
foreach ($tp in $tempPatterns) {
    foreach ($hit in @(Get-Item -Path $tp.Path -ErrorAction SilentlyContinue)) {
        Add-Finding -Class 'TempFile' -Item $hit.FullName -Detail $tp.Detail
    }
}

# ------------------------------------------------------ report-only info

$logDir = Join-Path $env:ProgramData 'HomeLab\Logs'
if (Test-Path $logDir) {
    $logCount = @(Get-ChildItem $logDir -File -ErrorAction SilentlyContinue).Count
    Add-Note -Class 'Logs' -Item $logDir -Detail "$logCount log file(s) -- evidence, intentionally kept"
}
if (Test-Path $LabSourcesRoot) {
    Add-Note -Class 'Sources' -Item $LabSourcesRoot -Detail 'consumed input (ISOs/packages) -- intentionally kept'
}

# --------------------------------------------------------------- output

if ($AsJson) {
    [pscustomobject]@{
        Timestamp       = (Get-Date).ToString('o')
        HyperVComplete  = $hyperVComplete
        Findings        = $findings
        Notes           = $notes
    } | ConvertTo-Json -Depth 4
} else {
    Write-Host ''
    Write-Host "HomeLab artifact audit -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "  ImageRoot : $LabImagePath"
    Write-Host "  Sources   : $LabSourcesRoot"
    Write-Host "  Identity  : $($labVmNames.Count) VM name(s), switches: $($labSwitchNames -join ', ')"
    Write-Host ''

    if ($findings.Count -gt 0) {
        Write-Host "DIRTY -- $($findings.Count) artifact(s) found:" -ForegroundColor Red
        $findings | Sort-Object Class, Item | Format-Table Class, Item, Detail -AutoSize -Wrap | Out-Host
    } else {
        Write-Host 'No lab artifacts found.' -ForegroundColor Green
    }

    if ($notes.Count -gt 0) {
        Write-Host 'Report-only (not counted dirty):' -ForegroundColor DarkGray
        $notes | Format-Table Class, Item, Detail -AutoSize -Wrap | Out-Host
    }

    if (-not $hyperVComplete) {
        Write-Host 'INCOMPLETE: Hyper-V objects could not be enumerated (run elevated). Do NOT treat this host as verified-clean.' -ForegroundColor Yellow
    } elseif ($findings.Count -eq 0) {
        Write-Host 'VERDICT: host is provably clean of lab artifacts.' -ForegroundColor Green
    } else {
        Write-Host 'VERDICT: host is DIRTY. Run Remove-HomeLab (with -RemoveBaseImageCache for a from-scratch run), then re-audit.' -ForegroundColor Red
    }
}

if (-not $hyperVComplete) { exit 3 }
if ($findings.Count -gt 0) { exit 1 }
exit 0
