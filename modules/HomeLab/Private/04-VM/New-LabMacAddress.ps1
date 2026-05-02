function New-LabMacAddress {
    <#
    .SYNOPSIS
        Build a deterministic Hyper-V static MAC from a VM IPv4 address.

    .DESCRIPTION
        Earlier builds used only the last IPv4 octet, which collides when two
        VMs share a host number across different /24s. This helper hashes the
        full IPv4 string into the locally administered Hyper-V prefix used by
        the lab and returns a dashed MAC.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IPAddress
    )

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsed)) {
        throw "New-LabMacAddress: '$IPAddress' is not a valid IP address"
    }

    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Count -ne 4) {
        throw "New-LabMacAddress: '$IPAddress' is not an IPv4 address"
    }

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($IPAddress))
    } finally {
        $md5.Dispose()
    }

    $plain = '00155D{0:X2}{1:X2}{2:X2}' -f $hash[0], $hash[1], $hash[2]
    return (Format-LabMacAddress -Mac $plain -Format Dash)
}
