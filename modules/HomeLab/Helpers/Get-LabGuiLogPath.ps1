function Get-LabGuiLogPath {
    <#
    .SYNOPSIS
        Resolve the GUI's log directory for the current checkout.

    .DESCRIPTION
        The GUI writes its logs to <repo>\gui\Logs (see
        start-homelab-gui.ps1, which sets $script:LogDir the same way).
        Write-LabDeploySummary lists that directory in its Paths block,
        but only when the GUI has actually run -- a cmdlet-only user has
        no gui\Logs and should not be pointed at a directory that does
        not exist.

        The path is derived from this file's own location rather than
        hardcoded. Before 1.4.0 it was the literal
        'C:\projects\mecm-homelab\gui\Logs', which silently resolved to
        nothing for every clone that did not sit at that exact path --
        the Test-Path guard meant the line just never rendered, with no
        error to explain why.

    .PARAMETER ModuleRoot
        Override for the modules\HomeLab directory. Defaults to the
        parent of this file's directory. Tests use it to point at a
        synthetic tree; production never passes it.

    .OUTPUTS
        [string] full path to <repo>\gui\Logs when it exists, otherwise
        $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$ModuleRoot = (Split-Path -Parent $PSScriptRoot)
    )

    # <repo>\modules\HomeLab -> <repo>
    $repoRoot = Split-Path -Parent (Split-Path -Parent $ModuleRoot)
    if (-not $repoRoot) { return $null }

    $guiLogDir = Join-Path $repoRoot 'gui\Logs'
    if (Test-Path -LiteralPath $guiLogDir -PathType Container) {
        return $guiLogDir
    }

    return $null
}
