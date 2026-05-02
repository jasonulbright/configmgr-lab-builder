function New-CMRoleTaskSequenceStub {
    <#
    .SYNOPSIS
        Create a minimal OSD task sequence stub. Idempotent.

    .DESCRIPTION
        Post-CM customization helper (S19). Creates a brand-new task
        sequence using New-CMTaskSequence with the
        InstallOperatingSystemImage variant -- the simplest OSD path
        that boots WinPE, applies an OS image, and joins the domain.

        This is a STUB: the resulting TS has the boilerplate steps
        but is not customised for production scenarios (no driver
        injection, no per-model conditional groups, no user-state
        migration, no application install steps). It exists so a
        future GUI can drop a "minimum OSD TS" into a fresh lab and
        let the user iterate.

        Idempotent: short-circuits when Get-CMTaskSequence by name
        already returns a result.

        Inputs assume the boot image and the OS install image
        already exist as CM packages (created via
        New-CMRoleBootImage and the user's own OS image import).

    .PARAMETER ComputerName
        Site server name.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        3-letter site code.

    .PARAMETER Name
        TS name. Must be unique within the site.

    .PARAMETER BootImageName
        Existing CM boot image to associate with the TS.

    .PARAMETER OsImageName
        Existing CM OS image package.

    .PARAMETER OsImageIndex
        WIM index inside the OS image (default 1).

    .PARAMETER LocalAdminPassword
        SecureString for the local Administrator password set during
        OSD. Must be supplied; the TS won't function without it.

    .PARAMETER DomainName
        Domain to join after OS apply.

    .PARAMETER DomainOuPath
        Optional LDAP path to drop the new computer object into.

    .EXAMPLE
        New-CMRoleTaskSequenceStub -ComputerName CM01 -DomainCredential $cred `
            -SiteCode MCM -Name 'Build Win11' `
            -BootImageName 'WinPE x64' -OsImageName 'Win11 Enterprise' `
            -LocalAdminPassword (Read-Host -AsSecureString) `
            -DomainName contoso.com
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
        [string]$BootImageName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OsImageName,

        [Parameter()]
        [ValidateRange(1, 64)]
        [int]$OsImageIndex = 1,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$LocalAdminPassword,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DomainName,

        [Parameter()]
        [string]$DomainOuPath,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$JoinAccount
    )

    Write-LabLog "[$ComputerName] Creating OSD task sequence stub '$Name'" -Status RUN

    $joinUser = $JoinAccount.UserName
    $joinPass = $JoinAccount.Password
    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity "Create TS stub $Name" -ScriptBlock {
            param($SiteCode, $Name, $Boot, $OsImg, $OsIdx, $LocalPwd, $Domain, $Ou, $JoinUser, $JoinPass)

            # Refresh from Machine scope: CM 2509 setup writes SMS_ADMIN_UI_PATH after
            # our PSSession was created; the WinRM listener inherited a stale env block.
            if (-not $env:SMS_ADMIN_UI_PATH) { $env:SMS_ADMIN_UI_PATH = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH','Machine') }
            $cmModule = Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'
            Import-Module $cmModule -Force -ErrorAction Stop
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop
            }
            Set-Location "${SiteCode}:"

            $existing = Get-CMTaskSequence -Name $Name -ErrorAction SilentlyContinue
            if ($existing) {
                return [pscustomobject]@{ Status = 'AlreadyExists'; Name = $Name; PackageId = $existing.PackageID }
            }

            $bi = Get-CMBootImage -Name $Boot -ErrorAction SilentlyContinue
            if (-not $bi)  { throw "Boot image '$Boot' not found" }
            $os = Get-CMOperatingSystemImage -Name $OsImg -ErrorAction SilentlyContinue
            if (-not $os)  { throw "OS image '$OsImg' not found" }

            $params = @{
                InstallOperatingSystemImage = $true
                Name                        = $Name
                BootImagePackageId          = $bi.PackageID
                OperatingSystemImagePackageId = $os.PackageID
                OperatingSystemImageIndex   = $OsIdx
                LocalAdminPassword          = $LocalPwd
                JoinDomain                  = 'DomainType'
                DomainAccount               = $JoinUser
                DomainPassword              = $JoinPass
                DomainName                  = $Domain
                ErrorAction                 = 'Stop'
            }
            # CM 2509 cmdlet uses DomainOrganizationUnit (no 'al' suffix);
            # DomainAccountPassword was renamed to DomainPassword in the
            # same release. Keys validated against Get-Command on CM01.
            if ($Ou) { $params['DomainOrganizationUnit'] = $Ou }

            $ts = New-CMTaskSequence @params
            return [pscustomobject]@{ Status = 'Created'; Name = $Name; PackageId = $ts.PackageID }
        } -ArgumentList $SiteCode, $Name, $BootImageName, $OsImageName, $OsImageIndex, $LocalAdminPassword, $DomainName, $DomainOuPath, $joinUser, $joinPass

    Write-LabLog "[$ComputerName] Task sequence stub '$Name' $($result.Status) (PackageID=$($result.PackageId))" -Status OK
    return $result
}
