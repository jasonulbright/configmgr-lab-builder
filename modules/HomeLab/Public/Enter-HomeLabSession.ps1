function Enter-HomeLabSession {
    <#
    .SYNOPSIS
        Enter an interactive PowerShell remoting session into a lab VM.
        Drop-in for AL's Enter-LabPSSession.

    .DESCRIPTION
        Resolves a credential via Get-LabCredential (default Identity =
        Admin) and enters a session against the target VM. Reuses the
        pooled session via Get-LabSession so you don't pay the
        connect cost twice when you alternate between Invoke-LabCommand
        and Enter-HomeLabSession in one shell.

    .PARAMETER ComputerName
        DNS / short name of the target VM.

    .PARAMETER Identity
        Credential identity to authenticate as. Default 'Admin'.
        Other valid: 'ClientPush', 'NAA', 'Join'.

    .PARAMETER Config
        Pre-loaded config hashtable (from Get-LabConfig). Optional;
        Get-LabCredential calls Get-LabConfig itself if omitted.

    .EXAMPLE
        Enter-HomeLabSession CM01.contoso.com
        Enter-HomeLabSession DC01.contoso.com -Identity Join
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [ValidateSet('Admin','ClientPush','NAA','Join')]
        [string]$Identity = 'Admin',

        [Parameter()]
        [hashtable]$Config,

        [Parameter()]
        [securestring]$LabPassword
    )

    $credParams = @{ Identity = $Identity }
    if ($Config) { $credParams.Config = $Config }
    if ($LabPassword) { $credParams.LabPassword = $LabPassword }
    $cred = Get-LabCredential @credParams

    $session = Get-LabSession -ComputerName $ComputerName -Credential $cred
    Enter-PSSession -Session $session
}
