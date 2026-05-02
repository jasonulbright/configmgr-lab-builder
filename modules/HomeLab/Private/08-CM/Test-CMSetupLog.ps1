function Test-CMSetupLog {
    <#
    .SYNOPSIS
        Stream-parse C:\ConfigMgrSetup.log on a CM site server and return
        the most recent terminal status.

    .DESCRIPTION
        ConfigMgrSetup.log is the single source of truth for "did setup
        actually finish?" -- setup.exe exit code is unreliable because
        the wrapper exits after kicking off the work and the actual
        installer threads continue. The log captures terminal lines we
        match on:

          - 'Configuration Manager Setup has successfully installed
             Configuration Manager'                         -> Success
          - 'Configuration Manager Setup failed'            -> Failure
          - 'An error occurred while installing the database' -> Failure
          - 'Setup was unable to verify Microsoft .NET'     -> Failure

        If none match, status is InProgress (call again later).

        Two PS-5.1 / PS-7 gotchas this function handles:

        1. ConfigMgrSetup.log is UTF-16LE. Get-Content with default
           encoding produces garbage. We open with explicit Unicode
           encoding via System.IO.StreamReader.

        2. Setup keeps the file open for write. Naive read with
           [System.IO.File]::ReadAllText fails with "process cannot
           access the file because it is being used by another process".
           We open via FileStream with FileShare.ReadWrite so we can
           tail-read the file while setup is still writing.

        Returns [pscustomobject]:
          Status       - Success / Failure / InProgress
          MatchLine    - the log line that drove the decision (empty for
                         InProgress)
          ErrorContext - up to 50 lines around the failure for triage

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER LogPath
        Path on the VM. Default 'C:\ConfigMgrSetup.log'.

    .EXAMPLE
        $r = Test-CMSetupLog -ComputerName CM01 -DomainCredential $cred
        switch ($r.Status) {
            'Success'    { Write-Host 'Site installed' }
            'Failure'    { throw $r.ErrorContext }
            'InProgress' { Start-Sleep 60; ... }
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter()]
        [string]$LogPath = 'C:\ConfigMgrSetup.log'
    )

    # Inside-VM: tail-safe read of the UTF-16LE log into a string array,
    # then ship the array back to the host where Resolve-CMSetupLogStatus
    # owns the parsing logic (so the algorithm has one home and is
    # unit-tested directly on synthetic input).
    $remote = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            param($Path)
            if (-not (Test-Path $Path)) {
                return [pscustomobject]@{ Lines = @(); Reason = 'LogNotPresent' }
            }

            $fs = $null
            $sr = $null
            try {
                $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::Unicode)
                $list = New-Object System.Collections.Generic.List[string]
                while (-not $sr.EndOfStream) {
                    $list.Add($sr.ReadLine())
                }
                return [pscustomobject]@{ Lines = $list.ToArray(); Reason = '' }
            } finally {
                if ($sr) { $sr.Dispose() }
                if ($fs) { $fs.Dispose() }
            }
        } -ArgumentList $LogPath

    if ($remote.Reason -eq 'LogNotPresent') {
        return [pscustomobject]@{
            Status       = 'InProgress'
            MatchLine    = ''
            ErrorContext = ''
            LineCount    = 0
            Reason       = 'LogNotPresent'
        }
    }

    return Resolve-CMSetupLogStatus -Lines $remote.Lines
}
