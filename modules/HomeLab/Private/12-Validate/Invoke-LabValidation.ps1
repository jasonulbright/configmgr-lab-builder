function Invoke-LabValidation {
    <#
    .SYNOPSIS
        Prove that a finished lab is healthy out of the box.

    .DESCRIPTION
        Runs these checks and returns one result object per check
        (Name, Target, Passed, Detail):

          WinRM             every VM answers a command over WinRM.
          ManagedClient     on each client VM: CcmExec is running and the
                            client is assigned to the site code; the site
                            reports Client = 1 for the client device.
          Console           the ConfigMgr console and its PowerShell module
                            exist on the site server and on each client VM.
          AdminServiceTrust each client VM opens a TLS connection to the SMS
                            Provider on port 443 with its own trust store
                            and no certificate error.
          AdminServiceRest  from each client VM, GET /AdminService/wmi/SMS_Site
                            returns the site code.
          CMPivot           from each client VM, a CMPivot query for the
                            client itself returns rows through the
                            administration service.

        The managed-client and CMPivot checks poll, because a new client
        needs time to register and to receive client policy. Each check
        reports the last error when it ends in failure.

        By default the function throws after it has run every check when any
        check failed. -NoThrow returns the results only.

    .PARAMETER SiteServer
        Short name of the site server and SMS Provider (for example CM01).

    .PARAMETER DomainName
        DNS domain (for example contoso.com).

    .PARAMETER SiteCode
        Three-letter site code.

    .PARAMETER ClientNames
        Short names of the client VMs. May be empty.

    .PARAMETER AllVmNames
        Short names of every VM, for the WinRM check.

    .PARAMETER DomainCredential
        Domain admin credential. It authenticates the WinRM sessions and the
        REST calls the client VMs make.

    .PARAMETER TimeoutMinutes
        Polling limit per polling check. Default 15.

    .PARAMETER NoThrow
        Return the results and do not throw on a failed check.

    .EXAMPLE
        Invoke-LabValidation -SiteServer CM01 -DomainName contoso.com -SiteCode MCM `
            -ClientNames CLIENT01 -AllVmNames DC01,CM01,CLIENT01 -DomainCredential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteServer,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$')]
        [string]$DomainName,

        [Parameter(Mandatory)]
        [ValidateLength(3,3)]
        [string]$SiteCode,

        [Parameter()]
        [string[]]$ClientNames = @(),

        [Parameter(Mandatory)]
        [string[]]$AllVmNames,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter()]
        [ValidateRange(1, 240)]
        [int]$TimeoutMinutes = 15,

        [Parameter()]
        [switch]$NoThrow
    )

    $providerFqdn = "$SiteServer.$DomainName"
    $results = New-Object System.Collections.Generic.List[object]

    function Add-Result {
        param([string]$Name, [string]$Target, [bool]$Passed, [string]$Detail)
        $results.Add([pscustomobject]@{ Name = $Name; Target = $Target; Passed = $Passed; Detail = $Detail })
        $tag = if ($Passed) { 'OK' } else { 'FAIL' }
        Write-LabLog "[validate] $Name on ${Target}: $Detail" -Status $tag
    }

    Write-LabLog 'Validating the lab (WinRM, managed client, console, admin service, CMPivot)' -Status RUN

    # --- WinRM ---------------------------------------------------------
    foreach ($vm in $AllVmNames) {
        try {
            $name = Invoke-LabCommand -ComputerName "$vm.$DomainName" -Credential $DomainCredential `
                -Activity $null -ScriptBlock { [pscustomobject]@{ Name = $env:COMPUTERNAME } }
            Add-Result 'WinRM' $vm $true "answered as $($name.Name)"
        } catch {
            Add-Result 'WinRM' $vm $false $_.Exception.Message.Split([char]10)[0]
        }
    }

    # --- Console on the site server ------------------------------------
    $consoleProbe = {
        $ui = [Environment]::GetEnvironmentVariable('SMS_ADMIN_UI_PATH', 'Machine')
        $module = $null
        if ($ui) { $module = Join-Path $ui '..\ConfigurationManager.psd1' }
        $exe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Configuration Manager\AdminConsole\bin\Microsoft.ConfigurationManagement.exe'
        [pscustomobject]@{
            Exe    = (Test-Path -Path $exe)
            Module = [bool]($module -and (Test-Path -Path $module))
        }
    }
    try {
        $c = Invoke-LabCommand -ComputerName $providerFqdn -Credential $DomainCredential -Activity $null -ScriptBlock $consoleProbe
        Add-Result 'Console' $SiteServer ($c.Exe -and $c.Module) "console exe=$($c.Exe) module=$($c.Module)"
    } catch {
        Add-Result 'Console' $SiteServer $false $_.Exception.Message.Split([char]10)[0]
    }

    foreach ($client in $ClientNames) {
        $clientFqdn = "$client.$DomainName"

        try {
            $c = Invoke-LabCommand -ComputerName $clientFqdn -Credential $DomainCredential -Activity $null -ScriptBlock $consoleProbe
            Add-Result 'Console' $client ($c.Exe -and $c.Module) "console exe=$($c.Exe) module=$($c.Module)"
        } catch {
            Add-Result 'Console' $client $false $_.Exception.Message.Split([char]10)[0]
        }

        # --- Managed client, admin service, CMPivot (all from the client) --
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $r = $null
        do {
            try {
                $r = Invoke-LabCommand -ComputerName $clientFqdn -Credential $DomainCredential `
                    -Activity $null -ArgumentList $providerFqdn, $SiteCode, $client, $DomainCredential -ScriptBlock {
                        param($Provider, $SiteCode, $ClientName, $Cred)
                        $o = [ordered]@{
                            CcmExec = $false; Authority = $null; SiteClient = $null
                            Trusted = $false; TrustError = $null
                            RestSite = $null; RestError = $null
                            PivotRows = $null; PivotError = $null
                        }
                        $svc = Get-Service -Name CcmExec -ErrorAction SilentlyContinue
                        $o.CcmExec = [bool]($svc -and $svc.Status -eq 'Running')
                        $auth = Get-CimInstance -Namespace root\ccm -ClassName SMS_Authority -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($auth) { $o.Authority = [string]$auth.Name }

                        $tcp = New-Object System.Net.Sockets.TcpClient
                        try {
                            $tcp.Connect($Provider, 443)
                            $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false)
                            $ssl.AuthenticateAsClient($Provider)
                            $o.Trusted = $true
                        } catch {
                            $o.TrustError = $_.Exception.Message
                        } finally {
                            $tcp.Close()
                        }

                        if ($o.Trusted) {
                            $base = "https://$Provider/AdminService"
                            try {
                                $site = Invoke-RestMethod -Uri "$base/wmi/SMS_Site" -Credential $Cred -ErrorAction Stop
                                $o.RestSite = [string]$site.value[0].SiteCode
                                $dev = (Invoke-RestMethod -Uri "$base/wmi/SMS_R_System?`$filter=Name eq '$ClientName'" -Credential $Cred -ErrorAction Stop).value | Select-Object -First 1
                                if ($dev) {
                                    $o.SiteClient = [int]$dev.Client
                                    $body = @{ InputQuery = 'OperatingSystem | project Caption' } | ConvertTo-Json
                                    $run = Invoke-RestMethod -Uri "$base/v1.0/Device($($dev.ResourceId))/AdminService.RunCMPivot" `
                                        -Method Post -Body $body -ContentType 'application/json' -Credential $Cred -ErrorAction Stop
                                    $opId = $run.value.OperationId
                                    $end = (Get-Date).AddMinutes(2)
                                    do {
                                        Start-Sleep -Seconds 5
                                        try {
                                            $res = Invoke-RestMethod -Uri "$base/v1.0/Device($($dev.ResourceId))/AdminService.CMPivotResult(OperationId=$opId)" -Credential $Cred -ErrorAction Stop
                                            $o.PivotRows = @($res.value).Count
                                        } catch {
                                            $o.PivotError = $_.Exception.Message
                                        }
                                    } while (-not $o.PivotRows -and (Get-Date) -lt $end)
                                }
                            } catch {
                                $o.RestError = $_.Exception.Message
                            }
                        }
                        [pscustomobject]$o
                    }
            } catch {
                $r = $null
            }
            $ready = $r -and $r.CcmExec -and ($r.Authority -eq "SMS:$SiteCode") -and ($r.SiteClient -eq 1) -and $r.Trusted -and $r.RestSite -and $r.PivotRows
            if (-not $ready -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 30 }
        } while (-not $ready -and (Get-Date) -lt $deadline)

        if (-not $r) {
            foreach ($n in 'ManagedClient', 'AdminServiceTrust', 'AdminServiceRest', 'CMPivot') {
                Add-Result $n $client $false 'the client check did not run'
            }
            continue
        }
        Add-Result 'ManagedClient' $client ($r.CcmExec -and $r.Authority -eq "SMS:$SiteCode" -and $r.SiteClient -eq 1) `
            "CcmExec=$($r.CcmExec) authority=$($r.Authority) site Client=$($r.SiteClient)"
        Add-Result 'AdminServiceTrust' $client $r.Trusted $(if ($r.Trusted) { 'chain trusted' } else { $r.TrustError })
        Add-Result 'AdminServiceRest' $client ($r.RestSite -eq $SiteCode) $(if ($r.RestSite) { "SMS_Site returned $($r.RestSite)" } else { $r.RestError })
        Add-Result 'CMPivot' $client ([bool]$r.PivotRows) $(if ($r.PivotRows) { "$($r.PivotRows) row(s) returned" } else { "no rows: $($r.PivotError)$($r.RestError)" })
    }

    $failed = @($results | Where-Object { -not $_.Passed })
    if ($failed.Count -eq 0) {
        Write-LabLog "Lab validation passed ($($results.Count) checks)" -Status OK
    } else {
        Write-LabLog "Lab validation failed: $($failed.Count) of $($results.Count) checks" -Status FAIL
        if (-not $NoThrow) {
            throw "Lab validation failed: $(($failed | ForEach-Object { "$($_.Name) on $($_.Target)" }) -join '; ')"
        }
    }
    return $results.ToArray()
}
