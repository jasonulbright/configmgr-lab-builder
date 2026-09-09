#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the CM site server's optional SQL / data volumes.

.DESCRIPTION
    config.psd1 declared SQLDisk and DataDisk from the start, but no code
    ever read them: CM01 came up as a single 250GB C: and every "dedicated
    volume" path in the engine pointed at a drive letter that did not
    exist. These tests pin the wiring -- disks requested get created,
    attached and lettered, and a topology that declares no disks keeps the
    single-volume C: defaults rather than being pointed at a missing drive.

    Source-text assertions use Contains rather than -Match: these paths are
    full of backslashes and regex escaping obscures what is being checked.
#>

BeforeAll {
    $script:moduleRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab"
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:moduleRoot 'HomeLab.psd1') -Force -ErrorAction Stop

    function Get-EngineSource {
        param([string]$Relative)
        Get-Content (Join-Path $script:moduleRoot $Relative) -Raw
    }
}

AfterAll {
    Get-Module HomeLab | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-LabVM data disk contract' {

    It 'declares a DataDisks parameter typed for hashtable entries' {
        # New-LabVM is private, so it only resolves inside the module.
        InModuleScope HomeLab {
            $p = (Get-Command New-LabVM).Parameters['DataDisks']
            $p | Should -Not -BeNullOrEmpty
            $p.ParameterType.Name | Should -Be 'Hashtable[]'
        }
    }

    It 'defaults DataDisks to empty so existing callers are unaffected' {
        (Get-EngineSource 'Private\04-VM\New-LabVM.ps1').Contains('$DataDisks = @()') | Should -BeTrue
    }

    It 'validates every required key in a disk spec' {
        $src = Get-EngineSource 'Private\04-VM\New-LabVM.ps1'
        $src.Contains("foreach (`$k in 'Label','SizeGB','DriveLetter')") | Should -BeTrue
        $src.Contains('is missing') | Should -BeTrue
    }

    # Two 50GB disks are indistinguishable by size, so matching raw disks
    # by size would letter them non-deterministically.
    It 'matches raw disks by attach order, not by size' {
        $src = Get-EngineSource 'Private\04-VM\New-LabVM.ps1'
        $src.Contains("PartitionStyle -eq 'RAW'") | Should -BeTrue
        $src.Contains('Sort-Object Number')       | Should -BeTrue
    }

    It 'fails loudly when the guest reports fewer raw disks than were attached' {
        (Get-EngineSource 'Private\04-VM\New-LabVM.ps1').Contains('raw data disk(s), found') | Should -BeTrue
    }
}

Describe 'Install-HomeLab data volume derivation' {

    BeforeAll { $script:src = Get-EngineSource '..\..\modules\HomeLab\Public\Install-HomeLab.ps1' }

    It 'reads SQLDisk and DataDisk from the topology' {
        $script:src.Contains("ContainsKey('SQLDisk')")  | Should -BeTrue
        $script:src.Contains("ContainsKey('DataDisk')") | Should -BeTrue
    }

    It 'resolves the drive letters above the phase blocks' {
        # Defined next to $siteVM so a -SkipPhase 04-VM run still sees them.
        $idxDerive  = $script:src.IndexOf('$sqlDrive')
        $idxPhase04 = $script:src.IndexOf("_Skip '04-VM'")
        $idxDerive  | Should -BeGreaterThan 0
        $idxPhase04 | Should -BeGreaterThan 0
        $idxDerive  | Should -BeLessThan $idxPhase04
    }

    It 'passes SQL paths only when a SQL volume was provisioned' {
        $script:src.Contains('if ($sqlDrive)')                               | Should -BeTrue
        $script:src.Contains('$sqlArgs.SqlUserDbDir    = "${sqlDrive}:\SQLData"') | Should -BeTrue
        $script:src.Contains('$cmArgs.SQLDataFilePath = "${sqlDrive}:\SQLData"')  | Should -BeTrue
    }

    It 'passes a ContentShare path only when a data volume was provisioned' {
        $script:src.Contains('if ($cmDataDrive) { $shareArgs.SharePath') | Should -BeTrue
    }

    It 'attaches SQL before Data so the drive letters are deterministic' {
        $idxSql  = $script:src.IndexOf("Label = 'SQL'")
        $idxData = $script:src.IndexOf("Label = 'Data'")
        $idxSql  | Should -BeGreaterThan 0
        $idxSql  | Should -BeLessThan $idxData
    }
}

Describe 'Single-volume defaults stay on C:' {

    # Only config.psd1 declares SQLDisk/DataDisk; no template does. A
    # template build must never be pointed at E: or F:.
    It 'New-LabSqlConfigIni still defaults to C:' {
        $src = Get-EngineSource 'Private\06-Sql\New-LabSqlConfigIni.ps1'
        $src.Contains("`$SqlUserDbDir = 'C:\SQLData'")    | Should -BeTrue
        $src.Contains("`$SqlUserDbLogDir = 'C:\SQLLogs'") | Should -BeTrue
    }

    It 'New-CMUnattendIni still defaults to C:' {
        $src = Get-EngineSource 'Private\08-CM\New-CMUnattendIni.ps1'
        $src.Contains("`$SQLDataFilePath = 'C:\SQLData'") | Should -BeTrue
        $src.Contains("`$SQLLogFilePath = 'C:\SQLLogs'")  | Should -BeTrue
    }

    It 'New-CMContentShare still defaults to C:' {
        (Get-EngineSource 'Private\09-CMConfig\New-CMContentShare.ps1').Contains("`$SharePath = 'C:\ContentShare'") |
            Should -BeTrue
    }

    It 'no engine source still points at a never-provisioned D: SQL path' {
        $hits = Get-ChildItem (Join-Path $script:moduleRoot '..') -Recurse -Filter '*.ps1' |
            Select-String -Pattern 'D:\SQL' -SimpleMatch
        @($hits).Count | Should -Be 0
    }

    It 'templates declare no data disks, so they keep the C: layout' {
        $templateRoot = Join-Path $script:moduleRoot '..\..\templates'
        $withDisks = Get-ChildItem $templateRoot -Filter '*.psd1' |
            Where-Object { (Get-Content $_.FullName -Raw) -match 'SQLDisk|DataDisk' }
        @($withDisks).Count | Should -Be 0
    }
}
