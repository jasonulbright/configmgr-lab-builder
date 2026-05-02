$script:LabConfigValidRoles = @(
    'DomainController'
    'CertificateAuthority'
    'SqlServer'
    'CentralAdministrationSite'
    'SiteServer'
    'ManagementPoint'
    'DistributionPoint'
    'SoftwareUpdatePoint'
    'Client'
)

$script:LabConfigLegacyRoleMap = @{
    DC     = @('DomainController','CertificateAuthority')
    CM     = @('SqlServer','SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint')
    Client = @('Client')
}

function Get-LabConfig {
    <#
    .SYNOPSIS
        Load and validate a HomeLab config.psd1 file.

    .DESCRIPTION
        Wraps Import-PowerShellDataFile and applies HomeLab-specific
        validation: required keys, IP-prefix consistency, MinMemory <=
        MaxMemory, exactly 3 service accounts, etc.

        Schema v2 (the canonical shape):
            VMs = @(
                @{ Name = 'DC01'    ; Roles = @('DomainController','CertificateAuthority') ; IP = ... ; Memory = ... ; ... }
                @{ Name = 'CM01'    ; Roles = @('SqlServer','SiteServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint') ; ... }
                @{ Name = 'CLIENT01'; Roles = @('Client') ; ... }
            )

        Schema v1 (legacy DC/CM/Client blocks) is still accepted; it is
        projected onto the v2 shape at load time. Each legacy block
        becomes one VM in $cfg.VMs (same hashtable reference, so
        $cfg.DC -eq $cfg.VMs[0] after projection). New-shape configs
        get DC / CM / Client aliases re-derived from VMs so existing
        engine consumers keep working unchanged.

        Returns the raw hashtable plus computed convenience fields:
          NetBIOS    - first label of DomainName, uppercased
          DomainDN   - distinguishedName form (DC=foo,DC=bar)
          ConfigPath - the resolved Path
          VMs        - canonical ordered array
          RoleIndex  - hashtable mapping Role -> VM list (for fast queries)
          DC, CM, Client - aliases pointing into VMs by role

        Throws on validation failure with a message that names the
        offending key. The intent is "fail at config load, not 90
        minutes into a deploy".

    .PARAMETER Path
        Path to config.psd1. Defaults to the repo-root config.psd1
        relative to the module location.

    .EXAMPLE
        $cfg = Get-LabConfig
        $cfg.NetBIOS                              # CONTOSO
        $cfg.SiteCode                             # MCM
        $cfg.RoleIndex['DomainController'][0].Name  # DC01
        Get-LabVMByRole -Config $cfg -Role SiteServer
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [string]$Path
    )

    if (-not $Path) {
        # Default: repo root config.psd1. This file lives at
        # modules/HomeLab/Helpers/, so the repo root is three Split-Path
        # steps up.
        $here = $PSScriptRoot
        $repoRoot = Split-Path (Split-Path (Split-Path $here -Parent) -Parent) -Parent
        $Path = Join-Path $repoRoot 'config.psd1'
    }

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Get-LabConfig: config file not found: $Path"
    }

    $cfg = Import-PowerShellDataFile -Path $Path

    # AdminPass is intentionally NOT required: Install-HomeLab injects it
    # from -LabPassword / interactive prompt. Templates ship without
    # plaintext passwords so the public repo never carries credentials.
    $required = @(
        'LabName','DomainName','SiteCode','SiteName','Network',
        'AdminUser','ServiceAccounts',
        'ServerOSFilter','ClientOSFilter'
    )
    foreach ($k in $required) {
        if (-not $cfg.ContainsKey($k)) {
            throw "Get-LabConfig: required key '$k' missing in $Path"
        }
    }

    if ($cfg.SiteCode.Length -ne 3) {
        throw "Get-LabConfig: SiteCode must be 3 characters (got '$($cfg.SiteCode)')"
    }

    # Resolve schema shape.
    $hasNew = $cfg.ContainsKey('VMs') -and ($cfg.VMs -is [System.Collections.IEnumerable]) -and (@($cfg.VMs).Count -gt 0)
    $hasOld = $cfg.ContainsKey('DC') -and $cfg.ContainsKey('CM') -and $cfg.ContainsKey('Client')

    if (-not $hasNew -and -not $hasOld) {
        throw "Get-LabConfig: config must define either 'VMs' (array, schema v2) or 'DC'/'CM'/'Client' blocks (legacy v1) in $Path"
    }

    if ($hasNew) {
        # v2 native: each VM hashtable must already carry an explicit Roles list.
        $cfg.VMs = @($cfg.VMs)
    }
    else {
        # v1 -> v2 projection. Mutate the existing legacy blocks in place
        # so $cfg.DC and $cfg.VMs[0] remain the same reference; engine
        # consumers reading $cfg.DC.Name still work.
        $projected = foreach ($key in 'DC','CM','Client') {
            $vm = $cfg[$key]
            if (-not $vm.ContainsKey('Roles')) {
                $vm['Roles'] = @($script:LabConfigLegacyRoleMap[$key])
            }
            $vm
        }
        $cfg['VMs'] = @($projected)
    }

    # Per-VM property + role validation.
    foreach ($vm in $cfg.VMs) {
        if ($vm -isnot [hashtable]) {
            throw "Get-LabConfig: VMs entry must be a hashtable, got '$($vm.GetType().FullName)'"
        }
        foreach ($p in 'Name','IP','Roles','Memory','MinMemory','MaxMemory','Processors') {
            if (-not $vm.ContainsKey($p)) {
                throw "Get-LabConfig: VM '$($vm.Name)' is missing required property '$p'"
            }
        }
        $roles = @($vm.Roles)
        if ($roles.Count -eq 0) {
            throw "Get-LabConfig: VM '$($vm.Name)' has no Roles"
        }
        foreach ($r in $roles) {
            if ($r -notin $script:LabConfigValidRoles) {
                throw "Get-LabConfig: VM '$($vm.Name)' has unknown role '$r'. Valid: $($script:LabConfigValidRoles -join ', ')"
            }
        }
        if ($vm.MinMemory -gt $vm.MaxMemory) {
            throw "Get-LabConfig: VM '$($vm.Name)' MinMemory ($($vm.MinMemory)) exceeds MaxMemory ($($vm.MaxMemory))"
        }
        if ($vm.IP -notlike "$($cfg.Network).*") {
            throw "Get-LabConfig: VM '$($vm.Name)' IP '$($vm.IP)' is not in network prefix '$($cfg.Network)'"
        }
    }

    # Topology constraints.
    $names = @($cfg.VMs | ForEach-Object { $_.Name })
    if (($names | Sort-Object -Unique).Count -ne $names.Count) {
        $dupes = ($names | Group-Object | Where-Object Count -gt 1 | ForEach-Object { $_.Name }) -join ', '
        throw "Get-LabConfig: duplicate VM names: $dupes"
    }
    $ips = @($cfg.VMs | ForEach-Object { $_.IP })
    if (($ips | Sort-Object -Unique).Count -ne $ips.Count) {
        $dupes = ($ips | Group-Object | Where-Object Count -gt 1 | ForEach-Object { $_.Name }) -join ', '
        throw "Get-LabConfig: duplicate VM IPs: $dupes"
    }

    $dcVms = @($cfg.VMs | Where-Object { 'DomainController' -in $_.Roles })
    if ($dcVms.Count -ne 1) {
        throw "Get-LabConfig: expected exactly 1 VM with role 'DomainController', got $($dcVms.Count)"
    }
    $siteVms = @($cfg.VMs | Where-Object { 'SiteServer' -in $_.Roles })
    if ($siteVms.Count -lt 1) {
        throw "Get-LabConfig: expected at least 1 VM with role 'SiteServer', got 0"
    }

    # CM-required role presence (S15). A working CM site needs SqlServer
    # + SiteServer + ManagementPoint + DistributionPoint + SoftwareUpdatePoint
    # somewhere in the topology. Co-location on the site server is fine
    # (default 3-VM lab); separate VMs are also fine (S15 distributed
    # roles). What's NOT fine is omitting a role entirely.
    foreach ($required in 'SqlServer','ManagementPoint','DistributionPoint','SoftwareUpdatePoint') {
        $matches = @($cfg.VMs | Where-Object { $required -in $_.Roles })
        if ($matches.Count -lt 1) {
            throw "Get-LabConfig: expected at least 1 VM with role '$required', got 0"
        }
    }

    # CAS hierarchy (S16). The CentralAdministrationSite role is in the
    # catalog so configs and templates can declare CAS topologies, but
    # the orchestrator does not yet plumb CAS install + replication.
    # We accept the role (validation passes) but flag the topology so
    # Install-HomeLab can emit a clear "not yet supported" error rather
    # than half-installing a primary site under a missing CAS.
    $casVms = @($cfg.VMs | Where-Object { 'CentralAdministrationSite' -in $_.Roles })
    if ($casVms.Count -gt 1) {
        throw "Get-LabConfig: expected at most 1 VM with role 'CentralAdministrationSite', got $($casVms.Count)"
    }

    # Role index for fast queries.
    $idx = @{}
    foreach ($r in $script:LabConfigValidRoles) { $idx[$r] = @() }
    foreach ($vm in $cfg.VMs) {
        foreach ($r in $vm.Roles) { $idx[$r] = @($idx[$r]) + $vm }
    }
    $cfg['RoleIndex'] = $idx

    # Legacy aliases. After projection these already point at the
    # right VMs (same reference); for native v2 configs we derive them
    # from the role index. Engine consumers (Install-HomeLab,
    # Set-LabAutoStartStop) read $cfg.DC.Name etc. and stay green.
    if (-not $cfg.ContainsKey('DC')) {
        $cfg['DC'] = @($idx['DomainController'])[0]
    }
    if (-not $cfg.ContainsKey('CM')) {
        $cfg['CM'] = @($idx['SiteServer'])[0]
    }
    if (-not $cfg.ContainsKey('Client')) {
        $clientVms = @($idx['Client'])
        if ($clientVms.Count -gt 0) { $cfg['Client'] = $clientVms[0] }
    }

    foreach ($acct in 'ClientPush','NAA','Join') {
        if (-not $cfg.ServiceAccounts.ContainsKey($acct)) {
            throw "Get-LabConfig: ServiceAccounts.$acct missing"
        }
        $a = $cfg.ServiceAccounts[$acct]
        # Password is intentionally optional here -- Install-HomeLab
        # injects it from -LabPassword / interactive prompt before any
        # phase consumes it. Only Name is required in the .psd1.
        if (-not $a.ContainsKey('Name') -or [string]::IsNullOrEmpty([string]$a['Name'])) {
            throw "Get-LabConfig: ServiceAccounts.$acct.Name is empty"
        }
    }

    # Computed convenience fields. These are NOT in the source psd1.
    $cfg['NetBIOS']    = ($cfg.DomainName -split '\.')[0].ToUpper()
    $cfg['DomainDN']   = (($cfg.DomainName -split '\.') | ForEach-Object { "DC=$_" }) -join ','
    $cfg['ConfigPath'] = $Path

    return $cfg
}
