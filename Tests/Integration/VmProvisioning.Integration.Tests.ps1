#requires -Module Pester
<#
.SYNOPSIS
    Tier-3 integration: New-LabVM against a cached base image.

.DESCRIPTION
    Provisions a single throwaway VM (HomeLab-IntTest-<guid>) from
    a base VHDX cached by BaseImage.Integration.Tests.ps1, asserts it
    boots to WinRM-ready, then removes it.

    Skipped unless HOMELAB_E2E=1 and a base image is configured.
    Typical runtime: 5-8 minutes.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force

    $script:base   = $env:HOMELAB_INT_BASE_VHDX
    $script:switch = $env:HOMELAB_INT_SWITCH
    $script:gate = ($env:HOMELAB_E2E -eq '1') -and `
        $script:base -and (Test-Path $script:base) -and `
        $script:switch

    $script:vmName = 'HomeLab-IntTest-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $script:imagePath = Join-Path $env:TEMP 'homelab-int-vm'
}

AfterAll {
    if ($script:gate) {
        Get-VM -Name $script:vmName -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.State -ne 'Off') {
                Stop-VM -Name $_.Name -TurnOff -Force -ErrorAction SilentlyContinue
            }
            Remove-VM -Name $_.Name -Force -ErrorAction SilentlyContinue
        }
        $childVhdx = Join-Path $script:imagePath ($script:vmName + '.vhdx')
        if (Test-Path $childVhdx) { Remove-Item $childVhdx -Force -ErrorAction SilentlyContinue }
    }
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-LabVM against cached base image' -Tag 'Integration','Tier3' {

    It 'creates a Gen2 VM, boots it, and Wait-LabVM passes' -Skip:(-not $script:gate) {
        $name      = $script:vmName
        $base      = $script:base
        $switch    = $script:switch
        $imagePath = $script:imagePath

        $result = InModuleScope HomeLab -Parameters @{
            Name = $name; Base = $base; Switch = $switch; ImagePath = $imagePath
        } {
            param($Name, $Base, $Switch, $ImagePath)
            New-LabVM `
                -VMName $Name -ParentVhdx $Base `
                -LabSwitchName $Switch `
                -LabIP '192.168.50.250/24' `
                -DnsServer '192.168.50.10' `
                -LabNicMac '00-15-5D-FE-50-FA' `
                -MemoryStartupBytes 2GB `
                -MinMemoryBytes 1GB -MaxMemoryBytes 2GB `
                -ProcessorCount 2 `
                -AdministratorPassword 'P@ssw0rd!' `
                -LabImagePath $ImagePath `
                -WinRMTimeoutSeconds 600 `
                -Force
        }

        $result.Name | Should -Be $name
        (Get-VM -Name $name).State | Should -Be 'Running'
    }
}
