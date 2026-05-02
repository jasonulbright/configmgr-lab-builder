function New-CMRoleApplication {
    <#
    .SYNOPSIS
        Create a CM Application with one Script-style deployment type.
        Idempotent. Designed to consume app-packager-style output
        (a content folder + explicit install / uninstall commands +
        a registry detection rule).

    .DESCRIPTION
        Post-CM customization helper (S19). Wraps:

          New-CMApplication -Name <Name> ...
          Add-CMScriptDeploymentType -ApplicationName <Name>
                                     -DeploymentTypeName <DT>
                                     -ContentLocation <Path>
                                     -InstallCommand <Cmd>
                                     -UninstallCommand <Cmd>
                                     -AddDetectionClause <Reg/Msi>

        Per `reference_cm_cmdlet_params.md` the homelab idiom uses
        Script DT (NOT MSI DT) for everything, with install.bat/ps1
        wrappers that drive the actual installer; this lines up with
        the user's portfolio philosophy
        (`feedback_script_deployment_type.md`).

        For `New-CMApplication` the homelab also passes
        `-AutoInstall $true` per the same reference doc, so deployments
        with -DeployAction Install actually push when targeted.

        Idempotent: short-circuits when Get-CMApplication by name
        already returns a result. If the app exists but has no DT,
        the DT is added on top.

    .PARAMETER ComputerName
        Site server name.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER Name
        Application Name (e.g. '7-Zip 26.00').

    .PARAMETER Publisher
        Publisher (e.g. 'Igor Pavlov').

    .PARAMETER SoftwareVersion
        Version string (e.g. '26.00').

    .PARAMETER ContentLocation
        UNC path the site server can reach for the deployment-type
        content.

    .PARAMETER InstallCommand
        Install command line (e.g. 'install.bat' or 'powershell.exe
        -NoProfile -ExecutionPolicy Bypass -File install.ps1').

    .PARAMETER UninstallCommand
        Uninstall command line.

    .PARAMETER DetectionRegistryKey
        Registry key path for the detection rule (e.g.
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{ProductCode}').

    .PARAMETER DetectionRegistryValue
        Value name to check (e.g. 'DisplayVersion').

    .PARAMETER DetectionRegistryExpectedValue
        Expected value contents (e.g. '26.00.00.0' for an MSI ARP key).

    .PARAMETER DeploymentTypeName
        Default '<Name> Script DT'.

    .EXAMPLE
        New-CMRoleApplication -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM `
            -Name '7-Zip 26.00' -Publisher 'Igor Pavlov' -SoftwareVersion '26.00' `
            -ContentLocation '\\CM01\ContentShare$\Apps\7-Zip\26.00' `
            -InstallCommand 'install.bat' -UninstallCommand 'uninstall.bat' `
            -DetectionRegistryKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip' `
            -DetectionRegistryValue 'DisplayVersion' `
            -DetectionRegistryExpectedValue '26.00.00.0'
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
        [string]$Publisher,

        [Parameter()]
        [string]$SoftwareVersion,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ContentLocation,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstallCommand,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UninstallCommand,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DetectionRegistryKey,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DetectionRegistryValue,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DetectionRegistryExpectedValue,

        [Parameter()]
        [string]$DeploymentTypeName
    )

    if (-not $DeploymentTypeName) { $DeploymentTypeName = "$Name Script DT" }

    Write-LabLog "[$ComputerName] Creating CM Application '$Name' from $ContentLocation" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Create application $Name" -ScriptBlock {
            param($SiteCode, $Name, $Pub, $Ver, $Content, $InstCmd, $UninstCmd, $RegKey, $RegVal, $RegExpected, $DtName)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existingApp = Get-CMApplication -Name $Name -ErrorAction SilentlyContinue
            if ($existingApp) {
                $existingDt = Get-CMDeploymentType -ApplicationName $Name -DeploymentTypeName $DtName -ErrorAction SilentlyContinue
                if ($existingDt) {
                    return [pscustomobject]@{ Status = 'AlreadyExists'; Name = $Name; DeploymentType = $DtName }
                }
                # App exists but DT does not -- add it.
            } else {
                $appParams = @{
                    Name        = $Name
                    AutoInstall = $true
                    ErrorAction = 'Stop'
                }
                if ($Pub) { $appParams['Publisher']       = $Pub }
                if ($Ver) { $appParams['SoftwareVersion'] = $Ver }
                New-CMApplication @appParams | Out-Null
            }

            $clause = New-CMDetectionClauseRegistryKeyValue `
                -Hive LocalMachine -KeyName $RegKey -ValueName $RegVal `
                -ExpectedValue $RegExpected -Value -PropertyType String -ExpressionOperator IsEquals

            $dtParams = @{
                ApplicationName    = $Name
                DeploymentTypeName = $DtName
                ContentLocation    = $Content
                InstallCommand     = $InstCmd
                UninstallCommand   = $UninstCmd
                AddDetectionClause = $clause
                ContentFallback    = $true
                ErrorAction        = 'Stop'
            }
            Add-CMScriptDeploymentType @dtParams | Out-Null

            $verb = if ($existingApp) { 'DTAdded' } else { 'Created' }
            return [pscustomobject]@{ Status = $verb; Name = $Name; DeploymentType = $DtName }
        } -ArgumentList $SiteCode, $Name, $Publisher, $SoftwareVersion, $ContentLocation, $InstallCommand, $UninstallCommand, $DetectionRegistryKey, $DetectionRegistryValue, $DetectionRegistryExpectedValue, $DeploymentTypeName

    Write-LabLog "[$ComputerName] Application '$Name' $($result.Status)" -Status OK
    return $result
}
