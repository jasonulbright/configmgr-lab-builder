function Test-LabIsElevated {
    <#
    .SYNOPSIS
        Return $true if the current process is running with the
        Administrator role token.

    .DESCRIPTION
        Wraps the standard WindowsPrincipal.IsInRole check. Centralised
        so engine code can avoid duplicating the same boilerplate, and
        so Pester tests can mock a single function instead of trying to
        reach into [System.Security.Principal] static calls.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}
