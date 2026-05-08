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
          - Site server computer$:   Read   (Distribution Manager
                                             pulls from package source)
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

    .PARAMETER SharePath
        Local path on the VM. Default 'E:\ContentShare' (E: is the
        CM-Data disk per S2 / config.psd1).

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
            param($SharePath, $ShareName, $Folders, $NetBIOS, $NAAAccount)

            New-Item -Path $SharePath -ItemType Directory -Force | Out-Null
            foreach ($f in $Folders) {
                New-Item -Path (Join-Path $SharePath $f) -ItemType Directory -Force | Out-Null
            }

            $shareCreated = $false
            if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
                New-SmbShare -Name $ShareName -Path $SharePath `
                    -FullAccess "$NetBIOS\Domain Admins" `
                    -ReadAccess "$NetBIOS\Domain Computers", "$NetBIOS\$NAAAccount" |
                    Out-Null
                $shareCreated = $true
            }

            $acl = Get-Acl -Path $SharePath
            $rules = @(
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
                FolderCount   = $Folders.Count
            }
        } -ArgumentList $SharePath, $ShareName, $Folders, $NetBIOSName, $NAAAccount

    Write-LabLog "[$ComputerName] Content share ready: \\$ComputerName\$ShareName" -Status OK
    return $result
}
