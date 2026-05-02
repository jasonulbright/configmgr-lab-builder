function Install-LabWsus {
    <#
    .SYNOPSIS
        Install WSUS (UpdateServices) on a lab VM and run wsusutil
        postinstall against the lab SQL instance.

    .DESCRIPTION
        Two-step:
          1. Install-WindowsFeature UpdateServices-Services,
             UpdateServices-DB -IncludeManagementTools
          2. wsusutil.exe postinstall SQL_INSTANCE_NAME=<server>
             CONTENT_DIR=<dir>

        Step 2 is the part that actually creates the SUSDB on SQL and
        sets up IIS sites. WsusPool tuning lives separately in S6 / S7
        (it has to wait until SUP role is added on the CM side).

        Idempotent: returns AlreadyInstalled when the WSUS service is
        Running.

        Default SQL instance is the local SQL we installed in S4
        (default instance MSSQLSERVER). Override via -SqlInstance.

    .PARAMETER ComputerName
        Target VM (typically CM01).

    .PARAMETER DomainCredential
        Domain admin credential.

    .PARAMETER ContentDir
        Local folder for WSUS update content. Default 'C:\WSUS'.
        Created if missing.

    .PARAMETER SqlInstance
        SQL Server identifier passed to wsusutil. Default
        $env:COMPUTERNAME (default instance on the same box).

    .EXAMPLE
        Install-LabWsus -ComputerName CM01 -DomainCredential $cred
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCredential,

        [Parameter()]
        [string]$ContentDir = 'C:\WSUS',

        [Parameter()]
        [string]$SqlInstance
    )

    Write-LabLog "[$ComputerName] Installing WSUS feature + postinstall" -Status RUN

    $result = Invoke-LabCommand -ComputerName $ComputerName -Credential $DomainCredential `
        -Activity 'WSUS feature + postinstall' -ScriptBlock {
            param($ContentDir, $SqlInstance)

            # Idempotency: WSUS service already up?
            $svc = Get-Service -Name WsusService -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                return [pscustomobject]@{ Status = 'AlreadyInstalled'; ContentDir = $ContentDir }
            }

            $feat = Install-WindowsFeature -Name UpdateServices-Services, UpdateServices-DB `
                -IncludeManagementTools -ErrorAction Stop
            if (-not $feat.Success) {
                throw "Install-WindowsFeature WSUS failed: $($feat | Out-String)"
            }

            if (-not (Test-Path $ContentDir)) {
                $null = New-Item -Path $ContentDir -ItemType Directory -Force
            }

            $instance = if ($SqlInstance) { $SqlInstance } else { $env:COMPUTERNAME }

            $wsusUtil = 'C:\Program Files\Update Services\Tools\wsusutil.exe'
            if (-not (Test-Path $wsusUtil)) {
                throw "wsusutil.exe missing after feature install (expected at $wsusUtil)"
            }

            $args = @(
                'postinstall',
                "SQL_INSTANCE_NAME=$instance",
                "CONTENT_DIR=$ContentDir"
            )
            $p = Start-Process -FilePath $wsusUtil -ArgumentList $args -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -ne 0) {
                throw "wsusutil postinstall returned $($p.ExitCode)"
            }

            return [pscustomobject]@{
                Status     = 'Installed'
                ContentDir = $ContentDir
                SqlInstance = $instance
                RestartNeeded = [bool]$feat.RestartNeeded
            }
        } -ArgumentList $ContentDir, $SqlInstance

    Write-LabLog "[$ComputerName] WSUS $($result.Status)" -Status OK
    return $result
}
