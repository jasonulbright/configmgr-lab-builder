function Connect-HomeLabVM {
    <#
    .SYNOPSIS
        Open a Hyper-V Virtual Machine Connection (vmconnect) window
        to a lab VM. Drop-in replacement for AL's Connect-LabVM.

    .DESCRIPTION
        Wraps vmconnect.exe (the GUI console). Useful when you want
        to see the desktop / OOBE state of a VM that isn't yet
        WinRM-reachable.

        Resolves the Hyper-V host: defaults to the local box (the
        engine's whole point is host-and-lab on the same machine);
        override with -HyperVHost to connect to a remote Hyper-V
        host's VM.

    .PARAMETER ComputerName
        Hyper-V VM name (e.g. CM01).

    .PARAMETER HyperVHost
        Hyper-V host computer name. Default 'localhost'.

    .EXAMPLE
        Connect-HomeLabVM CM01
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [string]$HyperVHost = 'localhost'
    )

    $exe = Join-Path $env:SystemRoot 'System32\vmconnect.exe'
    if (-not (Test-Path $exe)) {
        throw "Connect-HomeLabVM: vmconnect.exe not found at $exe (Hyper-V management tools missing)"
    }

    Start-Process -FilePath $exe -ArgumentList @($HyperVHost, $ComputerName)
    Write-LabLog "Opened vmconnect to $HyperVHost / $ComputerName" -Status OK
}
