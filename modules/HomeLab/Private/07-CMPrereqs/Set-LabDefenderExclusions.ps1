function Set-LabDefenderExclusions {
    <#
    .SYNOPSIS
        Apply the recommended Microsoft Defender exclusions for a CM
        site server / SQL host.

    .DESCRIPTION
        Microsoft publishes a "recommended antivirus exclusions for
        Configuration Manager" list that prevents Defender from
        scanning content distribution shares, package source, the SMS
        provider's working directories, SQL DB / log files, and WSUS
        content. Without these, content distribution and DB ops can
        slow to a crawl during high-IO operations.

        Path list:
          - CM source                  C:\Install\CM
          - CM bin                     C:\Program Files\Microsoft Configuration Manager
          - SMS_DP$ etc                <root>:\SMS_DP$, SMSPKGG$, SMSPKG, SMSPKGSIG, SMSSIG$
          - WSUS content               C:\WSUS
          - SQL data + log dirs        D:\SQLData, E:\SQLLogs (per S4 default)
          - SQL tempdb                 D:\SQLTempDb (per S4 default)
          - Default SQL install        C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER

        Idempotent: Add-MpPreference is additive and silent on already-
        present entries.

    .PARAMETER ComputerName
        Target VM.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER ExtraPaths
        Additional folder paths to exclude.

    .EXAMPLE
        Set-LabDefenderExclusions -ComputerName CM01 -DomainCredential $cred
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
        [string[]]$ExtraPaths
    )

    $defaultPaths = @(
        'C:\Install\CM'
        'C:\Program Files\Microsoft Configuration Manager'
        'C:\WSUS'
        'C:\SMS_DP$'
        'C:\SMSPKGG$'
        'C:\SMSPKG'
        'C:\SMSPKGSIG'
        'C:\SMSSIG$'
        'C:\RemoteInstall'
        'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER'
        'D:\SQLData'
        'E:\SQLLogs'
        'D:\SQLTempDb'
        'D:\SQLBackup'
    )

    $allPaths = @($defaultPaths) + @($ExtraPaths)

    Write-LabLog "[$ComputerName] Applying Defender exclusions ($($allPaths.Count) paths)" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Set Defender exclusions' -ScriptBlock {
            param($Paths)
            try {
                Add-MpPreference -ExclusionPath $Paths -ErrorAction Stop
                return [pscustomobject]@{ Applied = $Paths.Count; Skipped = 0 }
            } catch {
                # On VMs without Defender (Server Core, or Defender disabled),
                # Add-MpPreference throws. Treat as soft skip.
                return [pscustomobject]@{ Applied = 0; Skipped = $Paths.Count; Reason = $_.Exception.Message }
            }
        } -ArgumentList (,$allPaths)

    if ($result.Applied -gt 0) {
        Write-LabLog "[$ComputerName] Defender exclusions applied ($($result.Applied))" -Status OK
    } else {
        Write-LabLog "[$ComputerName] Defender exclusions skipped: $($result.Reason)" -Status WARN
    }

    return $result
}
