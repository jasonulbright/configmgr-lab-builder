function Copy-LabFile {
    <#
    .SYNOPSIS
        Copy a file or folder into a lab VM via the cached PSSession.

    .DESCRIPTION
        Wraps Copy-Item -ToSession. Cross-workgroup SMB admin shares
        (\\CM01\c$, \\CLIENT01\c$) do NOT work in this lab (the dev
        workstation is not domain-joined and there is no shared trust),
        so PSSession copy is the only reliable channel.

        Uses Get-LabSession so the auth round-trip is paid once per
        (VM, identity) pair across the whole deploy.

        On the receiving side, the destination path is created if missing.
        Existing files at Destination are overwritten.

    .PARAMETER ComputerName
        Target VM (e.g. CM01.contoso.com).

    .PARAMETER Credential
        Credential to authenticate with.

    .PARAMETER Path
        Local path to a file or folder on the host.

    .PARAMETER Destination
        Path on the remote VM. Folder is created if it does not exist.

    .PARAMETER Recurse
        For folder copy, copy contents recursively.

    .PARAMETER Activity
        Optional Write-LabLog label.

    .EXAMPLE
        Copy-LabFile -ComputerName CM01.contoso.com -Credential $cred `
                     -Path C:\Install\CM -Destination C:\Install\CM -Recurse `
                     -Activity 'Push CM source'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [Parameter()]
        [switch]$Recurse,

        [Parameter()]
        [string]$Activity
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Copy-LabFile: source path not found: $Path"
    }

    $session = Get-LabSession -ComputerName $ComputerName -Credential $Credential

    # Pre-create the destination folder. Copy-Item -ToSession will fail if
    # the parent does not exist on the remote.
    $remoteDestParent = if ((Get-Item $Path).PSIsContainer) {
        $Destination
    } else {
        Split-Path -Path $Destination -Parent
    }

    Invoke-Command -Session $session -ScriptBlock {
        param($p)
        if (-not (Test-Path -Path $p -PathType Container)) {
            $null = New-Item -Path $p -ItemType Directory -Force
        }
    } -ArgumentList $remoteDestParent -ErrorAction Stop

    if ($Activity) {
        Write-LabLog "[$ComputerName] $Activity ($Path -> $Destination)" -Status RUN
    }

    $copyParams = @{
        Path        = $Path
        Destination = $Destination
        ToSession   = $session
        Force       = $true
        ErrorAction = 'Stop'
    }
    if ($Recurse) { $copyParams.Recurse = $true }

    Copy-Item @copyParams

    if ($Activity) {
        Write-LabLog "[$ComputerName] $Activity done" -Status OK
    }
}
