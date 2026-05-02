function New-CMRoleDriverCategory {
    <#
    .SYNOPSIS
        Create a CM driver category. Idempotent.

    .DESCRIPTION
        Post-CM customization helper (S18). Driver categories are the
        primary way OSD task sequences reference drivers (e.g. by
        manufacturer-model: 'Dell-Latitude-7440'). Categories are
        created via New-CMCategory under the DriverCategories scope.

        Wraps:
          New-CMCategory -CategoryType DriverCategories -Name <Name>

        Returns AlreadyExists when the category is already present;
        otherwise Created.

    .PARAMETER ComputerName
        Site server name.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER Name
        Category name. Convention: Vendor-Model (e.g. 'Lenovo-T14s').

    .EXAMPLE
        New-CMRoleDriverCategory -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -Name 'Dell-Latitude-7440'
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
        [string]$Name
    )

    Write-LabLog "[$ComputerName] Creating driver category '$Name'" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Create driver category $Name" -ScriptBlock {
            param($SiteCode, $Name)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMCategory -CategoryType DriverCategories -Name $Name -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; Name = $Name }
            }

            New-CMCategory -CategoryType DriverCategories -Name $Name -ErrorAction Stop | Out-Null
            return [pscustomobject]@{ Status = 'Created'; Name = $Name }
        } -ArgumentList $SiteCode, $Name

    Write-LabLog "[$ComputerName] Driver category '$Name' $($result.Status)" -Status OK
    return $result
}
