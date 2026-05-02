function Resolve-LabVM {
    <#
    .SYNOPSIS
        Return the single VM hashtable that carries the requested role.

    .DESCRIPTION
        Thin wrapper around the RoleIndex for orchestrator code that
        wants exactly one VM. Throws when no VM carries the role (the
        common "I need THE DC" / "I need THE site server" contract);
        for surveying use Get-LabVMByRole directly, which returns an
        empty array for unassigned-but-valid roles.

        When multiple VMs carry the same role (e.g., several
        DistributionPoint VMs in a multi-DP topology) -Index selects
        which one; default 0 returns the first.

    .PARAMETER Config
        The hashtable returned by Get-LabConfig.

    .PARAMETER Role
        One of the catalog roles: DomainController, CertificateAuthority,
        SqlServer, SiteServer, ManagementPoint, DistributionPoint,
        SoftwareUpdatePoint, Client.

    .PARAMETER Index
        Zero-based index when multiple VMs carry the role. Defaults to 0.

    .EXAMPLE
        $cfg = Get-LabConfig
        $dc  = Resolve-LabVM -Config $cfg -Role DomainController
        $dc.Name   # DC01
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [hashtable]$Config,

        [Parameter(Mandatory, Position = 1)]
        [string]$Role,

        [Parameter()]
        [int]$Index = 0
    )

    # Walk RoleIndex directly. We deliberately don't go through
    # Get-LabVMByRole here because PS pipeline single-element unwrap
    # makes piping a single hashtable through a function and back
    # awkward; reading RoleIndex directly keeps the data path simple.
    if (-not $Config.ContainsKey('RoleIndex')) {
        throw "Resolve-LabVM: Config does not have a RoleIndex; was it loaded via Get-LabConfig?"
    }
    if (-not $Config.RoleIndex.ContainsKey($Role)) {
        $valid = ($Config.RoleIndex.Keys | Sort-Object) -join ', '
        throw "Resolve-LabVM: unknown role '$Role'. Valid roles: $valid"
    }

    $vms = $Config.RoleIndex[$Role]
    $count = if ($null -eq $vms) { 0 } else { @($vms).Count }

    if ($count -eq 0) {
        throw "Resolve-LabVM: no VM carries role '$Role'"
    }
    if ($Index -lt 0 -or $Index -ge $count) {
        throw "Resolve-LabVM: requested index $Index for role '$Role' but only $count VM(s) carry it"
    }

    return @($vms)[$Index]
}
