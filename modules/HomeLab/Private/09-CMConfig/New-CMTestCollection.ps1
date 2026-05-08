function New-CMTestCollection {
    <#
    .SYNOPSIS
        Idempotently create a CM device collection with a daily
        maintenance window and add a single device as a direct
        member.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 9 (lines 1370-1432).

        The homelab convention: one collection (`HomeLab - Test
        Deployments` by default) limited by `All Desktop and Server
        Clients`, with `CLIENT01` as the only direct member, and a
        single daily maintenance window from 00:00-06:00. This
        matches reference_mecm_homelab_bible.md "test collection?
        CLIENT01."

        Each operation is independently idempotent.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER CollectionName
        Default 'HomeLab - Test Deployments'.

    .PARAMETER LimitingCollectionName
        Default 'All Desktop and Server Clients'.

    .PARAMETER DeviceName
        Direct-membership device. Default 'CLIENT01'.

    .PARAMETER MaintenanceWindowName
        Default 'Daily Maintenance Window'.

    .PARAMETER MaintenanceWindowStart
        Window start time. Default 00:00:00 today.

    .PARAMETER MaintenanceWindowDurationHours
        Default 6.

    .EXAMPLE
        New-CMTestCollection -ComputerName CM01 -DomainCredential $cred -SiteCode MCM
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

        [Parameter()]
        [string]$CollectionName = 'HomeLab - Test Deployments',

        [Parameter()]
        [string]$LimitingCollectionName = 'All Desktop and Server Clients',

        [Parameter()]
        [string]$DeviceName = 'CLIENT01',

        [Parameter()]
        [string]$MaintenanceWindowName = 'Daily Maintenance Window',

        [Parameter()]
        [datetime]$MaintenanceWindowStart = (Get-Date -Hour 0 -Minute 0 -Second 0),

        [Parameter()]
        [ValidateRange(1, 24)]
        [int]$MaintenanceWindowDurationHours = 6
    )

    Write-LabLog "[$ComputerName] Provisioning test collection '$CollectionName'" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Create $CollectionName" -ScriptBlock {
            param($SiteCode, $CollectionName, $Limiting, $DeviceName, $MwName, $MwStart, $MwHours)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $coll = Get-CMDeviceCollection -Name $CollectionName -ErrorAction SilentlyContinue
            if (-not $coll) {
                $coll = New-CMDeviceCollection `
                    -Name $CollectionName `
                    -LimitingCollectionName $Limiting `
                    -RefreshType None -ErrorAction Stop
                $collAction = 'Created'
            } else {
                $collAction = 'AlreadyExists'
            }

            $memberAction = 'NotDiscovered'
            $device = Get-CMDevice -Name $DeviceName -ErrorAction SilentlyContinue
            if ($device) {
                $existing = Get-CMDeviceCollectionDirectMembershipRule `
                    -CollectionId $coll.CollectionID `
                    -ResourceName $DeviceName -ErrorAction SilentlyContinue
                if (-not $existing) {
                    Add-CMDeviceCollectionDirectMembershipRule `
                        -CollectionId $coll.CollectionID `
                        -ResourceId ([int]$device.ResourceID) -ErrorAction Stop
                    $memberAction = 'Added'
                } else {
                    $memberAction = 'AlreadyMember'
                }
            }

            $mwAction = 'Skipped'
            $existingMw = Get-CMMaintenanceWindow -CollectionId $coll.CollectionID -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $MwName }
            if (-not $existingMw) {
                $schedule = New-CMSchedule -Start $MwStart `
                    -DurationCount $MwHours -DurationInterval Hours `
                    -RecurInterval Days -RecurCount 1
                New-CMMaintenanceWindow `
                    -CollectionId $coll.CollectionID `
                    -Name $MwName -Schedule $schedule `
                    -ApplyTo Any -ErrorAction Stop | Out-Null
                $mwAction = 'Created'
            } else {
                $mwAction = 'AlreadyExists'
            }

            return [pscustomobject]@{
                CollectionId    = $coll.CollectionID
                CollectionName  = $CollectionName
                CollectionAction = $collAction
                DeviceMember    = $DeviceName
                MemberAction    = $memberAction
                MwAction        = $mwAction
            }
        } -ArgumentList $SiteCode, $CollectionName, $LimitingCollectionName,
                        $DeviceName, $MaintenanceWindowName,
                        $MaintenanceWindowStart, $MaintenanceWindowDurationHours

    Write-LabLog "[$ComputerName] Test collection $($result.CollectionAction); MW $($result.MwAction); $DeviceName $($result.MemberAction)" -Status OK
    return $result
}
