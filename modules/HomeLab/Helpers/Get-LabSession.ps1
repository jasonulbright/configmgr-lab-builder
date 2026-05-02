function Get-LabSession {
    <#
    .SYNOPSIS
        Return a cached open PSSession to a lab VM, creating one on demand.

    .DESCRIPTION
        Naively, every Invoke-Command pays a New-PSSession + auth round-trip
        cost. With ~80 sequential calls in a single deploy that is ~80
        round-trips of TLS handshake + Kerberos/Negotiate. The engine pools
        sessions in an in-memory hashtable keyed by ComputerName + the
        credential UserName so each VM pays the cost once.

        On each call the cached session is checked for State='Opened' and
        Availability='Available'. Stale or broken sessions are dropped and
        replaced. Pass -Force to bypass the cache and always create new.

        Sessions are disposed via Clear-LabSessionCache or when the host
        process exits.

    .PARAMETER ComputerName
        DNS or short name of the lab VM (e.g. CM01.contoso.com).

    .PARAMETER Credential
        The credential to authenticate with. The cache key includes
        Credential.UserName so different identities (Admin vs CMAdmin)
        get different sessions.

    .PARAMETER Force
        Always create a new session; do not consult the cache. The new
        session still replaces the cached entry for this key.

    .EXAMPLE
        $cred = Get-LabCredential -Identity Admin
        $s = Get-LabSession -ComputerName CM01.contoso.com -Credential $cred
        Invoke-Command -Session $s -ScriptBlock { hostname }
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory, Position = 1)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [switch]$Force
    )

    if (-not $script:LabSessionCache) {
        $script:LabSessionCache = @{}
    }

    $key = '{0}|{1}' -f $ComputerName.ToLowerInvariant(), $Credential.UserName

    if (-not $Force -and $script:LabSessionCache.ContainsKey($key)) {
        $existing = $script:LabSessionCache[$key]
        if ($existing -and $existing.State -eq 'Opened' -and $existing.Availability -eq 'Available') {
            return $existing
        }
        try { Remove-PSSession -Session $existing -ErrorAction SilentlyContinue } catch { }
        $script:LabSessionCache.Remove($key)
    } elseif ($Force -and $script:LabSessionCache.ContainsKey($key)) {
        try { Remove-PSSession -Session $script:LabSessionCache[$key] -ErrorAction SilentlyContinue } catch { }
        $script:LabSessionCache.Remove($key)
    }

    $session = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
    $script:LabSessionCache[$key] = $session
    return $session
}

function Clear-LabSessionCache {
    <#
    .SYNOPSIS
        Dispose every cached lab PSSession.

    .DESCRIPTION
        Call at the end of a deploy or on error to release WinRM resources.
        Safe to call when the cache is empty.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:LabSessionCache) { return }

    foreach ($entry in @($script:LabSessionCache.GetEnumerator())) {
        try {
            Remove-PSSession -Session $entry.Value -ErrorAction SilentlyContinue
        } catch { }
    }
    $script:LabSessionCache.Clear()
}

function Get-LabSessionCacheKey {
    <#
    .SYNOPSIS
        Return the deterministic cache key for a (ComputerName, Credential)
        pair. Exposed for testability; not used at runtime.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )
    return '{0}|{1}' -f $ComputerName.ToLowerInvariant(), $Credential.UserName
}
