function Test-HomeLab {
    <#
    .SYNOPSIS
        Probe lab health: VM state, WinRM, AD, SQL service, SMS_EXECUTIVE,
        CM provider WMI namespace.

    .DESCRIPTION
        Returns a structured health report Install-HomeLab uses to
        decide which phases to skip on a re-run. Also useful as a
        manual "is the lab actually ok?" check.

        Report shape:
          [pscustomobject]@{
              DC          = @{ State; WinRM; ADReady }
              CM          = @{ State; WinRM; SqlRunning; SmsExecutive; CmProviderReady }
              Client      = @{ State; WinRM; DomainJoined }
              OverallReady = [bool]   # all VMs WinRM + CM provider ready
          }

        Each individual probe is wrapped so the report is filled in
        as far as possible even when some VMs are off.

    .PARAMETER Config
        Pre-loaded config hashtable. Defaults to Get-LabConfig.

    .PARAMETER ProbeTimeoutSeconds
        Per-probe ceiling. Default 15.

    .EXAMPLE
        $health = Test-HomeLab
        if ($health.OverallReady) { 'lab fully up' }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [hashtable]$Config,

        [Parameter()]
        [ValidateRange(5, 120)]
        [int]$ProbeTimeoutSeconds = 15,

        [Parameter()]
        [securestring]$LabPassword
    )

    if (-not $Config) { $Config = Get-LabConfig }
    $cred = Get-LabCredential -Identity Admin -Config $Config -LabPassword $LabPassword

    function _State { param([string]$Name)
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if (-not $vm) { return 'Missing' }
        return [string]$vm.State
    }

    function _WinRM { param([string]$Fqdn)
        try {
            $tnc = Test-NetConnection -ComputerName $Fqdn -Port 5985 `
                -WarningAction SilentlyContinue -InformationLevel Quiet
            return [bool]$tnc
        } catch { return $false }
    }

    function _RemoteProbe { param([string]$Fqdn, [scriptblock]$Block, [object[]]$ArgumentList)
        try {
            $params = @{
                ComputerName = $Fqdn
                Credential   = $cred
                ScriptBlock  = $Block
                ErrorAction  = 'Stop'
            }
            if ($PSBoundParameters.ContainsKey('ArgumentList') -and $ArgumentList) {
                $params.ArgumentList = $ArgumentList
            }
            return Invoke-LabCommand @params
        } catch {
            return $null
        }
    }

    $dcFqdn     = "$($Config.DC.Name).$($Config.DomainName)"
    $cmFqdn     = "$($Config.CM.Name).$($Config.DomainName)"
    $clientFqdn = "$($Config.Client.Name).$($Config.DomainName)"

    $dcState    = _State $Config.DC.Name
    $cmState    = _State $Config.CM.Name
    $clientState = _State $Config.Client.Name

    $dcWinRM    = if ($dcState -eq 'Running')     { _WinRM $dcFqdn }     else { $false }
    $cmWinRM    = if ($cmState -eq 'Running')     { _WinRM $cmFqdn }     else { $false }
    $clientWinRM = if ($clientState -eq 'Running') { _WinRM $clientFqdn } else { $false }

    $adReady = $false
    if ($dcWinRM) {
        $r = _RemoteProbe $dcFqdn { (Get-Service ADWS -ErrorAction SilentlyContinue).Status -eq 'Running' }
        $adReady = [bool]$r
    }

    $sqlRunning = $false
    $smsExec    = $false
    $cmProvider = $false
    if ($cmWinRM) {
        $sqlRunning = [bool](_RemoteProbe $cmFqdn {
            (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status -eq 'Running'
        })
        $smsExec = [bool](_RemoteProbe $cmFqdn {
            (Get-Service SMS_EXECUTIVE -ErrorAction SilentlyContinue).Status -eq 'Running'
        })
        # CM provider readiness:
        #   - SMS_ProviderLocation in ROOT\SMS publishes as soon as the SMS
        #     provider is running. This is the right "provider is up" signal.
        #   - SMS_Site in ROOT\SMS\site_<code> only populates after
        #     SMS_SITE_COMPONENT_MANAGER finishes initializing components,
        #     which takes 5-15 min post-setup.exe-exit. Accept as a richer
        #     signal if it answers, but don't require it -- otherwise this
        #     check FAILs at deploy time even when the site is operational
        #     (Phase 09's CM-cmdlet calls already proved it works).
        $cmProvider = [bool](_RemoteProbe $cmFqdn {
            param($Site)
            try {
                $loc = Get-CimInstance -Namespace 'ROOT\SMS' `
                    -ClassName SMS_ProviderLocation -ErrorAction Stop |
                    Where-Object { $_.SiteCode -eq $Site -and $_.ProviderForLocalSite } |
                    Select-Object -First 1
                if ($loc) { return $true }
                # Fallback: rare edge case where ProviderForLocalSite isn't
                # tagged yet but SMS_Site has populated. Treat as ready.
                $cm = Get-CimInstance -Namespace "ROOT\SMS\site_$Site" `
                    -ClassName SMS_Site -ErrorAction Stop |
                    Where-Object { $_.SiteCode -eq $Site } |
                    Select-Object -First 1
                [bool]$cm
            } catch { $false }
        } -ArgumentList @($Config.SiteCode))
    }

    $clientJoined = $false
    if ($clientWinRM) {
        $r = _RemoteProbe $clientFqdn {
            (Get-CimInstance Win32_ComputerSystem).PartOfDomain
        }
        $clientJoined = [bool]$r
    }

    $report = [pscustomobject]@{
        DC = [pscustomobject]@{
            State   = $dcState
            WinRM   = $dcWinRM
            ADReady = $adReady
        }
        CM = [pscustomobject]@{
            State           = $cmState
            WinRM           = $cmWinRM
            SqlRunning      = $sqlRunning
            SmsExecutive    = $smsExec
            CmProviderReady = $cmProvider
        }
        Client = [pscustomobject]@{
            State        = $clientState
            WinRM        = $clientWinRM
            DomainJoined = $clientJoined
        }
        OverallReady = $dcWinRM -and $cmWinRM -and $clientWinRM -and $adReady -and $smsExec -and $cmProvider
    }

    return $report
}
