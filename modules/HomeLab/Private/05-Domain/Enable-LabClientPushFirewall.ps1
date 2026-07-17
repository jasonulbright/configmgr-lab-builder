function Enable-LabClientPushFirewall {
    <#
    .SYNOPSIS
        Open the inbound firewall paths CM client push needs on a lab
        client VM (SMB/admin$ + RPC/WMI).

    .DESCRIPTION
        Client push connects to \\client\admin$ (SMB, TCP 445) and uses
        RPC/WMI (TCP 135 + DCOM) to start ccmsetup. Windows 11 blocks
        all of that inbound BY DEFAULT -- even on the Domain profile.
        WinRM works out of the box because the WinRM service ships its
        own domain-profile allow rule; File and Printer Sharing has no
        such default. In production a GPO opens this; the lab engine
        has to do it itself.

        Found on the first verified E2E (2026-07-16): the very first
        CCR for CLIENT01 failed "Unable to access target machine ...
        access denied or invalid network path" on a healthy,
        WinRM-reachable client, and ccm.log retried hourly forever.

        Enables the rules in these display groups, restricted to rules
        whose profile includes Domain (or Any):
          - File and Printer Sharing
          - Windows Management Instrumentation (WMI)

        Idempotent: enabling an enabled rule is a no-op.

    .PARAMETER ComputerName
        Target client VM.

    .PARAMETER Credential
        Credential with local admin on the target (domain admin in the
        lab).

    .EXAMPLE
        Enable-LabClientPushFirewall -ComputerName CLIENT01 -Credential $cred
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    Write-LabLog "[$ComputerName] Enabling client-push firewall rules (SMB + RPC/WMI, Domain profile)" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $Credential `
        -Activity 'Enable client push firewall rules' -ScriptBlock {
            $groups = @('File and Printer Sharing', 'Windows Management Instrumentation (WMI)')
            $enabled = 0
            foreach ($g in $groups) {
                # Profile compare via string: the NetSecurity Profile enum
                # does not -band cleanly ("Specified cast is not valid" on
                # live Win11 25H2), and 'Any' is enum value 0. ToString()
                # yields e.g. 'Domain', 'Domain, Private', or 'Any'; keep
                # everything except Public-only rules (the NAT NIC sits on
                # a Public network and stays closed).
                $rules = @(Get-NetFirewallRule -DisplayGroup $g -ErrorAction SilentlyContinue |
                    Where-Object { $_.Direction -eq 'Inbound' -and $_.Profile.ToString() -match 'Domain|Private|Any' })
                foreach ($r in $rules) {
                    Enable-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
                    $enabled++
                }
            }
            [pscustomobject]@{
                Enabled  = $enabled
                Smb445   = [bool](Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -Enabled True -ErrorAction SilentlyContinue)
            }
        }

    Write-LabLog "[$ComputerName] Client-push firewall ready ($($result.Enabled) rules enabled)" -Status OK
    return $result
}
