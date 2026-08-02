function Write-LabDeploySummary {
    <#
    .SYNOPSIS
        Print a post-install report at the tail of Install-HomeLab.

    .DESCRIPTION
        Calls Test-HomeLab for live health probes, formats a structured
        summary block, and writes it via Write-LabLog so it lands in both
        the console output and the C:\ProgramData\HomeLab\Logs file. The
        report covers VM state, service health, accounts created, paths
        (logs, install media, config), and applied PostCmConfig flags.

    .PARAMETER Config
        Loaded HomeLab config hashtable (from Get-LabConfig).

    .PARAMETER PostCmConfig
        The hashtable that was passed to Install-HomeLab -PostCmConfig,
        if any. Each key with a truthy value is listed in "Applied".

    .PARAMETER ConfigPath
        Path to the .psd1 used for this deploy (informational only).

    .PARAMETER Elapsed
        TimeSpan of the full Install-HomeLab run. Stamped at the top.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter()]
        [hashtable]$PostCmConfig,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [TimeSpan]$Elapsed
    )

    $health = $null
    try { $health = Test-HomeLab -Config $Config -ProbeTimeoutSeconds 20 }
    catch { Write-LabLog "Test-HomeLab probe failed: $($_.Exception.Message.Split([char]10)[0])" -Level Verbose }

    $glyphOK   = '[OK  ]'
    $glyphWarn = '[WARN]'
    $glyphFail = '[FAIL]'

    function _Mark { param($Bool) if ($Bool) { $glyphOK } else { $glyphFail } }

    $today = Get-Date -Format 'yyyy-MM-dd'
    $engineLog = "C:\ProgramData\HomeLab\Logs\HomeLab-$today.log"

    $accounts = @()
    $accounts += [pscustomobject]@{ SAM = $Config.AdminUser; Role = 'Lab admin (orchestrator + CM Full Administrator)' }
    if ($Config.ServiceAccounts) {
        foreach ($svc in 'ClientPush','NAA','Join') {
            if ($Config.ServiceAccounts[$svc]) {
                $accounts += [pscustomobject]@{
                    SAM  = $Config.ServiceAccounts[$svc].Name
                    Role = switch ($svc) {
                        'ClientPush' { 'CM Client Push installation account' }
                        'NAA'        { 'CM Network Access Account' }
                        'Join'       { 'OSD task sequence domain-join account' }
                    }
                }
            }
        }
    }

    $appliedFlags = @()
    if ($PostCmConfig) {
        foreach ($k in $PostCmConfig.Keys | Sort-Object) {
            if ([bool]$PostCmConfig[$k]) { $appliedFlags += $k }
        }
    }

    $banner = '=' * 78

    $lines = @()
    $lines += $banner
    $lines += '   Install-HomeLab DEPLOYMENT SUMMARY'
    if ($Elapsed) {
        $lines += ('   Elapsed: {0}h {1}m {2}s' -f $Elapsed.Hours, $Elapsed.Minutes, $Elapsed.Seconds)
    }
    if ($ConfigPath) { $lines += "   Config:  $ConfigPath" }
    $lines += "   Domain:  $($Config.DomainName)  /  NetBIOS: $($Config.NetBIOS)  /  Site: $($Config.SiteCode)"
    $lines += $banner
    $lines += ''

    $lines += '   VMs'
    $lines += '   ' + ('-' * 60)
    if ($health) {
        $rows = @(
            @{ Name = $Config.DC.Name;     Role = 'DomainController'; Probe = $health.DC;     Fqdn = "$($Config.DC.Name).$($Config.DomainName)" }
            @{ Name = $Config.CM.Name;     Role = 'CM SiteServer';    Probe = $health.CM;     Fqdn = "$($Config.CM.Name).$($Config.DomainName)" }
            @{ Name = $Config.Client.Name; Role = 'Client';           Probe = $health.Client; Fqdn = "$($Config.Client.Name).$($Config.DomainName)" }
        )
        foreach ($r in $rows) {
            $st = $r.Probe.State
            $wr = if ($r.Probe.WinRM) { 'WinRM:up' } else { 'WinRM:down' }
            $lines += ('   {0,-9} {1,-18} {2,-26} {3,-10} {4}' -f $r.Name, $r.Role, $r.Fqdn, $st, $wr)
        }
    } else {
        $lines += '   (Test-HomeLab probe unavailable; check engine log)'
    }
    $lines += ''

    if ($health) {
        $lines += '   Service health'
        $lines += '   ' + ('-' * 60)
        $lines += ('   {0} AD Web Services + Get-ADDomain (DC)' -f (_Mark $health.DC.ADReady))
        $lines += ('   {0} SQL Server engine (CM)' -f (_Mark $health.CM.SqlRunning))
        $lines += ('   {0} SMS_EXECUTIVE service (CM)' -f (_Mark $health.CM.SmsExecutive))
        $lines += ('   {0} CM provider WMI namespace (CM)' -f (_Mark $health.CM.CmProviderReady))
        $lines += ('   {0} Client domain join' -f (_Mark $health.Client.DomainJoined))
        $overall = if ($health.OverallReady) { "$glyphOK  ALL GREEN" } else { "$glyphWarn  Some checks did not pass" }
        $lines += ''
        $lines += "   Overall: $overall"
        $lines += ''
    }

    $lines += '   Accounts'
    $lines += '   ' + ('-' * 60)
    foreach ($a in $accounts) {
        $lines += ('   {0,-18} {1}' -f "$($Config.NetBIOS)\$($a.SAM)", $a.Role)
    }
    $lines += '   (single password supplied at deploy time via -LabPassword or prompt)'
    $lines += ''

    if ($appliedFlags.Count) {
        $lines += '   PostCM customization applied'
        $lines += '   ' + ('-' * 60)
        foreach ($f in $appliedFlags) { $lines += "   $glyphOK $f" }
        $lines += ''
    }

    $lines += '   Paths'
    $lines += '   ' + ('-' * 60)
    $lines += "   Engine log:    $engineLog"
    $lines += "   Engine JSON:   $engineLog.json"
    $guiLogDir = Get-LabGuiLogPath
    if ($guiLogDir) {
        $lines += "   GUI logs:      $guiLogDir"
    }
    $lines += ''

    $lines += '   Next steps'
    $lines += '   ' + ('-' * 60)
    $lines += "   1) Console:  Connect to $($Config.CM.Name) via Hyper-V; ConfigMgr console at"
    $lines += '      C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\Microsoft.ConfigurationManagement.exe'
    $lines += '   2) Verify:   Test-HomeLab  (re-run any time)'
    $lines += '   3) Tear-down + redeploy: Remove-HomeLab; Install-HomeLab ...'
    $lines += $banner

    foreach ($line in $lines) {
        Write-LabLog $line -Status INFO
    }

    return [pscustomobject]@{
        Health   = $health
        Accounts = $accounts
        Applied  = $appliedFlags
    }
}
