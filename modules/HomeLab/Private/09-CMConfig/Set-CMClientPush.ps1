function Set-CMClientPush {
    <#
    .SYNOPSIS
        Enable Client Push Installation on the CM site and bind the
        push account.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 9 (lines 1210-1222). Set-CMClientPushInstallation
        is idempotent (overwrites the current configuration).

        Defaults:
          - InstallClientToDomainController = $true (so DC01 gets the
            client too; safe for a single-DC lab, would be wrong in
            production)
          - EnableSystemTypeServer + EnableSystemTypeWorkstation = $true

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER PushAccount
        DOMAIN\sAMAccountName (e.g. CONTOSO\svc-CMPush). Must already
        be registered with CM (Set-CMServiceAccount).

    .EXAMPLE
        Set-CMClientPush -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -PushAccount 'CONTOSO\svc-CMPush'
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
        [string]$PushAccount
    )

    Write-LabLog "[$ComputerName] Enabling Client Push (account $PushAccount)" -Status RUN

    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Configure Client Push Installation' -ScriptBlock {
            param($SiteCode, $PushAccount)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            Set-CMClientPushInstallation `
                -SiteCode $SiteCode `
                -EnableAutomaticClientPushInstallation $true `
                -InstallClientToDomainController $true `
                -EnableSystemTypeServer $true `
                -EnableSystemTypeWorkstation $true `
                -AddAccount $PushAccount `
                -ErrorAction Stop
        } -ArgumentList $SiteCode, $PushAccount | Out-Null

    Write-LabLog "[$ComputerName] Client Push enabled" -Status OK
}
