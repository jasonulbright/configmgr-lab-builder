function Get-LabVMByRole {
    <#
    .SYNOPSIS
        Return all VMs in a loaded HomeLab config that carry the given role.

    .DESCRIPTION
        Reads the RoleIndex that Get-LabConfig attaches to its return
        value. Use this in engine code that needs to walk roles
        independently of which VM hosts them (e.g., apply the SUP role
        config to whichever VM carries 'SoftwareUpdatePoint', whether
        that's CM01 in the default topology or a separate VM in a
        role-per-server template).

        Returns an array (possibly empty for roles no VM carries, e.g.
        no VM has 'CertificateAuthority' in some topologies). Does not
        throw on zero matches; throws only if the role is unknown.

        Callers MUST wrap the call in @(...) to defeat PowerShell's
        single-element pipeline unwrap:

            $vms = @(Get-LabVMByRole -Config $cfg -Role DomainController)

        That is the only contract callers need to honour.

    .PARAMETER Config
        The hashtable returned by Get-LabConfig. Must carry a RoleIndex.

    .PARAMETER Role
        One of: DomainController, CertificateAuthority, SqlServer,
        SiteServer, ManagementPoint, DistributionPoint,
        SoftwareUpdatePoint, Client.

    .EXAMPLE
        $cfg = Get-LabConfig
        $vms = @(Get-LabVMByRole -Config $cfg -Role DomainController)
        $vms[0].Name   # DC01

    .EXAMPLE
        # Apply SUP config wherever it lives.
        foreach ($vm in @(Get-LabVMByRole -Config $cfg -Role SoftwareUpdatePoint)) {
            Install-LabSup -ComputerName $vm.Name ...
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [hashtable]$Config,

        [Parameter(Mandatory, Position = 1)]
        [string]$Role
    )

    if (-not $Config.ContainsKey('RoleIndex')) {
        throw "Get-LabVMByRole: Config does not have a RoleIndex; was it loaded via Get-LabConfig?"
    }
    if (-not $Config.RoleIndex.ContainsKey($Role)) {
        $valid = ($Config.RoleIndex.Keys | Sort-Object) -join ', '
        throw "Get-LabVMByRole: unknown role '$Role'. Valid roles: $valid"
    }

    # Emit each VM as a pipeline element. Caller's @(...) wrapper
    # collects them into an array of the right shape:
    #   0 elements -> @()
    #   1 element  -> @($vm1)
    #   N elements -> @($vm1, ..., $vmN)
    foreach ($vm in $Config.RoleIndex[$Role]) {
        Write-Output $vm
    }
}
