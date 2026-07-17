function Install-LabMsOleDb {
    <#
    .SYNOPSIS
        Install Microsoft OLE DB Driver for SQL Server (MSOLEDB) inside
        a lab VM. Fail-soft.

    .DESCRIPTION
        OPT-IN pre-stage only -- CM setup manages the OLE DB driver
        itself. Verified on the 2026-07-16 E2E: setup treated
        msoledbsql.msi as an external dependency file, validated the
        copy in the CM-PreReqs cache (the site media's own copy failed
        hash verification!), and installed 19.3.5 x64 with exit 0. The
        site DB connection is enforced over ODBC regardless ("Enforce
        using MSODBC for SQL connection" in ConfigMgrSetup.log), which
        is why the ODBC 18.5.2.1 pin is the driver decision that
        actually matters.

        Because CM owns this driver, Install-HomeLab no longer calls
        this function unless -MsOleDbMsiPath is explicitly provided.
        Fail-soft: a non-zero exit code is logged WARN and the function
        returns without throwing.

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
    $detail = switch ($exit) {
        # 1633 = ERROR_INSTALL_PLATFORM_UNSUPPORTED. Seen on the first
        # real-host run 2026-07-16: the staged msoledbsql.msi was the
        # Arm64 build. Name the fix instead of leaving a bare code.
        1633 { ' (MSI platform does not match the VM: you likely downloaded the Arm64 MSOLEDB MSI; stage the x64 build in SoftwarePackages\MSOLEDB)' }
        3010 { ' (installed; reboot requested)' }
        1638 { ' (a newer version is already installed)' }
        default { '' }
    }
    Write-LabLog "[$ComputerName] MSOLEDB exit $exit$detail" -Status $tag

    return [pscustomobject]@{
        ExitCode       = $exit
        RebootRequired = ($exit -eq 3010)
        AlreadyNewer   = ($exit -eq 1638)
        Skipped        = $false
    }
}
