<#
.SYNOPSIS
    Required-deploy every CM application in the site to a target collection.

.DESCRIPTION
    Run on CM01 (or any box with the ConfigMgr admin console + access to the
    site). Defaults align with the homelab: site MCM, target collection
    'HomeLab - Test Deployments' (which holds CLIENT01 as a direct member).

    Skips apps that:
      - have no deployment types (half-baked)
      - already have a deployment to the target collection

    All deployments are Required, Install, HideAll, available + deadline = now.

.EXAMPLE
    .\deploy-all-apps.ps1
    .\deploy-all-apps.ps1 -WhatIf
    .\deploy-all-apps.ps1 -CollectionName 'All Workstations'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SiteCode       = 'MCM',
    [string]$CollectionName = 'HomeLab - Test Deployments'
)

$ErrorActionPreference = 'Stop'

# --- CM module load ---
if (-not (Get-Module ConfigurationManager -ErrorAction SilentlyContinue)) {
    if (-not $env:SMS_ADMIN_UI_PATH) {
        $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine')
    }
    $cmModule = $null
    if ($env:SMS_ADMIN_UI_PATH) {
        $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
    }
    if ($cmModule -and (Test-Path -LiteralPath $cmModule)) {
        Import-Module $cmModule -Force -ErrorAction Stop
    } else {
        Import-Module ConfigurationManager -Force -ErrorAction Stop
    }
}

if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
}
Set-Location "${SiteCode}:"

# --- Resolve target collection ---
$collection = Get-CMDeviceCollection -Name $CollectionName -ErrorAction Stop
if (-not $collection) {
    throw "Collection '$CollectionName' not found in site $SiteCode."
}
Write-Host ("Target collection : {0}  [{1}]  members={2}" -f $collection.Name, $collection.CollectionID, $collection.MemberCount)

# --- Enumerate apps ---
$apps = @(Get-CMApplication | Sort-Object LocalizedDisplayName)
Write-Host ("CM applications   : {0}" -f $apps.Count)
Write-Host ""

$counts = @{ Deployed = 0; SkippedExists = 0; SkippedNoDT = 0; Failed = 0 }

foreach ($app in $apps) {
    $appName = $app.LocalizedDisplayName

    if ($app.NumberOfDeploymentTypes -eq 0) {
        Write-Host ("[SKIP-NODT]   {0}" -f $appName)
        $counts.SkippedNoDT++
        continue
    }

    $existing = Get-CMApplicationDeployment -Name $appName -CollectionId $collection.CollectionID -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host ("[SKIP-EXISTS] {0}" -f $appName)
        $counts.SkippedExists++
        continue
    }

    if ($PSCmdlet.ShouldProcess($appName, ("Required deployment to {0}" -f $collection.Name))) {
        try {
            New-CMApplicationDeployment `
                -Name              $appName `
                -CollectionId      $collection.CollectionID `
                -DeployAction      Install `
                -DeployPurpose     Required `
                -UserNotification  HideAll `
                -AvailableDateTime (Get-Date) `
                -DeadlineDateTime  (Get-Date) `
                -TimeBaseOn        LocalTime `
                -ErrorAction       Stop | Out-Null
            Write-Host ("[OK]          {0}" -f $appName)
            $counts.Deployed++
        } catch {
            Write-Host ("[FAIL]        {0} : {1}" -f $appName, $_.Exception.Message) -ForegroundColor Red
            $counts.Failed++
        }
    }
}

Write-Host ""
Write-Host ("Summary: Deployed={0}  AlreadyDeployed={1}  NoDeploymentType={2}  Failed={3}" -f `
    $counts.Deployed, $counts.SkippedExists, $counts.SkippedNoDT, $counts.Failed)
