function Test-CMAdminServiceTrust {
    <#
    .SYNOPSIS
        Check from a domain member that the administration service
        certificate is trusted, with no per-machine certificate import.

    .DESCRIPTION
        Runs on the member VM (for example CLIENT01). Opens a TLS
        connection to https://<SMS Provider FQDN>:443 and validates the
        chain with the member's own trusted root store. No HTTP request is
        sent, so no authentication is needed. Returns Trusted ($true or
        $false), the presented Subject and Issuer, and the error text when
        the handshake fails.

        CMPivot, the console and Invoke-RestMethod against
        https://<provider>/AdminService/wmi/SMS_Site use the same trust
        decision.

    .PARAMETER ComputerName
        The member VM that runs the check.

    .PARAMETER DomainCredential
        Domain admin credential for the WinRM session.

    .PARAMETER ProviderFqdn
        FQDN of the SMS Provider, for example CM01.contoso.com.

    .EXAMPLE
        Test-CMAdminServiceTrust -ComputerName CLIENT01 -DomainCredential $cred -ProviderFqdn CM01.contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProviderFqdn
    )

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Test administration service trust' -ScriptBlock {
            param($ProviderFqdn)
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $tcp.Connect($ProviderFqdn, 443)
                $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false)
                $ssl.AuthenticateAsClient($ProviderFqdn)
                $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
                [pscustomobject]@{ Trusted = $true; Subject = $c.Subject; Issuer = $c.Issuer; Error = $null }
            } catch {
                [pscustomobject]@{ Trusted = $false; Subject = $null; Issuer = $null; Error = $_.Exception.Message }
            } finally {
                $tcp.Close()
            }
        } -ArgumentList $ProviderFqdn

    return $result
}
