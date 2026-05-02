#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Get-LabSession cache-key behavior. Live PSSession
    behavior (open, stale, force) lives in Tests/Integration/.
#>

BeforeAll {
    $script:helpersRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Helpers"
    . (Join-Path $script:helpersRoot 'Get-LabSession.ps1')

    function New-FakeCred {
        param([string]$User)
        $sec = ConvertTo-SecureString -String 'irrelevant' -AsPlainText -Force
        New-Object System.Management.Automation.PSCredential($User, $sec)
    }
}

Describe 'Get-LabSessionCacheKey' {

    It 'lower-cases the computer name' {
        $cred = New-FakeCred 'CONTOSO\LabAdmin'
        $k = Get-LabSessionCacheKey -ComputerName 'CM01.Contoso.Com' -Credential $cred
        $k | Should -Be 'cm01.contoso.com|CONTOSO\LabAdmin'
    }

    It 'preserves case of the username (DOMAIN\user)' {
        $cred = New-FakeCred 'CONTOSO\svc-CMPush'
        $k = Get-LabSessionCacheKey -ComputerName 'cm01' -Credential $cred
        $k | Should -Match 'svc-CMPush$'
    }

    It 'returns different keys for different credentials on the same VM' {
        $a = New-FakeCred 'CONTOSO\LabAdmin'
        $b = New-FakeCred 'CONTOSO\svc-CMAdmin'
        (Get-LabSessionCacheKey -ComputerName 'cm01' -Credential $a) |
            Should -Not -Be (Get-LabSessionCacheKey -ComputerName 'cm01' -Credential $b)
    }

    It 'returns different keys for the same credential on different VMs' {
        $cred = New-FakeCred 'CONTOSO\LabAdmin'
        (Get-LabSessionCacheKey -ComputerName 'cm01' -Credential $cred) |
            Should -Not -Be (Get-LabSessionCacheKey -ComputerName 'client01' -Credential $cred)
    }
}

Describe 'Clear-LabSessionCache' {

    It 'is a no-op when cache is empty' {
        # Force-reset the cache
        $script:LabSessionCache = @{}
        { Clear-LabSessionCache } | Should -Not -Throw
        $script:LabSessionCache.Count | Should -Be 0
    }

    It 'empties a populated cache' {
        # Inject fake entries that look like PSSessions enough for Remove-PSSession
        # to fail silently with -ErrorAction SilentlyContinue.
        $script:LabSessionCache = @{
            'a|b' = [pscustomobject]@{ State = 'Opened'; Availability = 'Available' }
            'c|d' = [pscustomobject]@{ State = 'Opened'; Availability = 'Available' }
        }
        Clear-LabSessionCache
        $script:LabSessionCache.Count | Should -Be 0
    }
}
