function Add-LabSchemaContainer {
    <#
    .SYNOPSIS
        Extend the AD schema for ConfigMgr and create the System
        Management container with full-control ACL for the CM site server.

    .DESCRIPTION
        Two pre-CM-install steps that MUST land before Install-CMSite:

          1. Schema extension. Run extadsch.exe (ships in the CM source
             at SMSSETUP\BIN\X64\). Adds CM-specific attributes and
             classes. Idempotent in practice; re-running is a no-op once
             the schema version has been bumped.

          2. System Management container. CM publishes site / boundary
             / MP info under CN=System Management,CN=System,<DomainDN>.
             This container does NOT exist by default; create it and
             grant the CM server's computer account GenericAll rights so
             CM can write its records.

        AL's Install-CMSite.ps1 does both, but interleaved with other
        pre-flight; we split them out so they can be invoked
        independently and tested by themselves.

        Step 1 runs ON the CM server (where the CM source lives, as a
        host->VM push or already-pushed). Step 2 runs ON the DC (which
        has the AD cmdlets and the schema-master role).

    .PARAMETER DCComputerName
        DC FQDN or short name. The System Management container creation
        and ACL set happen here.

    .PARAMETER CMComputerName
        CM site server name (e.g. CM01). The schema-extender runs here
        and the resulting computer account is the ACL grantee.

    .PARAMETER DomainCredential
        Domain admin credential. Schema admins / Enterprise admins
        membership is required for extadsch.exe; Domain Admins is
        sufficient for the System Management container ACL.

    .PARAMETER ExtAdSchPath
        Path to extadsch.exe ON THE CM SERVER. Default
        'C:\Install\CM\SMSSETUP\BIN\X64\extadsch.exe'.

    .PARAMETER NetBIOSName
        Domain NetBIOS name. Used to format the CM computer account
        as <NetBIOS>\<CMComputerName>$. If omitted, derived from the
        DC's environment.

    .EXAMPLE
        Add-LabSchemaContainer -DCComputerName DC01 -CMComputerName CM01 `
                               -DomainCredential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DCComputerName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CMComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter()]
        [string]$ExtAdSchPath = 'C:\Install\CM\SMSSETUP\BIN\X64\extadsch.exe',

        [Parameter()]
        [string]$NetBIOSName
    )

    Write-LabLog "[$CMComputerName] Extending AD schema for ConfigMgr" -Status RUN

    # extadsch.exe needs Schema Admins + an interactive token. Running
    # it directly via WinRM (network logon) hits "Unable to connect to
    # AD Schema - error 8224" because RPC schema ops require credential
    # delegation. Run via scheduled task with explicit domain creds so
    # the run-as identity is a real interactive logon with Schema Admins
    # rights (built-in Administrator IS in Schema Admins by default).
    $extResult = Invoke-LabCommand -ComputerName $CMComputerName -Credential $DomainCredential `
        -Activity 'Run extadsch.exe' -ScriptBlock {
            param($Exe, $DomUser, $DomPass)
            if (-not (Test-Path $Exe)) {
                throw "extadsch.exe not found at '$Exe'. Push CM source to CM01 first (S5)."
            }

            $taskName = 'HomeLab-ExtAdSch'
            $action   = New-ScheduledTaskAction -Execute $Exe
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
            Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User $DomUser -Password $DomPass -RunLevel Highest -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName

            $startDeadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $startDeadline) {
                if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') { break }
                Start-Sleep -Seconds 1
            }
            $deadline = (Get-Date).AddMinutes(15)
            $exit = $null
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 5
                if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') {
                    $exit = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
                    break
                }
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

            if ($null -eq $exit) { throw "extadsch.exe scheduled task did not complete in 15 min" }
            if ($exit -ne 0) {
                $log = Get-Content 'C:\ExtADSch.log' -ErrorAction SilentlyContinue | Out-String
                throw "extadsch.exe exited $exit. Log:`n$log"
            }
            return [pscustomobject]@{ ExitCode = 0; Log = (Get-Content 'C:\ExtADSch.log' -ErrorAction SilentlyContinue | Out-String) }
        } -ArgumentList $ExtAdSchPath, $DomainCredential.UserName,
                        ([System.Net.NetworkCredential]::new('', $DomainCredential.Password).Password)

    Write-LabLog "[$CMComputerName] Schema extension OK" -Status OK

    Write-LabLog "[$DCComputerName] Creating System Management container + CM ACL" -Status RUN

    $contResult = Invoke-LabCommand -ComputerName $DCComputerName -Credential $DomainCredential `
        -Activity 'Create CN=System Management + ACL' -ScriptBlock {
            param($CMComputerName, $NetBIOSHint)

            Import-Module ActiveDirectory -ErrorAction Stop

            $rootDomainNc = (Get-ADRootDSE).defaultNamingContext
            $smPath = "CN=System Management,CN=System,$rootDomainNc"

            $existing = $null
            try {
                $existing = Get-ADObject -Identity $smPath -ErrorAction Stop
            } catch { }

            if (-not $existing) {
                $null = New-ADObject -Type Container -Name 'System Management' `
                    -Path "CN=System,$rootDomainNc" -Passthru
            }

            # Grant CM01$ GenericAll on the container.
            # NOTE: -Identity on Get-ADComputer matches by SamAccountName / DN /
            # GUID / SID. Passing a short name like 'CM01' resolves to
            # SamAccountName 'CM01$' uniquely WITHIN A SINGLE DOMAIN. The
            # homelab is single-domain (contoso.com) by design (see
            # config.psd1), so this is unambiguous. If we ever extend to a
            # multi-domain forest, add -Server <DomainFQDN> to scope the
            # lookup explicitly.
            $cmAccount = Get-ADComputer -Identity $CMComputerName -ErrorAction Stop
            $cmSid = [System.Security.Principal.SecurityIdentifier]$cmAccount.SID

            $acl = Get-Acl -Path "AD:$smPath"

            # Skip if the rule is already present (idempotency).
            $alreadyHas = $false
            foreach ($rule in $acl.Access) {
                if ($rule.IdentityReference -eq $cmSid -and `
                    $rule.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::GenericAll) {
                    $alreadyHas = $true
                    break
                }
            }

            if (-not $alreadyHas) {
                $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                    $cmSid,
                    [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
                    [System.Security.AccessControl.AccessControlType]::Allow,
                    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::SelfAndChildren,
                    [guid]'00000000-0000-0000-0000-000000000000'
                )
                $acl.AddAccessRule($ace)
                Set-Acl -AclObject $acl -Path "AD:$smPath"
            }

            return [pscustomobject]@{
                ContainerExisted = ($null -ne $existing)
                AclAlreadyHadRule = $alreadyHas
                ContainerDN = $smPath
                CMAccount = $cmAccount.SamAccountName
            }
        } -ArgumentList $CMComputerName, $NetBIOSName

    Write-LabLog "[$DCComputerName] System Management container ready ($($contResult.ContainerDN))" -Status OK

    return [pscustomobject]@{
        SchemaExtended = $true
        SchemaLog      = $extResult.Log
        Container      = $contResult.ContainerDN
        CMAccount      = $contResult.CMAccount
    }
}
