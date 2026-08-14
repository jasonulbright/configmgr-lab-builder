function Test-LabMedia {
    <#
    .SYNOPSIS
        Report presence of every external media asset the deploy needs.

    .DESCRIPTION
        Read-only pre-flight over the LabSources tree. Resolution rules
        mirror Install-HomeLab's defaults exactly (same ISO wildcard
        patterns, same canonical-subfolder-then-flat fallbacks, same
        nested CM source detection); Install-HomeLab remains the
        authority -- a rule change there must land here too or this
        report lies.

        Each item carries enough metadata for a caller to remediate:
        the folder the file belongs in, the vendor download page, and
        -- for the assets Microsoft serves from stable direct links --
        the URLs a caller can fetch without a browser session. Eval
        ISOs and the ConfigMgr media sit behind registration pages, so
        those only get a DownloadUrl.

    .PARAMETER LabSourcesRoot
        Root of the staged sources tree. Default 'C:\LabSources'.

    .PARAMETER OdbcUrl
        Direct MSI link for ODBC Driver 18.5.2.1. Pinned: 18.6.x has a
        documented NULL regression that breaks CM setup. Matches the
        config.psd1 ODBCURL default.

    .PARAMETER VcRedistX64Url

    .PARAMETER VcRedistX86Url
        Direct links for the VC++ 14.50 redistributables. Match the
        config.psd1 defaults.

    .OUTPUTS
        [pscustomobject] with LabSourcesRoot, Items (one object per
        asset), RequiredMissing (count), Pass (no required item
        missing).

    .EXAMPLE
        Test-LabMedia | Select-Object -ExpandProperty Items |
            Format-Table Name, Required, Found, Detail
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$LabSourcesRoot = 'C:\LabSources',

        [string]$OdbcUrl        = 'https://go.microsoft.com/fwlink/?linkid=2335671',
        [string]$VcRedistX64Url = 'https://aka.ms/vs/18/release/vc_redist.x64.exe',
        [string]$VcRedistX86Url = 'https://aka.ms/vs/18/release/vc_redist.x86.exe'
    )

    $sw      = Join-Path $LabSourcesRoot 'SoftwarePackages'
    $isoRoot = Join-Path $LabSourcesRoot 'ISOs'
    $items   = [System.Collections.Generic.List[object]]::new()

    function Format-MediaFileDetail {
        param([string]$Path)
        $f = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $f) { return $Path }
        if ($f.Length -ge 1GB) { return ('{0} ({1:N1} GB)' -f $f.Name, ($f.Length / 1GB)) }
        return ('{0} ({1:N1} MB)' -f $f.Name, ($f.Length / 1MB))
    }

    function New-MediaItem {
        param([hashtable]$Props)
        $base = @{
            Id = ''; Name = ''; Required = $true; Found = $false
            Path = ''; Detail = ''; TargetDir = ''; DownloadUrl = ''
            AutoFiles = @(); LayoutSetupUrl = ''; LayoutSetupName = ''; LayoutDir = ''
        }
        foreach ($k in $Props.Keys) { $base[$k] = $Props[$k] }
        [pscustomobject]$base
    }

    # ---- ISOs (registration-gated; browser download only) ----
    $serverIso = Find-LabIsoPath -Directory $isoRoot -Patterns @('*SERVER*EVAL*.iso')
    $items.Add((New-MediaItem @{
        Id = 'ServerIso'; Name = 'Windows Server 2025 Eval ISO'
        Found = [bool]$serverIso; Path = [string]$serverIso
        Detail = if ($serverIso) { Format-MediaFileDetail $serverIso } else { "No *SERVER*EVAL*.iso in $isoRoot" }
        TargetDir = $isoRoot
        DownloadUrl = 'https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025'
    }))

    $clientPatterns = @('*WIN11*EVAL*.iso', '*Windows*11*Eval*.iso', '*CLIENTENTERPRISE*EVAL*.iso')
    $clientIso = Find-LabIsoPath -Directory $isoRoot -Patterns $clientPatterns
    $items.Add((New-MediaItem @{
        Id = 'ClientIso'; Name = 'Windows 11 Enterprise Eval ISO'
        Found = [bool]$clientIso; Path = [string]$clientIso
        Detail = if ($clientIso) { Format-MediaFileDetail $clientIso } else { "No Win11 eval ISO in $isoRoot (accepted patterns include CLIENTENTERPRISEEVAL names)" }
        TargetDir = $isoRoot
        DownloadUrl = 'https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise'
    }))

    $sqlIso = Find-LabIsoPath -Directory $isoRoot -Patterns @('*SQL*2022*.iso')
    $items.Add((New-MediaItem @{
        Id = 'SqlIso'; Name = 'SQL Server 2022 Eval ISO'
        Found = [bool]$sqlIso; Path = [string]$sqlIso
        Detail = if ($sqlIso) { Format-MediaFileDetail $sqlIso } else { "No *SQL*2022*.iso in $isoRoot (the eval page serves a bootstrapper; run it and pick 'Download Media' for the ISO)" }
        TargetDir = $isoRoot
        DownloadUrl = 'https://www.microsoft.com/en-us/evalcenter/download-sql-server-2022'
    }))

    # ---- ConfigMgr media (extracted folder; SMSSETUP at root or one level
    #      down -- same nested-layout detection as Install-HomeLab) ----
    $cmRoot  = Join-Path $sw 'CM'
    $cmFound = $false
    $cmPath  = ''
    if (Test-Path -LiteralPath $cmRoot -PathType Container) {
        if (Test-Path (Join-Path $cmRoot 'SMSSETUP')) {
            $cmFound = $true; $cmPath = $cmRoot
        } else {
            foreach ($kid in @(Get-ChildItem -LiteralPath $cmRoot -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path (Join-Path $kid.FullName 'SMSSETUP')) {
                    $cmFound = $true; $cmPath = $kid.FullName; break
                }
            }
        }
    }
    $items.Add((New-MediaItem @{
        Id = 'CMSource'; Name = 'ConfigMgr 2509 media (extracted)'
        Found = $cmFound; Path = $cmPath
        Detail = if ($cmFound) { "SMSSETUP found under $cmPath" } else { "No SMSSETUP folder under $cmRoot -- extract the eval download (7-Zip) into a subfolder such as ConfigMgr_2509" }
        TargetDir = $cmRoot
        DownloadUrl = 'https://www.microsoft.com/en-us/evalcenter/download-microsoft-endpoint-configuration-manager'
    }))

    # ---- ADK / WinPE offline layouts (direct-link bootstrappers; the
    #      layout run itself downloads the payload, no registration) ----
    $adkDir   = Join-Path $sw 'ADK\Offline'
    $adkFound = (Test-Path -LiteralPath $adkDir -PathType Container) -and
                (@(Get-ChildItem -LiteralPath $adkDir -ErrorAction SilentlyContinue).Count -gt 0)
    $items.Add((New-MediaItem @{
        Id = 'AdkLayout'; Name = 'ADK offline layout'
        Found = $adkFound; Path = if ($adkFound) { $adkDir } else { '' }
        Detail = if ($adkFound) { "Layout present at $adkDir" } else { "Empty or missing: $adkDir (adksetup.exe /quiet /layout <folder>)" }
        TargetDir = $adkDir
        DownloadUrl = 'https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install'
        LayoutSetupUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980'
        LayoutSetupName = 'adksetup.exe'
        LayoutDir = $adkDir
    }))

    $adkPeDir   = Join-Path $sw 'ADKPE\Offline'
    $adkPeFound = (Test-Path -LiteralPath $adkPeDir -PathType Container) -and
                  (@(Get-ChildItem -LiteralPath $adkPeDir -ErrorAction SilentlyContinue).Count -gt 0)
    $items.Add((New-MediaItem @{
        Id = 'AdkPeLayout'; Name = 'WinPE add-on offline layout'
        Found = $adkPeFound; Path = if ($adkPeFound) { $adkPeDir } else { '' }
        Detail = if ($adkPeFound) { "Layout present at $adkPeDir" } else { "Empty or missing: $adkPeDir (adkwinpesetup.exe /quiet /layout <folder>)" }
        TargetDir = $adkPeDir
        DownloadUrl = 'https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install'
        LayoutSetupUrl = 'https://go.microsoft.com/fwlink/?linkid=2289981'
        LayoutSetupName = 'adkwinpesetup.exe'
        LayoutDir = $adkPeDir
    }))

    # ---- VC++ redistributables (x64 + x86 must sit in the SAME resolved
    #      folder: Install-HomeLab picks the directory off the x64 probe,
    #      canonical VCRedist\ first, flat SoftwarePackages\ fallback) ----
    $vcCanon = Join-Path $sw 'VCRedist'
    $vcDir   = if (Test-Path (Join-Path $vcCanon 'vc_redist.x64.exe')) { $vcCanon } else { $sw }
    $vcX64   = Test-Path (Join-Path $vcDir 'vc_redist.x64.exe')
    $vcX86   = Test-Path (Join-Path $vcDir 'vc_redist.x86.exe')
    $vcMissing = @()
    if (-not $vcX64) { $vcMissing += 'vc_redist.x64.exe' }
    if (-not $vcX86) { $vcMissing += 'vc_redist.x86.exe' }
    $items.Add((New-MediaItem @{
        Id = 'VcRedist'; Name = 'VC++ 14.50 redistributables (x64 + x86)'
        Found = ($vcX64 -and $vcX86)
        Path = if ($vcX64 -and $vcX86) { $vcDir } else { '' }
        Detail = if ($vcX64 -and $vcX86) { "Both present in $vcDir" } else { ('Missing {0} in {1}' -f ($vcMissing -join ' and '), $vcDir) }
        TargetDir = $vcCanon
        DownloadUrl = 'https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist'
        AutoFiles = @(
            @{ Url = $VcRedistX64Url; Target = Join-Path $vcCanon 'vc_redist.x64.exe' }
            @{ Url = $VcRedistX86Url; Target = Join-Path $vcCanon 'vc_redist.x86.exe' }
        )
    }))

    # ---- ODBC driver (version-pinned; canonical ODBC\ then flat) ----
    $odbcPath = $null
    foreach ($candidate in 'ODBC\msodbcsql.msi', 'msodbcsql.msi') {
        $p = Join-Path $sw $candidate
        if (Test-Path -LiteralPath $p) { $odbcPath = $p; break }
    }
    $items.Add((New-MediaItem @{
        Id = 'Odbc'; Name = 'ODBC Driver 18.5.2.1 MSI'
        Found = [bool]$odbcPath; Path = [string]$odbcPath
        Detail = if ($odbcPath) { Format-MediaFileDetail $odbcPath } else { "No msodbcsql.msi under $sw\ODBC or $sw (must be 18.5.2.1 -- 18.6.x breaks CM setup)" }
        TargetDir = Join-Path $sw 'ODBC'
        DownloadUrl = $OdbcUrl
        AutoFiles = @(
            @{ Url = $OdbcUrl; Target = Join-Path $sw 'ODBC\msodbcsql.msi' }
        )
    }))

    # ---- CM prerequisite offline cache (optional: setup downloads live
    #      into C:\Install\CM-PreReqs when no cache is staged) ----
    $preReqPath = $null
    foreach ($candidate in 'CM-Prereqs', 'CMPrereqs', 'CM-Prereqs-2509-CB') {
        $p = Join-Path $sw $candidate
        if (Test-Path -LiteralPath $p -PathType Container) { $preReqPath = $p; break }
    }
    $items.Add((New-MediaItem @{
        Id = 'CMPreReqs'; Name = 'CM prerequisite offline cache'
        Required = $false
        Found = [bool]$preReqPath; Path = [string]$preReqPath
        Detail = if ($preReqPath) { "Cache found at $preReqPath" } else { 'Optional -- CM setup downloads prerequisites live when no cache is staged' }
        TargetDir = Join-Path $sw 'CM-Prereqs'
        DownloadUrl = ''
    }))

    $requiredMissing = @($items | Where-Object { $_.Required -and -not $_.Found })
    [pscustomobject]@{
        LabSourcesRoot  = $LabSourcesRoot
        Items           = $items.ToArray()
        RequiredMissing = $requiredMissing.Count
        Pass            = ($requiredMissing.Count -eq 0)
    }
}
