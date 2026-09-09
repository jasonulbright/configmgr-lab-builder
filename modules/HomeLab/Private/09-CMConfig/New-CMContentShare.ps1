function New-CMContentShare {
    <#
    .SYNOPSIS
        Idempotently create the CM content source share on the CM site
        server.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 5 (lines 838-885). Creates an
        SMB share at the configured path, populated with the standard
        CM source folder layout (Applications / Drivers / Images /
        OperatingSystems / Packages / Scripts / SoftwareUpdates), and
        sets NTFS + SMB ACLs that match the lab pattern:

          - Domain Admins:           Full
          - AdminUser (LabAdmin):    Full   (share + NTFS, by user SID.
                                             An admin's UAC-filtered token
                                             marks Administrators and Domain
                                             Admins use-for-deny-only, so
                                             neither of those ACEs fires from
                                             a non-elevated Explorer session:
                                             the console user could not
                                             populate the share without
                                             elevating. A plain user SID is
                                             never filtered.)
          - NT AUTHORITY\SYSTEM:     Full   (SHARE level -- Distribution
                                             Manager runs as SYSTEM and
                                             reads \\self\share loopback;
                                             share-level access is checked
                                             BEFORE NTFS, and a missing
                                             share entry = access denied.
                                             Found on the 2026-07-17 probe:
                                             distmgr 2306 LE=0x5 taking the
                                             content snapshot, which blocked
                                             SMSContentHash, which blocked
                                             app policy generation, which
                                             silently broke ALL app deploys)
          - Site server computer$:   Read   (share + NTFS; DPs pulling
                                             from package source)
          - Domain Computers:        Read
          - svc-CMNAA:               Read

        This is a non-CM-cmdlet operation (SMB / NTFS only), so the
        remote script block does NOT import the ConfigurationManager
        module.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER NetBIOSName
        Domain NetBIOS (e.g. CONTOSO).

    .PARAMETER NAAAccount
        sAMAccountName of the NAA (e.g. svc-CMNAA). Domain prefix is
        added inside the script block.

    .PARAMETER AdminUser
        sAMAccountName of the lab admin (e.g. LabAdmin). Granted Full on
        both the share and NTFS so the interactive console user can
        populate the share without elevating.

    .PARAMETER SharePath
        Local path on the VM. Default 'C:\ContentShare'. CM01 is
        provisioned with a single OS volume, so C: is the only option.

    .PARAMETER ShareName
        SMB share name. Default 'ContentShare$' (hidden).

    .PARAMETER Folders
        Subfolders created under SharePath.

    .EXAMPLE
        New-CMContentShare -ComputerName CM01 -DomainCredential $cred `
            -NetBIOSName CONTOSO -NAAAccount 'svc-CMNAA'
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
        [ValidateNotNullOrEmpty()]
        [string]$NetBIOSName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NAAAccount,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AdminUser,

        [Parameter()]
        [string]$SharePath = 'C:\ContentShare',

        [Parameter()]
        [string]$ShareName = 'ContentShare$',

        [Parameter()]
        [string[]]$Folders = @(
            'Applications','Drivers','Images','OperatingSystems',
            'Packages','Scripts','SoftwareUpdates'
        )
    )

    Write-LabLog "[$ComputerName] Provisioning content share \\$ComputerName\$ShareName" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Create CM content share' -ScriptBlock {
            param($SharePath, $ShareName, $Folders, $NetBIOS, $NAAAccount, $AdminUser)

            New-Item -Path $SharePath -ItemType Directory -Force | Out-Null
            foreach ($f in $Folders) {
                New-Item -Path (Join-Path $SharePath $f) -ItemType Directory -Force | Out-Null
            }

            # Single desired-state table drives both the create and the
            # repair path. Splitting them let the repair path fall behind:
            # it only ever reconciled SYSTEM and the computer account, so a
            # share missing its Domain Admins grant stayed broken while the
            # function still reported OK.
            $desiredShare = [ordered]@{
                "$NetBIOS\Domain Admins"        = 'Full'
                'NT AUTHORITY\SYSTEM'           = 'Full'
                "$NetBIOS\$AdminUser"           = 'Full'
                "$NetBIOS\Domain Computers"     = 'Read'
                "$NetBIOS\$NAAAccount"          = 'Read'
                "$NetBIOS\$env:COMPUTERNAME$"   = 'Read'
            }

            $shareCreated = $false
            if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
                New-SmbShare -Name $ShareName -Path $SharePath | Out-Null
                # New-SmbShare seeds Everyone:Read. Drop it -- the desired
                # table below is the whole ACL.
                Revoke-SmbShareAccess -Name $ShareName -AccountName 'Everyone' -Force -ErrorAction SilentlyContinue | Out-Null
                $shareCreated = $true
            }

            $existing = @{}
            foreach ($a in Get-SmbShareAccess -Name $ShareName) {
                if ($a.AccessControlType -eq 'Allow') { $existing[$a.AccountName] = [string]$a.AccessRight }
            }
            $shareRepaired = @()
            foreach ($account in $desiredShare.Keys) {
                if ($existing[$account] -ne $desiredShare[$account]) {
                    Grant-SmbShareAccess -Name $ShareName -AccountName $account `
                        -AccessRight $desiredShare[$account] -Force | Out-Null
                    $shareRepaired += $account
                }
            }

            # NTFS. $AdminUser is granted explicitly by user SID rather than
            # relying on BUILTIN\Administrators: an admin's UAC-filtered token
            # marks Administrators and Domain Admins use-for-deny-only, so
            # neither ACE fires from a non-elevated Explorer session and the
            # console user cannot populate the share without elevating.
            $acl = Get-Acl -Path $SharePath
            $rules = @(
                New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "$NetBIOS\$AdminUser",       'FullControl',
                    'ContainerInherit,ObjectInherit', 'None', 'Allow')
                New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "$env:COMPUTERNAME$",      'Read',
                    'ContainerInherit,ObjectInherit', 'None', 'Allow')
                New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "$NetBIOS\$NAAAccount",    'Read',
                    'ContainerInherit,ObjectInherit', 'None', 'Allow')
                New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "$NetBIOS\Domain Computers", 'Read',
                    'ContainerInherit,ObjectInherit', 'None', 'Allow')
            )
            foreach ($r in $rules) { $acl.AddAccessRule($r) }
            Set-Acl -Path $SharePath -AclObject $acl

            return [pscustomobject]@{
                SharePath     = $SharePath
                ShareName     = $ShareName
                ShareCreated  = $shareCreated
                ShareRepaired = $shareRepaired
                FolderCount   = $Folders.Count
            }
        } -ArgumentList $SharePath, $ShareName, $Folders, $NetBIOSName, $NAAAccount, $AdminUser

    Write-LabLog "[$ComputerName] Content share ready: \\$ComputerName\$ShareName" -Status OK
    return $result
}
