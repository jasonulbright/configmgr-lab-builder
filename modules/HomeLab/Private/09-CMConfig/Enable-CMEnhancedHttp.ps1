function Enable-CMEnhancedHttp {
    <#
    .SYNOPSIS
        Turn on enhanced HTTP for the site ("Use Configuration
        Manager-generated certificates for HTTP site systems").

    .DESCRIPTION
        Microsoft recommends enhanced HTTP as the minimum for client to
        site system traffic. HTTP-only client communication has been
        deprecated since version 2103. The SMS Issuing root signs the role
        certificates that the site generates. If a PKI certificate is bound
        in IIS, site systems keep using it.
        https://learn.microsoft.com/intune/configmgr/core/plan-design/hierarchy/enhanced-http

        Calls Set-CMSite -UseSmsGeneratedCert $true. The value is the same
        when it is already on, so the step is idempotent. Returns Status
        'Enabled' or 'AlreadyEnabled' when Get-CMSite reports the value.

        Undo: Set-CMSite -SiteCode <code> -UseSmsGeneratedCert $false

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER PlanOnly
        Report the plan and make no change.

    .EXAMPLE
        Enable-CMEnhancedHttp -ComputerName CM01 -DomainCredential $cred -SiteCode MCM
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

        [Parameter()]
        [switch]$PlanOnly
    )

    Write-LabLog "[$ComputerName] Enhanced HTTP (PlanOnly=$([bool]$PlanOnly))" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Enable enhanced HTTP' -ScriptBlock {
            param($SiteCode, $PlanOnly)

            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $site = Get-CMSite -SiteCode $SiteCode -ErrorAction Stop
            if ($site.UseSmsGeneratedCert -eq $true) {
                return [pscustomobject]@{ Status = 'AlreadyEnabled' }
            }
            if ($PlanOnly) {
                return [pscustomobject]@{ Status = 'WouldEnable' }
            }
            Set-CMSite -SiteCode $SiteCode -UseSmsGeneratedCert $true -ErrorAction Stop
            [pscustomobject]@{ Status = 'Enabled' }
        } -ArgumentList $SiteCode, ([bool]$PlanOnly)

    Write-LabLog "[$ComputerName] Enhanced HTTP: $($result.Status)" -Status OK
    return $result
}
