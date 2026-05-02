function Invoke-LabCommand {
    <#
    .SYNOPSIS
        Invoke-Command against a lab VM through the cached session pool,
        returning unwrapped objects.

    .DESCRIPTION
        Wraps Invoke-Command for use in the engine. Behavior:
          - Uses Get-LabSession's pooled PSSession (no per-call WinRM auth)
          - Strips PSComputerName / RunspaceId / PSShowComputerName note
            properties from returned objects so callers do not need to cast
            with [bool]($r | Select-Object -First 1) or unwrap PSObjects
          - Surfaces the remote exit code via $LASTEXITCODE if the remote
            block calls a native exe
          - Always passes Credential through Get-LabSession so identity is
            explicit (the dev workstation is not domain-joined; implicit
            Kerberos always fails, see reference_mecm_homelab_bible.md)

        Exceptions thrown inside the ScriptBlock propagate out as normal
        PowerShell terminating errors. Use try/catch around Invoke-LabCommand
        the same way you would around Invoke-Command.

    .PARAMETER ComputerName
        DNS name of the target VM (e.g. CM01.contoso.com).

    .PARAMETER Credential
        Credential to authenticate with. Required.

    .PARAMETER ScriptBlock
        The script block to run on the remote VM.

    .PARAMETER ArgumentList
        Optional positional arguments forwarded to the script block.

    .PARAMETER Activity
        Optional label for Write-LabLog at start and end. Pass $null to
        suppress logging.

    .PARAMETER Raw
        Skip the noteproperty stripping and return the raw deserialized
        PSObject(s) Invoke-Command produced. Use only when the caller
        actively needs PSComputerName / RunspaceId.

    .EXAMPLE
        $cred = Get-LabCredential -Identity Admin
        $isUp = Invoke-LabCommand -ComputerName CM01.contoso.com -Credential $cred `
            -Activity 'Check SMS_EXECUTIVE' -ScriptBlock {
                (Get-Service SMS_EXECUTIVE -ErrorAction SilentlyContinue).Status -eq 'Running'
            }
        # $isUp is a real [bool], not a PSObject wrapping one
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory, Position = 1)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [object[]]$ArgumentList,

        [Parameter()]
        [string]$Activity,

        [Parameter()]
        [switch]$Raw
    )

    $session = Get-LabSession -ComputerName $ComputerName -Credential $Credential

    if ($Activity) {
        Write-LabLog "[$ComputerName] $Activity" -Status RUN
    }

    $invokeParams = @{
        Session     = $session
        ScriptBlock = $ScriptBlock
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('ArgumentList')) {
        $invokeParams.ArgumentList = $ArgumentList
    }

    try {
        $result = Invoke-Command @invokeParams
    } catch {
        if ($Activity) {
            Write-LabLog "[$ComputerName] $Activity failed: $($_.Exception.Message)" -Status FAIL
        }
        throw
    }

    if ($Activity) {
        Write-LabLog "[$ComputerName] $Activity done" -Status OK
    }

    if ($Raw -or $null -eq $result) {
        return $result
    }

    # Strip the deserialization tax. Invoke-Command -Session adds three note
    # properties to every returned object (string and value-type results too).
    # Stripping them is the difference between `$result -eq $true` working
    # and callers having to write `[bool]($result | Select-Object -First 1)`
    # to unwrap the remoting envelope.
    #
    # Mutate in place rather than `PSObject.Copy()`-then-modify -- Copy()
    # throws on some deserialized AD/CIM types
    # (Deserialized.Microsoft.ActiveDirectory.Management.ADDomain returns
    # "A PSProperty or PSMethod object cannot be added to this collection").
    # The Invoke-Command result is already a fresh deserialization, so the
    # caller never aliases another reference -- mutation is safe.
    $stripProps = @('PSComputerName','RunspaceId','PSShowComputerName')
    $unwrapped = foreach ($item in @($result)) {
        if ($null -eq $item) { $null; continue }

        foreach ($prop in $stripProps) {
            try {
                if ($item.PSObject.Properties[$prop]) {
                    $item.PSObject.Properties.Remove($prop)
                }
            } catch { }
        }
        $item
    }

    if ($unwrapped.Count -eq 1) { return $unwrapped[0] }
    return $unwrapped
}
