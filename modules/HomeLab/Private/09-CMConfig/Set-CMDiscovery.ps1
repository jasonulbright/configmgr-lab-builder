function Set-CMDiscovery {
    <#
    .SYNOPSIS
        Enable AD Forest / System / User Discovery on a CM site.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 9 (lines 1098-1132) verbatim into
        a focused function. Three discovery methods are toggled on:

          - ActiveDirectoryForestDiscovery, with auto-creation of AD
            site boundaries and IP subnet boundaries
          - ActiveDirectorySystemDiscovery, scoped to the lab domain
            container, recursive, delta enabled at 3-minute interval
            (homelab-tight cadence so newly domain-joined VMs become
            CM resources -- and trigger client push -- within minutes
            instead of the production-default 6 hours)
          - ActiveDirectoryUserDiscovery, same scope + delta cadence

        After enabling, all three methods are kicked off via
        Invoke-CMForestDiscovery / Invoke-CMSystemDiscovery /
        Invoke-CMUserDiscovery so the first pass starts immediately.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER DomainDN
        Distinguished name of the domain (e.g. DC=contoso,DC=com).

    .PARAMETER DeltaIntervalMinutes
        Delta discovery cadence. Default 3 (homelab-tight). Range 1-1440.

    .EXAMPLE
        Set-CMDiscovery -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -DomainDN 'DC=contoso,DC=com'
    #>
    [CmdletBinding()]
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
        [string]$DomainDN,

        [Parameter()]
        [ValidateRange(5, 1440)]
        [int]$DeltaIntervalMinutes = 5
    )

    Write-LabLog "[$ComputerName] Enabling AD Forest / System / User discovery" -Status RUN

    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Set CM discovery methods' -ScriptBlock {
            param($SiteCode, $DomainDN, $DeltaMinutes)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            Set-CMDiscoveryMethod -ActiveDirectoryForestDiscovery `
                -SiteCode $SiteCode -Enabled $true `
                -EnableActiveDirectorySiteBoundaryCreation $true `
                -EnableSubnetBoundaryCreation $true -ErrorAction Stop

            Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery `
                -SiteCode $SiteCode -Enabled $true `
                -EnableDeltaDiscovery $true `
                -DeltaDiscoveryMins $DeltaMinutes `
                -AddActiveDirectoryContainer "LDAP://$DomainDN" `
                -EnableRecursive $true -ErrorAction Stop

            Set-CMDiscoveryMethod -ActiveDirectoryUserDiscovery `
                -SiteCode $SiteCode -Enabled $true `
                -EnableDeltaDiscovery $true `
                -DeltaDiscoveryMins $DeltaMinutes `
                -AddActiveDirectoryContainer "LDAP://$DomainDN" `
                -EnableRecursive $true -ErrorAction Stop

            Invoke-CMForestDiscovery -SiteCode $SiteCode -ErrorAction SilentlyContinue
            Invoke-CMSystemDiscovery -SiteCode $SiteCode -ErrorAction SilentlyContinue
            Invoke-CMUserDiscovery   -SiteCode $SiteCode -ErrorAction SilentlyContinue
        } -ArgumentList $SiteCode, $DomainDN, $DeltaIntervalMinutes | Out-Null

    Write-LabLog "[$ComputerName] Discovery enabled (Forest+System+User, ${DeltaIntervalMinutes}m delta)" -Status OK
}
