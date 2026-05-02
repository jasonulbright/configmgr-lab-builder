function Install-LabMsOleDb {
    <#
    .SYNOPSIS
        Install Microsoft OLE DB Driver for SQL Server (MSOLEDB) inside
        a lab VM. Fail-soft.

    .DESCRIPTION
        CM 2509 has a baseline MSOLEDB shim and works without a
        separate driver install, so this step is fail-soft: a non-zero
        exit code is logged WARN and the function returns without
        throwing. Useful when the source download is flaky.

        Caller decides whether to escalate. The earlier approach made
        MSOLEDB optional for the same reason; we replicate.

    .PARAMETER ComputerName
        Target VM.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER MsiPath
        Path on the HOST to msoledbsql.msi.

    .EXAMPLE
        Install-LabMsOleDb -ComputerName CM01 -DomainCredential $cred `
            -MsiPath C:\LabSources\SoftwarePackages\msoledbsql.msi
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MsiPath
    )

    if (-not (Test-Path -Path $MsiPath -PathType Leaf)) {
        Write-LabLog "Install-LabMsOleDb: MSI not found at $MsiPath; skipping (fail-soft)" -Status WARN
        return [pscustomobject]@{ ExitCode = $null; Skipped = $true; Reason = 'SourceNotFound' }
    }

    $remoteDir = 'C:\Install\MSOLEDB'
    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
        param($d)
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    } -ArgumentList $remoteDir | Out-Null

    $remoteMsi = Join-Path $remoteDir (Split-Path $MsiPath -Leaf)
    try {
        Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                     -Path $MsiPath -Destination $remoteMsi `
                     -Activity 'Push MSOLEDB MSI'
    } catch {
        Write-LabLog "Install-LabMsOleDb: file copy failed: $($_.Exception.Message); skipping" -Status WARN
        return [pscustomobject]@{ ExitCode = $null; Skipped = $true; Reason = 'CopyFailed' }
    }

    Write-LabLog "[$ComputerName] Installing MSOLEDB" -Status RUN
    try {
        $exit = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
            -ScriptBlock {
                param($msi)
                $p = Start-Process -FilePath msiexec.exe -ArgumentList @(
                    '/i', "`"$msi`"",
                    '/quiet', '/norestart',
                    'IACCEPTMSOLEDBSQLLICENSETERMS=YES'
                ) -Wait -PassThru -NoNewWindow
                return $p.ExitCode
            } -ArgumentList $remoteMsi
    } catch {
        Write-LabLog "Install-LabMsOleDb: invoke failed: $($_.Exception.Message); CM has baseline, skipping" -Status WARN
        return [pscustomobject]@{ ExitCode = $null; Skipped = $true; Reason = 'InvokeFailed' }
    }

    $tag = switch ($exit) { 0 { 'OK' } 3010 { 'WARN' } 1638 { 'WARN' } default { 'WARN' } }
    Write-LabLog "[$ComputerName] MSOLEDB exit $exit" -Status $tag

    return [pscustomobject]@{
        ExitCode       = $exit
        RebootRequired = ($exit -eq 3010)
        AlreadyNewer   = ($exit -eq 1638)
        Skipped        = $false
    }
}
