function Invoke-LabPostCmCustomization {
    <#
    .SYNOPSIS
        Apply GUI-selected post-CM customizations after CM setup.

    .DESCRIPTION
        Bridges the GUI's captured PostCmConfig hashtable to the S18/S19
        helper functions. Only deterministic choices with enough captured
        input are executed. Choices that still need extra user input are logged
        as warnings instead of guessed.
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
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [hashtable]$PostCmConfig,

        [Parameter()]
        [string]$IsoRoot = 'C:\LabSources\ISOs'
    )

    function _Enabled {
        param([string]$Key)
        return ($PostCmConfig.ContainsKey($Key) -and [bool]$PostCmConfig[$Key])
    }

    function _NextStart {
        param(
            [System.DayOfWeek]$Day,
            [int]$Hour
        )
        $today = (Get-Date).Date
        $days = ([int]$Day - [int]$today.DayOfWeek + 7) % 7
        $candidate = $today.AddDays($days).AddHours($Hour)
        if ($candidate -le (Get-Date)) { $candidate = $candidate.AddDays(7) }
        return $candidate
    }

    $actions = [System.Collections.Generic.List[string]]::new()
    $clientNames = @((Get-LabVMByRole -Config $Config -Role Client) | ForEach-Object { [string]$_.Name })

    if (_Enabled 'Coll_AllWorkstations') {
        [void]$actions.Add('Coll_AllWorkstations')
        New-CMRoleCollection -ComputerName $ComputerName -DomainCredential $DomainCredential `
            -SiteCode $SiteCode `
            -Name 'All Workstations' `
            -Query "select * from SMS_R_System where SMS_R_System.OperatingSystemNameAndVersion like 'Microsoft Windows NT Workstation%'" `
            -QueryRuleName 'All Workstations' | Out-Null
    }

    if (_Enabled 'Coll_AllServers') {
        [void]$actions.Add('Coll_AllServers')
        New-CMRoleCollection -ComputerName $ComputerName -DomainCredential $DomainCredential `
            -SiteCode $SiteCode `
            -Name 'All Servers' `
            -Query "select * from SMS_R_System where SMS_R_System.OperatingSystemNameAndVersion like 'Microsoft Windows NT Server%'" `
            -QueryRuleName 'All Servers' | Out-Null
    }

    if (_Enabled 'Coll_TestDirect') {
        if ($clientNames.Count -gt 0) {
            [void]$actions.Add('Coll_TestDirect')
            New-CMRoleCollection -ComputerName $ComputerName -DomainCredential $DomainCredential `
                -SiteCode $SiteCode `
                -Name 'HomeLab - Test Deployments' `
                -Direct $clientNames | Out-Null
        } else {
            Write-LabLog 'Post-CM: test direct collection requested but no Client VM exists in the config' -Status WARN
        }
    }

    if (_Enabled 'MW_PatchSaturday') {
        [void]$actions.Add('MW_PatchSaturday')
        New-CMRoleMaintenanceWindow -ComputerName $ComputerName -DomainCredential $DomainCredential `
            -SiteCode $SiteCode `
            -CollectionName 'All Workstations' `
            -Name 'Patch Saturday 02:00-06:00' `
            -Start (_NextStart -Day Saturday -Hour 2) `
            -DurationHours 4 `
            -Cadence Weekly `
            -DayOfWeek Saturday `
            -ApplyTo SoftwareUpdates | Out-Null
    }

    if (_Enabled 'MW_TestDaily') {
        [void]$actions.Add('MW_TestDaily')
        New-CMRoleMaintenanceWindow -ComputerName $ComputerName -DomainCredential $DomainCredential `
            -SiteCode $SiteCode `
            -CollectionName 'HomeLab - Test Deployments' `
            -Name 'Daily 00:00-06:00 (test)' `
            -Start ((Get-Date).Date.AddDays(1)) `
            -DurationHours 6 `
            -Cadence Daily `
            -ApplyTo Any | Out-Null
    }

    $driverText = if ($PostCmConfig.ContainsKey('Drivers_Csv')) { [string]$PostCmConfig['Drivers_Csv'] } else { '' }
    $drivers = @($driverText -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($driver in $drivers) {
        [void]$actions.Add("Driver:$driver")
        New-CMRoleDriverCategory -ComputerName $ComputerName -DomainCredential $DomainCredential `
            -SiteCode $SiteCode -Name $driver | Out-Null
    }

    if (_Enabled 'Osd_BootImage') {
        [void]$actions.Add('Osd_BootImage')
        $wimPath = if ($PostCmConfig.ContainsKey('Osd_BootImageWimPath') -and $PostCmConfig['Osd_BootImageWimPath']) {
            [string]$PostCmConfig['Osd_BootImageWimPath']
        } else {
            'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\en-us\winpe.wim'
        }
        # CM cmdlets access boot images via UNC, not local path. Convert
        # local C:\ path to admin share \\<server>\C$\... so the provider
        # service account can pull the WIM.
        if ($wimPath -match '^[A-Za-z]:\\') {
            $drive = $wimPath.Substring(0,1)
            $rest = $wimPath.Substring(3)
            $wimPath = "\\$ComputerName\$drive`$\$rest"
        }
        New-CMRoleBootImage -ComputerName $ComputerName -DomainCredential $DomainCredential `
            -SiteCode $SiteCode -Name 'WinPE x64' -WimPath $wimPath `
            -Description 'HomeLab WinPE boot image' | Out-Null
    }

    if (_Enabled 'Osd_TaskSequenceStub') {
        # Pre-supplied image name short-circuits the auto-import. Otherwise
        # locate the host's Win11 client ISO via Find-LabIsoPath, run the
        # full extract -> stage -> import -> distribute pipeline, then feed
        # the resulting CM image name into the TS stub.
        $osImageName = if ($PostCmConfig.ContainsKey('Osd_OsImageName')) { [string]$PostCmConfig['Osd_OsImageName'] } else { '' }

        if ([string]::IsNullOrWhiteSpace($osImageName)) {
            $clientIso = Find-LabIsoPath -Directory $IsoRoot -Patterns @(
                '*WIN11*EVAL*.iso'
                '*Windows*11*Eval*.iso'
                '*CLIENTENTERPRISE*EVAL*.iso'
            )
            if (-not $clientIso) {
                Write-LabLog "Post-CM: TS stub requested but no Win11 client ISO found in $IsoRoot; skipping TS + OS-image import" -Status WARN
            } else {
                [void]$actions.Add('Osd_OsImageImport')
                $importResult = Import-CMRoleOsImage -ComputerName $ComputerName -DomainCredential $DomainCredential `
                    -SiteCode $SiteCode -IsoPath $clientIso
                $osImageName = $importResult.ImageName
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($osImageName)) {
            [void]$actions.Add('Osd_TaskSequenceStub')
            $secureLocal = ConvertTo-SecureString -String $Config.AdminPass -AsPlainText -Force
            $joinCred = Get-LabCredential -Identity Join -Config $Config
            New-CMRoleTaskSequenceStub -ComputerName $ComputerName -DomainCredential $DomainCredential `
                -SiteCode $SiteCode `
                -Name 'Build Win11' `
                -BootImageName 'WinPE x64' `
                -OsImageName $osImageName `
                -LocalAdminPassword $secureLocal `
                -DomainName $Config.DomainName `
                -JoinAccount $joinCred | Out-Null
        }
    }

    $appRoot = if ($PostCmConfig.ContainsKey('AppPackager_Root')) { [string]$PostCmConfig['AppPackager_Root'] } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($appRoot)) {
        Write-LabLog "Post-CM: app-packager import root '$appRoot' captured, but application import needs package metadata not exposed by the GUI yet; skipping app import" -Status WARN
    }

    return [pscustomobject]@{
        Status  = 'Complete'
        Actions = @($actions)
    }
}
