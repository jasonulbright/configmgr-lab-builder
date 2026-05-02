#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Format-LabMacAddress.
#>

BeforeAll {
    $script:imgRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\04-VM"
    . (Join-Path $script:imgRoot 'Format-LabMacAddress.ps1')
    . (Join-Path $script:imgRoot 'New-LabMacAddress.ps1')
}

Describe 'Format-LabMacAddress' {

    It 'accepts plain 12-hex and produces dashed by default' {
        Format-LabMacAddress '00155d505020' | Should -Be '00-15-5D-50-50-20'
    }

    It 'accepts dashed and round-trips to plain' {
        Format-LabMacAddress -Mac '00-15-5D-50-50-20' -Format Plain | Should -Be '00155D505020'
    }

    It 'accepts colon and converts to dashed' {
        Format-LabMacAddress -Mac '00:15:5D:50:50:20' -Format Dash | Should -Be '00-15-5D-50-50-20'
    }

    It 'accepts dotted-quad style (Cisco) and converts' {
        Format-LabMacAddress -Mac '0015.5d50.5020' -Format Plain | Should -Be '00155D505020'
    }

    It 'is case-insensitive on input, uppercase on output' {
        Format-LabMacAddress 'aabbccddeeff' | Should -Be 'AA-BB-CC-DD-EE-FF'
    }

    It 'emits colon format when requested' {
        Format-LabMacAddress -Mac '00155D505020' -Format Colon | Should -Be '00:15:5D:50:50:20'
    }

    It 'rejects too-short input' {
        { Format-LabMacAddress 'ABCDEF' } | Should -Throw '*not a valid 12-hex MAC*'
    }

    It 'rejects too-long input' {
        { Format-LabMacAddress '00155D5050200000' } | Should -Throw '*not a valid 12-hex MAC*'
    }

    It 'rejects non-hex characters' {
        { Format-LabMacAddress '00-15-5D-ZZ-50-20' } | Should -Throw '*not a valid 12-hex MAC*'
    }

    It 'is idempotent across formats' {
        $original = '00-15-5D-AB-50-20'
        $plain    = Format-LabMacAddress $original -Format Plain
        $back     = Format-LabMacAddress $plain    -Format Dash
        $back | Should -Be $original
    }
}

Describe 'New-LabMacAddress' {

    It 'uses the full IPv4 address, not only the final octet' {
        $a = New-LabMacAddress -IPAddress '192.168.50.20'
        $b = New-LabMacAddress -IPAddress '192.168.60.20'
        $a | Should -Not -Be $b
    }

    It 'returns a valid dashed MAC address' {
        New-LabMacAddress -IPAddress '192.168.50.20' |
            Should -Match '^[0-9A-F]{2}(-[0-9A-F]{2}){5}$'
    }

    It 'rejects non-IPv4 input' {
        { New-LabMacAddress -IPAddress 'not-an-ip' } |
            Should -Throw '*not a valid IP address*'
    }
}
