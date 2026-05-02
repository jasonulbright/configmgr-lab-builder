function Set-LabSqlMemory {
    <#
    .SYNOPSIS
        Cap SQL Server's max server memory so it doesn't starve CM's
        SMS_EXECUTIVE / SMS Provider on the same box.

    .DESCRIPTION
        Runs `EXEC sp_configure 'max server memory', <MB>; RECONFIGURE;`
        via sqlcmd inside the VM under integrated auth. The default cap
        of 8192 MB lines up with the 12 GB ceiling on the homelab CM01;
        SQL gets 8 GB, CM keeps a comfortable 3-4 GB.

        Idempotent: queries the current value first; no-op if it
        already matches.

    .PARAMETER ComputerName
        DNS / short name of the SQL host (typically CM01).

    .PARAMETER DomainCredential
        Domain admin credential. Must already be a SQL sysadmin (this
        is one of the pre-CM-install configurations from the kickstart
        SQL pitfall note: CONTOSO\Domain Admins is added to sysadmin
        at install time).

    .PARAMETER MaxMemoryMB
        Cap value in MB. Default 8192.

    .PARAMETER InstanceName
        SQL instance. Default 'MSSQLSERVER'. Used to compute
        '-S <ComputerName>\<InstanceName>' for sqlcmd.

    .EXAMPLE
        Set-LabSqlMemory -ComputerName CM01 -DomainCredential $cred -MaxMemoryMB 8192
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter()]
        [ValidateRange(512, 1048576)]
        [int]$MaxMemoryMB = 8192,

        [Parameter()]
        [string]$InstanceName = 'MSSQLSERVER'
    )

    Write-LabLog "[$ComputerName] Setting SQL max server memory to ${MaxMemoryMB} MB" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Set SQL max server memory' -ScriptBlock {
            param($Cap, $Instance)

            $serverInstance = if ($Instance -eq 'MSSQLSERVER') { '.' } else { ".\$Instance" }
            $connStr = "Server=$serverInstance;Integrated Security=True;TrustServerCertificate=True"
            Add-Type -AssemblyName 'System.Data'

            $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
            $conn.Open()
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'max server memory (MB)';"
                $current = [int]$cmd.ExecuteScalar()
                if ($current -eq $Cap) {
                    return [pscustomobject]@{ Status = 'AlreadySet'; CurrentMB = $current }
                }
                $cmd.CommandText = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max server memory', $Cap; RECONFIGURE;"
                $null = $cmd.ExecuteNonQuery()
                return [pscustomobject]@{ Status = 'Set'; PreviousMB = $current; CurrentMB = $Cap }
            } finally { $conn.Close() }
        } -ArgumentList $MaxMemoryMB, $InstanceName

    Write-LabLog "[$ComputerName] SQL max memory $($result.Status) ($($result.CurrentMB) MB)" -Status OK
    return $result
}
