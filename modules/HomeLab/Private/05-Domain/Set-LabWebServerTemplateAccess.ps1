function Set-LabWebServerTemplateAccess {
    <#
    .SYNOPSIS
        Let one computer account enroll for the Web Server certificate
        template and make sure the CA publishes that template.

    .DESCRIPTION
        The built-in Web Server template lets only Domain Admins and
        Enterprise Admins enroll. The ConfigMgr SMS Provider on the site
        server needs a server authentication certificate for the
        administration service (CMPivot, the console, the REST API), so the
        site server computer account needs the Enroll extended right on
        that template.

        Microsoft Learn, "How to set up the administration service in
        Configuration Manager", section "Enable secure HTTPS
        communication": bind a PKI-based server authentication certificate
        for the SMS Provider on port 443. Most enterprise PKI distributes
        the trusted root to clients; an Enterprise Root CA does this
        through Active Directory.
        https://learn.microsoft.com/intune/configmgr/develop/adminservice/set-up

        Idempotent. Returns Status 'Granted' or 'AlreadyGranted', and
        TemplatePublished ('Published' or 'AlreadyPublished').

        -PlanOnly changes nothing and reports what a real run would do.

        Undo: remove the Enroll ACE for the computer account from
        CN=WebServer,CN=Certificate Templates,CN=Public Key Services,
        CN=Services,CN=Configuration,<forest DN>. See docs/admin-service-pki.md.

    .PARAMETER ComputerName
        The CA / domain controller (FQDN or short name).

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER EnrollComputer
        Short name of the computer that enrolls (no trailing dollar sign),
        for example CM01.

    .PARAMETER TemplateName
        Template common name. Default 'WebServer'.

    .PARAMETER PlanOnly
        Report the planned change and make none.

    .EXAMPLE
        Set-LabWebServerTemplateAccess -ComputerName DC01.contoso.com -DomainCredential $cred -EnrollComputer CM01
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
        [string]$EnrollComputer,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateName = 'WebServer',

        [Parameter()]
        [switch]$PlanOnly
    )

    Write-LabLog "[$ComputerName] Web Server template: enroll right for ${EnrollComputer}$ (PlanOnly=$([bool]$PlanOnly))" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'Grant Web Server template enroll right' -ScriptBlock {
            param($EnrollComputer, $TemplateName, $PlanOnly)

            Import-Module ActiveDirectory -ErrorAction Stop
            $configNc = (Get-ADRootDSE).configurationNamingContext
            $templateDn = "CN=$TemplateName,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNc"
            $enrollRight = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'

            $computer = Get-ADComputer -Identity $EnrollComputer -ErrorAction Stop
            $sid = $computer.SID

            $acl = Get-Acl -Path "AD:$templateDn"
            $have = $false
            foreach ($ace in $acl.Access) {
                if ($ace.AccessControlType -ne 'Allow' -or $ace.ObjectType -ne $enrollRight) { continue }
                try {
                    $aceSid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
                } catch {
                    continue
                }
                if ($aceSid -eq $sid) { $have = $true }
            }

            $status = 'AlreadyGranted'
            if (-not $have) {
                $status = if ($PlanOnly) { 'WouldGrant' } else { 'Granted' }
                if (-not $PlanOnly) {
                    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                        $sid,
                        [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
                        [System.Security.AccessControl.AccessControlType]::Allow,
                        $enrollRight,
                        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None)
                    $acl.AddAccessRule($rule)
                    Set-Acl -Path "AD:$templateDn" -AclObject $acl -ErrorAction Stop
                }
            }

            $published = (certutil -CATemplates 2>&1 | Out-String) -match "(?m)^$([regex]::Escape($TemplateName)):"
            $pubStatus = 'AlreadyPublished'
            if (-not $published) {
                $pubStatus = if ($PlanOnly) { 'WouldPublish' } else { 'Published' }
                if (-not $PlanOnly) {
                    Add-CATemplate -Name $TemplateName -Force -Confirm:$false -ErrorAction Stop
                }
            }

            [pscustomobject]@{
                Status            = $status
                TemplatePublished = $pubStatus
                TemplateDn        = $templateDn
            }
        } -ArgumentList $EnrollComputer, $TemplateName, ([bool]$PlanOnly)

    Write-LabLog "[$ComputerName] Web Server template: $($result.Status), $($result.TemplatePublished)" -Status OK
    return $result
}
