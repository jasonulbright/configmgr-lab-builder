function Copy-CMTools {
    <#
    .SYNOPSIS
        Copy CM administration tools (Client Center for ConfigMgr,
        Application Packager) onto the CM site server's C:\Tools.

    .DESCRIPTION
        Ports Deploy-HomeLab.ps1 Phase 7 (lines 988-1028). Two
        independent operations, each fail-soft:

          - Client Center: looks for the latest ClientCenter-*.zip on
            the host (default C:\temp). Pushes + Expand-Archive.
          - ApplicationPackager: looks for the host repo at
            C:\projects\app-packager (or override). Pushes the folder
            tree -> C:\Tools\ApplicationPackager.

        Both are optional. If the host source is absent, that tool is
        skipped with a WARN log line.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER ClientCenterZipPath
        Path on the HOST to a ClientCenter-*.zip. If omitted, the
        latest match in C:\temp is used.

    .PARAMETER AppPackagerSourcePath
        Path on the HOST to the AppPackager folder tree. If omitted,
        C:\projects\app-packager is used.

    .EXAMPLE
        Copy-CMTools -ComputerName CM01 -DomainCredential $cred
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
        [string]$ClientCenterZipPath,

        [Parameter()]
        [string]$AppPackagerSourcePath = 'C:\projects\app-packager'
    )

    # Ensure C:\Tools exists.
    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
        if (-not (Test-Path 'C:\Tools')) { New-Item -Path 'C:\Tools' -ItemType Directory -Force | Out-Null }
    } | Out-Null

    $clientCenter = $null
    $appPackager  = $null

    # 1. Client Center
    if (-not $ClientCenterZipPath) {
        $latest = Get-ChildItem -Path 'C:\temp' -Filter 'ClientCenter-*.zip' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { $ClientCenterZipPath = $latest.FullName }
    }

    if ($ClientCenterZipPath -and (Test-Path -Path $ClientCenterZipPath -PathType Leaf)) {
        $remoteZip = "C:\temp\$([System.IO.Path]::GetFileName($ClientCenterZipPath))"
        Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
            if (-not (Test-Path 'C:\temp')) { New-Item -Path 'C:\temp' -ItemType Directory -Force | Out-Null }
        } | Out-Null

        Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                     -Path $ClientCenterZipPath -Destination $remoteZip `
                     -Activity 'Push Client Center zip'

        Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
            -Activity 'Extract Client Center' -ScriptBlock {
                param($zip)
                Expand-Archive -Path $zip -DestinationPath 'C:\Tools\ClientCenter' -Force
            } -ArgumentList $remoteZip | Out-Null

        $clientCenter = 'C:\Tools\ClientCenter'
        Write-LabLog "[$ComputerName] Client Center deployed -> $clientCenter" -Status OK
    } else {
        Write-LabLog "[$ComputerName] Client Center zip not found; skipping" -Status SKIP
    }

    # 2. ApplicationPackager
    if (Test-Path -Path $AppPackagerSourcePath -PathType Container) {
        Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                     -Path $AppPackagerSourcePath -Destination 'C:\Tools' -Recurse `
                     -Activity 'Push ApplicationPackager'

        # The push produces C:\Tools\<source-folder-name> on the VM. Rename
        # to a canonical 'ApplicationPackager' if needed.
        Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
            param($SourceLeaf)
            $src = Join-Path 'C:\Tools' $SourceLeaf
            $dst = 'C:\Tools\ApplicationPackager'
            if ($SourceLeaf -ne 'ApplicationPackager' -and (Test-Path $src) -and -not (Test-Path $dst)) {
                Rename-Item -Path $src -NewName 'ApplicationPackager'
            }
        } -ArgumentList (Split-Path $AppPackagerSourcePath -Leaf) | Out-Null

        $appPackager = 'C:\Tools\ApplicationPackager'
        Write-LabLog "[$ComputerName] ApplicationPackager deployed -> $appPackager" -Status OK
    } else {
        Write-LabLog "[$ComputerName] ApplicationPackager source not found at $AppPackagerSourcePath; skipping" -Status SKIP
    }

    return [pscustomobject]@{
        ClientCenter   = $clientCenter
        AppPackager    = $appPackager
    }
}
