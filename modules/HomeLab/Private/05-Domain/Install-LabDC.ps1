function Install-LabDC {
    <#
    .SYNOPSIS
        Promote a freshly-provisioned VM to a single-forest root domain
        controller and wait until AD is fully online.

    .DESCRIPTION
        Runs end-to-end inside the target VM via Invoke-LabCommand:

          1. Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
          2. Install-ADDSForest -DomainName <DomainName> ... (no-confirm,
             auto-reboot suppressed so we control the reboot ourselves)
          3. Wait for the auto-reboot the AD module schedules (the VM goes
             Off briefly, then comes back as a DC)
          4. Wait for the Active Directory Web Services (ADWS) service
             to be Running and a `(Get-ADDomain).DomainMode` query to
             succeed -- this is the "AD is actually answering" signal
             AutomatedLab also gated on

        After return, the VM's local Administrator account has become
        the domain Administrator (CONTOSO\Administrator). The caller
        should use Get-LabCredential -Identity Admin for follow-on
        operations.

        Idempotent: if the box is already a DC for $DomainName, returns
        success immediately.

    .PARAMETER ComputerName
        DNS name of the target VM (e.g. DC01.contoso.com or just DC01
        before domain join exists; pre-promotion the box answers on its
        local-admin static IP, so use the IP or short name).

    .PARAMETER LocalCredential
        Local Administrator credential (the one Unattend.xml created).
        Used for the pre-promotion Invoke-LabCommand.

    .PARAMETER DomainName
        FQDN of the new forest root domain (e.g. contoso.com).

    .PARAMETER NetBIOSName
        Optional explicit NetBIOS name. Defaults to the first label of
        DomainName uppercased (contoso.com -> CONTOSO).

    .PARAMETER SafeModeAdministratorPassword
        DSRM password. Pass a SecureString. Lab pattern: same as the
        local Administrator password. Required by Install-ADDSForest.

    .PARAMETER ForestMode
        DS forest functional level. Default WinThreshold (Server 2016+).

    .PARAMETER DomainMode
        DS domain functional level. Default WinThreshold.

    .PARAMETER PostRebootTimeoutSeconds
        How long to wait for ADWS-ready after the auto-reboot. Default 600.

    .EXAMPLE
        $local = New-Object PSCredential('Administrator', $sec)
        Install-LabDC -ComputerName DC01 -LocalCredential $local `
                      -DomainName contoso.com `
                      -SafeModeAdministratorPassword $sec
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$LocalCredential,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9-]+\.[A-Za-z0-9.-]+$')]
        [string]$DomainName,

        [Parameter()]
        [string]$NetBIOSName,

        [Parameter(Mandatory)]
        [securestring]$SafeModeAdministratorPassword,

        [Parameter()]
        [ValidateSet('Win2008','Win2008R2','Win2012','Win2012R2','WinThreshold','Default')]
        [string]$ForestMode = 'WinThreshold',

        [Parameter()]
        [ValidateSet('Win2008','Win2008R2','Win2012','Win2012R2','WinThreshold','Default')]
        [string]$DomainMode = 'WinThreshold',

        [Parameter()]
        [int]$PostRebootTimeoutSeconds = 1800
    )

    if (-not $NetBIOSName) {
        $NetBIOSName = ($DomainName -split '\.')[0].ToUpperInvariant()
    }

    Write-LabLog "[$ComputerName] Promoting to DC for $DomainName (NetBIOS: $NetBIOSName)" -Status RUN

    # 1 + 2: Install feature + run promotion. The promotion implicitly
    # reboots the VM. We pass -NoRebootOnCompletion:$false so the box
    # comes back as a DC on its own; we handle the wait below.
    #
    # Two non-deterministic failure modes during the call. Both end the
    # WinRM transport before the script block returns its $result, both
    # are non-fatal (the promotion is in flight), and both are validated
    # downstream by the post-reboot WinRM + ADWS gate:
    #
    #   a. "Access is denied" -- Install-ADDSForest's authority swap from
    #      LOCAL\Administrator to CONTOSO\Administrator can invalidate the
    #      current WinRM session token mid-call.
    #   b. Channel-drop messages (shut/connect/transport/broken/terminated/
    #      aborted/I/O) -- the auto-reboot kicks off before the cmdlet's
    #      result is serialized back across the wire.
    #
    # Run #1 of S15 won the timing race; run #2 lost it with mode (a).
    # Treat both as "promotion launched, validate downstream."
    $result = $null
    try {
        $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $LocalCredential `
            -Activity 'Install AD DS feature + promote forest' -ScriptBlock {
                param($DomainName, $NetBIOSName, $DsrmPasswordPlain, $ForestMode, $DomainMode)

                # Idempotency: if the box thinks it's a DC for this domain, no-op.
                try {
                    $current = Get-ADDomain -Identity $DomainName -ErrorAction Stop
                    if ($current.NetBIOSName -eq $NetBIOSName) {
                        return [pscustomobject]@{ Status = 'AlreadyPromoted'; DomainMode = $current.DomainMode }
                    }
                } catch { }

                $feat = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop
                if (-not $feat.Success) {
                    throw "Install-WindowsFeature AD-Domain-Services failed: $($feat | Out-String)"
                }

                $sec = ConvertTo-SecureString -String $DsrmPasswordPlain -AsPlainText -Force

                Import-Module ADDSDeployment -ErrorAction Stop
                Install-ADDSForest `
                    -DomainName $DomainName `
                    -DomainNetbiosName $NetBIOSName `
                    -ForestMode $ForestMode `
                    -DomainMode $DomainMode `
                    -SafeModeAdministratorPassword $sec `
                    -InstallDns:$true `
                    -CreateDnsDelegation:$false `
                    -NoRebootOnCompletion:$false `
                    -Force:$true `
                    -Confirm:$false `
                    -ErrorAction Stop | Out-Null

                return [pscustomobject]@{ Status = 'PromotedRebootingNow' }
            } -ArgumentList $DomainName, $NetBIOSName,
                           ([System.Net.NetworkCredential]::new('', $SafeModeAdministratorPassword).Password),
                           $ForestMode, $DomainMode
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Access is denied|shut|connect|transport|broken|terminated|aborted|I/O|operation has timed out') {
            Write-LabLog "[$ComputerName] WinRM channel dropped during promotion (expected, post-reboot gate will validate): $msg" -Status WARN
            $result = [pscustomobject]@{ Status = 'PromotedRebootingNow' }
        } else {
            throw
        }
    }

    if ($result -and $result.Status -eq 'AlreadyPromoted') {
        Write-LabLog "[$ComputerName] Already a DC for $DomainName (DomainMode=$($result.DomainMode))" -Status SKIP
        return $result
    }

    # 3. The VM is now rebooting after Install-ADDSForest. Drop the cached
    # session so we don't try to talk to a recycled WinRM listener.
    Clear-LabSessionCache

    # Settle delay: Install-ADDSForest -NoRebootOnCompletion:$false
    # triggers the reboot but the outgoing WinRM listener is briefly
    # still alive (~1-3s). Without this sleep, Wait-LabVM races and
    # the post-reboot ADWS gate then waits 1800s against a VM that
    # was actually still rebooting. Sleep 60s to clear the shutdown
    # window before polling. (DC reboot is the single longest in the
    # pipeline; pad more aggressively here.)
    Start-Sleep -Seconds 60

    # Wait for it to come BACK up. The local-admin cred we just used has
    # been promoted to domain-admin; it still authenticates by SAM name.
    Write-LabLog "[$ComputerName] Waiting for post-promotion reboot + WinRM" -Status RUN
    $up = Wait-LabVM -ComputerName $ComputerName -Credential $LocalCredential `
                     -TimeoutSeconds $PostRebootTimeoutSeconds
    if (-not $up) {
        throw "Install-LabDC: $ComputerName did not return to WinRM-ready within ${PostRebootTimeoutSeconds}s"
    }

    # 4. ADWS-ready gate. Get-ADDomain throwing means AD service stack is
    # still booting; treat as transient.
    # NOTE: Do NOT use .GetNewClosure() to capture $ComputerName/$LocalCredential/$NetBIOSName.
    # GetNewClosure rebinds SessionState to the caller's global scope, which makes
    # Invoke-LabCommand resolve to AutomatedLab's auto-imported version instead of
    # HomeLab's helper. AL silently fails the call (no Lab loaded), the predicate
    # never returns truthy, and the wait times out after 1800s. Pass values via
    # -ArgumentList instead so the predicate runs with module SessionState intact.
    $ready = Wait-LabReady -Activity "[$ComputerName] AD Web Services + Get-ADDomain" `
                           -TimeoutSeconds $PostRebootTimeoutSeconds -IntervalSeconds 10 `
                           -ArgumentList @($ComputerName, $LocalCredential, $NetBIOSName) `
                           -Predicate {
        param($cn, $cred, $netbios)
        try {
            $d = Invoke-LabCommand -ComputerName $cn -Credential $cred -ScriptBlock {
                $svc = Get-Service -Name ADWS -ErrorAction Stop
                if ($svc.Status -ne 'Running') { return $null }
                Get-ADDomain -ErrorAction Stop
            }
            return ($null -ne $d -and $d.NetBIOSName -eq $netbios)
        } catch {
            return $false
        }
    }

    if (-not $ready) {
        throw "Install-LabDC: ADWS / Get-ADDomain did not become ready on $ComputerName"
    }

    Write-LabLog "[$ComputerName] DC ready; forest $DomainName online" -Status OK
    return [pscustomobject]@{
        Status     = 'Ready'
        DomainName = $DomainName
        NetBIOS    = $NetBIOSName
    }
}
