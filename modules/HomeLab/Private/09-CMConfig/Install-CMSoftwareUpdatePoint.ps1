function Install-CMSoftwareUpdatePoint {
    <#
    .SYNOPSIS
        Tune the WsusPool IIS app pool, add the Software Update Point
        role to the CM site server, and configure products /
        classifications / sync schedule.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 (lines 1272-1365). The WSUS feature
        itself is installed in S5 (Install-LabWsus); this function
        does the CM-side configuration.

        Three logical phases:

          1. WsusPool IIS best practices: Private Memory Limit and
             Periodic Recycle to 0 (unlimited), queueLength 2000,
             idleTimeout 0, periodicRestart.time 0. Without these,
             WsusPool recycles under normal sync load.

          2. Add-CMSoftwareUpdatePoint on the site system. WSUS ports
             8530 (HTTP) and 8531 (HTTPS) are the WSUS defaults.

          3. Set-CMSoftwareUpdatePointComponent for each product +
             classification + sync schedule + cleanup. Initial
             Sync-CMSoftwareUpdate -FullSync triggers the first pull.

        Idempotent: each call to Set-CMSoftwareUpdatePointComponent
        is additive; -AddProduct / -AddUpdateClassification skip when
        already present (or throw and we tolerate).

    .PARAMETER ComputerName
        DNS / short name of the CM site server (also the SUP host).

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER ServerFqdn
        FQDN of the CM site server (= SUP server).

    .PARAMETER Products
        Product strings to enable. Defaults match the homelab
        deployment-tested set.

    .PARAMETER Classifications
        Update classifications. Default: Critical Updates, Security
        Updates, Updates.

    .PARAMETER SyncStartTime
        DateTime for the daily sync start. Default 02:00 today.

    .PARAMETER WaitMonth
        Supersedence wait window. Default 3 months.

    .EXAMPLE
        Install-CMSoftwareUpdatePoint -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -ServerFqdn 'CM01.contoso.com'
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
        [string]$ServerFqdn,

        [Parameter()]
        [string[]]$Products = @(
            'Windows 11'
            'Microsoft Server Operating System-24H2'
            'Microsoft SQL Server 2022'
            'Microsoft SQL Server Management Studio v20'
            'Microsoft OLE DB Driver 19 for SQL Server'
            'Microsoft ODBC Driver 18 for SQL Server'
            'PowerShell - x64'
        ),

        [Parameter()]
        [string[]]$Classifications = @(
            'Critical Updates','Security Updates','Updates'
        ),

        [Parameter()]
        [datetime]$SyncStartTime = (Get-Date '02:00:00'),

        [Parameter()]
        [int]$WaitMonth = 3
    )

    Write-LabLog "[$ComputerName] Tuning WsusPool + adding SUP role" -Status RUN

    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'WsusPool IIS tune + SUP role' -ScriptBlock {
            param($SiteCode, $ServerFqdn)

            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $poolPath = 'IIS:\AppPools\WsusPool'
            if (Test-Path $poolPath) {
                Set-ItemProperty $poolPath -Name recycling.periodicRestart.privateMemory -Value 0
                try { Set-ItemProperty $poolPath -Name recycling.periodicRestart.memory -Value 0 } catch { }
                Set-ItemProperty $poolPath -Name queueLength -Value 2000
                Set-ItemProperty $poolPath -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
                Set-ItemProperty $poolPath -Name processModel.pingingEnabled -Value $false
                Set-ItemProperty $poolPath -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
            }

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existingSup = Get-CMSoftwareUpdatePoint -SiteCode $SiteCode -ErrorAction SilentlyContinue
            if (-not $existingSup) {
                Add-CMSoftwareUpdatePoint -SiteCode $SiteCode `
                    -SiteSystemServerName $ServerFqdn `
                    -WsusIisPort 8530 -WsusIisSslPort 8531 `
                    -ErrorAction Stop | Out-Null
            }
            return [string]'Done'
        } -ArgumentList $SiteCode, $ServerFqdn | Out-Null

    Write-LabLog "[$ComputerName] WsusPool tuned + SUP role added" -Status OK

    Write-LabLog "[$ComputerName] Configuring SUP products + classifications + sync" -Status RUN

    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'SUP products + classifications + schedule' -ScriptBlock {
            param($SiteCode, $Products, $Classifications, $SyncStartTime, $WaitMonth)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            foreach ($p in $Products) {
                try {
                    Set-CMSoftwareUpdatePointComponent -SiteCode $SiteCode -AddProduct $p -ErrorAction Stop
                } catch {
                    Write-Warning "Product skipped: $p ($($_.Exception.Message))"
                }
            }

            foreach ($c in $Classifications) {
                try {
                    Set-CMSoftwareUpdatePointComponent -SiteCode $SiteCode -AddUpdateClassification $c -ErrorAction Stop
                } catch {
                    Write-Warning "Classification skipped: $c ($($_.Exception.Message))"
                }
            }

            try {
                $schedule = New-CMSchedule -RecurCount 1 -RecurInterval Days -Start $SyncStartTime
                Set-CMSoftwareUpdatePointComponent -SiteCode $SiteCode `
                    -AddLanguageUpdateFile 'English' `
                    -AddLanguageSummaryDetail 'English' `
                    -Schedule $schedule `
                    -EnableSyncFailureAlert $true `
                    -EnableCallWsusCleanupWizard $true `
                    -ImmediatelyExpireSupersedence $false `
                    -WaitMonth $WaitMonth `
                    -ErrorAction Stop
            } catch {
                Write-Warning "Schedule/cleanup config skipped: $($_.Exception.Message)"
            }

            Sync-CMSoftwareUpdate -FullSync $true -ErrorAction SilentlyContinue
        } -ArgumentList $SiteCode, $Products, $Classifications, $SyncStartTime, $WaitMonth | Out-Null

    Write-LabLog "[$ComputerName] SUP fully configured; initial sync triggered" -Status OK
}
