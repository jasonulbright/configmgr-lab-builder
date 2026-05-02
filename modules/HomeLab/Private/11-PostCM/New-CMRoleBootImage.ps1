function New-CMRoleBootImage {
    <#
    .SYNOPSIS
        Add a CM boot image from a WIM file. Idempotent.

    .DESCRIPTION
        Post-CM customization helper (S19). Wraps:

          New-CMBootImage -Name <Name> -Path <WimUncOrLocal>

        The WIM must already be reachable from the site server (the
        boot image source is staged once; CM copies it into its own
        package store). Typical sources:
          - %ADK%\Assessment and Deployment Kit\Windows Preinstallation
            Environment\amd64\en-us\winpe.wim
          - A custom-built WIM from `New-CMBootImageWim` (not a thing
            yet; this helper accepts pre-built WIMs only).

        Idempotent: short-circuits when Get-CMBootImage by name already
        returns a result.

        After creation the boot image is NOT distributed to any DP --
        callers that want clients to PXE-boot off it must call
        Start-CMContentDistribution separately or add a DP via
        Add-CMRoleDistributionPoint then assign the boot image.

    .PARAMETER ComputerName
        Site server name.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER Name
        Boot image name (e.g. 'WinPE x64 ADK 10.1.26100').

    .PARAMETER WimPath
        UNC or local path on the site server pointing at the WIM.
        Validated to exist via Test-Path inside the remote scriptblock.

    .PARAMETER Description
        Optional description.

    .EXAMPLE
        New-CMRoleBootImage -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -Name 'WinPE x64' `
            -WimPath '\\CM01\Sources$\Boot\winpe.wim'
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
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WimPath,

        [Parameter()]
        [string]$Description
    )

    Write-LabLog "[$ComputerName] Adding boot image '$Name' from $WimPath" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Add boot image $Name" -ScriptBlock {
            param($SiteCode, $Name, $Wim, $Desc)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMBootImage -Name $Name -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; Name = $Name; PackageId = $existing.PackageID }
            }

            # Skip Test-Path on UNC paths: loopback access to local admin
            # shares (\\hostname\C$\...) is blocked from within the same
            # WinRM session. Let New-CMBootImage do its own validation.
            if ($Wim -notmatch '^\\\\') {
                if (-not (Test-Path -Path $Wim -PathType Leaf)) {
                    throw "WIM not found at '$Wim' on $env:COMPUTERNAME"
                }
            }

            $params = @{
                Name        = $Name
                Path        = $Wim
                Index       = 1
                ErrorAction = 'Stop'
            }
            if ($Desc) { $params['Description'] = $Desc }

            $bi = New-CMBootImage @params
            return [pscustomobject]@{ Status = 'Created'; Name = $Name; PackageId = $bi.PackageID }
        } -ArgumentList $SiteCode, $Name, $WimPath, $Description

    Write-LabLog "[$ComputerName] Boot image '$Name' $($result.Status) (PackageID=$($result.PackageId))" -Status OK
    return $result
}
