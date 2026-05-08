function Set-CMServiceAccount {
    <#
    .SYNOPSIS
        Register the CM Client Push and Network Access Account
        identities with Configuration Manager (New-CMAccount).

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 9 (lines 1198-1207). The
        accounts must already exist in AD (S3 New-LabServiceAccounts);
        this function tells CM about them so subsequent
        Set-CMClientPushInstallation / NAA configuration works.

        Idempotent: New-CMAccount throws when the account is already
        registered; we treat that as success/no-op.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER PushAccount
        DOMAIN\sAMAccountName (e.g. CONTOSO\svc-CMPush).

    .PARAMETER PushPassword
        Plain-text password for PushAccount. Converted to SecureString
        inside the remote script block.

    .PARAMETER NAAAccount
        DOMAIN\sAMAccountName for the Network Access Account.

    .PARAMETER NAAPassword
        Plain-text password for NAAAccount.

    .EXAMPLE
        Set-CMServiceAccount `
            -ComputerName CM01 -DomainCredential $cred -SiteCode MCM `
            -PushAccount 'CONTOSO\svc-CMPush' -PushPassword $cfg.ServiceAccounts.ClientPush.Password `
            -NAAAccount  'CONTOSO\svc-CMNAA'  -NAAPassword  $cfg.ServiceAccounts.NAA.Password
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
        [string]$PushAccount,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PushPassword,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NAAAccount,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NAAPassword
    )

    Write-LabLog "[$ComputerName] Registering CM accounts ($PushAccount, $NAAAccount)" -Status RUN

    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Register CM accounts' -ScriptBlock {
            param($SiteCode, $PushAccount, $PushPassword, $NAAAccount, $NAAPassword)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            foreach ($entry in @(
                @{ Name = $PushAccount; Pass = $PushPassword }
                @{ Name = $NAAAccount;  Pass = $NAAPassword  }
            )) {
                $sec = ConvertTo-SecureString -String $entry.Pass -AsPlainText -Force
                try {
                    New-CMAccount -Name $entry.Name -Password $sec -SiteCode $SiteCode -ErrorAction Stop | Out-Null
                } catch {
                    # New-CMAccount throws when the principal is already
                    # registered with CM. Re-throw anything else.
                    if ($_.Exception.Message -notmatch 'already exist|account.*exist') {
                        throw
                    }
                }
            }
        } -ArgumentList $SiteCode, $PushAccount, $PushPassword, $NAAAccount, $NAAPassword | Out-Null

    Write-LabLog "[$ComputerName] CM accounts registered" -Status OK
}
