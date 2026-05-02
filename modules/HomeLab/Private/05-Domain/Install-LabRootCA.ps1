function Install-LabRootCA {
    <#
    .SYNOPSIS
        Install ADCS Enterprise Root CA on a domain controller.

    .DESCRIPTION
        Adds the ADCS-Cert-Authority Windows feature and runs
        Install-AdcsCertificationAuthority for an Enterprise Root CA tied
        to the local AD forest. The CM 2509 install does NOT strictly
        require an enterprise CA on the homelab path (we use HTTP for MP
        / DP / SUP), but the CA is needed for any future PKI work
        (HTTPS-only sites, Apple device enrollment, RDP cert names).

        Idempotent: if the local CA service is already present and
        running, returns Status='AlreadyInstalled'.

        Run AFTER Install-LabDC. The DC's domain admin credential is
        required for ADCS install.

    .PARAMETER ComputerName
        DC FQDN or short name.

    .PARAMETER DomainCredential
        Domain admin credential (now contoso\Administrator after Install-LabDC).

    .PARAMETER CACommonName
        CA subject CN. Default 'CONTOSO Root CA' (or
        '<NetBIOS> Root CA' if it can be derived). Customize for branding.

    .PARAMETER CryptoProvider
        Cryptographic provider name. Default 'RSA#Microsoft Software Key
        Storage Provider'.

    .PARAMETER KeyLength
        RSA key length in bits. Default 4096.

    .PARAMETER HashAlgorithm
        Default 'SHA256'.

    .PARAMETER ValidityPeriod
        Default 'Years'.

    .PARAMETER ValidityPeriodUnits
        Default 10.

    .EXAMPLE
        Install-LabRootCA -ComputerName DC01.contoso.com -DomainCredential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter()]
        [string]$CACommonName,

        [Parameter()]
        [string]$CryptoProvider = 'RSA#Microsoft Software Key Storage Provider',

        [Parameter()]
        [ValidateSet(2048, 3072, 4096)]
        [int]$KeyLength = 4096,

        [Parameter()]
        [ValidateSet('SHA256','SHA384','SHA512')]
        [string]$HashAlgorithm = 'SHA256',

        [Parameter()]
        [ValidateSet('Hours','Days','Weeks','Months','Years')]
        [string]$ValidityPeriod = 'Years',

        [Parameter()]
        [int]$ValidityPeriodUnits = 10
    )

    Write-LabLog "[$ComputerName] Installing ADCS Enterprise Root CA" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Install ADCS Enterprise Root CA' -ScriptBlock {
            param($CACommonName, $CryptoProvider, $KeyLength, $HashAlgorithm, $ValidityPeriod, $ValidityPeriodUnits)

            $svc = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                return [pscustomobject]@{ Status = 'AlreadyInstalled'; CommonName = $CACommonName }
            }

            $feat = Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools -ErrorAction Stop
            if (-not $feat.Success) {
                throw "Install-WindowsFeature ADCS-Cert-Authority failed: $($feat | Out-String)"
            }

            if (-not $CACommonName) {
                $CACommonName = "$env:USERDOMAIN Root CA"
            }

            Import-Module ServerManager -ErrorAction SilentlyContinue
            Import-Module ADCSDeployment -ErrorAction Stop

            Install-AdcsCertificationAuthority `
                -CAType EnterpriseRootCA `
                -CACommonName $CACommonName `
                -CryptoProviderName $CryptoProvider `
                -KeyLength $KeyLength `
                -HashAlgorithmName $HashAlgorithm `
                -ValidityPeriod $ValidityPeriod `
                -ValidityPeriodUnits $ValidityPeriodUnits `
                -Force:$true `
                -Confirm:$false `
                -ErrorAction Stop | Out-Null

            # CertSvc starts as part of the install. Verify.
            $start = Get-Date
            do {
                Start-Sleep -Seconds 5
                $svc = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
            } while ((-not $svc -or $svc.Status -ne 'Running') -and ((Get-Date) - $start) -lt '00:03:00')

            if (-not $svc -or $svc.Status -ne 'Running') {
                throw "Install-AdcsCertificationAuthority completed but CertSvc is not Running"
            }

            return [pscustomobject]@{ Status = 'Installed'; CommonName = $CACommonName }
        } -ArgumentList $CACommonName, $CryptoProvider, $KeyLength, $HashAlgorithm, $ValidityPeriod, $ValidityPeriodUnits

    Write-LabLog "[$ComputerName] ADCS $($result.Status) ($($result.CommonName))" -Status OK
    return $result
}
