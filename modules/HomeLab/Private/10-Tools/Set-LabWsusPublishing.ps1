function Set-LabWsusPublishing {
    <#
    .SYNOPSIS
        Prepare the lab for publishing local or third-party updates to
        WSUS: a signing certificate and the trust that Windows Update needs.

    .DESCRIPTION
        Local publishing signs each update with a code-signing certificate.
        Microsoft Learn names these requirements:
          - The certificate is in the WSUS certificate store of the WSUS
            server, with its private key, and in the Trusted Publishers
            store of the WSUS server and of the publishing computer. A
            self-signed certificate is also in Trusted Root Certification
            Authorities.
            https://learn.microsoft.com/intune/configmgr/sum/tools/updates-publisher-security
          - Each client that scans the updates has the certificate in
            Trusted Publishers (and Trusted Root for a self-signed one).
          - The Windows Update policy "Allow signed content from intranet
            Microsoft update service location" is on. The policy value is
            AcceptTrustedPublisherCerts = 1 under
            HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate.
          - For ConfigMgr-managed self-signed WSUS signing certificates the
            site server needs HKLM\Software\Microsoft\Update Services\
            Server\Setup, DWORD EnableSelfSignedCertificates = 1.
            https://learn.microsoft.com/intune/configmgr/sum/deploy-use/third-party-software-updates

        Steps, each idempotent (keyed on the certificate thumbprint):
          1. On the WSUS server: reuse a valid certificate with the
             subject in -CertificateSubject from the WSUS store, or create
             a self-signed code-signing certificate (exportable key, valid
             -ValidYears) and put it in the WSUS store. Add it to Trusted
             Publishers and Trusted Root. Set EnableSelfSignedCertificates.
          2. On every VM in -TrustedComputerName: import the public
             certificate into Trusted Publishers and Trusted Root and turn
             on the policy value.
          3. Check every store and the policy value again. Throw on a gap.

        Only the public certificate leaves the WSUS server.

        Returns Thumbprint, Status ('Created' or 'Reused') and Computers.

    .PARAMETER ComputerName
        The WSUS server (the site server in the default topology).

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER TrustedComputerName
        VMs that trust the certificate, usually the client VMs. The WSUS
        server always trusts it.

    .PARAMETER CertificateSubject
        Subject of the signing certificate. Default 'CN=HomeLab WSUS Signing'.

    .PARAMETER ValidYears
        Validity of a new certificate. Default 5.

    .EXAMPLE
        Set-LabWsusPublishing -ComputerName CM01 -DomainCredential $cred -TrustedComputerName CLIENT01.contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter()]
        [string[]]$TrustedComputerName = @(),

        [Parameter()]
        [ValidatePattern('^CN=.+')]
        [string]$CertificateSubject = 'CN=HomeLab WSUS Signing',

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$ValidYears = 5
    )

    Write-LabLog "[$ComputerName] WSUS signing certificate and publishing trust" -Status RUN

    # Trust steps shared by the server and the clients. Passed as text so the
    # same code runs in each remote session.
    $trustBlock = {
        param([string]$CertBase64)
        $bytes = [Convert]::FromBase64String($CertBase64)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $bytes)
        $added = @()
        foreach ($storeName in 'TrustedPublisher', 'Root') {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
            $store.Open('ReadWrite')
            try {
                if (-not ($store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
                    $store.Add($cert)
                    $added += $storeName
                }
            } finally { $store.Close() }
        }
        $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        if (-not (Test-Path -Path $policy)) { New-Item -Path $policy -Force | Out-Null }
        $cur = (Get-ItemProperty -Path $policy -Name AcceptTrustedPublisherCerts -ErrorAction SilentlyContinue).AcceptTrustedPublisherCerts
        if ($cur -ne 1) {
            New-ItemProperty -Path $policy -Name AcceptTrustedPublisherCerts -Value 1 -PropertyType DWord -Force | Out-Null
            $added += 'Policy'
        }
        $ok = ((Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object Thumbprint -eq $cert.Thumbprint) -and
               (Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $cert.Thumbprint) -and
               ((Get-ItemProperty -Path $policy -Name AcceptTrustedPublisherCerts).AcceptTrustedPublisherCerts -eq 1))
        [pscustomobject]@{ Computer = $env:COMPUTERNAME; Added = $added; Trusted = [bool]$ok }
    }

    $server = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Create or reuse the WSUS signing certificate' -ScriptBlock {
            param($Subject, $ValidYears, $TrustText)
            $codeSigning = '1.3.6.1.5.5.7.3.3'
            $now = Get-Date

            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('WSUS', 'LocalMachine')
            $store.Open('ReadWrite')
            try {
                $cert = $store.Certificates | Where-Object {
                    $_.Subject -eq $Subject -and $_.HasPrivateKey -and
                    $_.NotBefore -lt $now -and $_.NotAfter -gt $now.AddDays(30) -and
                    ($_.EnhancedKeyUsageList.ObjectId -contains $codeSigning)
                } | Sort-Object NotAfter -Descending | Select-Object -First 1
                $status = 'Reused'
                if (-not $cert) {
                    $new = New-SelfSignedCertificate -Subject $Subject -Type CodeSigningCert `
                        -KeyExportPolicy Exportable -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 2048 `
                        -HashAlgorithm SHA256 -NotAfter $now.AddYears($ValidYears) `
                        -CertStoreLocation Cert:\LocalMachine\My
                    $store.Add($new)
                    Remove-Item -Path "Cert:\LocalMachine\My\$($new.Thumbprint)" -Force
                    $cert = $store.Certificates | Where-Object Thumbprint -eq $new.Thumbprint | Select-Object -First 1
                    $status = 'Created'
                }
            } finally { $store.Close() }

            # The site server reads this value when it manages self-signed WSUS signing certificates.
            $setup = 'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup'
            if (Test-Path -Path $setup) {
                New-ItemProperty -Path $setup -Name EnableSelfSignedCertificates -Value 1 -PropertyType DWord -Force | Out-Null
            }

            $b64 = [Convert]::ToBase64String($cert.Export('Cert'))
            $trust = & ([scriptblock]::Create($TrustText)) $b64
            [pscustomobject]@{ Thumbprint = $cert.Thumbprint; Status = $status; CertBase64 = $b64; Trust = $trust }
        } -ArgumentList $CertificateSubject, $ValidYears, $trustBlock.ToString()

    $computers = @($server.Trust)
    foreach ($target in $TrustedComputerName) {
        $t = Invoke-LabCommand -ComputerName $target -Credential $DomainCredential `
            -Activity 'Trust the WSUS signing certificate' -ScriptBlock {
                param($TrustText, $B64)
                & ([scriptblock]::Create($TrustText)) $B64
            } -ArgumentList $trustBlock.ToString(), $server.CertBase64
        $computers += $t
    }

    $gaps = @($computers | Where-Object { -not $_.Trusted })
    if ($gaps.Count -gt 0) {
        throw "WSUS signing certificate trust is incomplete on: $(($gaps | ForEach-Object { $_.Computer }) -join ', ')"
    }

    Write-LabLog "[$ComputerName] WSUS signing certificate $($server.Thumbprint) ($($server.Status)); trusted on $($computers.Count) computer(s)" -Status OK
    return [pscustomobject]@{ Thumbprint = $server.Thumbprint; Status = $server.Status; Computers = $computers }
}
