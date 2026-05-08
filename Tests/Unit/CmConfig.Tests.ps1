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
    It 'forwards default Folders to the inside-VM script' {
        $script:capturedFolders = $null
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:capturedFolders = $ArgumentList[2]
            return [pscustomobject]@{ SharePath = 'E:\ContentShare'; ShareName = 'ContentShare$'
                                       ShareCreated = $true; FolderCount = $ArgumentList[2].Count }
        }
        New-CMContentShare -ComputerName CM01 -DomainCredential (New-FakeCred) `
            -NetBIOSName CONTOSO -NAAAccount svc-CMNAA | Out-Null
        $script:capturedFolders | Should -Contain 'Applications'
        $script:capturedFolders | Should -Contain 'SoftwareUpdates'
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
