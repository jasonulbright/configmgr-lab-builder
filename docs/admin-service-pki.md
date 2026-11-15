# Administration service certificate (CMPivot, console, REST)

## Problem

The ConfigMgr administration service runs on the SMS Provider, port 443.
By default it uses the site self-signed certificate issued by
"SMS Issuing". Domain members do not trust that root. A client call such
as CMPivot, or `Invoke-RestMethod https://CM01.contoso.com/AdminService/wmi/SMS_Site`,
fails with "remote certificate is invalid".

## Design (the Microsoft-supported path)

Microsoft Learn describes this path. Bind a PKI server authentication
certificate for the SMS Provider on port 443, and let clients trust the
issuing CA. Most enterprise PKI distributes the trusted root to Windows
clients; an Enterprise Root CA does this through Active Directory.

| Step | Function | Where it runs |
|---|---|---|
| 1 | `Install-LabRootCA` (existing) installs an Enterprise Root CA. | DC01 |
| 2 | `Set-LabWebServerTemplateAccess` gives the CM01 computer account the Enroll right on the built-in Web Server template and makes sure the CA publishes it. | DC01 |
| 3 | `Enable-CMEnhancedHttp` turns on "Use Configuration Manager-generated certificates for HTTP site systems". | CM01 |
| 4 | `Set-CMAdminServiceCertificate` requests a Web Server certificate with subject `CN=<FQDN>` and DNS names FQDN and short name, binds it to `0.0.0.0:443` with `netsh http`, restarts `SMS_EXECUTIVE`, and reads back what port 443 presents. | CM01 |
| 5 | `Test-CMAdminServiceTrust` opens a TLS connection from a member VM and validates the chain with the member's own trust store. | CLIENT01 |

Every step reads the current state first and changes nothing when the
state is already correct. Each function accepts `-PlanOnly` (steps 2 to 4)
to report the planned change without making it. `Install-HomeLab` runs the
steps at the end of phase `09-CMConfig`.

### Root distribution

An Enterprise Root CA publishes its root in Active Directory. Domain
members install it into Trusted Root Certification Authorities during
Group Policy refresh and certificate autoenrollment. No Group Policy
object and no per-VM import are needed. Step 5 checks the result.

### Why the built-in Web Server template

The Web Server template lets the requester supply the subject name, which
the SMS Provider needs (`CN=<FQDN>`). A duplicate template adds no
capability for this lab. The only change is one scoped ACE: Enroll for the
CM01 computer account. The Domain Computers group is not granted.

### Enhanced HTTP and the PKI certificate

If a PKI certificate is bound in IIS, site systems use it, even when
enhanced HTTP is on. The SMS Issuing root still signs the role
certificates for site systems that have no PKI certificate.

## Undo

1. Restore the old binding. The result of `Set-CMAdminServiceCertificate`
   holds `OldThumbprint` and `OldAppId`.
   ```
   netsh http delete sslcert ipport=0.0.0.0:443
   netsh http add sslcert ipport=0.0.0.0:443 certhash=<OldThumbprint> appid={<OldAppId>} certstorename=MY
   Restart-Service SMS_EXECUTIVE
   ```
2. Remove the Enroll ACE for the CM01 computer account from
   `CN=WebServer,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,<forest DN>`.
3. Enhanced HTTP: `Set-CMSite -SiteCode MCM -UseSmsGeneratedCert $false`.
4. Delete the issued certificate from `Cert:\LocalMachine\My` on CM01 if it is no longer needed.

## Check

From any domain member:

```powershell
Invoke-RestMethod https://CM01.contoso.com/AdminService/wmi/SMS_Site -UseDefaultCredentials
```

No certificate error is the expected result. CMPivot in the console and in
tools that call the administration service use the same trust decision.

## Microsoft Learn sources

- https://learn.microsoft.com/intune/configmgr/develop/adminservice/set-up (section "Enable secure HTTPS communication")
- https://learn.microsoft.com/intune/configmgr/core/plan-design/hierarchy/enhanced-http
- https://learn.microsoft.com/intune/configmgr/core/plan-design/network/pki-certificate-requirements
- https://learn.microsoft.com/powershell/module/configurationmanager/set-cmsite (parameter `-UseSmsGeneratedCert`)
