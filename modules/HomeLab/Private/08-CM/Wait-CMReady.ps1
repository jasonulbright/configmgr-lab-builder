function Wait-CMReady {
    <#
    .SYNOPSIS
        Block until the CM site is operational: SMS_EXECUTIVE running and
        the CM provider WMI namespace returns Get-CimInstance SMS_Site
        with a matching SiteCode.

    .DESCRIPTION
        After Install-CMSite.ps1 reports "successfully installed", the
        CM provider takes another 1-6 minutes to initialize. Set-Location
        '<Site>:' fails during that window with
        "Drive '<Site>' does not exist." This gate is the difference
        between immediate-fail-on-first-cmdlet and a clean ready signal.

        Wraps Wait-LabReady with a predicate that:
          1. Runs Get-Service SMS_EXECUTIVE inside the VM; aborts the
             attempt if not Running
          2. Queries SMS_Site in ROOT\SMS\site_<SiteCode>; succeeds when
             a site with the expected SiteCode is returned

        AL's cadence: 12 attempts at 30s = 6 min, then 6 attempts at 60s
        = another 6 min. We replicate via -TimeoutSeconds and
        -IntervalSeconds; defaults are 720s / 30s.

    .PARAMETER ComputerName
        DNS / short name of the CM site server.

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER SiteCode
        Expected 3-letter site code.

    .PARAMETER TimeoutSeconds
        Hard ceiling. Default 720 (12 min).

    .PARAMETER IntervalSeconds
        Poll interval. Default 30.

    .PARAMETER ThrowOnTimeout
        Throw a TimeoutException on timeout. Default false (returns false).

    .EXAMPLE
        Wait-CMReady -ComputerName CM01 -DomainCredential $cred -SiteCode MCM -ThrowOnTimeout
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter(Mandatory)]
        [ValidateLength(3,3)]
        [string]$SiteCode,

        [Parameter()]
        [int]$TimeoutSeconds = 720,

        [Parameter()]
        [int]$IntervalSeconds = 30,

        [Parameter()]
        [switch]$ThrowOnTimeout
    )

    $activity = "[$ComputerName] CM site $SiteCode (SMS_EXECUTIVE + provider)"
    Write-LabLog "Waiting for $activity (timeout ${TimeoutSeconds}s, interval ${IntervalSeconds}s)" -Status RUN

    $start    = Get-Date
    $deadline = $start.AddSeconds($TimeoutSeconds)
    $attempt  = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++
        $ready = $false
        try {
            $r = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
                -ScriptBlock {
                    param($Site)
                    $svc = Get-Service -Name SMS_EXECUTIVE -ErrorAction SilentlyContinue
                    if (-not $svc -or $svc.Status -ne 'Running') {
                        return [pscustomobject]@{ Ready = $false; Reason = 'SMS_EXECUTIVE not running' }
                    }
                    try {
                        $cm = Get-CimInstance -Namespace "ROOT\SMS\site_$Site" -ClassName SMS_Site -ErrorAction Stop |
                            Where-Object { $_.SiteCode -eq $Site } | Select-Object -First 1
                        if ($cm) {
                            return [pscustomobject]@{ Ready = $true; Reason = 'SMS_Site returned' }
                        }
                        return [pscustomobject]@{ Ready = $false; Reason = 'SMS_Site empty' }
                    } catch {
                        return [pscustomobject]@{ Ready = $false; Reason = "WMI: $($_.Exception.Message)" }
                    }
                } -ArgumentList $SiteCode
            $ready = [bool]$r.Ready
        } catch {
            $ready = $false
        }

        if ($ready) {
            $elapsed = ((Get-Date) - $start).TotalSeconds
            Write-LabLog ("$activity ready after attempt {0} ({1:F1}s)" -f $attempt, $elapsed) -Status OK
            return $true
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-LabLog "$activity not ready after ${TimeoutSeconds}s ($attempt attempts)" -Status FAIL
    if ($ThrowOnTimeout) {
        throw [System.TimeoutException]::new("Wait-CMReady: '$activity' did not become ready within ${TimeoutSeconds}s")
    }
    return $false
}
