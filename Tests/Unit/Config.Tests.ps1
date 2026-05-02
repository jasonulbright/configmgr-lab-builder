#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Get-LabConfig validation behavior.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    . (Join-Path $script:helpersRoot 'Get-LabConfig.ps1')

    $script:repoRoot = Resolve-Path "$PSScriptRoot\..\.."
    $script:liveConfig = Join-Path $script:repoRoot 'config.psd1'

    $script:fixtureDir = Join-Path $TestDrive 'config-fixtures'
    New-Item -Path $script:fixtureDir -ItemType Directory -Force | Out-Null

    function New-MinimalConfigFile {
        param([string]$Path, [hashtable]$Override = @{})
        $cfg = @{
            LabName        = 'TestLab'
            DomainName     = 'contoso.com'
            SiteCode       = 'MCM'
            SiteName       = 'Test Lab Primary'
            Network        = '192.168.50'
            AdminUser      = 'LabAdmin'
            AdminPass      = 'P@ssw0rd!'
            ServerOSFilter = 'Windows Server 2025*'
            ClientOSFilter = 'Windows 11*'
            DC             = @{ Name='DC01'; IP='192.168.50.10'; Memory=2GB; MinMemory=1GB; MaxMemory=2GB; Processors=2 }
            CM             = @{ Name='CM01'; IP='192.168.50.20'; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
            Client         = @{ Name='CLIENT01'; IP='192.168.50.100'; Memory=4GB; MinMemory=2GB; MaxMemory=4GB; Processors=2 }
            ServiceAccounts = @{
                ClientPush = @{ Name='svc-CMPush'; Password='p1' }
                NAA        = @{ Name='svc-CMNAA'; Password='p2' }
                Join       = @{ Name='svc-CMJoin'; Password='p3' }
            }
        }
        foreach ($k in $Override.Keys) { $cfg[$k] = $Override[$k] }

        # Emit the file as a PowerShell data hash literal.
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('@{')
        foreach ($entry in $cfg.GetEnumerator()) {
            $val = $entry.Value
            $repr = if ($val -is [string]) {
                "'$($val.Replace("'","''"))'"
            } elseif ($val -is [hashtable]) {
                $inner = [System.Text.StringBuilder]::new()
                [void]$inner.Append('@{ ')
                foreach ($k in $val.Keys) {
                    $v = $val[$k]
                    $vRepr = if ($v -is [string]) { "'$($v.Replace("'","''"))'" }
                             elseif ($v -is [hashtable]) {
                                 $a = [System.Text.StringBuilder]::new()
                                 [void]$a.Append('@{ ')
                                 foreach ($kk in $v.Keys) {
                                     $vv = $v[$kk]
                                     $vvRepr = if ($vv -is [string]) { "'$($vv.Replace("'","''"))'" } else { "$vv" }
                                     [void]$a.Append("$kk = $vvRepr; ")
                                 }
                                 [void]$a.Append('}')
                                 $a.ToString()
                             }
                             else { "$v" }
                    [void]$inner.Append("$k = $vRepr; ")
                }
                [void]$inner.Append('}')
                $inner.ToString()
            } else {
                "$val"
            }
            [void]$sb.AppendLine("    $($entry.Key) = $repr")
        }
        [void]$sb.AppendLine('}')
        Set-Content -Path $Path -Value $sb.ToString() -Encoding UTF8
    }
}

Describe 'Get-LabConfig with the live repo config.psd1' {

    It 'loads without error' {
        { Get-LabConfig -Path $script:liveConfig } | Should -Not -Throw
    }

    It 'returns the expected SiteCode' {
        (Get-LabConfig -Path $script:liveConfig).SiteCode | Should -Be 'MCM'
    }

    It 'computes NetBIOS' {
        (Get-LabConfig -Path $script:liveConfig).NetBIOS | Should -Be 'CONTOSO'
    }

    It 'computes DomainDN' {
        (Get-LabConfig -Path $script:liveConfig).DomainDN | Should -Be 'DC=contoso,DC=com'
    }

    It 'records ConfigPath' {
        (Get-LabConfig -Path $script:liveConfig).ConfigPath | Should -Be (Resolve-Path $script:liveConfig).Path
    }
}

Describe 'Get-LabConfig validation failures' {

    It 'throws when the file is missing' {
        { Get-LabConfig -Path (Join-Path $TestDrive 'no-such.psd1') } |
            Should -Throw "*config file not found*"
    }

    It 'throws when SiteCode is not 3 characters' {
        $p = Join-Path $script:fixtureDir 'badsite.psd1'
        New-MinimalConfigFile -Path $p -Override @{ SiteCode = 'TOOLONG' }
        { Get-LabConfig -Path $p } | Should -Throw "*SiteCode must be 3 characters*"
    }

    It 'throws when MinMemory exceeds MaxMemory' {
        $p = Join-Path $script:fixtureDir 'memswap.psd1'
        New-MinimalConfigFile -Path $p -Override @{
            CM = @{ Name='CM01'; IP='192.168.50.20'; Memory=10GB; MinMemory=12GB; MaxMemory=4GB; Processors=4 }
        }
        { Get-LabConfig -Path $p } | Should -Throw "*MinMemory*exceeds MaxMemory*"
    }

    It 'throws when an IP is outside the configured network prefix' {
        $p = Join-Path $script:fixtureDir 'badip.psd1'
        New-MinimalConfigFile -Path $p -Override @{
            CM = @{ Name='CM01'; IP='10.0.0.20'; Memory=10GB; MinMemory=4GB; MaxMemory=12GB; Processors=4 }
        }
        { Get-LabConfig -Path $p } | Should -Throw "*not in network prefix*"
    }

    It 'throws when a service-account Name is empty' {
        # Per S15 design, Password on individual ServiceAccounts entries
        # is optional in the .psd1 -- Install-HomeLab injects it from
        # -LabPassword / $env:HOMELAB_PASSWORD at deploy time. Name is
        # still required because it becomes the AD sAMAccountName and
        # cannot be derived.
        $p = Join-Path $script:fixtureDir 'emptyname.psd1'
        New-MinimalConfigFile -Path $p -Override @{
            ServiceAccounts = @{
                ClientPush = @{ Name=''; Password='p1' }
                NAA        = @{ Name='svc-CMNAA'; Password='p2' }
                Join       = @{ Name='svc-CMJoin'; Password='p3' }
            }
        }
        { Get-LabConfig -Path $p } | Should -Throw "*ClientPush.Name is empty*"
    }
}
