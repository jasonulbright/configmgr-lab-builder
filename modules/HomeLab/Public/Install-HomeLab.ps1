function Install-HomeLab {
    <#
    .SYNOPSIS
        Build the entire ConfigMgr home lab from a Hyper-V-less Windows host.
        End-to-end orchestrator for the native engine.

    .DESCRIPTION
        Sequence (each step idempotent + skippable via -SkipPhases):

          01-Prereq    Test-HostPrereq, Install-LabHyperV
          02-Network   New-LabSwitch
          03-Image     New-LabBaseImage server + client (cache-keyed)
          04-VM        New-LabVM DC + CM + CLIENT (PARALLEL)
          05-Domain    Install-LabDC, Install-LabRootCA,
                       Join-LabDomain CM + CLIENT (PARALLEL),
                       New-LabServiceAccounts,
                       Add-LabSchemaContainer
          07-CMPrereqs Install-LabVcRedist (reboot if 3010),
                       Install-LabOdbcDriver, Install-LabMsOleDb,
                       Install-LabAdk, Install-LabAdkPe,
                       Install-LabWsus, Set-LabDefenderExclusions
          06-Sql       Install-LabSqlServer, Set-LabSqlMemory,
                       Set-LabSqlFirewall
          08-CM        Install-CMSite (the long one)
          09-CMConfig  Set-CMDiscovery, New-CMBoundary,
                       New-CMBoundaryGroup, New-CMDistributionPointGroup,
                       Set-CMServiceAccount, Set-CMClientPush,
                       Set-CMSoftwareDistributionThreads,
                       New-CMContentShare,
                       Install-CMSoftwareUpdatePoint,
                       New-CMTestCollection, Set-CMClientCacheSize
          10-Tools     Copy-CMTools, Set-LabAutoStartStop

        Idempotency story: every leaf operation has its own
        AlreadyInstalled / AlreadyExists short-circuit, so re-running
        on a partial deploy resumes from the first incomplete step.
        Test-HomeLab is consulted at start to choose the entry point.

        Role-driven addressing (S13): VMs are resolved through
        Resolve-LabVM at orchestrator entry, so each phase calls leaf
        functions with the VM that carries the relevant role rather
        than "the CM" or "the DC". The legacy 3-VM topology is the
        default (DC carries DomainController + CertificateAuthority;
        CM carries SqlServer + SiteServer + ManagementPoint +
        DistributionPoint + SoftwareUpdatePoint; CLIENT carries
        Client). Role-per-server templates land in S15.

        Cache wins: New-LabBaseImage hashes ISO size + LastWriteTimeUtc
        + edition, so once the cache exists in $LabImagePath every
        re-deploy starts each VM in <90s instead of ~10min from-WIM.

    .PARAMETER ConfigPath
        Path to config.psd1. Default: repo-root config.psd1.
        Mutually exclusive with -Template.

    .PARAMETER Template
        Name of a built-in topology template (without .psd1). Resolves
        to `templates/<name>.psd1` relative to the module root. Common
        values: default, split-sql, role-per-server, aio, cas-2-dps,
        cas-role-per-server. See templates/README.md. Mutually
        exclusive with -ConfigPath.

    .PARAMETER LabSourcesRoot
        Folder containing ISOs/ + SoftwarePackages/. Default
        'C:\LabSources'. ISO and CM source paths are resolved relative
        to this unless overridden.

    .PARAMETER ServerIsoPath
        Override path to the Windows Server 2025 ISO.

    .PARAMETER ClientIsoPath
        Override path to the Windows 11 ISO.

    .PARAMETER SqlIsoPath
        Override path to the SQL 2022 ISO.

    .PARAMETER CMSourcePath
        Override path to the extracted CM 2509 source tree.

    .PARAMETER LabImagePath
        Folder for cached base images and per-VM VHDXs. Default
        'C:\LabImages'.

    .PARAMETER VcRedistPath
        Folder containing vc_redist.x64.exe + vc_redist.x86.exe.
        Default: $LabSourcesRoot\SoftwarePackages.

    .PARAMETER OdbcMsiPath
        Path to msodbcsql_18.5.2.1.msi. Default:
        $LabSourcesRoot\SoftwarePackages\msodbcsql.msi.

    .PARAMETER MsOleDbMsiPath
        Path to msoledbsql.msi. OPT-IN: when omitted, the engine does
        NOT pre-install the OLE DB driver at all. CM setup manages
        MSOLEDB itself as a bundled redistributable -- verified on the
        2026-07-16 E2E: ConfigMgrSetup.log installed msoledbsql.msi
        19.3.5 x64 from C:\Install\CM-PreReqs (exit 0) after the site
        media's own copy failed hash verification. The site DB
        connection itself is enforced over ODBC ("Enforce using MSODBC
        for SQL connection"), so ODBC 18.5.2.1 is the driver that
        actually matters. Pass a path only to pre-stage a specific
        MSOLEDB build ahead of setup.

    .PARAMETER AdkOfflinePath
        ADK offline layout folder. Default:
        $LabSourcesRoot\SoftwarePackages\ADK\Offline.

    .PARAMETER AdkPeOfflinePath
        WinPE offline layout folder. Default:
        $LabSourcesRoot\SoftwarePackages\ADKPE\Offline.

    .PARAMETER SkipPhases
        Phase prefixes to skip (e.g. '01-Prereq', '03-Image'). Useful
        when iterating on later steps after an alpha tag.

    .PARAMETER ParallelThrottle
        Maximum number of `ForEach-Object -Parallel` runspaces for
        Phase 04-VM (VM provisioning) and the Phase 05-Domain join
        sub-phase. Default 3 matches the DC + CM + Client
        layout. Larger topologies (role-per-server, multi-DP) can
        raise this up to 16; the host CPU + RAM + disk IO are the
        actual ceiling. Sub-phases automatically clamp to
        min(target-count, ParallelThrottle), so a value larger
        than the topology is harmless.

    .EXAMPLE
        Install-HomeLab
        # uses defaults rooted at C:\LabSources / C:\LabImages

    .EXAMPLE
        Install-HomeLab -CMSourcePath 'D:\Stage\CM2509' -SkipPhases 01-Prereq

    .EXAMPLE
        # 7-VM role-per-server topology with more parallelism.
        Install-HomeLab -ParallelThrottle 6
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$Template,

        [Parameter()]
        [string]$LabSourcesRoot = 'C:\LabSources',

        [Parameter()]
        [string]$ServerIsoPath,

        [Parameter()]
        [string]$ClientIsoPath,

        [Parameter()]
        [string]$SqlIsoPath,

        [Parameter()]
        [string]$CMSourcePath,

        [Parameter()]
        [string]$LabImagePath = 'C:\LabImages',

        [Parameter()]
        [string]$VcRedistPath,

        [Parameter()]
        [string]$OdbcMsiPath,

        [Parameter()]
        [string]$MsOleDbMsiPath,

        [Parameter()]
        [string]$CMPreReqsPath,

        [Parameter()]
        [securestring]$LabPassword,

        [Parameter()]
        [string]$AdkOfflinePath,

        [Parameter()]
        [string]$AdkPeOfflinePath,

        [Parameter()]
        [string[]]$SkipPhases = @(),

        [Parameter()]
        [ValidateRange(1, 16)]
        [int]$ParallelThrottle = 3,

        [Parameter()]
        [hashtable]$PostCmConfig
    )

    # AutomatedLab kill (S10 mission, enforced at every entry point):
    # strip any AL path from PSModulePath so auto-load cannot drag it
    # in via name resolution, and defensively unload AL + SHiPS if
    # anything upstream already imported them. Auto-loading itself
    # stays enabled -- the engine relies on lazy import for CimCmdlets,
    # Hyper-V, Storage, NetTCPIP, Dism, ScheduledTasks, etc.
    Get-Module AutomatedLab,SHiPS -ErrorAction SilentlyContinue |
        Remove-Module -Force -ErrorAction SilentlyContinue
    $env:PSModulePath = (
        ($env:PSModulePath -split [IO.Path]::PathSeparator) |
            Where-Object { $_ -and $_ -notmatch 'AutomatedLab' }
    ) -join [IO.Path]::PathSeparator

    $deployStart = Get-Date

    # Mutex + template resolution. These are parameter-shape checks
    # and run BEFORE the PS version / elevation gates so they fail
    # cleanly in tests + scripted harness environments without
    # admin rights.
    if ($ConfigPath -and $Template) {
        throw "Install-HomeLab: -ConfigPath and -Template are mutually exclusive. Use one or the other."
    }
    if ($Template) {
        $here     = $PSScriptRoot
        $repoRoot = Split-Path (Split-Path (Split-Path $here -Parent) -Parent) -Parent
        $tmplPath = Join-Path $repoRoot (Join-Path 'templates' "$Template.psd1")
        if (-not (Test-Path -Path $tmplPath -PathType Leaf)) {
            $available = ''
            $tmplDir = Join-Path $repoRoot 'templates'
            if (Test-Path $tmplDir) {
                $available = (Get-ChildItem -Path $tmplDir -Filter '*.psd1' |
                    ForEach-Object { $_.BaseName }) -join ', '
            }
            throw "Install-HomeLab: template '$Template' not found at '$tmplPath'. Available: $available"
        }
        $ConfigPath = $tmplPath
    }

    # PS 7.6 LTS is the orchestrator floor. The manifest declares
    # PowerShellVersion='7.6' but PS does not enforce that on dot-source or
    # Import-Module from a path -- only when discovering via PSModulePath.
    # We use ForEach-Object -Parallel below (Phase 04, Phase 05 join), which
    # is PS 7-only; bail early on 5.1 with a helpful message instead of a
    # cryptic "A parameter cannot be found that matches parameter name 'Parallel'".
    if ($PSVersionTable.PSVersion -lt [version]'7.6') {
        throw "Install-HomeLab requires PowerShell 7.6 LTS+ (orchestrator). Got $($PSVersionTable.PSVersion). Install via 'winget install Microsoft.PowerShell'."
    }

    if (-not (Test-LabIsElevated)) {
        throw 'Install-HomeLab: process must be elevated; Hyper-V cmdlets require admin'
    }

    $cfg = if ($ConfigPath) { Get-LabConfig -Path $ConfigPath } else { Get-LabConfig }

    # Lab password injection. Templates ship without plaintext passwords;
    # the same single password is used for AdminPass + every entry in
    # $cfg.ServiceAccounts.*.Password. Source order:
    #   1. -LabPassword (SecureString) on the cmdline
    #   2. $cfg.AdminPass already in the .psd1 (legacy / explicit override)
    #   3. $env:HOMELAB_PASSWORD environment variable
    #   4. Interactive Read-Host -AsSecureString
    # The Read-Host fallback only runs when stdin is not redirected. Even
    # then, some hosts (non-interactive PSHost, scriptblock / Start-Job /
    # remoting / CI runners) have a non-null $Host.UI.RawUI yet still cannot
    # prompt -- Read-Host throws a cryptic "host does not support user
    # interaction" error. We catch that and rethrow the actionable message
    # below so the user learns how to supply the password instead of seeing
    # a raw host exception. Mirrors the handling in Get-LabCredential.ps1.
    if ($LabPassword) {
        $plain = [System.Net.NetworkCredential]::new('', $LabPassword).Password
    } elseif ($cfg.AdminPass) {
        $plain = [string]$cfg.AdminPass
    } elseif ($env:HOMELAB_PASSWORD) {
        $plain = [string]$env:HOMELAB_PASSWORD
    } elseif (-not [Console]::IsInputRedirected) {
        try {
            $secured = Read-Host -Prompt 'Enter lab password (used for Administrator + all service accounts)' -AsSecureString
        } catch {
            throw "Install-HomeLab: lab password is required (pass -LabPassword, set `$cfg.AdminPass, set `$env:HOMELAB_PASSWORD, or run from an interactive console)"
        }
        $plain = [System.Net.NetworkCredential]::new('', $secured).Password
        if ([string]::IsNullOrEmpty($plain)) { throw "Install-HomeLab: lab password is required" }
    } else {
        throw "Install-HomeLab: lab password is required (pass -LabPassword, set `$cfg.AdminPass, set `$env:HOMELAB_PASSWORD, or run from an interactive console)"
    }
    $cfg.AdminPass = $plain
    foreach ($svc in 'ClientPush','NAA','Join') {
        if ($cfg.ServiceAccounts -and $cfg.ServiceAccounts[$svc]) {
            $cfg.ServiceAccounts[$svc].Password = $plain
        }
    }

    # Role-driven VM resolution. Each phase below references these
    # variables instead of $cfg.DC/$cfg.CM/$cfg.Client so distributed
    # topologies (S15+) can split roles onto separate VMs without
    # touching the orchestrator. CertificateAuthority is optional;
    # if no VM carries it, the DC VM is reused (default).
    $dcVM     = Resolve-LabVM -Config $cfg -Role DomainController
    $caVMs    = @(Get-LabVMByRole -Config $cfg -Role CertificateAuthority)
    $caVM     = if ($caVMs.Count -gt 0) { $caVMs[0] } else { $dcVM }
    $siteVM   = Resolve-LabVM -Config $cfg -Role SiteServer
    $sqlVM    = Resolve-LabVM -Config $cfg -Role SqlServer
    $mpVM     = Resolve-LabVM -Config $cfg -Role ManagementPoint
    $dpVM     = Resolve-LabVM -Config $cfg -Role DistributionPoint
    $supVM    = Resolve-LabVM -Config $cfg -Role SoftwareUpdatePoint
    $clientVMs = @(Get-LabVMByRole -Config $cfg -Role Client)

    # CAS hierarchy (S16). The CentralAdministrationSite role is part
    # of the schema so CAS topologies can be defined and validated,
    # but the orchestrator does not yet plumb the CAS install + child
    # primary replication path. Fail clearly rather than half-install.
    $casVMs = @(Get-LabVMByRole -Config $cfg -Role CentralAdministrationSite)
    if ($casVMs.Count -gt 0) {
        throw "Install-HomeLab: CAS hierarchy topology detected (VM '$($casVMs[0].Name)' carries CentralAdministrationSite). The CAS install + replication path is not yet implemented in this engine. Use a non-CAS topology, or wait for a future tag that adds Private/08-CM/CAS/ helpers."
    }

    # Resolve defaults that depend on $LabSourcesRoot.
    $sw = Join-Path $LabSourcesRoot 'SoftwarePackages'
    # Canonical subfolder first (SoftwarePackages\VCRedist), flat layout
    # as fallback -- same pattern as ODBC/MSOLEDB below. The real host
    # keeps vc_redist.x64.exe in VCRedist\; with the flat default the
    # Phase 07 VC++ install silently skipped (Test-Path gate).
    if (-not $VcRedistPath) {
        $VcRedistPath = if (Test-Path (Join-Path $sw 'VCRedist\vc_redist.x64.exe')) {
            Join-Path $sw 'VCRedist'
        } else { $sw }
    }
    # ODBC + MSOLEDB are required pre-setup: CM 2509's setup.exe makes its
    # initial SQL probe (ConfigMgrSetup.log "Failed to connect SQL Server
    # 'master' db" with "Invalid connection string attribute") using the
    # current ODBC client BEFORE its bundled MSI install kicks in. If the
    # box only has the legacy "ODBC SQL Server Driver" that ships with
    # Windows, the probe fails and setup exits 1. Phase 07 must place the
    # 18.5.2.1 ODBC + MSOLEDBSQL19 drivers first.
    #
    # Resolve from the canonical subfolder layout (SoftwarePackages\ODBC,
    # SoftwarePackages\MSOLEDB) and fall back to a flat layout for legacy
    # installs.
    if (-not $OdbcMsiPath) {
        foreach ($candidate in 'ODBC\msodbcsql.msi','msodbcsql.msi') {
            $p = Join-Path $sw $candidate
            if (Test-Path $p) { $OdbcMsiPath = $p; break }
        }
        if (-not $OdbcMsiPath) { $OdbcMsiPath = Join-Path $sw 'msodbcsql.msi' }
    }
    # MsOleDbMsiPath intentionally has NO default resolution: MSOLEDB
    # is a CM-setup-managed redistributable (see the parameter help),
    # so the engine only pre-installs it when the caller explicitly
    # provides a path.
    if (-not $CMPreReqsPath) {
        foreach ($candidate in @('CM-Prereqs','CMPrereqs','CM-Prereqs-2509-CB')) {
            $p = Join-Path $sw $candidate
            if (Test-Path $p) { $CMPreReqsPath = $p; break }
        }
    }
    if (-not $AdkOfflinePath)  { $AdkOfflinePath  = Join-Path $sw 'ADK\Offline' }
    if (-not $AdkPeOfflinePath) { $AdkPeOfflinePath = Join-Path $sw 'ADKPE\Offline' }
    if (-not $CMSourcePath)    { $CMSourcePath    = Join-Path $sw 'CM' }

    $isoRoot = Join-Path $LabSourcesRoot 'ISOs'
    if (-not $ServerIsoPath) {
        $ServerIsoPath = Find-LabIsoPath -Directory $isoRoot -Patterns @('*SERVER*EVAL*.iso')
    }
    if (-not $ClientIsoPath) {
        # Accept the common Microsoft Eval ISO filename patterns, including
        # the 25H2 SVC release naming (CLIENTENTERPRISEEVAL_OEMRET).
        $ClientIsoPath = Find-LabIsoPath -Directory $isoRoot -Patterns @(
            '*WIN11*EVAL*.iso'
            '*Windows*11*Eval*.iso'
            '*CLIENTENTERPRISE*EVAL*.iso'
        )
    }
    if (-not $SqlIsoPath) {
        $SqlIsoPath = Find-LabIsoPath -Directory $isoRoot -Patterns @('*SQL*2022*.iso')
    }

    function _Skip { param([string]$Phase) return ($SkipPhases -contains $Phase) }

    $domainCred = $null
    $localCred  = New-Object System.Management.Automation.PSCredential(
        'Administrator',
        (ConvertTo-SecureString -String $cfg.AdminPass -AsPlainText -Force))

    Write-LabLog "===== Install-HomeLab starting =====" -Status INFO
    Write-LabLog "Domain=$($cfg.DomainName) Site=$($cfg.SiteCode)" -Status INFO

    # ---- 01-Prereq ----
    if (-not (_Skip '01-Prereq')) {
        Write-LabLog '--- Phase 01-Prereq ---' -Status INFO
        $winrmProbe = foreach ($vm in $cfg.VMs) {
            $vm.Name
            "$($vm.Name).$($cfg.DomainName)"
        }
        $startupDemand = [long](($cfg.VMs | Measure-Object -Property Memory -Sum).Sum)
        $hp = Test-HostPrereq -LabImagePath $LabImagePath -RequireElevation `
            -WinRMProbeNames @($winrmProbe) `
            -VMStartupMemoryBytes $startupDemand `
            -ConfigVMNames @($cfg.VMs.Name)
        if (-not $hp.Pass) {
            $failures = $hp.Checks.GetEnumerator() | Where-Object { -not $_.Value.Pass }
            # Hyper-V missing is a warning, not a hard fail; we install it next.
            $hard = $failures | Where-Object { $_.Key -ne 'HyperVFeature' -and $_.Key -ne 'HyperVModule' }
            if ($hard) {
                throw ("Install-HomeLab: host prereqs failed: " + (($hard | ForEach-Object { "$($_.Key)=$($_.Value.Message)" }) -join '; '))
            }
        }

        $hv = Install-LabHyperV
        if ($hv.Status -eq 'EnabledRebootRequired') {
            throw 'Install-HomeLab: Hyper-V was just enabled and the host needs a reboot. Reboot, then re-run Install-HomeLab.'
        }
    }

    # ---- 02-Network ----
    $networkName = "$($cfg.LabName)-Network"
    if (-not (_Skip '02-Network')) {
        Write-LabLog '--- Phase 02-Network ---' -Status INFO
        $null = New-LabSwitch -Name $networkName

        # Host->VM name resolution. The host is not in the lab domain
        # and its DNS knows nothing about it; every later phase connects
        # by name (New-PSSession CM01 / DC01.contoso.com). The engine
        # owns hosts-file entries for this -- previously it silently
        # relied on hand-added ones (real-host drift, found 2026-07-16).
        $hostsEntries = foreach ($vm in $cfg.VMs) {
            @{ IP = $vm.IP; Names = @($vm.Name, "$($vm.Name).$($cfg.DomainName)") }
        }
        $null = Set-LabHostsEntries -Entries $hostsEntries
    }

    # ---- 03-Image ----
    $serverBase = $null
    $clientBase = $null
    if (-not (_Skip '03-Image')) {
        Write-LabLog '--- Phase 03-Image ---' -Status INFO
        if (-not $ServerIsoPath -or -not (Test-Path $ServerIsoPath)) {
            throw "Install-HomeLab: Server ISO not found at '$ServerIsoPath'"
        }
        if (-not $ClientIsoPath -or -not (Test-Path $ClientIsoPath)) {
            throw "Install-HomeLab: Client ISO not found at '$ClientIsoPath'"
        }

        $serverBase = New-LabBaseImage -IsoPath $ServerIsoPath `
            -NameFilter $cfg.ServerOSFilter `
            -LabImagePath $LabImagePath `
            -AdministratorPassword $cfg.AdminPass `
            -SizeGB 100

        $clientBase = New-LabBaseImage -IsoPath $ClientIsoPath `
            -NameFilter $cfg.ClientOSFilter `
            -LabImagePath $LabImagePath `
            -AdministratorPassword $cfg.AdminPass `
            -SizeGB 100
    }

    # ---- 04-VM (parallel provisioning) ----
    if (-not (_Skip '04-VM')) {
        Write-LabLog "--- Phase 04-VM (parallel x$($cfg.VMs.Count)) ---" -Status INFO

        $modulePath = (Get-Module HomeLab).Path
        if (-not $modulePath) {
            $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'HomeLab.psd1'
        }

        # Build a job spec per VM. Server VMs (anything not Client-only)
        # use the server base image; Client-only VMs use the client base.
        $jobs = foreach ($vm in $cfg.VMs) {
            $isClientOnly = ($vm.Roles.Count -eq 1) -and ($vm.Roles[0] -eq 'Client')
            $parent = if ($isClientOnly) { $clientBase.Path } else { $serverBase.Path }
            $disk = if ($vm.ContainsKey('OSDiskSize')) { [int]$vm.OSDiskSize } else { 0 }
            @{
                Name   = $vm.Name
                IP     = "$($vm.IP)/24"
                Mac    = New-LabMacAddress -IPAddress $vm.IP
                Memory = $vm.Memory; Min = $vm.MinMemory; Max = $vm.MaxMemory
                Cpu    = $vm.Processors; Disk = $disk
                Parent = $parent
            }
        }
        $macDupes = @($jobs | Group-Object Mac | Where-Object { $_.Count -gt 1 })
        if ($macDupes.Count -gt 0) {
            $dupes = ($macDupes | ForEach-Object { $_.Name }) -join ', '
            throw "Install-HomeLab: generated duplicate lab NIC MAC address(es): $dupes"
        }

        $gatewayIp = $dcVM.IP
        $dnsIp     = $dcVM.IP

        # Bare-metal rule (feedback_homelab_build_from_bare_metal.md): the
        # engine never preserves prior state. Any VM with one of the
        # config's VM names is clobbered before recreation. Anything
        # else on the host is untouched.
        $existingNames = @(
            Get-VM -Name $jobs.Name -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name
        )
        if ($existingNames.Count -gt 0) {
            Write-LabLog "Removing existing lab VMs before recreate: $($existingNames -join ', ')" -Status WARN
        }

        $vmThrottle = [Math]::Min($jobs.Count, $ParallelThrottle)
        $results = $jobs | ForEach-Object -Parallel {
            Import-Module $using:modulePath -Force -ErrorAction Stop

            $j = $_
            New-LabVM `
                -VMName $j.Name `
                -ParentVhdx $j.Parent `
                -LabSwitchName $using:networkName `
                -LabIP $j.IP `
                -Gateway $using:gatewayIp `
                -DnsServer $using:dnsIp `
                -LabNicMac $j.Mac `
                -MemoryStartupBytes $j.Memory `
                -MinMemoryBytes $j.Min `
                -MaxMemoryBytes $j.Max `
                -ProcessorCount $j.Cpu `
                -OSDiskSize $j.Disk `
                -AdministratorPassword $using:cfg.AdminPass `
                -LabImagePath $using:LabImagePath `
                -Force
        } -ThrottleLimit $vmThrottle

        Write-LabLog "Phase 04-VM: $($results.Count) VMs provisioned (throttle=$vmThrottle)" -Status OK

        # First software install on every fresh VM: latest Microsoft VC++
        # v14 runtime. Installed before Phase 05+ so ALL downstream
        # installers (SQL setup, MSOLEDBSQL19, ConfigMgr setup, ADK)
        # find a current-enough runtime. C++ is foundational on Windows;
        # mismatched/old runtimes silently break MSI prereq checks.
        Write-LabLog 'Phase 04-VM: installing latest VC++ runtime on every VM (foundational prereq)' -Status RUN
        $vcResults = Install-LabVcLatest -ComputerNames @($cfg.VMs.Name) -Credential $localCred `
            -ThrottleLimit $vmThrottle
        # 3010 from vc_redist means reboot recommended. Pending-reboot
        # state poisons every downstream MSI (SQL setup, MSOLEDBSQL19,
        # ConfigMgr) -- reboot now and wait for WinRM before we move on.
        $rebootTargets = @($vcResults | Where-Object { $_.RebootNeeded } | ForEach-Object ComputerName)
        if ($rebootTargets) {
            Write-LabLog "Phase 04-VM: VC++ install requested reboot on $($rebootTargets -join ', ')" -Status RUN
            # Capture LastBootUpTime BEFORE rebooting so we can verify the
            # VM actually rebooted -- not just that WinRM is up. Trigger
            # the restart from inside the VM (so failures surface as
            # exceptions, not silently swallowed by Restart-Computer
            # -ErrorAction SilentlyContinue from the host side). Then
            # wait for LastBootUpTime to advance.
            $bootBefore = @{}
            foreach ($cn in $rebootTargets) {
                $bootBefore[$cn] = Invoke-LabCommand -ComputerName $cn -Credential $localCred -ScriptBlock {
                    [string](Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                }
            }
            foreach ($cn in $rebootTargets) {
                try {
                    Invoke-LabCommand -ComputerName $cn -Credential $localCred -ScriptBlock {
                        Restart-Computer -Force
                    } 2>$null | Out-Null
                } catch {
                    # Expected: WinRM channel drops as the VM goes down.
                    if ($_.Exception.Message -notmatch 'shut|connect|transport|broken|terminated|aborted|I/O') { throw }
                }
            }
            Clear-LabSessionCache
            Start-Sleep -Seconds 30
            foreach ($cn in $rebootTargets) {
                $up = Wait-LabVM -ComputerName $cn -Credential $localCred -TimeoutSeconds 600
                if (-not $up) { throw "Phase 04-VM: $cn did not return to WinRM-ready after VC++ reboot" }
                $bootAfter = Invoke-LabCommand -ComputerName $cn -Credential $localCred -ScriptBlock {
                    [string](Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                }
                if ($bootAfter -eq $bootBefore[$cn]) {
                    throw "Phase 04-VM: $cn LastBootUpTime did not advance ($bootBefore[$cn]) -- restart did not actually happen, pending-reboot state still in place"
                }
            }
        }
        Write-LabLog 'Phase 04-VM: VC++ runtime baseline complete' -Status OK
    }

    # ---- 05-Domain ----
    if (-not (_Skip '05-Domain')) {
        Write-LabLog '--- Phase 05-Domain (DC promotion + ADCS) ---' -Status INFO
        $dcFqdn = "$($dcVM.Name).$($cfg.DomainName)"

        # Promote DC.
        Install-LabDC `
            -ComputerName $dcVM.Name -LocalCredential $localCred `
            -DomainName $cfg.DomainName `
            -SafeModeAdministratorPassword (ConvertTo-SecureString $cfg.AdminPass -AsPlainText -Force)

        # Phase 05 bootstrap uses the built-in domain Administrator (the
        # promoted local-Admin, password preserved). LabAdmin does not exist
        # yet; New-LabServiceAccounts creates it below. After that we rebind
        # $domainCred to LabAdmin for all downstream phases.
        $bootstrapCred = New-Object System.Management.Automation.PSCredential(
            "$($cfg.NetBIOS)\Administrator",
            (ConvertTo-SecureString -String $cfg.AdminPass -AsPlainText -Force))

        Install-LabRootCA -ComputerName "$($caVM.Name).$($cfg.DomainName)" -DomainCredential $bootstrapCred

        # Domain-join every VM that is NOT itself the Domain Controller.
        # In default topology that's CM + CLIENT; in role-per-server
        # topologies it's everything but the DC VM.
        $joinTargets = @($cfg.VMs | Where-Object { 'DomainController' -notin $_.Roles })
        if ($joinTargets.Count -gt 0) {
            Write-LabLog "--- Phase 05-Domain (parallel domain join: $($joinTargets.Name -join ', ')) ---" -Status INFO
            $modulePath = (Get-Module HomeLab).Path
            $throttle = [Math]::Min($joinTargets.Count, $ParallelThrottle)
            $joinTargets | ForEach-Object -Parallel {
                Import-Module $using:modulePath -Force
                $localCred = $using:localCred
                $domainCred = $using:bootstrapCred
                Join-LabDomain `
                    -ComputerName $_.Name `
                    -LocalCredential $localCred `
                    -DomainCredential $domainCred `
                    -DomainName ($using:cfg).DomainName
            } -ThrottleLimit $throttle | Out-Null
        }

        # Client push prerequisite: open inbound SMB/admin$ + RPC/WMI on
        # every Client-role VM. Win11 blocks these by default even on
        # the Domain profile (WinRM has its own default rule; File and
        # Printer Sharing does not), so without this the CCRs fail
        # forever with "access denied or invalid network path"
        # (first verified E2E, 2026-07-16).
        foreach ($clientVm in $clientVMs) {
            Enable-LabClientPushFirewall -ComputerName $clientVm.Name -Credential $localCred | Out-Null
        }

        # Service accounts on the DC: LabAdmin (orchestrator/Full Admin)
        # plus the 3 functional accounts (ClientPush / NAA / Join).
        New-LabServiceAccounts `
            -DCComputerName $dcFqdn -DomainCredential $bootstrapCred `
            -DomainName $cfg.DomainName -NetBIOSName $cfg.NetBIOS `
            -AdminUser $cfg.AdminUser -AdminPass $cfg.AdminPass `
            -ServiceAccounts $cfg.ServiceAccounts

        # LabAdmin now exists; rebind for downstream phases.
        $domainCred = Get-LabCredential -Identity Admin -Config $cfg
    }

    # ---- 07-CMPrereqs (run before SQL because the CM site server
    # needs VC++ before SQL) ----
    if (-not (_Skip '07-CMPrereqs')) {
        Write-LabLog '--- Phase 07-CMPrereqs ---' -Status INFO
        if (-not $domainCred) { $domainCred = Get-LabCredential -Identity Admin -Config $cfg }
        $cmName = $siteVM.Name

        # CM 2509 setup checks for .NET Framework 3.5. Windows Server 2025
        # ships with it as a Feature-on-Demand removed by default. Install
        # from the Win Server ISO's sources\sxs payload.
        $netFxInstalled = Invoke-LabCommand -ComputerName $cmName -Credential $domainCred -ScriptBlock {
            [bool]((Get-WindowsFeature -Name NET-Framework-Core).InstallState -eq 'Installed')
        }
        if (-not $netFxInstalled) {
            Write-LabLog "[$cmName] Installing .NET Framework 3.5 (CM prereq)" -Status RUN
            $alreadyAttached = Get-VMDvdDrive -VMName $cmName -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $ServerIsoPath }
            if (-not $alreadyAttached) {
                Add-VMDvdDrive -VMName $cmName -Path $ServerIsoPath -ErrorAction Stop
            }
            try {
                $r = Invoke-LabCommand -ComputerName $cmName -Credential $domainCred -ScriptBlock {
                    $dvd = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' |
                        Where-Object { Test-Path "$($_.DeviceID)\sources\sxs" } |
                        Select-Object -First 1
                    if (-not $dvd) { throw "No DVD with sources\sxs found inside $env:COMPUTERNAME" }
                    $sxs = "$($dvd.DeviceID)\sources\sxs"
                    $feat = Install-WindowsFeature -Name NET-Framework-Core -Source $sxs -ErrorAction Stop
                    if (-not $feat.Success) {
                        throw "Install-WindowsFeature NET-Framework-Core failed: $($feat | Out-String)"
                    }
                    return [pscustomobject]@{ ExitCode = 0; State = [string](Get-WindowsFeature NET-Framework-Core).InstallState }
                }
                Write-LabLog "[$cmName] .NET Framework 3.5: $($r.State)" -Status OK
            } finally {
                Get-VMDvdDrive -VMName $cmName -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -eq $ServerIsoPath } |
                    Set-VMDvdDrive -Path $null
            }
        } else {
            Write-LabLog "[$cmName] .NET Framework 3.5 already installed" -Status SKIP
        }

        # CM site server Windows-feature prereqs: IIS (with the long list
        # of sub-features CM checks), BITS + BITS-IIS extensions, RDC.
        # Without these the CM setup prereq rule check fails on
        # "RDC library not registered" + "could not connect to
        # root\WebAdministration".
        Write-LabLog "[$cmName] Installing CM site-server Windows features (IIS, BITS, RDC)" -Status RUN
        $featResult = Invoke-LabCommand -ComputerName $cmName -Credential $domainCred -ScriptBlock {
            $wanted = @(
                'RDC'
                'BITS','BITS-IIS-Ext','BITS-Compact-Server'
                'Web-Server','Web-WebServer','Web-Common-Http','Web-Default-Doc','Web-Dir-Browsing'
                'Web-Http-Errors','Web-Static-Content','Web-Http-Redirect','Web-Health','Web-Http-Logging'
                'Web-Log-Libraries','Web-Request-Monitor','Web-Http-Tracing','Web-Performance'
                'Web-Stat-Compression','Web-Dyn-Compression','Web-Security','Web-Filtering'
                'Web-Url-Auth','Web-Windows-Auth','Web-App-Dev','Web-Net-Ext','Web-Net-Ext45'
                'Web-Asp-Net','Web-Asp-Net45','Web-ISAPI-Ext','Web-ISAPI-Filter'
                'Web-Mgmt-Tools','Web-Mgmt-Console','Web-Mgmt-Compat','Web-Metabase'
                'Web-WMI','Web-Lgcy-Scripting','Web-Lgcy-Mgmt-Console','Web-Scripting-Tools'
                'NET-Framework-45-Features','NET-Framework-45-ASPNET','NET-WCF-HTTP-Activation45'
            )
            # Filter to features that actually exist on this OS (some IIS
            # legacy compat names were removed in Server 2022/2025).
            $available = (Get-WindowsFeature -Name $wanted -ErrorAction SilentlyContinue).Name
            $features = $wanted | Where-Object { $available -contains $_ }
            $r = Install-WindowsFeature -Name $features -ErrorAction Stop
            return [pscustomobject]@{ Success = [bool]$r.Success; Restart = [bool]$r.RestartNeeded; Installed = $features.Count }
        }
        if ($featResult.Restart) {
            Write-LabLog "[$cmName] Reboot required after feature install; restarting" -Status RUN
            Invoke-LabCommand -ComputerName $cmName -Credential $domainCred -ScriptBlock {
                Restart-Computer -Force
            } 2>$null | Out-Null
            Clear-LabSessionCache
            Start-Sleep -Seconds 60
            $up = Wait-LabVM -ComputerName $cmName -Credential $domainCred -TimeoutSeconds 600
            if (-not $up) { throw "CM01 did not return to WinRM-ready after feature-install reboot" }
        }
        Write-LabLog "[$cmName] CM site-server features ready" -Status OK

        $vc64 = Join-Path $VcRedistPath 'vc_redist.x64.exe'
        $vc86 = Join-Path $VcRedistPath 'vc_redist.x86.exe'
        if (Test-Path $vc64) {
            # `-X86Path:(if ...)` would parse the parens as a command call
            # and try to resolve `if` as a cmdlet -- the same trap that bit
            # Install-LabHyperV's fast path. Use a separate variable.
            $x86PathArg = if (Test-Path $vc86) { $vc86 } else { $null }
            $vcResult = Install-LabVcRedist -ComputerName $cmName -DomainCredential $domainCred `
                -X64Path $vc64 -X86Path $x86PathArg
            if ($vcResult.RebootRequired) {
                Write-LabLog "[$cmName] VC++ requested reboot; restarting" -Status WARN
                Invoke-LabCommand -ComputerName $cmName -Credential $domainCred -ScriptBlock {
                    Restart-Computer -Force
                } -ErrorAction SilentlyContinue
                Clear-LabSessionCache
                $vcReady = Wait-LabVM -ComputerName $cmName -Credential $domainCred -TimeoutSeconds 600
                if (-not $vcReady) {
                    throw "Install-HomeLab: $cmName did not return to WinRM-ready within 600s after VC++ reboot."
                }
            }
        }

        if (Test-Path $OdbcMsiPath) {
            Install-LabOdbcDriver -ComputerName $cmName -DomainCredential $domainCred -MsiPath $OdbcMsiPath | Out-Null
        }

        if ($MsOleDbMsiPath) {
            Install-LabMsOleDb -ComputerName $cmName -DomainCredential $domainCred -MsiPath $MsOleDbMsiPath | Out-Null
        } else {
            Write-LabLog "[$cmName] MSOLEDB pre-install skipped by design: CM setup installs its own OLE DB driver (pass -MsOleDbMsiPath to override)" -Status SKIP
        }

        if (Test-Path $AdkOfflinePath) {
            Install-LabAdk -ComputerName $cmName -DomainCredential $domainCred -OfflineLayoutPath $AdkOfflinePath | Out-Null
        }
        if (Test-Path $AdkPeOfflinePath) {
            Install-LabAdkPe -ComputerName $cmName -DomainCredential $domainCred -OfflineLayoutPath $AdkPeOfflinePath | Out-Null
        }

        Set-LabDefenderExclusions -ComputerName $cmName -DomainCredential $domainCred | Out-Null
    }

    # ---- 06-Sql ----
    if (-not (_Skip '06-Sql')) {
        Write-LabLog '--- Phase 06-Sql ---' -Status INFO
        if (-not $SqlIsoPath -or -not (Test-Path $SqlIsoPath)) {
            throw "Install-HomeLab: SQL ISO not found at '$SqlIsoPath'"
        }
        if (-not $domainCred) { $domainCred = Get-LabCredential -Identity Admin -Config $cfg }

        Install-LabSqlServer `
            -ComputerName $sqlVM.Name -DomainCredential $domainCred `
            -IsoPath $SqlIsoPath `
            -SaPassword $cfg.AdminPass `
            -SqlSysAdminAccounts @(
                'BUILTIN\Administrators'
                "$($cfg.NetBIOS)\Domain Admins"
                "$($cfg.NetBIOS)\$($siteVM.Name)$"
            ) | Out-Null

        Set-LabSqlMemory   -ComputerName $sqlVM.Name -DomainCredential $domainCred | Out-Null
        Set-LabSqlFirewall -ComputerName $sqlVM.Name -DomainCredential $domainCred | Out-Null
    }

    # WSUS install moved out of Phase 07 because wsusutil postinstall needs
    # SQL up. Still gated by 07-CMPrereqs so -SkipPhases works as before.
    if (-not (_Skip '07-CMPrereqs')) {
        if (-not $domainCred) { $domainCred = Get-LabCredential -Identity Admin -Config $cfg }
        Install-LabWsus -ComputerName $cmName -DomainCredential $domainCred | Out-Null
    }

    # ---- 05-Domain (continued): schema container after CM source is stagable ----
    if (-not (_Skip '05-Domain')) {
        # Schema extension needs extadsch.exe from CM media. Push CM
        # source to CM01 here so Install-CMSite can skip the push later.
        # Auto-detect nested layout: if $CMSourcePath has a single
        # subfolder containing SMSSETUP, use that subfolder as the
        # actual source (common when admins drop CM media inside a
        # version-named folder like ConfigMgr_2509).
        if ($CMSourcePath -and (Test-Path -Path $CMSourcePath -PathType Container)) {
            $effectiveSrc = $CMSourcePath
            if (-not (Test-Path (Join-Path $CMSourcePath 'SMSSETUP'))) {
                $kids = @(Get-ChildItem -Path $CMSourcePath -Directory)
                $nested = $kids | Where-Object { Test-Path (Join-Path $_.FullName 'SMSSETUP') } | Select-Object -First 1
                if ($nested) { $effectiveSrc = $nested.FullName }
            }
            $hasSource = Invoke-LabCommand -ComputerName $siteVM.Name -Credential $domainCred -ScriptBlock {
                Test-Path 'C:\Install\CM\SMSSETUP\BIN\X64\extadsch.exe'
            }
            if (-not $hasSource) {
                Write-LabLog "[$($siteVM.Name)] Pushing CM source from $effectiveSrc (pre-schema)" -Status RUN
                Invoke-LabCommand -ComputerName $siteVM.Name -Credential $domainCred -ScriptBlock {
                    if (Test-Path 'C:\Install\CM')        { Remove-Item 'C:\Install\CM'        -Recurse -Force -ErrorAction SilentlyContinue }
                    if (Test-Path 'C:\Install\__cmstage') { Remove-Item 'C:\Install\__cmstage' -Recurse -Force -ErrorAction SilentlyContinue }
                    New-Item -Path 'C:\Install' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                } | Out-Null
                # Push into a staging dir then move the inner folder up
                # so the final layout is C:\Install\CM\SMSSETUP\... and
                # not C:\Install\CM\<source-leaf>\SMSSETUP\...
                Copy-LabFile -ComputerName $siteVM.Name -Credential $domainCred `
                             -Path $effectiveSrc -Destination 'C:\Install\__cmstage' -Recurse `
                             -Activity 'Push CM 2509 source'
                Invoke-LabCommand -ComputerName $siteVM.Name -Credential $domainCred -ScriptBlock {
                    $stageRoot = 'C:\Install\__cmstage'
                    $dirs = @(Get-ChildItem $stageRoot -Directory)
                    if ($dirs.Count -ne 1) {
                        throw "Push CM source (pre-schema): expected exactly 1 staged child folder, got $($dirs.Count)"
                    }
                    Move-Item $dirs[0].FullName 'C:\Install\CM' -Force
                    Remove-Item $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
                } | Out-Null
            }
        }

        # Schema extension MUST run as a Schema Admin. LabAdmin is in
        # Domain Admins only -- not Schema Admins. The built-in
        # CONTOSO\Administrator IS in Schema Admins by default in the
        # forest root domain, so use $bootstrapCred (== CONTOSO\Administrator)
        # for this single call.
        Add-LabSchemaContainer `
            -DCComputerName "$($dcVM.Name).$($cfg.DomainName)" `
            -CMComputerName $siteVM.Name `
            -DomainCredential $bootstrapCred `
            -ExtAdSchPath 'C:\Install\CM\SMSSETUP\BIN\X64\extadsch.exe' | Out-Null
    }

    # ---- 08-CM (the long one) ----
    if (-not (_Skip '08-CM')) {
        Write-LabLog '--- Phase 08-CM (CM 2509 site install, ~30-60min) ---' -Status INFO
        if (-not $domainCred) { $domainCred = Get-LabCredential -Identity Admin -Config $cfg }

        # Don't pass -CMSourcePath: the pre-schema push above already
        # placed CM media at C:\Install\CM with the correct layout.
        # Letting Install-CMSite re-push would re-introduce the nested
        # folder structure that breaks setup.exe path resolution.

        # Pre-push CM prereqs cache via stage-rename to dodge the same
        # nested-folder bug. Install-CMSite still gates PrerequisiteComp
        # on whether $CMPreReqsPath was provided to it, so we ALSO pass
        # the path; but our pre-push already placed files correctly so
        # Install-CMSite's own Copy-LabFile call below sees the dest is
        # already populated and overwrites in place.
        if ($CMPreReqsPath -and (Test-Path -Path $CMPreReqsPath -PathType Container)) {
            $hasPrereqs = Invoke-LabCommand -ComputerName $siteVM.Name -Credential $domainCred -ScriptBlock {
                $root = 'C:\Install\CM-PreReqs'
                (Test-Path $root) -and ((Get-ChildItem $root -File -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null)
            }
            if (-not $hasPrereqs) {
                Write-LabLog "[$($siteVM.Name)] Pre-pushing CM prereqs cache" -Status RUN
                Invoke-LabCommand -ComputerName $siteVM.Name -Credential $domainCred -ScriptBlock {
                    if (Test-Path 'C:\Install\CM-PreReqs')   { Remove-Item 'C:\Install\CM-PreReqs'   -Recurse -Force -ErrorAction SilentlyContinue }
                    if (Test-Path 'C:\Install\__prereqstage') { Remove-Item 'C:\Install\__prereqstage' -Recurse -Force -ErrorAction SilentlyContinue }
                } | Out-Null
                Copy-LabFile -ComputerName $siteVM.Name -Credential $domainCred `
                             -Path $CMPreReqsPath -Destination 'C:\Install\__prereqstage' -Recurse `
                             -Activity 'Push CM prereqs cache'
                Invoke-LabCommand -ComputerName $siteVM.Name -Credential $domainCred -ScriptBlock {
                    $stage = 'C:\Install\__prereqstage'
                    $dirs = @(Get-ChildItem $stage -Directory)
                    if ($dirs.Count -ne 1) {
                        throw "Pre-push CM prereqs: expected exactly 1 staged child folder, got $($dirs.Count)"
                    }
                    Move-Item $dirs[0].FullName 'C:\Install\CM-PreReqs' -Force
                    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
                } | Out-Null
                $hasFiles = Invoke-LabCommand -ComputerName $siteVM.Name -Credential $domainCred -ScriptBlock {
                    (Get-ChildItem 'C:\Install\CM-PreReqs' -File -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null
                }
                if (-not $hasFiles) {
                    throw "Pre-push CM prereqs: C:\Install\CM-PreReqs is empty after stage-rename"
                }
            }
        }

        Install-CMSite `
            -ComputerName $siteVM.Name -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode -SiteName $cfg.SiteName `
            -CMServerFqdn "$($siteVM.Name).$($cfg.DomainName)" `
            -CMPreReqsPath $CMPreReqsPath | Out-Null

        # CM setup writes machine-wide $env:SMS_ADMIN_UI_PATH and installs
        # the AdminConsole/PowerShell module. Cached PSSessions captured
        # their environment BEFORE setup ran, so they don't see the new
        # var. Drop the cache so Phase 09 wrappers get fresh sessions
        # with SMS_ADMIN_UI_PATH populated.
        Clear-LabSessionCache
    }

    # ---- 09-CMConfig ----
    if (-not (_Skip '09-CMConfig')) {
        Write-LabLog '--- Phase 09-CMConfig ---' -Status INFO
        if (-not $domainCred) { $domainCred = Get-LabCredential -Identity Admin -Config $cfg }
        $cmName = $siteVM.Name
        $cmFqdn = "$($siteVM.Name).$($cfg.DomainName)"

        New-CMContentShare -ComputerName $cmName -DomainCredential $domainCred `
            -NetBIOSName $cfg.NetBIOS -NAAAccount $cfg.ServiceAccounts.NAA.Name | Out-Null

        # No explicit Add-CMFullAdministrator call needed: CM setup auto-
        # adds the user account that ran setup.exe to the 'Full Administrator'
        # role at install time. Phase 08 runs setup.exe as $domainCred =
        # CONTOSO\LabAdmin (rebound after New-LabServiceAccounts created it),
        # so LabAdmin is already the lab's Full Administrator and the engine
        # never has to call New-CMAdministrativeUser.

        Set-CMServiceAccount -ComputerName $cmName -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode `
            -PushAccount  "$($cfg.NetBIOS)\$($cfg.ServiceAccounts.ClientPush.Name)" `
            -PushPassword $cfg.ServiceAccounts.ClientPush.Password `
            -NAAAccount   "$($cfg.NetBIOS)\$($cfg.ServiceAccounts.NAA.Name)" `
            -NAAPassword  $cfg.ServiceAccounts.NAA.Password

        Set-CMDiscovery -ComputerName $cmName -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode -DomainDN $cfg.DomainDN

        # Tight discovery cadence (3 min) burns CPU long-term. Schedule a
        # one-shot 6 hours out that flips it back to the production-default
        # 6-hour delta and self-deletes. By T+6h all lab VMs are discovered,
        # client push has fired, and the homelab can idle quietly.
        Register-CMDiscoveryRelaxTask -ComputerName $cmName `
            -DomainCredential $domainCred -SiteCode $cfg.SiteCode | Out-Null

        $boundary = New-CMBoundary -ComputerName $cmName -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode -Subnet "$($cfg.Network).0/24"

        New-CMBoundaryGroup -ComputerName $cmName -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode -Name 'HomeLab Boundary Group' `
            -BoundaryId $boundary.BoundaryId `
            -SiteSystemServerFqdn $cmFqdn | Out-Null

        New-CMDistributionPointGroup -ComputerName $cmName -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode | Out-Null

        Set-CMClientPush -ComputerName $cmName -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode `
            -PushAccount "$($cfg.NetBIOS)\$($cfg.ServiceAccounts.ClientPush.Name)"

        Set-CMSoftwareDistributionThreads -ComputerName $cmName -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode `
            -NAAAccount "$($cfg.NetBIOS)\$($cfg.ServiceAccounts.NAA.Name)"

        # Distributed CM roles (S15). The unattend INI already wires
        # ManagementPoint and DistributionPoint to the site server, so
        # we only invoke the per-role helpers when those roles live on
        # a DIFFERENT VM. For default 3-VM topology this block is a
        # no-op; for role-per-server topologies the additional MP / DP
        # roles get attached after Install-CMSite has stood up the
        # site database and CM provider.
        foreach ($extraMp in @(Get-LabVMByRole -Config $cfg -Role ManagementPoint)) {
            if ($extraMp.Name -ne $siteVM.Name) {
                Add-CMRoleManagementPoint -ComputerName $cmName -DomainCredential $domainCred `
                    -SiteCode $cfg.SiteCode `
                    -MpServerFqdn "$($extraMp.Name).$($cfg.DomainName)" | Out-Null
            }
        }
        foreach ($extraDp in @(Get-LabVMByRole -Config $cfg -Role DistributionPoint)) {
            if ($extraDp.Name -ne $siteVM.Name) {
                Add-CMRoleDistributionPoint -ComputerName $cmName -DomainCredential $domainCred `
                    -SiteCode $cfg.SiteCode `
                    -DpServerFqdn "$($extraDp.Name).$($cfg.DomainName)" | Out-Null
            }
        }

        # SUP: the role still installs on whatever VM carries
        # SoftwareUpdatePoint, but distributed-WSUS (WSUS feature on a
        # non-site-server VM, IIS WsusPool tune on the SUP VM) is not
        # plumbed yet -- Phase 07-CMPrereqs installs WSUS on the site
        # server. For now, distributed SUP requires the SUP role to
        # share a VM with the site server. A future tag will plumb
        # WSUS install + IIS tune to follow the SoftwareUpdatePoint
        # role assignment.
        if ($supVM.Name -ne $siteVM.Name) {
            Write-LabLog "Phase 09-CMConfig: SUP role on $($supVM.Name) but distributed SUP not yet plumbed; installing on $($siteVM.Name) instead" -Status WARN
        }
        Install-CMSoftwareUpdatePoint -ComputerName $cmName -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode -ServerFqdn "$($siteVM.Name).$($cfg.DomainName)"

        if ($clientVMs.Count -gt 0) {
            New-CMTestCollection -ComputerName $cmName -DomainCredential $domainCred `
                -SiteCode $cfg.SiteCode -DeviceName $clientVMs[0].Name | Out-Null
        }

        Set-CMClientCacheSize -ComputerName $cmName -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode
    }

    # ---- 10-Tools ----
    if (-not (_Skip '10-Tools')) {
        Write-LabLog '--- Phase 10-Tools ---' -Status INFO
        if (-not $domainCred) { $domainCred = Get-LabCredential -Identity Admin -Config $cfg }

        Copy-CMTools -ComputerName $siteVM.Name -DomainCredential $domainCred | Out-Null

        # Walk every VM in the topology so role-per-server / multi-DP /
        # CAS layouts inherit auto-start policy without a code change.
        $autoStartVms = foreach ($vm in $cfg.VMs) {
            $delay = if ($vm.ContainsKey('AutoStartDelay')) { [int]$vm.AutoStartDelay } else { 30 }
            [pscustomobject]@{ Name = $vm.Name; AutoStartDelay = $delay }
        }
        Set-LabAutoStartStop -VMs $autoStartVms `
            -AutoStartAction $cfg.AutoStartAction `
            -AutoStopAction  $cfg.AutoStopAction
    }

    # ---- 11-PostCM ----
    if ($PostCmConfig -and -not (_Skip '11-PostCM')) {
        Write-LabLog '--- Phase 11-PostCM ---' -Status INFO
        if (-not $domainCred) { $domainCred = Get-LabCredential -Identity Admin -Config $cfg }
        Invoke-LabPostCmCustomization -ComputerName $siteVM.Name -DomainCredential $domainCred `
            -SiteCode $cfg.SiteCode -Config $cfg -PostCmConfig $PostCmConfig `
            -IsoRoot $isoRoot | Out-Null
    }

    $elapsed = (Get-Date) - $deployStart
    Write-LabLog ("===== Install-HomeLab complete in {0}h {1}m {2}s =====" -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds) -Status OK

    # Post-install summary: VM state, service health, accounts, paths, next steps.
    try {
        Write-LabDeploySummary -Config $cfg -PostCmConfig $PostCmConfig -ConfigPath $ConfigPath -Elapsed $elapsed | Out-Null
    } catch {
        Write-LabLog "Write-LabDeploySummary failed: $($_.Exception.Message.Split([char]10)[0])" -Status WARN
    }

    return [pscustomobject]@{
        Status   = 'Complete'
        Domain   = $cfg.DomainName
        SiteCode = $cfg.SiteCode
        Elapsed  = $elapsed
    }
}
