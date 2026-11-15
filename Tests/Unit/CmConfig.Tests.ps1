#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the S7 CM-config + tools helpers. All 12 functions
    are remote-call orchestrators wrapping CM cmdlets via Invoke-LabCommand;
    parameter validation + idempotency-shape coverage. Live behavior
    tested in Tests/Integration/.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    $script:cfgRoot     = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\09-CMConfig"
    $script:toolsRoot   = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\10-Tools"

    . (Join-Path $script:helpersRoot 'Write-LabLog.ps1')
    . (Join-Path $script:helpersRoot 'Wait-LabReady.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabSession.ps1')
    . (Join-Path $script:helpersRoot 'Invoke-LabCommand.ps1')
    . (Join-Path $script:helpersRoot 'Copy-LabFile.ps1')

    Get-ChildItem $script:cfgRoot   -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    Get-ChildItem $script:toolsRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function New-FakeCred {
        $sec = ConvertTo-SecureString -String 'p' -AsPlainText -Force
        New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $sec)
    }
}

Describe 'Set-CMDiscovery' {
    It 'rejects a non-3-character SiteCode' {
        { Set-CMDiscovery -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'XX' -DomainDN 'DC=contoso,DC=com' } |
            Should -Throw '*length*'
    }
    It 'rejects DeltaIntervalMinutes outside 1-1440' {
        { Set-CMDiscovery -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -DomainDN 'DC=contoso,DC=com' -DeltaIntervalMinutes 0 } |
            Should -Throw '*minimum allowed range*'
    }
    It 'invokes Invoke-LabCommand once with the supplied args' {
        $script:tries = 0
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:tries++
            $script:capturedArgs = $ArgumentList
        }
        Set-CMDiscovery -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -DomainDN 'DC=contoso,DC=com' -DeltaIntervalMinutes 7
        $script:tries | Should -Be 1
        $script:capturedArgs[0] | Should -Be 'MCM'
        $script:capturedArgs[1] | Should -Be 'DC=contoso,DC=com'
        $script:capturedArgs[2] | Should -Be 7
    }
}

Describe 'New-CMBoundary' {
    It 'rejects a non-CIDR subnet' {
        { New-CMBoundary -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -Subnet '192.168.50.0' } |
            Should -Throw '*does not match*'
    }
    It 'returns AlreadyExists when the boundary is found' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ BoundaryId = 42; DisplayName = '192.168.50.0/24'; Action = 'AlreadyExists' }
        }
        $r = New-CMBoundary -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -Subnet '192.168.50.0/24'
        $r.Action     | Should -Be 'AlreadyExists'
        $r.BoundaryId | Should -Be 42
    }
}

Describe 'New-CMBoundaryGroup' {
    It 'requires SiteSystemServerFqdn' {
        { New-CMBoundaryGroup -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -Name 'BG' -BoundaryId 1 } |
            Should -Throw '*SiteSystemServerFqdn*'
    }
    It 'returns AlreadyExists when the group already exists' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ GroupId = 100; Name = 'BG'; Action = 'AlreadyExists'
                                       BoundaryAdded = $false; SiteSystemAdded = $false }
        }
        $r = New-CMBoundaryGroup -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -Name 'BG' -BoundaryId 1 -SiteSystemServerFqdn 'CM01.contoso.com'
        $r.Action | Should -Be 'AlreadyExists'
    }
}

Describe 'New-CMDistributionPointGroup' {
    It "defaults Name to 'All DPs'" {
        $script:capturedName = $null
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:capturedName = $ArgumentList[1]
            return [pscustomobject]@{ GroupName = $ArgumentList[1]; Action = 'Created'; DPAdded = $true; DPName = 'CM01' }
        }
        New-CMDistributionPointGroup -ComputerName CM01 -DomainCredential (New-FakeCred) -SiteCode MCM | Out-Null
        $script:capturedName | Should -Be 'All DPs'
    }
}

Describe 'Set-CMServiceAccount' {
    It 'rejects a missing PushPassword' {
        { Set-CMServiceAccount -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -PushAccount 'CONTOSO\svc-CMPush' -PushPassword '' `
            -NAAAccount 'CONTOSO\svc-CMNAA' -NAAPassword 'p' } |
            Should -Throw '*null*empty*'
    }
}

Describe 'Set-CMClientPush' {
    It 'rejects a non-3 SiteCode' {
        { Set-CMClientPush -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'XX' -PushAccount 'CONTOSO\svc-CMPush' } |
            Should -Throw '*length*'
    }
}

Describe 'Set-CMSoftwareDistributionThreads' {
    It 'rejects MaximumThreadCountPerPackage outside 1-50' {
        { Set-CMSoftwareDistributionThreads -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode MCM -NAAAccount 'CONTOSO\svc-CMNAA' -MaximumThreadCountPerPackage 100 } |
            Should -Throw '*maximum allowed range*'
    }
    It 'rejects MaximumPackageCount outside 1-25' {
        { Set-CMSoftwareDistributionThreads -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode MCM -NAAAccount 'CONTOSO\svc-CMNAA' -MaximumPackageCount 99 } |
            Should -Throw '*maximum allowed range*'
    }
}

Describe 'Add-CMFullAdministrator' {
    It 'rejects a UserName without DOMAIN\\sAM format' {
        { Add-CMFullAdministrator -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -UserName 'no-slash' } |
            Should -Throw '*does not match*'
    }
    It 'reports AlreadyExists when the user already has a role' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ Action = 'AlreadyExists'; UserName = 'CONTOSO\svc-CMAdmin' }
        }
        $r = Add-CMFullAdministrator -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -UserName 'CONTOSO\svc-CMAdmin'
        $r.Action | Should -Be 'AlreadyExists'
    }
}

Describe 'New-CMContentShare' {

    BeforeEach {
        $script:captured = $null
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:captured = @{ Args = $ArgumentList; Body = $ScriptBlock.ToString() }
            return [pscustomobject]@{ SharePath = 'C:\ContentShare'; ShareName = 'ContentShare$'
                                       ShareCreated = $true; ShareRepaired = @()
                                       FolderCount = $ArgumentList[2].Count }
        }
    }

    It 'forwards default Folders to the inside-VM script' {
        New-CMContentShare -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -NetBIOSName CONTOSO -NAAAccount svc-CMNAA -AdminUser LabAdmin | Out-Null
        $script:captured.Args[2] | Should -Contain 'Applications'
        $script:captured.Args[2] | Should -Contain 'SoftwareUpdates'
    }

    It 'requires AdminUser' {
        { New-CMContentShare -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -NetBIOSName CONTOSO -NAAAccount svc-CMNAA } |
            Should -Throw '*AdminUser*'
    }

    It 'forwards AdminUser to the inside-VM script' {
        New-CMContentShare -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -NetBIOSName CONTOSO -NAAAccount svc-CMNAA -AdminUser LabAdmin | Out-Null
        $script:captured.Args[5] | Should -Be 'LabAdmin'
    }

    # An admin's UAC-filtered token marks Administrators and Domain Admins
    # use-for-deny-only, so a share whose only Full grants are those two is
    # unreachable from a non-elevated Explorer session on the site server.
    # The lab admin must be granted by user SID on BOTH layers.
    It 'grants the lab admin on the share and on NTFS' {
        New-CMContentShare -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -NetBIOSName CONTOSO -NAAAccount svc-CMNAA -AdminUser LabAdmin | Out-Null
        $body = $script:captured.Body
        $body.Contains('"$NetBIOS\$AdminUser"') | Should -BeTrue
        # ...and on NTFS, not just the share.
        ([regex]::Matches($body, 'FileSystemAccessRule')).Count | Should -BeGreaterThan 3
    }

    # The repair path used to reconcile only SYSTEM and the computer account,
    # so a share missing its Domain Admins grant stayed broken while the
    # function still reported OK.
    It 'reconciles every desired share ACE, not just SYSTEM and the computer account' {
        New-CMContentShare -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -NetBIOSName CONTOSO -NAAAccount svc-CMNAA -AdminUser LabAdmin | Out-Null
        $body = $script:captured.Body
        $body.Contains('desiredShare') | Should -BeTrue
        foreach ($principal in @('Domain Admins', 'NT AUTHORITY\SYSTEM', 'Domain Computers')) {
            $body.Contains($principal) | Should -BeTrue
        }
        # One reconcile loop drives both create and repair.
        ([regex]::Matches($body, 'Grant-SmbShareAccess')).Count | Should -Be 1
    }

    It 'reports which ACEs it repaired' {
        $r = New-CMContentShare -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -NetBIOSName CONTOSO -NAAAccount svc-CMNAA -AdminUser LabAdmin
        $r.PSObject.Properties.Name | Should -Contain 'ShareRepaired'
    }
}

Describe 'Install-CMSoftwareUpdatePoint' {
    It 'requires ServerFqdn' {
        { Install-CMSoftwareUpdatePoint -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' } |
            Should -Throw '*ServerFqdn*'
    }
}

Describe 'New-CMTestCollection' {
    It 'rejects a 0-hour MW duration' {
        { New-CMTestCollection -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -MaintenanceWindowDurationHours 0 } |
            Should -Throw '*minimum allowed range*'
    }
    It 'reports collection + member + MW actions' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{
                CollectionId    = 'MCM00001'
                CollectionName  = 'HomeLab - Test Deployments'
                CollectionAction = 'Created'
                DeviceMember    = 'CLIENT01'
                MemberAction    = 'Added'
                MwAction        = 'Created'
            }
        }
        $r = New-CMTestCollection -ComputerName CM01 -DomainCredential (New-FakeCred) -SiteCode 'MCM'
        $r.CollectionAction | Should -Be 'Created'
        $r.MwAction         | Should -Be 'Created'
    }
}

Describe 'Set-CMClientCacheSize' {
    It 'rejects a cache size below 256 MB' {
        { Set-CMClientCacheSize -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -SiteCode 'MCM' -MaxCacheSizeMB 128 } |
            Should -Throw '*minimum allowed range*'
    }
}

Describe 'Copy-CMTools' {
    It 'skips both tools when neither source is present' {
        $env:USERPROFILE_OK = $true
        Mock Invoke-LabCommand -MockWith { } -Verifiable
        Mock Copy-LabFile -MockWith { }
        $r = Copy-CMTools -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -ClientCenterZipPath 'C:\does-not-exist.zip' `
            -AppPackagerSourcePath 'C:\does-not-exist'
        $r.ClientCenter | Should -BeNullOrEmpty
        $r.AppPackager  | Should -BeNullOrEmpty
    }
}

Describe 'Set-LabAutoStartStop' {
    It 'rejects an empty VMs array' {
        { Set-LabAutoStartStop -VMs @() } |
            Should -Throw '*null*empty*'
    }
    It 'rejects an unsupported AutoStartAction' {
        { Set-LabAutoStartStop -VMs @([pscustomobject]@{ Name = 'DC01'; AutoStartDelay = 30 }) `
            -AutoStartAction 'Pause' } |
            Should -Throw '*ValidateSet*'
    }
}

Describe 'Set-CMAdminServiceCertificate' {
    It 'rejects a domain name that is not a DNS name' {
        { Set-CMAdminServiceCertificate -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -DomainName 'notadomain' } | Should -Throw '*does not match*'
    }
    It 'rejects MinValidDays below 1' {
        { Set-CMAdminServiceCertificate -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -DomainName 'contoso.com' -MinValidDays 0 } | Should -Throw '*minimum allowed range*'
    }
    It 'builds the subject FQDN from the short name and the domain, and passes PlanOnly' {
        Mock Write-LabLog { }
        Mock Invoke-LabCommand -MockWith {
            [pscustomobject]@{ Status = 'Plan'; Thumbprint = 'AA'; OldThumbprint = 'BB'; OldAppId = 'x' }
        }
        $r = Set-CMAdminServiceCertificate -ComputerName 'CM01.contoso.com' `
            -DomainCredential (New-FakeCred) -DomainName 'contoso.com' -PlanOnly
        $r.Status | Should -Be 'Plan'
        Should -Invoke Invoke-LabCommand -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'CM01.contoso.com' -and
            $ArgumentList[1] -eq 'CM01' -and
            $ArgumentList[2] -eq 'WebServer' -and
            $ArgumentList[5] -eq $true
        }
    }
    It 'keeps the undo data of a real bind in the result' {
        Mock Write-LabLog { }
        Mock Invoke-LabCommand -MockWith {
            [pscustomobject]@{ Status = 'Bound'; Thumbprint = 'AA'; OldThumbprint = 'BB'; OldAppId = 'x' }
        }
        $r = Set-CMAdminServiceCertificate -ComputerName CM01 `
            -DomainCredential (New-FakeCred) -DomainName 'contoso.com'
        $r.OldThumbprint | Should -Be 'BB'
        $r.OldAppId      | Should -Be 'x'
    }
    It 'is idempotent: the guest script sees the same binding and reports AlreadyBound' {
        Mock Write-LabLog { }
        Mock Invoke-LabCommand -MockWith {
            [pscustomobject]@{ Status = 'AlreadyBound'; Thumbprint = 'AA'; OldThumbprint = 'AA'; OldAppId = 'x' }
        }
        (Set-CMAdminServiceCertificate -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -DomainName 'contoso.com').Status | Should -Be 'AlreadyBound'
    }
}

Describe 'Set-CMAdminServiceCertificate guest script' {
    # The guest script runs on CM01. Static checks keep the security-relevant
    # choices from drifting without a lab run.
    BeforeAll {
        $script:guest = Get-Content -Raw (Join-Path $script:cfgRoot 'Set-CMAdminServiceCertificate.ps1')
    }
    It 'never accepts a certificate issued by SMS Issuing or self-signed' {
        $script:guest | Should -Match "Issuer -notmatch 'SMS Issuing'"
        $script:guest | Should -Match '\$_\.Issuer -ne \$_\.Subject'
    }
    It 'requires the server authentication EKU' {
        $script:guest | Should -Match '1\.3\.6\.1\.5\.5\.7\.3\.1'
    }
    It 'reuses the old application id so the IIS binding keeps its owner' {
        $script:guest | Should -Match 'appid="\{\$appId\}"'
    }
    It 'restores the old binding when the add fails' {
        $script:guest | Should -Match 'old binding restored'
    }
    It 'checks what port 443 presents and throws on a mismatch' {
        $script:guest | Should -Match "Port 443 presents"
    }
    It 'rolls the old binding back when port 443 presents the wrong certificate' {
        $script:guest | Should -Match 'Rollback: \$rollback'
    }
    It 'retries the certificate request while the template and ACL propagate' {
        $script:guest | Should -Match 'enrollDeadline'
    }
    It 'makes no change in PlanOnly before the binding code' {
        $planIdx = $script:guest.IndexOf('if ($PlanOnly) {', $script:guest.IndexOf('$bound = Get-BoundHttpSys'))
        $netshIdx = $script:guest.IndexOf('netsh http delete sslcert ipport=0.0.0.0:443 | Out-Null')
        $planIdx | Should -BeGreaterThan 0
        $planIdx | Should -BeLessThan $netshIdx
    }
}

Describe 'Enable-CMEnhancedHttp' {
    It 'rejects a non-3-character SiteCode' {
        { Enable-CMEnhancedHttp -ComputerName CM01 -DomainCredential (New-FakeCred) -SiteCode 'XX' } |
            Should -Throw '*length*'
    }
    It 'reports the guest status' {
        Mock Write-LabLog { }
        Mock Invoke-LabCommand -MockWith { [pscustomobject]@{ Status = 'AlreadyEnabled' } }
        (Enable-CMEnhancedHttp -ComputerName CM01 -DomainCredential (New-FakeCred) -SiteCode 'MCM').Status |
            Should -Be 'AlreadyEnabled'
    }
}

Describe 'Test-CMAdminServiceTrust' {
    It 'returns Trusted false with the error text for an untrusted chain' {
        Mock Invoke-LabCommand -MockWith {
            [pscustomobject]@{ Trusted = $false; Subject = $null; Issuer = $null; Error = 'remote certificate is invalid' }
        }
        $r = Test-CMAdminServiceTrust -ComputerName CLIENT01 -DomainCredential (New-FakeCred) `
            -ProviderFqdn 'CM01.contoso.com'
        $r.Trusted | Should -BeFalse
        $r.Error   | Should -Match 'invalid'
    }
    It 'returns Trusted true for a trusted chain' {
        Mock Invoke-LabCommand -MockWith {
            [pscustomobject]@{ Trusted = $true; Subject = 'CN=CM01.contoso.com'; Issuer = 'CN=CONTOSO Root CA, DC=contoso, DC=com'; Error = $null }
        }
        (Test-CMAdminServiceTrust -ComputerName CLIENT01 -DomainCredential (New-FakeCred) `
            -ProviderFqdn 'CM01.contoso.com').Trusted | Should -BeTrue
    }
}
