function Set-LabSqlFirewall {
    <#
    .SYNOPSIS
        Open the local Windows Firewall ports SQL Server needs (1433 TCP,
        1434 UDP).

    .DESCRIPTION
        Idempotent New-NetFirewallRule wrappers. The lab is internal-
        only so a coarse Allow on these ports is fine; production would
        scope by source address.

          - SQL Database Engine: TCP 1433, inbound, Domain + Private profiles
          - SQL Browser:         UDP 1434, inbound, Domain + Private profiles

        Rules are named 'HomeLab-SQL-Engine-1433' and
        'HomeLab-SQL-Browser-1434' so they are easy to find / remove.

    .PARAMETER ComputerName
        DNS / short name of the SQL host.

    .PARAMETER DomainCredential
        Domain admin credential. Local admin via group membership is
        sufficient for New-NetFirewallRule.

    .EXAMPLE
        Set-LabSqlFirewall -ComputerName CM01 -DomainCredential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential
    )

    Write-LabLog "[$ComputerName] Opening firewall for SQL (1433/TCP, 1434/UDP)" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Set SQL firewall rules' -ScriptBlock {
            $rules = @(
                @{ Name = 'HomeLab-SQL-Engine-1433';  DisplayName = 'HomeLab SQL Database Engine 1433/TCP'; Protocol = 'TCP'; Port = 1433 }
                @{ Name = 'HomeLab-SQL-Browser-1434'; DisplayName = 'HomeLab SQL Browser 1434/UDP';         Protocol = 'UDP'; Port = 1434 }
            )

            $created = @()
            $skipped = @()
            foreach ($r in $rules) {
                $existing = Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
                if ($existing) {
                    $skipped += $r.Name
                    continue
                }
                $null = New-NetFirewallRule `
                    -Name $r.Name `
                    -DisplayName $r.DisplayName `
                    -Direction Inbound `
                    -Action Allow `
                    -Protocol $r.Protocol `
                    -LocalPort $r.Port `
                    -Profile Domain,Private `
                    -ErrorAction Stop
                $created += $r.Name
            }

            [pscustomobject]@{ Created = $created; Skipped = $skipped }
        }

    Write-LabLog "[$ComputerName] SQL firewall: created=$($result.Created.Count) skipped=$($result.Skipped.Count)" -Status OK
    return $result
}
