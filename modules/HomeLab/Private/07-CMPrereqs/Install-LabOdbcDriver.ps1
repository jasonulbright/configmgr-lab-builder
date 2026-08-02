function Install-LabOdbcDriver {
    <#
    .SYNOPSIS
        Install Microsoft ODBC Driver 18 for SQL Server inside a lab VM.

    .DESCRIPTION
        ###############################################################
        # DO NOT "UPGRADE" THE ODBC DRIVER. READ THIS FIRST.
        #
        # CM 2509 is BROKEN with ODBC 18.6.x (NULL-handling regression
        # in the SQL provider that breaks CM site DB writes during
        # Install-CMSite and at runtime). The known-good build is
        # 18.5.2.1 and ONLY 18.5.2.1.
        #
        # Symptoms when 18.6.x is installed:
        #   - CM site install hangs at "Configuring database upgrade"
        #   - ConfigMgrSetup.log shows NULL-related ODBC errors
        #   - SMS_EXECUTIVE crashes intermittently after install
        #
        # Source pinned in config.psd1 (do not change):
        #   https://go.microsoft.com/fwlink/?linkid=2335671  (18.5.2.1)
        #
        # If a future Microsoft release fixes the regression, the
        # validation step belongs in `docs/pitfalls/odbc-18.6-regression.md`
        # FIRST, then we re-pin. Until then the MSI ships in
        # $LabSourcesRoot\SoftwarePackages\msodbcsql.msi must be 18.5.2.1.
        ###############################################################

        MSI args: /quiet /norestart IACCEPTMSODBCSQLLICENSETERMS=YES.
        Exit 0 = installed, 1638 = newer-already-present (treat as
        WARN, NOT skip -- "newer" is the regression we're avoiding;
        the operator must downgrade manually).

        The lab-known-good is 18.5.2.1; if a newer driver is
        already present we WARN but do not throw -- caller can choose
        to fail-hard via a -StrictVersion switch (not yet implemented;
        add only if a real regression motivates it).

    .PARAMETER ComputerName
        DNS / short name of the target VM.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER MsiPath
        Path on the HOST to msodbcsql.msi (the 18.5.2.1 build).

    .EXAMPLE
        Install-LabOdbcDriver -ComputerName CM01 -DomainCredential $cred `
            -MsiPath C:\LabSources\SoftwarePackages\msodbcsql_18.5.2.1.msi
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
        throw "Install-LabOdbcDriver: MSI not found: $MsiPath"
    }

    $remoteDir = 'C:\Install\ODBC'
    Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential -ScriptBlock {
        param($d)
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    } -ArgumentList $remoteDir | Out-Null

    $remoteMsi = Join-Path $remoteDir (Split-Path $MsiPath -Leaf)
    Copy-LabFile -ComputerName $ComputerName -Credential $DomainCredential `
                 -Path $MsiPath -Destination $remoteMsi `
                 -Activity 'Push ODBC 18 MSI'

    # NOTE: pinned 18.5.2.1; 18.6.x is broken for ConfigMgr 2509 (NULL-handling
    # regression in SQL provider). Do NOT swap the MSI to a newer build
    # without re-validating end-to-end CM install. See header.
    Write-LabLog "[$ComputerName] Installing ODBC Driver 18 (pinned 18.5.2.1; 18.6.x BROKEN for CM 2509)" -Status RUN
    $exit = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            param($msi)
            $p = Start-Process -FilePath msiexec.exe -ArgumentList @(
                '/i', "`"$msi`"",
                '/quiet', '/norestart',
                'IACCEPTMSODBCSQLLICENSETERMS=YES'
            ) -Wait -PassThru -NoNewWindow
            return $p.ExitCode
        } -ArgumentList $remoteMsi

    $tag = switch ($exit) { 0 { 'OK' } 3010 { 'WARN' } 1638 { 'WARN' } default { 'FAIL' } }
    Write-LabLog "[$ComputerName] ODBC 18 exit $exit" -Status $tag

    if ($exit -notin 0, 1638, 3010) {
        throw "Install-LabOdbcDriver: msiexec returned $exit on $ComputerName"
    }

    return [pscustomobject]@{
        ExitCode       = $exit
        RebootRequired = ($exit -eq 3010)
        AlreadyNewer   = ($exit -eq 1638)
    }
}
