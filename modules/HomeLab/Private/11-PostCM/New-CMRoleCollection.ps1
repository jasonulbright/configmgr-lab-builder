function New-CMRoleCollection {
    <#
    .SYNOPSIS
        Create a CM device collection with a query or direct-membership
        rule. Idempotent; short-circuits when a collection of the same
        name already exists in the site.

    .DESCRIPTION
        Post-CM customization helper (S18). Wraps the CM cmdlet
        sequence:

          New-CMDeviceCollection -Name <Name> -LimitingCollectionName <Limit>
          Add-CMDeviceCollectionQueryMembershipRule (when -Query is set)
          Add-CMDeviceCollectionDirectMembershipRule (when -Direct is set)

        Supports two membership models, mutually exclusive on a single
        call:
          -Query  : a WQL query string. Examples in the homelab: "All
                    Workstations" via "select * from SMS_R_System
                    where SMS_R_System.OperatingSystemNameAndVersion
                    like 'Microsoft Windows NT Workstation%'".
          -Direct : an array of resource names (computer names) for
                    a direct-membership collection. Used in the
                    homelab for the test-deployment collection
                    (CLIENT01).

        Default LimitingCollectionName is 'All Systems'.

    .PARAMETER ComputerName
        DNS / short name of the CM site server (where the CM provider
        runs).

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER Name
        Collection name. Must be unique within the site.

    .PARAMETER LimitingCollectionName
        Parent / scope collection. Default 'All Systems'.

    .PARAMETER Query
        WQL membership query string. Mutually exclusive with -Direct.

    .PARAMETER Direct
        Array of resource names to add as direct members. Mutually
        exclusive with -Query.

    .PARAMETER QueryRuleName
        Friendly name for the query rule. Default: 'All <Name>'.

    .EXAMPLE
        New-CMRoleCollection -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -Name 'All Workstations' `
            -Query "select * from SMS_R_System where SMS_R_System.OperatingSystemNameAndVersion like 'Microsoft Windows NT Workstation%'"

    .EXAMPLE
        New-CMRoleCollection -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -Name 'Test Direct' -Direct @('CLIENT01','CLIENT02')
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

        [Parameter()]
        [string]$LimitingCollectionName = 'All Systems',

        [Parameter()]
        [string]$Query,

        [Parameter()]
        [string[]]$Direct,

        [Parameter()]
        [string]$QueryRuleName
    )

    if ($Query -and $Direct) {
        throw "New-CMRoleCollection: -Query and -Direct are mutually exclusive."
    }
    if (-not $Query -and -not $Direct) {
        throw "New-CMRoleCollection: provide either -Query or -Direct."
    }
    if (-not $QueryRuleName) { $QueryRuleName = "All $Name" }

    Write-LabLog "[$ComputerName] Creating device collection '$Name'" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Create collection $Name" -ScriptBlock {
            param($SiteCode, $Name, $Limit, $Query, $Direct, $RuleName)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMDeviceCollection -Name $Name -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; Name = $Name }
            }

            $coll = New-CMDeviceCollection -Name $Name -LimitingCollectionName $Limit -ErrorAction Stop

            if ($Query) {
                Add-CMDeviceCollectionQueryMembershipRule -CollectionName $Name `
                    -RuleName $RuleName -QueryExpression $Query -ErrorAction Stop
            } elseif ($Direct) {
                foreach ($d in $Direct) {
                    $r = Get-CMDevice -Name $d -ErrorAction SilentlyContinue
                    if ($r) {
                        Add-CMDeviceCollectionDirectMembershipRule -CollectionName $Name `
                            -ResourceId $r.ResourceID -ErrorAction Stop
                    }
                }
            }

            return [pscustomobject]@{ Status = 'Created'; Name = $Name }
        } -ArgumentList $SiteCode, $Name, $LimitingCollectionName, $Query, $Direct, $QueryRuleName

    Write-LabLog "[$ComputerName] Collection '$Name' $($result.Status)" -Status OK
    return $result
}
