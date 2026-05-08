function Import-CMModule {
    <#
    .SYNOPSIS
        Verify the ConfigurationManager PowerShell module loads on the CM
        site server and the PS drive '<SiteCode>:' exists.

    .DESCRIPTION
        Wraps the 3-line preamble every CM-cmdlet caller needs:

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force
            Set-Location "<SiteCode>:"

        This function runs that preamble once on the remote VM as a
        smoke test and returns Site / Version metadata. Most callers
        will inline the same preamble inside their own Invoke-LabCommand
        script blocks (the CM provider is per-session, so a host-side
        Import-CMModule does NOT make CM cmdlets available locally).

        Returns [pscustomobject]:
          SiteCode
          SiteName
          Version       - SMS provider version string
          Drive         - the PS drive name (= SiteCode)
          ProviderServer

        Throws on:
          - $env:SMS_ADMIN_UI_PATH is unset (CM admin console / SDK not
            installed yet -- you're calling this too early)
          - the .psd1 import fails
          - Get-PSDrive cannot find <SiteCode>:

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        Expected site code (the PS drive name will match this).

    .EXAMPLE
        Import-CMModule -ComputerName CM01 -DomainCredential $cred -SiteCode MCM
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
        [string]$SiteCode
    )

    Write-LabLog "[$ComputerName] Bootstrapping ConfigurationManager module + drive $SiteCode" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            param($Site)

            if (-not $env:SMS_ADMIN_UI_PATH) {
                throw "SMS_ADMIN_UI_PATH not set; CM admin console / SDK not installed on this box yet"
            }

            $modulePath = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            $modulePath = (Resolve-Path $modulePath -ErrorAction Stop).Path

            Import-Module $modulePath -Force -ErrorAction Stop

            $drive = Get-PSDrive -Name $Site -ErrorAction SilentlyContinue
            if (-not $drive) {
                $null = New-PSDrive -Name $Site -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
                $drive = Get-PSDrive -Name $Site -ErrorAction Stop
            }

            $prevLoc = Get-Location
            try {
                Set-Location "${Site}:"
                $site = Get-CMSite -SiteCode $Site -ErrorAction Stop
                return [pscustomobject]@{
                    SiteCode       = $site.SiteCode
                    SiteName       = $site.SiteName
                    Version        = $site.Version
                    Drive          = $drive.Name
                    ProviderServer = $env:COMPUTERNAME
                }
            } finally {
                Set-Location $prevLoc
            }
        } -ArgumentList $SiteCode

    Write-LabLog "[$ComputerName] CM module ready: $($result.SiteCode) $($result.SiteName) v$($result.Version)" -Status OK
    return $result
}
