#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the S3 domain helpers (Install-LabDC,
    Install-LabRootCA, Add-LabSchemaContainer, Join-LabDomain,
    New-LabServiceAccounts). These are orchestrators that wrap remote
    AD/ADCS work via Invoke-LabCommand; full E2E lives in
    Tests/Integration/. Here we cover parameter validation and the
    pure-logic spec-shaping done before the remote call.
#>

BeforeAll {
    $script:domainRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\05-Domain"
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"

    # Load helpers the S3 functions depend on
    . (Join-Path $script:helpersRoot 'Write-LabLog.ps1')
    . (Join-Path $script:helpersRoot 'Wait-LabReady.ps1')
    . (Join-Path $script:helpersRoot 'Get-LabSession.ps1')
    . (Join-Path $script:helpersRoot 'Invoke-LabCommand.ps1')

    # Load the S3 functions
    . (Join-Path $script:domainRoot 'Install-LabDC.ps1')
    . (Join-Path $script:domainRoot 'Install-LabRootCA.ps1')
    . (Join-Path $script:domainRoot 'Add-LabSchemaContainer.ps1')
    . (Join-Path $script:domainRoot 'Join-LabDomain.ps1')
    . (Join-Path $script:domainRoot 'New-LabServiceAccounts.ps1')
    . (Join-Path $script:domainRoot 'Enable-LabClientPushFirewall.ps1')

    function New-FakeCred {
        param([string]$User = 'Administrator', [string]$Pass = 'p')
        $sec = ConvertTo-SecureString -String $Pass -AsPlainText -Force
        New-Object System.Management.Automation.PSCredential($User, $sec)
    }

    $script:goodAccounts = @{
        ClientPush = @{ Name = 'svc-CMPush';  Password = 'p1'; Desc = 'push' }
        NAA        = @{ Name = 'svc-CMNAA';   Password = 'p2'; Desc = 'naa'  }
        Join       = @{ Name = 'svc-CMJoin'; Password = 'p3'; Desc = 'osd-join' }
    }
}

Describe 'Install-LabDC parameter validation' {

    It 'rejects a non-FQDN domain name' {
        { Install-LabDC -ComputerName DC01 -LocalCredential (New-FakeCred) `
                        -DomainName 'notafqdn' `
                        -SafeModeAdministratorPassword (ConvertTo-SecureString 'p' -AsPlainText -Force) } |
            Should -Throw "*does not match*"
    }

    It 'accepts a typical lab domain' {
        # We can not actually reach the remote VM in unit tests; just check
        # parameter binding succeeds enough to start the function and fail
        # at the Invoke-LabCommand boundary.
        Mock Invoke-LabCommand -MockWith { throw 'unit test stop' }
        { Install-LabDC -ComputerName DC01 -LocalCredential (New-FakeCred) `
                        -DomainName 'contoso.com' `
                        -SafeModeAdministratorPassword (ConvertTo-SecureString 'p' -AsPlainText -Force) } |
            Should -Throw "*unit test stop*"
    }

    It 'derives NetBIOS from the domain name when not supplied' {
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            # Second arg passed in -ArgumentList is NetBIOSName.
            $script:capturedNetBIOS = $ArgumentList[1]
            return [pscustomobject]@{ Status = 'AlreadyPromoted'; DomainMode = 'Win2025' }
        }
        $null = Install-LabDC -ComputerName DC01 -LocalCredential (New-FakeCred) `
                              -DomainName 'contoso.com' `
                              -SafeModeAdministratorPassword (ConvertTo-SecureString 'p' -AsPlainText -Force)
        $script:capturedNetBIOS | Should -Be 'CONTOSO'
    }

    It 'uses an explicit NetBIOSName when supplied' {
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:capturedNetBIOS = $ArgumentList[1]
            return [pscustomobject]@{ Status = 'AlreadyPromoted'; DomainMode = 'Win2025' }
        }
        $null = Install-LabDC -ComputerName DC01 -LocalCredential (New-FakeCred) `
                              -DomainName 'corp.fabrikam.io' -NetBIOSName 'FABRIKAM' `
                              -SafeModeAdministratorPassword (ConvertTo-SecureString 'p' -AsPlainText -Force)
        $script:capturedNetBIOS | Should -Be 'FABRIKAM'
    }
}

Describe 'Install-LabDC DNS forwarders' {
    BeforeAll {
        # Wait-LabVM lives under Private/04-VM and is not dot-sourced by the
        # domain test setup; stub it so the post-promotion ready path runs.
        . (Join-Path $script:domainRoot '..\04-VM\Wait-LabVM.ps1')
    }

    It 'configures DNS forwarders on the ready path' {
        Mock Wait-LabVM            -MockWith { $true }
        Mock Wait-LabReady         -MockWith { $true }
        Mock Start-Sleep           -MockWith { }
        Mock Clear-LabSessionCache -MockWith { }
        $script:fwdScripts = @()
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:fwdScripts += $ScriptBlock.ToString()
            return [pscustomobject]@{ Status = 'PromotedRebootingNow' }
        }

        Install-LabDC -ComputerName DC01 -LocalCredential (New-FakeCred) `
                      -DomainName 'contoso.com' `
                      -SafeModeAdministratorPassword (ConvertTo-SecureString 'p' -AsPlainText -Force) `
                      -DnsForwarders @('1.1.1.1','8.8.8.8') | Out-Null

        ($script:fwdScripts -join "`n") | Should -Match 'Set-DnsServerForwarder'
    }

    It 'skips forwarder configuration when -DnsForwarders is empty' {
        Mock Wait-LabVM            -MockWith { $true }
        Mock Wait-LabReady         -MockWith { $true }
        Mock Start-Sleep           -MockWith { }
        Mock Clear-LabSessionCache -MockWith { }
        $script:fwdScripts2 = @()
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:fwdScripts2 += $ScriptBlock.ToString()
            return [pscustomobject]@{ Status = 'PromotedRebootingNow' }
        }

        Install-LabDC -ComputerName DC01 -LocalCredential (New-FakeCred) `
                      -DomainName 'contoso.com' `
                      -SafeModeAdministratorPassword (ConvertTo-SecureString 'p' -AsPlainText -Force) `
                      -DnsForwarders @() | Out-Null

        ($script:fwdScripts2 -join "`n") | Should -Not -Match 'Set-DnsServerForwarder'
    }
}

Describe 'Enable-LabClientPushFirewall' {

    It 'enables inbound rules via the remoting layer and reports the count' {
        Mock Write-LabLog -MockWith { }
        $script:fwArgs = $null
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:fwArgs = @{ ComputerName = $ComputerName; Activity = $Activity }
            return [pscustomobject]@{ Enabled = 12; Smb445 = $true }
        }
        $r = Enable-LabClientPushFirewall -ComputerName CLIENT01 -Credential (New-FakeCred)
        $r.Enabled | Should -Be 12
        $script:fwArgs.ComputerName | Should -Be 'CLIENT01'
    }

    It 'rejects an empty ComputerName' {
        { Enable-LabClientPushFirewall -ComputerName '' -Credential (New-FakeCred) } |
            Should -Throw '*null*empty*'
    }
}

Describe 'Install-LabRootCA parameter validation' {

    It 'rejects an unsupported KeyLength' {
        { Install-LabRootCA -ComputerName DC01 -DomainCredential (New-FakeCred) -KeyLength 1024 } |
            Should -Throw "*ValidateSet*"
    }

    It 'rejects an unsupported HashAlgorithm' {
        { Install-LabRootCA -ComputerName DC01 -DomainCredential (New-FakeCred) -HashAlgorithm SHA1 } |
            Should -Throw "*ValidateSet*"
    }

    It 'accepts the default 4096/SHA256/Years/10 set' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ Status = 'AlreadyInstalled'; CommonName = 'CONTOSO Root CA' }
        }
        { Install-LabRootCA -ComputerName DC01 -DomainCredential (New-FakeCred) } |
            Should -Not -Throw
    }
}

Describe 'Join-LabDomain parameter validation' {

    It 'rejects a non-FQDN domain name' {
        { Join-LabDomain -ComputerName CM01 `
                         -LocalCredential (New-FakeCred) `
                         -DomainCredential (New-FakeCred 'CONTOSO\Administrator') `
                         -DomainName 'notafqdn' } |
            Should -Throw "*does not match*"
    }

    It 'short-circuits when the box is already in the target domain' {
        Mock Invoke-LabCommand -MockWith {
            return [pscustomobject]@{ PartOfDomain = $true; Domain = 'contoso.com' }
        }
        $r = Join-LabDomain -ComputerName CM01 `
                            -LocalCredential (New-FakeCred) `
                            -DomainCredential (New-FakeCred 'CONTOSO\Administrator') `
                            -DomainName 'contoso.com'
        $r.Status | Should -Be 'AlreadyJoined'
    }
}

Describe 'New-LabServiceAccounts parameter validation' {

    It 'rejects a missing service-account key' {
        $bad = $script:goodAccounts.Clone()
        $bad.Remove('NAA')
        { New-LabServiceAccounts -DCComputerName DC01 `
                                 -DomainCredential (New-FakeCred) `
                                 -DomainName 'contoso.com' `
                                 -NetBIOSName 'CONTOSO' `
                                 -AdminUser 'LabAdmin' `
                                 -AdminPass 'P@ssw0rd!' `
                                 -ServiceAccounts $bad } |
            Should -Throw "*ServiceAccounts.NAA missing*"
    }

    It 'rejects an empty password in the supplied hashtable' {
        $bad = @{
            ClientPush = @{ Name = 'svc-CMPush'; Password = ''; Desc = '' }
            NAA        = @{ Name = 'svc-CMNAA'; Password = 'p'; Desc = '' }
            Join       = @{ Name = 'svc-CMJoin'; Password = 'p'; Desc = '' }
        }
        { New-LabServiceAccounts -DCComputerName DC01 `
                                 -DomainCredential (New-FakeCred) `
                                 -DomainName 'contoso.com' `
                                 -NetBIOSName 'CONTOSO' `
                                 -AdminUser 'LabAdmin' `
                                 -AdminPass 'P@ssw0rd!' `
                                 -ServiceAccounts $bad } |
            Should -Throw "*ClientPush.Password is empty*"
    }

    It 'forwards the spec to Invoke-LabCommand without string-interpolating passwords' {
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            $script:capturedScript = $ScriptBlock.ToString()
            $script:capturedArgs   = $ArgumentList
            return [pscustomobject]@{ OU = 'OU=Service Accounts,DC=contoso,DC=com'; Created = @() }
        }

        New-LabServiceAccounts -DCComputerName DC01 `
                               -DomainCredential (New-FakeCred) `
                               -DomainName 'contoso.com' `
                               -NetBIOSName 'CONTOSO' `
                               -AdminUser 'LabAdmin' `
                               -AdminPass 'P@ssw0rd!' `
                               -ServiceAccounts $script:goodAccounts

        # Script body must not contain raw passwords. The passwords are
        # forwarded via -ArgumentList (the $Accounts hashtable), not
        # inlined.
        $script:capturedScript | Should -Not -Match 'p1|p2|p3'
        # ArgumentList[4] is the accounts array: LabAdmin first, then
        # ClientPush, NAA, Join (4 entries total).
        $script:capturedArgs[4].Count | Should -Be 4
        $script:capturedArgs[4][0].Sam | Should -Be 'LabAdmin'
        $script:capturedArgs[4][1].Sam | Should -Be 'svc-CMPush'
    }
}

Describe 'Add-LabSchemaContainer parameter validation' {

    It 'requires DCComputerName' {
        { Add-LabSchemaContainer -CMComputerName CM01 -DomainCredential (New-FakeCred) } |
            Should -Throw "*DCComputerName*"
    }

    It 'requires CMComputerName' {
        { Add-LabSchemaContainer -DCComputerName DC01 -DomainCredential (New-FakeCred) } |
            Should -Throw "*CMComputerName*"
    }

    It 'defaults ExtAdSchPath to the standard CM source layout' {
        # Add-LabSchemaContainer issues two Invoke-LabCommand calls; the
        # first targets the CM server with the exe path, the second
        # targets the DC. Capture the first one only.
        $script:capturedExe = $null
        Mock Invoke-LabCommand -MockWith {
            param($ComputerName, $Credential, $ScriptBlock, $ArgumentList, $Activity)
            if ($ComputerName -eq 'CM01' -and -not $script:capturedExe) {
                $script:capturedExe = $ArgumentList[0]
            }
            return [pscustomobject]@{ ExitCode = 0; Log = ''; ContainerExisted = $false; ContainerDN = 'x'; CMAccount = 'CM01' }
        }
        Add-LabSchemaContainer -DCComputerName DC01 -CMComputerName CM01 `
                               -DomainCredential (New-FakeCred) | Out-Null
        $script:capturedExe | Should -Be 'C:\Install\CM\SMSSETUP\BIN\X64\extadsch.exe'
    }
}
