function Get-LabCredential {
    <#
    .SYNOPSIS
        Build a PSCredential for a HomeLab account.

    .DESCRIPTION
        Pluggable credential resolver. Reads from a HomeLab config
        hashtable; a vault provider can be added behind the same
        cmdlet surface without changing callers.

        The Identity parameter selects which credential to return:
          'Admin'      - Lab orchestrator/admin (config.AdminUser/AdminPass).
                         Default 'LabAdmin'. Runs CM setup, becomes
                         CM Full Administrator automatically at install time.
          'ClientPush' - svc-CMPush (config.ServiceAccounts.ClientPush)
          'NAA'        - svc-CMNAA  (config.ServiceAccounts.NAA)
          'Join'       - svc-CMJoin (config.ServiceAccounts.Join)
                         OSD task-sequence domain-join account.

        Returns a PSCredential with username in NETBIOS\sAMAccountName form.

    .PARAMETER Identity
        Account identity to resolve.

    .PARAMETER Config
        Optional pre-loaded config hashtable (from Get-LabConfig). If omitted,
        Get-LabConfig is called with default Path.

    .EXAMPLE
        $cred = Get-LabCredential -Identity Admin
        Invoke-Command -ComputerName CM01.contoso.com -Credential $cred ...
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('Admin','ClientPush','NAA','Join')]
        [string]$Identity,

        [Parameter()]
        [hashtable]$Config,

        # Optional override for the lab password. Templates ship without
        # plaintext passwords; Install-HomeLab injects via $cfg.AdminPass
        # in-memory but standalone callers (Test-HomeLab, Start-HomeLab,
        # Enter-HomeLabSession) load a fresh config and find no password.
        # Pass -LabPassword to override, or set $env:HOMELAB_PASSWORD to
        # supply non-interactively. Falls back to Read-Host when the
        # console is interactive.
        [Parameter()]
        [securestring]$LabPassword
    )

    if (-not $Config) {
        $Config = Get-LabConfig
    }

    $netbios = $Config['NetBIOS']
    if (-not $netbios) {
        # Defensive: if a caller passed a hashtable that did not flow through
        # Get-LabConfig, derive NetBIOS on the fly.
        $netbios = ($Config.DomainName -split '\.')[0].ToUpper()
    }

    # Pick the username + identity-specific password slot first.
    switch ($Identity) {
        'Admin'      { $user = $Config.AdminUser;                      $pass = $Config.AdminPass }
        'ClientPush' { $user = $Config.ServiceAccounts.ClientPush.Name; $pass = $Config.ServiceAccounts.ClientPush.Password }
        'NAA'        { $user = $Config.ServiceAccounts.NAA.Name;        $pass = $Config.ServiceAccounts.NAA.Password }
        'Join'       { $user = $Config.ServiceAccounts.Join.Name;       $pass = $Config.ServiceAccounts.Join.Password }
    }

    # Precedence:
    #   1. Explicit -LabPassword always wins (lab-wide override). When
    #      this fires we ALSO write back to AdminPass + mirror into any
    #      empty service-account slots so subsequent calls see it.
    #   2. The requested identity's own Password if already populated
    #      (honors per-account passwords without a lab-wide prompt).
    #   3. Lab-wide fallback chain ($env:HOMELAB_PASSWORD ->
    #      $script:LabPasswordCache -> Read-Host) when neither of the
    #      above had a value. Result is mirrored into AdminPass and
    #      empty service-account slots.
    if ($LabPassword) {
        $plain = [System.Net.NetworkCredential]::new('', $LabPassword).Password
        $Config.AdminPass = $plain
        $script:LabPasswordCache = $plain
        foreach ($svc in 'ClientPush','NAA','Join') {
            if ($Config.ServiceAccounts -and $Config.ServiceAccounts[$svc] -and -not $Config.ServiceAccounts[$svc].Password) {
                $Config.ServiceAccounts[$svc].Password = $plain
            }
        }
        $pass = $plain
    } elseif (-not [string]::IsNullOrEmpty([string]$pass)) {
        # Identity already had a password; nothing to resolve.
    } else {
        # Lab-wide resolver fallback. Order:
        #   $Config.AdminPass (in-memory, e.g. injected by Install-HomeLab)
        #   $env:HOMELAB_PASSWORD
        #   $script:LabPasswordCache
        #   Read-Host
        $plain = $null
        if (-not [string]::IsNullOrEmpty([string]$Config.AdminPass)) {
            $plain = [string]$Config.AdminPass
        } elseif ($env:HOMELAB_PASSWORD) {
            $plain = $env:HOMELAB_PASSWORD
        } elseif ($script:LabPasswordCache) {
            $plain = $script:LabPasswordCache
        } elseif ($Host.UI.RawUI -and -not [Console]::IsInputRedirected) {
            $sec = Read-Host -Prompt 'Lab password (one password covers all 4 accounts)' -AsSecureString
            $plain = [System.Net.NetworkCredential]::new('', $sec).Password
        } else {
            throw "Get-LabCredential: '$Identity' has no Password and no lab-wide password available (-LabPassword, `$cfg.AdminPass, `$env:HOMELAB_PASSWORD all empty; non-interactive session)"
        }
        if (-not $Config.AdminPass) { $Config.AdminPass = $plain }
        $script:LabPasswordCache = $plain
        foreach ($svc in 'ClientPush','NAA','Join') {
            if ($Config.ServiceAccounts -and $Config.ServiceAccounts[$svc] -and -not $Config.ServiceAccounts[$svc].Password) {
                $Config.ServiceAccounts[$svc].Password = $plain
            }
        }
        $pass = $plain
    }

    if ([string]::IsNullOrEmpty($user) -or [string]::IsNullOrEmpty($pass)) {
        throw "Get-LabCredential: '$Identity' resolved to empty username or password"
    }

    $sec = ConvertTo-SecureString -String $pass -AsPlainText -Force
    $fullName = "$netbios\$user"
    return New-Object System.Management.Automation.PSCredential($fullName, $sec)
}
