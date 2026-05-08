function Join-LabDomain {
    <#
    .SYNOPSIS
        Join a non-domain VM to the lab forest and reboot, waiting for it
        to return to WinRM-ready as a domain member.

    .DESCRIPTION
        Run on each member VM (CM01, CLIENT01) AFTER Install-LabDC has
        promoted the forest root. Steps:

          1. Verify the VM can resolve the domain name (DNS sanity)
          2. Add-Computer -DomainName ... -Credential $DomainCredential
             -Restart from inside the VM via Invoke-LabCommand using the
             CURRENT local-admin credential
          3. Drop the cached PSSession (the VM is rebooting)
          4. Wait-LabVM with the DOMAIN credential (post-reboot the box
             accepts contoso\Administrator over WinRM)
          5. Verify domain membership via Get-ComputerInfo

        Idempotent: if the box is already domain-joined to $DomainName,
        returns 'AlreadyJoined' without rebooting.

    .PARAMETER ComputerName
        DNS or short name of the target VM.

    .PARAMETER LocalCredential
        Pre-join local-admin credential.

    .PARAMETER DomainCredential
        Post-join domain admin credential (e.g. CONTOSO\Administrator).

    .PARAMETER DomainName
        FQDN to join.

    .PARAMETER PostRebootTimeoutSeconds
        Default 600.

    .EXAMPLE
        Join-LabDomain -ComputerName CM01 `
                       -LocalCredential $localCred `
                       -DomainCredential $domCred `
                       -DomainName contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$LocalCredential,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9-]+\.[A-Za-z0-9.-]+$')]
        [string]$DomainName,

        [Parameter()]
        [int]$PostRebootTimeoutSeconds = 600
    )

    # Idempotency: ask the VM if it's already a domain member.
    $current = Invoke-LabCommand -ComputerName $ComputerName -Credential $LocalCredential `
        -ScriptBlock {
            $cs = Get-CimInstance Win32_ComputerSystem
            [pscustomobject]@{ PartOfDomain = $cs.PartOfDomain; Domain = $cs.Domain }
        }

    if ($current.PartOfDomain -and $current.Domain -ieq $DomainName) {
        Write-LabLog "[$ComputerName] Already joined to $DomainName" -Status SKIP
        return [pscustomobject]@{ Status = 'AlreadyJoined'; Domain = $current.Domain }
    }

    Write-LabLog "[$ComputerName] Joining $DomainName" -Status RUN

    # Add-Computer -Restart triggers an immediate restart, so this Invoke
    # will return with the VM going down.
    try {
        Invoke-LabCommand -ComputerName $ComputerName -Credential $LocalCredential `
            -Activity "Add-Computer to $DomainName" -ScriptBlock {
                param($DomainName, $DomCredUser, $DomCredPlain)
                $sec = ConvertTo-SecureString -String $DomCredPlain -AsPlainText -Force
                $cred = New-Object System.Management.Automation.PSCredential($DomCredUser, $sec)
                Add-Computer -DomainName $DomainName -Credential $cred -Force -Restart -ErrorAction Stop
            } -ArgumentList $DomainName, $DomainCredential.UserName,
                            ([System.Net.NetworkCredential]::new('', $DomainCredential.Password).Password)
    } catch {
        # The VM is probably already rebooting; the WinRM channel can drop
        # mid-call with a generic transport error. Treat anything matching
        # transport / connection / shutdown as expected.
        $msg = $_.Exception.Message
        if ($msg -notmatch 'shut|connect|transport|broken|terminated') {
            throw
        }
        Write-LabLog "[$ComputerName] Add-Computer triggered reboot (transport error expected)" -Level Verbose
    }

    Clear-LabSessionCache

    # Settle delay: Add-Computer -Restart starts the reboot but the
    # outgoing WinRM listener is briefly still alive (~1-3s). Without
    # this sleep, Wait-LabVM races and hits the dying listener, then
    # the post-reboot Invoke-Command fails with an I/O abort. Sleep
    # 45s to clear the shutdown window before polling.
    Start-Sleep -Seconds 45

    Write-LabLog "[$ComputerName] Waiting for post-join reboot + WinRM (domain creds)" -Status RUN
    $up = Wait-LabVM -ComputerName $ComputerName -Credential $DomainCredential `
                     -TimeoutSeconds $PostRebootTimeoutSeconds
    if (-not $up) {
        throw "Join-LabDomain: $ComputerName did not return to WinRM-ready as a domain member within ${PostRebootTimeoutSeconds}s"
    }

    # Verify
    $verify = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -ScriptBlock {
            $cs = Get-CimInstance Win32_ComputerSystem
            [pscustomobject]@{ PartOfDomain = $cs.PartOfDomain; Domain = $cs.Domain }
        }

    if (-not $verify.PartOfDomain -or $verify.Domain -ine $DomainName) {
        throw "Join-LabDomain: $ComputerName came back up but is not in $DomainName (got '$($verify.Domain)')"
    }

    Write-LabLog "[$ComputerName] Joined to $($verify.Domain)" -Status OK
    return [pscustomobject]@{ Status = 'Joined'; Domain = $verify.Domain }
}
