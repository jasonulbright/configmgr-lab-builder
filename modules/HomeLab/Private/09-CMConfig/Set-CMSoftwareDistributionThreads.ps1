function Set-CMSoftwareDistributionThreads {
    <#
    .SYNOPSIS
        Set Software Distribution thread limits + the Network Access
        Account on the CM site.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 9 (lines 1224-1245). Two
        Set-CMSoftwareDistributionComponent calls collapsed into one
        function:

          1. NetworkAccessAccountName -- bind the NAA principal CM
             uses for clients that can not authenticate as their
             computer account (workgroup, DMZ, OSD WinPE)
          2. MaximumThreadCountPerPackage / MaximumPackageCount --
             10 / 3 for the homelab.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER NAAAccount
        DOMAIN\sAMAccountName for the Network Access Account.

    .PARAMETER MaximumThreadCountPerPackage
        Default 10.

    .PARAMETER MaximumPackageCount
        Default 3.

    .EXAMPLE
        Set-CMSoftwareDistributionThreads -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -NAAAccount 'CONTOSO\svc-CMNAA'
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
        [string]$NAAAccount,

        [Parameter()]
        [ValidateRange(1, 50)]
        [int]$MaximumThreadCountPerPackage = 10,

        [Parameter()]
        [ValidateRange(1, 25)]
        [int]$MaximumPackageCount = 3
    )

    Write-LabLog "[$ComputerName] Setting NAA + thread limits ($MaximumThreadCountPerPackage/$MaximumPackageCount)" -Status RUN

    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Configure SD thread limits + NAA' -ScriptBlock {
            param($SiteCode, $NAAAccount, $ThreadsPerPackage, $PackageCount)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            Set-CMSoftwareDistributionComponent -SiteCode $SiteCode `
                -NetworkAccessAccountName @($NAAAccount) -ErrorAction Stop

            Set-CMSoftwareDistributionComponent -SiteCode $SiteCode `
                -MaximumThreadCountPerPackage $ThreadsPerPackage `
                -MaximumPackageCount $PackageCount -ErrorAction Stop
        } -ArgumentList $SiteCode, $NAAAccount, $MaximumThreadCountPerPackage, $MaximumPackageCount | Out-Null

    Write-LabLog "[$ComputerName] NAA + thread limits set" -Status OK
}
