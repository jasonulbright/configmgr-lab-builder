function Wait-LabVM {
    <#
    .SYNOPSIS
        Block until a freshly-booted lab VM is reachable, WinRM-ready, and
        actually executes a remote round-trip.

    .DESCRIPTION
        Three gates, in order. Each is treated as transient until the
        Wait-LabReady timeout:

          1. TCP/5985 reachable (Test-NetConnection). Cheapest signal.
          2. Test-WSMan with the supplied credential succeeds (the WinRM
             service has bound a listener and is accepting auth).
          3. A real Invoke-Command round-trip returns 2 from { 1 + 1 }
             (the OS has reached a state where remote PowerShell actually
             executes).

        Returns $true on full success, $false on timeout (with -WarningAction
        Continue messaging via Wait-LabReady). Throws on -ThrowOnTimeout.

    .PARAMETER ComputerName
        DNS name of the target VM.

    .PARAMETER Credential
        Credential for Test-WSMan + the Invoke-Command round-trip.

    .PARAMETER TimeoutSeconds
        Hard ceiling. Default 600 (10 minutes; first boot of a sysprepped
        Windows on a hot host is 4-7 min).

    .PARAMETER IntervalSeconds
        Poll interval between predicate evaluations. Default 5.

    .PARAMETER ThrowOnTimeout
        Throw a TimeoutException on timeout instead of returning $false.

    .EXAMPLE
        $cred = Get-LabCredential -Identity Admin
        Wait-LabVM -ComputerName CLIENT01.contoso.com -Credential $cred -ThrowOnTimeout
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [int]$TimeoutSeconds = 600,

        [Parameter()]
        [int]$IntervalSeconds = 5,

        [Parameter()]
        [switch]$ThrowOnTimeout
    )

    # NOTE: Do NOT use .GetNewClosure() to capture $ComputerName/$Credential.
    # GetNewClosure rebinds SessionState to the caller's global scope and breaks
    # helper resolution (see Install-LabDC.ps1 for the full incident write-up).
    # Pass values via -ArgumentList instead.
    $predicate = {
        param($cn, $cred)
        $tnc = Test-NetConnection -ComputerName $cn -Port 5985 -WarningAction SilentlyContinue -InformationLevel Quiet
        if (-not $tnc) { return $false }

        try {
            $null = Test-WSMan -ComputerName $cn -Credential $cred -Authentication Negotiate -ErrorAction Stop
        } catch {
            return $false
        }

        try {
            $sum = Invoke-Command -ComputerName $cn -Credential $cred `
                -ScriptBlock { 1 + 1 } -ErrorAction Stop
            return ($sum -eq 2)
        } catch {
            return $false
        }
    }

    $params = @{
        Predicate       = $predicate
        ArgumentList    = @($ComputerName, $Credential)
        TimeoutSeconds  = $TimeoutSeconds
        IntervalSeconds = $IntervalSeconds
        Activity        = "VM $ComputerName WinRM ready"
    }
    if ($ThrowOnTimeout) { $params.ThrowOnTimeout = $true }

    return (Wait-LabReady @params)
}
