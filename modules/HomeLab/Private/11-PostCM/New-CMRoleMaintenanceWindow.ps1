function New-CMRoleMaintenanceWindow {
    <#
    .SYNOPSIS
        Add a recurring maintenance window to a CM device collection.
        Idempotent; short-circuits when an MW of the same name already
        exists on the collection.

    .DESCRIPTION
        Post-CM customization helper (S18). Wraps:

          $sched = New-CMSchedule -Start <Start> -DayOfWeek <Day> -RecurCount 1
                                  -DurationCount <Hours> -DurationInterval Hours
          New-CMMaintenanceWindow -CollectionName <Coll> -Name <Mw>
                                  -Schedule $sched -ApplyTo <ApplyTo>

        ApplyTo controls which deployment types honour the window:
          Any         = any deployment
          SoftwareUpdates = updates only (the homelab default)
          TaskSequencesOnly = OSD-only

    .PARAMETER ComputerName
        Site server name.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER CollectionName
        Target collection.

    .PARAMETER Name
        MW name. Must be unique within the collection.

    .PARAMETER Start
        DateTime for the first MW occurrence.

    .PARAMETER DurationHours
        How long the window stays open. Default 4.

    .PARAMETER Cadence
        Recurrence: Daily | Weekly | Monthly. Default Weekly.

    .PARAMETER DayOfWeek
        For Weekly cadence (Sunday..Saturday). Default Saturday.

    .PARAMETER ApplyTo
        Any | SoftwareUpdates | TaskSequencesOnly. Default
        SoftwareUpdates.

    .EXAMPLE
        New-CMRoleMaintenanceWindow -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -CollectionName 'All Workstations' `
            -Name 'Patch Saturday 02:00-06:00' `
            -Start '02:00' -DurationHours 4 -DayOfWeek Saturday
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
        [string]$CollectionName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [datetime]$Start,

        [Parameter()]
        [ValidateRange(1, 24)]
        [int]$DurationHours = 4,

        [Parameter()]
        [ValidateSet('Daily','Weekly','Monthly')]
        [string]$Cadence = 'Weekly',

        [Parameter()]
        [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
        [string]$DayOfWeek = 'Saturday',

        [Parameter()]
        [ValidateSet('Any','SoftwareUpdates','TaskSequencesOnly')]
        [string]$ApplyTo = 'SoftwareUpdates'
    )

    Write-LabLog "[$ComputerName] Adding MW '$Name' to collection '$CollectionName'" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Add MW $Name" -ScriptBlock {
            param($SiteCode, $Coll, $MwName, $StartTime, $Hours, $Cadence, $Day, $ApplyTo)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMMaintenanceWindow -CollectionName $Coll -Name $MwName -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; Name = $MwName }
            }

            $sched = switch ($Cadence) {
                'Daily'   { New-CMSchedule -Start $StartTime -RecurCount 1 -RecurInterval Days -DurationCount $Hours -DurationInterval Hours }
                'Weekly'  { New-CMSchedule -Start $StartTime -DayOfWeek $Day -RecurCount 1 -DurationCount $Hours -DurationInterval Hours }
                'Monthly' { New-CMSchedule -Start $StartTime -DayOfMonth 1 -RecurCount 1 -DurationCount $Hours -DurationInterval Hours }
            }

            New-CMMaintenanceWindow -CollectionName $Coll -Name $MwName -Schedule $sched `
                -ApplyTo $ApplyTo -ErrorAction Stop | Out-Null

            return [pscustomobject]@{ Status = 'Created'; Name = $MwName }
        } -ArgumentList $SiteCode, $CollectionName, $Name, $Start, $DurationHours, $Cadence, $DayOfWeek, $ApplyTo

    Write-LabLog "[$ComputerName] MW '$Name' $($result.Status)" -Status OK
    return $result
}
