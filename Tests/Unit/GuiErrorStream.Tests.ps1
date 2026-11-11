#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the deploy error-stream handler in the GUI entry script.
    A handler fault must reach the deploy state. It must not be dropped.
    The function is read from the script with the PowerShell parser, so the
    test does not start the GUI.
#>

BeforeAll {
    $guiScript = Resolve-Path "$PSScriptRoot\..\..\gui\start-homelab-gui.ps1"
    $tokens = $null
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($guiScript.Path, [ref]$tokens, [ref]$errs)
    $fn = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Register-DeployStreamHandlers'
    }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}

Describe 'Register-DeployStreamHandlers error stream' {

    It 'records an error record in the log lines and ErrorMsg' {
        $ps = [powershell]::Create()
        try {
            $state = @{ Lines = [System.Collections.ArrayList]::new(); ErrorMsg = $null; PhaseIndex = 0; Step = '' }
            Register-DeployStreamHandlers -PowerShell $ps -State $state -Phases @('01-Prereq')
            $ps.Streams.Error.Add([System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('unit-test deploy error'), 'UnitTest', 'NotSpecified', $null))

            $state.ErrorMsg | Should -Be 'unit-test deploy error'
            @($state.Lines | Where-Object { $_ -match '\[ERROR\].*unit-test deploy error' }).Count | Should -Be 1
        } finally { $ps.Dispose() }
    }

    It 'reports a handler fault in ErrorMsg instead of hiding it' {
        $ps = [powershell]::Create()
        try {
            # A null Lines list makes the handler fail on the first record.
            $state = @{ Lines = $null; ErrorMsg = $null; PhaseIndex = 0; Step = '' }
            Register-DeployStreamHandlers -PowerShell $ps -State $state -Phases @('01-Prereq')
            $ps.Streams.Error.Add([System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('unit-test deploy error'), 'UnitTest', 'NotSpecified', $null))

            $state.ErrorMsg | Should -Match 'Error stream handler failed'
        } finally { $ps.Dispose() }
    }
}