function Add-CMFullAdministrator {
    <#
    .SYNOPSIS
        Add a domain user as a CM Full Administrator.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 6 (the Add-CMAdministrativeUser
        path; lines 947-967). Idempotent: Get-CMAdministrativeUser
        short-circuits when the principal already has any CM role.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER UserName
        DOMAIN\sAMAccountName (e.g. CONTOSO\svc-CMAdmin).

    .EXAMPLE
        Add-CMFullAdministrator -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -UserName 'CONTOSO\svc-CMAdmin'
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
        [ValidatePattern('^[^\\]+\\[^\\]+$')]
        [string]$UserName
    )

    Write-LabLog "[$ComputerName] Granting Full Administrator to $UserName" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Add Full Administrator $UserName" -ScriptBlock {
            param($SiteCode, $UserName)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMAdministrativeUser -Name $UserName -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Action = 'AlreadyExists'; UserName = $UserName }
            }

            New-CMAdministrativeUser -Name $UserName `
                -RoleName 'Full Administrator' `
                -SecurityScopeName 'All' -ErrorAction Stop | Out-Null
            return [pscustomobject]@{ Action = 'Added'; UserName = $UserName }
        } -ArgumentList $SiteCode, $UserName

    Write-LabLog "[$ComputerName] Full Administrator $UserName $($result.Action)" -Status OK
    return $result
}
