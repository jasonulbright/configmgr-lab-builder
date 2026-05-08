function Set-CMClientCacheSize {
    <#
    .SYNOPSIS
        Set the CCMCache (CM client cache) max size on the default
        client settings.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 (lines 1437-1452). One
        Set-CMClientSettingClientCache call against the default
        settings; affects every client that does not override.

        Default 40 GB (CLIENT01 needs the
        cache to install/uninstall 117 apps without thrashing).

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER MaxCacheSizeMB
        Cache cap in MB. Default 40960 (40 GB).

    .EXAMPLE
        Set-CMClientCacheSize -ComputerName CM01 -DomainCredential $cred -SiteCode MCM
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
        [ValidateRange(256, 1048576)]
        [int]$MaxCacheSizeMB = 40960
    )

    Write-LabLog "[$ComputerName] Setting CCMCache max size to ${MaxCacheSizeMB} MB" -Status RUN

    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Set CCMCache size' -ScriptBlock {
            param($SiteCode, $SizeMB)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            Set-CMClientSettingClientCache -DefaultSetting `
                -ConfigureCacheSize $true -MaxCacheSize $SizeMB -ErrorAction Stop
        } -ArgumentList $SiteCode, $MaxCacheSizeMB | Out-Null

    Write-LabLog "[$ComputerName] CCMCache cap set" -Status OK
}
