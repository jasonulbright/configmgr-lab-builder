function New-CMRoleDeployment {
    <#
    .SYNOPSIS
        Skeleton for deploying a CM Application to a collection. Wraps
        New-CMApplicationDeployment with the homelab's preferred
        defaults (Available + UserNotification).

    .DESCRIPTION
        Post-CM customization helper (S18). Idempotent: short-circuits
        when a deployment of the same Application + Collection pair
        already exists.

        The homelab's deployment defaults match what a ConfigMgr admin
        would expect for a sandbox lab: Available (not Required) so
        clients pull only when the user clicks Install in Software
        Center; user-visible notifications enabled; rerun on failure.

        Supports app deployments only at this tag. Package /
        TaskSequence / Update group deployments live in their own
        helpers (S19+).

    .PARAMETER ComputerName
        Site server name.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER ApplicationName
        Existing CM Application to deploy. Throw if not found.

    .PARAMETER CollectionName
        Target collection.

    .PARAMETER DeployPurpose
        Available | Required. Default Available (homelab sandbox).

    .PARAMETER UserNotification
        DisplayAll | DisplaySoftwareCenterOnly | HideAll. Default
        DisplayAll.

    .EXAMPLE
        New-CMRoleDeployment -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -ApplicationName '7-Zip 26.00' `
            -CollectionName 'All Workstations'
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
        [string]$ApplicationName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionName,

        [Parameter()]
        [ValidateSet('Available','Required')]
        [string]$DeployPurpose = 'Available',

        [Parameter()]
        [ValidateSet('DisplayAll','DisplaySoftwareCenterOnly','HideAll')]
        [string]$UserNotification = 'DisplayAll'
    )

    Write-LabLog "[$ComputerName] Deploying '$ApplicationName' to '$CollectionName' ($DeployPurpose)" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Deploy $ApplicationName" -ScriptBlock {
            param($SiteCode, $App, $Coll, $Purpose, $Notif)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $appObj = Get-CMApplication -Name $App -ErrorAction SilentlyContinue
            if (-not $appObj) {
                throw "Application '$App' not found"
            }
            $collObj = Get-CMDeviceCollection -Name $Coll -ErrorAction SilentlyContinue
            if (-not $collObj) {
                throw "Collection '$Coll' not found"
            }

            $existing = Get-CMApplicationDeployment -Name $App -CollectionName $Coll -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; Application = $App; Collection = $Coll }
            }

            New-CMApplicationDeployment -Name $App -CollectionName $Coll `
                -DeployAction Install -DeployPurpose $Purpose `
                -UserNotification $Notif -ErrorAction Stop | Out-Null

            return [pscustomobject]@{ Status = 'Created'; Application = $App; Collection = $Coll }
        } -ArgumentList $SiteCode, $ApplicationName, $CollectionName, $DeployPurpose, $UserNotification

    Write-LabLog "[$ComputerName] Deployment '$ApplicationName' -> '$CollectionName' $($result.Status)" -Status OK
    return $result
}
