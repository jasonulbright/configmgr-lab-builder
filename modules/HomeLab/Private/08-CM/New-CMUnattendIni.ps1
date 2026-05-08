function New-CMUnattendIni {
    <#
    .SYNOPSIS
        Build the ConfigurationFile-CM.ini that drives unattended CM 2509
        primary-site setup.

    .DESCRIPTION
        Captures the AL fork's `Install-CMSite.ps1` lines 81-138 (the
        $configurationManagerContent INI assembly) into a focused builder.

        Five sections are emitted:

          [Identification]
            - Action=InstallPrimarySite
            - Preview=1 (ONLY when Branch=TP; the key is omitted entirely
              for CB, the homelab default; including it for CB causes
              setup to refuse the .ini)

          [Options]
            - ProductID=EVAL
            - SiteCode / SiteName
            - SMSInstallDir (default C:\Program Files\Microsoft Configuration Manager)
            - SDKServer = <CMServerFqdn>
            - PrerequisiteComp = 1 if PrerequisitePath has files, 0 otherwise
              (lets setup.exe download prereqs when the offline cache is
              absent; cheaper than failing)
            - PrerequisitePath
            - ManagementPoint / DistributionPoint = <CMServerFqdn>
            - DistributionPointInstallIIS = 1
            - AdminConsole / JoinCEIP / MobileDeviceLanguage as documented
              defaults

          [SQLConfigOptions]
            - SQLServerName / DatabaseName / SQLSSBPort
            - SQLDataFilePath / SQLLogFilePath

          [CloudConnectorOptions]
            - CloudConnector=0 (homelab is offline; no Intune tenant attach)

          [SystemCenterOptions] / [HierarchyExpansionOption]
            - empty for primary site

        The output is written via Write-LabIni (ASCII, no BOM) so it
        round-trips cleanly.

    .PARAMETER CMServerFqdn
        FQDN of the CM site server (e.g. CM01.contoso.com).

    .PARAMETER SQLServerFqdn
        FQDN of the SQL host. May equal CMServerFqdn for the homelab
        co-located install. Default: CMServerFqdn.

    .PARAMETER SiteCode
        3-letter site code (e.g. MCM).

    .PARAMETER SiteName
        Display name for the site.

    .PARAMETER Branch
        CB (Current Branch, the homelab default) or TP (Technical Preview).

    .PARAMETER ProductID
        Default 'EVAL'. Override only when installing with a paid key.

    .PARAMETER PrerequisitePath
        Path INSIDE the CM VM where prereq downloads live. Default
        C:\Install\CM-PreReqs. PrerequisiteComp is auto-set based on
        whether $PrerequisitePathHasFiles is true (caller responsibility).

    .PARAMETER PrerequisitePathHasFiles
        When $true, set PrerequisiteComp=1 (use the offline cache).
        When $false, set PrerequisiteComp=0 (let setup download).

    .PARAMETER SMSInstallDir
        Default C:\Program Files\Microsoft Configuration Manager.

    .PARAMETER DatabaseName
        Default 'CM_<SiteCode>'.

    .PARAMETER SQLDataFilePath
        Default 'C:\SQLData' (single-disk default; templates with a dedicated SQL volume override via -SQLDataFilePath).

    .PARAMETER SQLLogFilePath
        Default 'E:\SQLLogs' (matches S4 default).

    .PARAMETER OutputPath
        Output file. Default $env:TEMP\HomeLab-CM-ConfigurationFile.ini.

    .EXAMPLE
        New-CMUnattendIni `
            -CMServerFqdn 'CM01.contoso.com' `
            -SiteCode 'MCM' -SiteName 'Home Lab Primary Site' `
            -PrerequisitePathHasFiles $false
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CMServerFqdn,

        [Parameter()]
        [string]$SQLServerFqdn,

        [Parameter(Mandatory)]
        [ValidateLength(3,3)]
        [string]$SiteCode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteName,

        [Parameter()]
        [ValidateSet('CB','TP')]
        [string]$Branch = 'CB',

        [Parameter()]
        [string]$ProductID = 'EVAL',

        [Parameter()]
        [string]$PrerequisitePath = 'C:\Install\CM-PreReqs',

        [Parameter()]
        [bool]$PrerequisitePathHasFiles = $false,

        [Parameter()]
        [string]$SMSInstallDir = 'C:\Program Files\Microsoft Configuration Manager',

        [Parameter()]
        [string]$DatabaseName,

        [Parameter()]
        [string]$SQLDataFilePath = 'C:\SQLData',

        [Parameter()]
        [string]$SQLLogFilePath = 'C:\SQLLogs',

        [Parameter()]
        [string]$OutputPath
    )

    if (-not $SQLServerFqdn) { $SQLServerFqdn = $CMServerFqdn }
    if (-not $DatabaseName)  { $DatabaseName  = "CM_$SiteCode" }
    if (-not $OutputPath)    { $OutputPath    = Join-Path $env:TEMP 'HomeLab-CM-ConfigurationFile.ini' }

    $prereqComp = if ($PrerequisitePathHasFiles) { '1' } else { '0' }

    $identification = [ordered]@{
        Action = 'InstallPrimarySite'
    }
    if ($Branch -eq 'TP') {
        # CB rejects the Preview key; only emit it on TP.
        $identification['Preview'] = '1'
    }

    $options = [ordered]@{
        ProductID                  = $ProductID
        SiteCode                   = $SiteCode
        SiteName                   = $SiteName
        SMSInstallDir              = $SMSInstallDir
        SDKServer                  = $CMServerFqdn
        RoleCommunicationProtocol  = 'HTTPorHTTPS'
        ClientsUsePKICertificate   = '0'
        PrerequisiteComp           = $prereqComp
        PrerequisitePath           = $PrerequisitePath
        MobileDeviceLanguage       = '0'
        AdminConsole               = '1'
        JoinCEIP                   = '0'
        ManagementPoint            = $CMServerFqdn
        ManagementPointProtocol    = 'HTTP'
        DistributionPoint          = $CMServerFqdn
        DistributionPointProtocol  = 'HTTP'
        DistributionPointInstallIIS = '1'
    }

    $sql = [ordered]@{
        SQLServerName    = $SQLServerFqdn
        DatabaseName     = $DatabaseName
        SQLSSBPort       = '4022'
        SQLDataFilePath  = $SQLDataFilePath
        SQLLogFilePath   = $SQLLogFilePath
    }

    $cloud = [ordered]@{
        CloudConnector       = '0'
        CloudConnectorServer = $CMServerFqdn
        UseProxy             = '0'
        ProxyName            = ''
        ProxyPort            = ''
    }

    $sysCenter = [ordered]@{
        SysCenterId = ''
    }

    $hierarchy = [ordered]@{}

    $cfg = [ordered]@{
        Identification        = $identification
        Options               = $options
        SQLConfigOptions      = $sql
        CloudConnectorOptions = $cloud
        SystemCenterOptions   = $sysCenter
        HierarchyExpansionOption = $hierarchy
    }

    Write-LabIni -Data $cfg -Path $OutputPath -Encoding ASCII
    return (Resolve-Path $OutputPath).Path
}
