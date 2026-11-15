function Set-CMAdminServiceCertificate {
    <#
    .SYNOPSIS
        Give the ConfigMgr administration service a PKI server
        authentication certificate on port 443 of the SMS Provider.

    .DESCRIPTION
        By default the administration service uses the site self-signed
        certificate issued by "SMS Issuing". Domain clients do not trust
        that root, so CMPivot and other REST callers fail with "remote
        certificate is invalid". Microsoft's supported setup is to bind a
        PKI-based server authentication certificate for the SMS Provider on
        port 443 and let clients trust the issuing CA.
        https://learn.microsoft.com/intune/configmgr/develop/adminservice/set-up
        (section "Enable secure HTTPS communication")

        Steps, each idempotent:
          1. Find a valid certificate in LocalMachine\My: subject
             CN=<FQDN>, server authentication, not issued by SMS Issuing,
             not self-signed, chain builds, valid for MinValidDays more.
             If none, request one from the enterprise CA with the template
             (Get-Certificate, machine context, DNS names FQDN and short).
          2. Compare the certificate bound to 0.0.0.0:443. If it differs,
             record the old hash and application id, delete the binding and
             add the new one with the same application id
             (netsh http delete / add sslcert).
          3. Restart SMS_EXECUTIVE so the SMS_REST_PROVIDER component reads
             the binding again (Learn: restart the component).
          4. Read the certificate that port 443 presents. Throw if it is
             not the PKI certificate.

        Returns Status 'Bound' or 'AlreadyBound', Thumbprint, OldThumbprint,
        OldAppId. Keep OldThumbprint for the undo step.

        -PlanOnly changes nothing and reports what a real run would do.

        Undo: netsh http delete sslcert ipport=0.0.0.0:443, then
        netsh http add sslcert ipport=0.0.0.0:443 certhash=<OldThumbprint>
        appid={<OldAppId>} certstorename=MY, then restart SMS_EXECUTIVE.
        See docs/admin-service-pki.md.

    .PARAMETER ComputerName
        DNS / short name of the SMS Provider (the site server).

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER DomainName
        DNS domain of the lab, for example contoso.com. The certificate
        subject is CN=<ComputerName short>.<DomainName>.

    .PARAMETER TemplateName
        Certificate template name. Default 'WebServer'.

    .PARAMETER MinValidDays
        Reuse an existing certificate only if it is valid for this many
        more days. Default 30.

    .PARAMETER SkipRestart
        Do not restart SMS_EXECUTIVE.

    .PARAMETER PlanOnly
        Report the plan and make no change.

    .EXAMPLE
        Set-CMAdminServiceCertificate -ComputerName CM01 -DomainCredential $cred -DomainName contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$')]
        [string]$DomainName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateName = 'WebServer',

        [Parameter()]
        [ValidateRange(1, 3650)]
        [int]$MinValidDays = 30,

        [Parameter()]
        [switch]$SkipRestart,

        [Parameter()]
        [switch]$PlanOnly
    )

    $short = $ComputerName.Split('.')[0]
    $fqdn = "$short.$DomainName"

    Write-LabLog "[$ComputerName] Administration service certificate for $fqdn (PlanOnly=$([bool]$PlanOnly))" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Bind PKI certificate for the administration service' -ScriptBlock {
            param($Fqdn, $Short, $TemplateName, $MinValidDays, $SkipRestart, $PlanOnly)

            $serverAuth = '1.3.6.1.5.5.7.3.1'

            function Get-BoundHttpSys {
                $text = netsh http show sslcert ipport=0.0.0.0:443 2>&1 | Out-String
                $hash = $null
                $app = $null
                if ($text -match 'Certificate Hash\s*:\s*([0-9a-fA-F]{40})') { $hash = $Matches[1].ToUpper() }
                if ($text -match 'Application ID\s*:\s*\{([0-9a-fA-F-]{36})\}') { $app = $Matches[1] }
                return [pscustomobject]@{ Hash = $hash; AppId = $app }
            }

            function Get-PresentedThumbprint {
                param($TargetHost)
                $tcp = New-Object System.Net.Sockets.TcpClient
                try {
                    $tcp.Connect('127.0.0.1', 443)
                    $cb = [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
                    $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb)
                    $ssl.AuthenticateAsClient($TargetHost)
                    return (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)).Thumbprint.ToUpper()
                } finally {
                    $tcp.Close()
                }
            }

            $now = Get-Date
            $cert = Get-ChildItem -Path Cert:\LocalMachine\My |
                Where-Object {
                    $_.HasPrivateKey -and
                    $_.Subject -eq "CN=$Fqdn" -and
                    $_.Issuer -notmatch 'SMS Issuing' -and
                    $_.Issuer -ne $_.Subject -and
                    $_.NotBefore -lt $now -and
                    $_.NotAfter -gt $now.AddDays($MinValidDays) -and
                    ($_.EnhancedKeyUsageList.ObjectId -contains $serverAuth)
                } |
                Sort-Object NotAfter -Descending |
                Where-Object {
                    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                    $chain.ChainPolicy.RevocationMode = 'NoCheck'
                    $chain.Build($_)
                } |
                Select-Object -First 1

            $certAction = 'Reused'
            if (-not $cert) {
                $certAction = if ($PlanOnly) { 'WouldRequest' } else { 'Requested' }
                if (-not $PlanOnly) {
                    $req = Get-Certificate -Template $TemplateName `
                        -SubjectName "CN=$Fqdn" -DnsName $Fqdn, $Short `
                        -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop
                    $cert = $req.Certificate
                }
            }

            $bound = Get-BoundHttpSys
            $thumb = if ($cert) { $cert.Thumbprint.ToUpper() } else { $null }

            if ($PlanOnly) {
                return [pscustomobject]@{
                    Status        = 'Plan'
                    CertAction    = $certAction
                    Thumbprint    = $thumb
                    OldThumbprint = $bound.Hash
                    OldAppId      = $bound.AppId
                    WouldRebind   = ($thumb -ne $bound.Hash)
                    WouldRestart  = (-not $SkipRestart)
                }
            }

            $status = 'AlreadyBound'
            $restart = $false
            if ($bound.Hash -ne $thumb) {
                $appId = if ($bound.AppId) { $bound.AppId } else { [guid]::NewGuid().ToString() }
                if ($bound.Hash) {
                    netsh http delete sslcert ipport=0.0.0.0:443 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'netsh http delete sslcert failed' }
                }
                netsh http add sslcert ipport=0.0.0.0:443 certhash=$thumb appid="{$appId}" certstorename=MY | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    # Put the old binding back before failing.
                    if ($bound.Hash) {
                        netsh http add sslcert ipport=0.0.0.0:443 certhash=$($bound.Hash) appid="{$appId}" certstorename=MY | Out-Null
                    }
                    throw 'netsh http add sslcert failed; old binding restored'
                }
                $status = 'Bound'
                $restart = $true
            }

            if ($restart -and -not $SkipRestart) {
                Restart-Service -Name SMS_EXECUTIVE -Force -ErrorAction Stop
                $deadline = (Get-Date).AddMinutes(5)
                do {
                    Start-Sleep -Seconds 10
                    $svc = Get-Service -Name SMS_EXECUTIVE
                } while ($svc.Status -ne 'Running' -and (Get-Date) -lt $deadline)
                if ($svc.Status -ne 'Running') { throw 'SMS_EXECUTIVE did not return to Running' }
            }

            # Read what port 443 presents. The REST provider component can
            # take a while to settle after a restart, so poll.
            $deadline = (Get-Date).AddMinutes(5)
            $presented = $null
            do {
                try { $presented = Get-PresentedThumbprint -TargetHost $Fqdn } catch { $presented = $null }
                if ($presented -eq $thumb) { break }
                Start-Sleep -Seconds 10
            } while ((Get-Date) -lt $deadline)
            if ($presented -ne $thumb) {
                throw "Port 443 presents '$presented', expected '$thumb'"
            }

            [pscustomobject]@{
                Status        = $status
                CertAction    = $certAction
                Thumbprint    = $thumb
                OldThumbprint = $bound.Hash
                OldAppId      = $bound.AppId
            }
        } -ArgumentList $fqdn, $short, $TemplateName, $MinValidDays, ([bool]$SkipRestart), ([bool]$PlanOnly)

    Write-LabLog "[$ComputerName] Administration service certificate: $($result.Status) ($($result.Thumbprint))" -Status OK
    return $result
}
