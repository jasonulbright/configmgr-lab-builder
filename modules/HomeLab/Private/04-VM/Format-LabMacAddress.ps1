function Format-LabMacAddress {
    <#
    .SYNOPSIS
        Normalize a MAC string into the requested separator format.

    .DESCRIPTION
        Hyper-V's Set-VMNetworkAdapter -StaticMacAddress wants a 12-hex
        string with NO separators (00155D505020). Unattend.xml NIC
        Identifier wants hyphenated hex (00-15-5D-50-50-20). Display
        (Get-VMNetworkAdapter) returns dashes by default.

        This helper accepts any of those forms and emits the format the
        caller asks for. Throws on input that is not 12 hex digits after
        separator stripping.

    .PARAMETER Mac
        Input MAC. Allowed separators: '-', ':', '.', or none.

    .PARAMETER Format
        Output style: 'Plain' (12 hex, no separators), 'Dash'
        (XX-XX-XX-XX-XX-XX), 'Colon' (XX:XX:XX:XX:XX:XX). Default Dash.

    .EXAMPLE
        Format-LabMacAddress '00155d505020' -Format Dash   # 00-15-5D-50-50-20
        Format-LabMacAddress '00-15-5D-50-50-20' -Format Plain  # 00155D505020
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Mac,

        [Parameter()]
        [ValidateSet('Plain','Dash','Colon')]
        [string]$Format = 'Dash'
    )

    $stripped = ($Mac -replace '[-:.\s]', '').ToUpperInvariant()
    if ($stripped.Length -ne 12 -or $stripped -notmatch '^[0-9A-F]{12}$') {
        throw "Format-LabMacAddress: '$Mac' is not a valid 12-hex MAC address"
    }

    switch ($Format) {
        'Plain' { return $stripped }
        'Dash'  { return ($stripped -replace '(.{2})(?=.)', '$1-') }
        'Colon' { return ($stripped -replace '(.{2})(?=.)', '$1:') }
    }
}
