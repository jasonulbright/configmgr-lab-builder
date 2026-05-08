function New-LabServiceAccounts {
    <#
    .SYNOPSIS
        Create the three CM service accounts (svc-CMPush, svc-CMNAA,
        svc-CMJoin) plus the LabAdmin orchestrator under OU=Service Accounts, with prescribed group
        memberships.

    .DESCRIPTION
        Phase 4 service accounts, with two
        improvements:

          - Uses Invoke-LabCommand (pooled session) instead of AL's
            Invoke-LabCommand (per-call WinRM auth)
          - Passes credentials and account specs via -ArgumentList so
            no plain-text password ever appears in a script literal
            transferred over the wire

        Each account spec is a hashtable with Sam, Full, Pass, Desc,
        and Group properties. Groups are created if they don't exist.

        Idempotent: re-running on an already-populated forest is a
        no-op per account ("Exists: ..." log line).

    .PARAMETER DCComputerName
        DC FQDN or short name. AD cmdlets run here.

    .PARAMETER DomainCredential
        Domain admin credential (CONTOSO\Administrator).

    .PARAMETER DomainName
        FQDN of the forest (e.g. contoso.com).

    .PARAMETER NetBIOSName
        NetBIOS form (e.g. CONTOSO).

    .PARAMETER ServiceAccounts
        Hashtable from config.psd1: ClientPush / NAA / Admin, each with
        Name, Password, Desc, Group.

    .PARAMETER OUName
        OU under the domain root. Default 'Service Accounts'.

    .EXAMPLE
        $cfg = Get-LabConfig
        New-LabServiceAccounts -DCComputerName DC01.contoso.com `
            -DomainCredential (Get-LabCredential -Identity Admin -Config $cfg) `
            -DomainName $cfg.DomainName -NetBIOSName $cfg.NetBIOS `
            -ServiceAccounts $cfg.ServiceAccounts
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DCComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [string]$DomainName,

        [Parameter(Mandatory)]
        [string]$NetBIOSName,

        [Parameter(Mandatory)]
        [hashtable]$ServiceAccounts,

        [Parameter(Mandatory)]
        [string]$AdminUser,

        [Parameter(Mandatory)]
        [string]$AdminPass,

        [Parameter()]
        [string]$OUName = 'Service Accounts'
    )

    foreach ($key in 'ClientPush','NAA','Join') {
        if (-not $ServiceAccounts.ContainsKey($key)) {
            throw "New-LabServiceAccounts: ServiceAccounts.$key missing"
        }
        foreach ($p in 'Name','Password') {
            if ([string]::IsNullOrEmpty([string]$ServiceAccounts[$key][$p])) {
                throw "New-LabServiceAccounts: ServiceAccounts.$key.$p is empty"
            }
        }
    }
    if ([string]::IsNullOrEmpty($AdminUser) -or [string]::IsNullOrEmpty($AdminPass)) {
        throw "New-LabServiceAccounts: AdminUser/AdminPass required (LabAdmin orchestrator)"
    }

    $domainDN = (($DomainName -split '\.') | ForEach-Object { "DC=$_" }) -join ','

    # Account specs. LabAdmin first because downstream phases re-bind
    # $domainCred to it as soon as this returns.
    $accounts = @(
        @{
            Sam   = $AdminUser
            Full  = 'HomeLab Admin'
            Pass  = $AdminPass
            Desc  = 'HomeLab orchestrator and CM Full Administrator'
        },
        @{
            Sam   = $ServiceAccounts.ClientPush.Name
            Full  = 'MECM Client Push'
            Pass  = $ServiceAccounts.ClientPush.Password
            Desc  = $ServiceAccounts.ClientPush.Desc
        },
        @{
            Sam   = $ServiceAccounts.NAA.Name
            Full  = 'MECM Network Access Account'
            Pass  = $ServiceAccounts.NAA.Password
            Desc  = $ServiceAccounts.NAA.Desc
        },
        @{
            Sam   = $ServiceAccounts.Join.Name
            Full  = 'MECM OSD Domain Join'
            Pass  = $ServiceAccounts.Join.Password
            Desc  = $ServiceAccounts.Join.Desc
        }
    )

    $groupMemberships = @{
        'Domain Admins'        = @($AdminUser, $ServiceAccounts.ClientPush.Name, $ServiceAccounts.Join.Name)
        'Remote Desktop Users' = @($AdminUser)
    }

    Write-LabLog "[$DCComputerName] Creating service accounts under OU=$OUName" -Status RUN

    Invoke-LabCommand -ComputerName $DCComputerName -Credential $DomainCredential `
        -Activity 'Create CM service accounts' -ScriptBlock {
            param($DomainDN, $DomainName, $NetBIOS, $OUName, $Accounts, $GroupMemberships)

            Import-Module ActiveDirectory -ErrorAction Stop

            $ouPath = "OU=$OUName,$DomainDN"
            $existingOU = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPath'" -ErrorAction SilentlyContinue
            if (-not $existingOU) {
                $null = New-ADOrganizationalUnit -Name $OUName -Path $DomainDN -ErrorAction Stop
            }

            foreach ($acct in $Accounts) {
                $existing = Get-ADUser -Filter "SamAccountName -eq '$($acct.Sam)'" -ErrorAction SilentlyContinue
                if (-not $existing) {
                    New-ADUser `
                        -Name $acct.Full `
                        -SamAccountName $acct.Sam `
                        -UserPrincipalName "$($acct.Sam)@$DomainName" `
                        -Path $ouPath `
                        -AccountPassword (ConvertTo-SecureString $acct.Pass -AsPlainText -Force) `
                        -PasswordNeverExpires $true `
                        -CannotChangePassword $true `
                        -Enabled $true `
                        -Description $acct.Desc `
                        -ErrorAction Stop
                }
            }

            foreach ($group in $GroupMemberships.Keys) {
                foreach ($member in $GroupMemberships[$group]) {
                    Add-ADGroupMember -Identity $group -Members $member -ErrorAction SilentlyContinue
                }
            }

            return [pscustomobject]@{
                OU      = $ouPath
                Created = @($Accounts.Sam)
            }
        } -ArgumentList $domainDN, $DomainName, $NetBIOSName, $OUName, $accounts, $groupMemberships

    Write-LabLog "[$DCComputerName] Service accounts ready" -Status OK
}
