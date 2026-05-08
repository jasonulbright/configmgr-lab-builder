#requires -Module Pester
<#
.SYNOPSIS
    Pester tests for Get-LabBaseImageCacheKey and New-LabBaseUnattend.
    These are the testable bits of the base-image helper; the
    Mount-VHD / Expand-WindowsImage / VM-sysprep pipeline lives in
    Tests/Integration/ (manual gate, requires elevation + ISO).
#>

BeforeAll {
    $script:imgRoot = Resolve-Path "$PSScriptRoot\..\..\modules\HomeLab\Private\03-Image"
    . (Join-Path $script:imgRoot 'Get-LabBaseImageCacheKey.ps1')
    . (Join-Path $script:imgRoot 'New-LabBaseUnattend.ps1')

    # Build a tiny "ISO" file we can hash. Real ISOs are multi-GB; the helper
    # only reads file size and LastWriteTimeUtc, so any seekable file works.
    $script:fakeIso = Join-Path $TestDrive 'fake.iso'
    [System.IO.File]::WriteAllBytes($script:fakeIso, [byte[]](1..32))
}

Describe 'Get-LabBaseImageCacheKey' {

    It 'returns the same key for the same inputs' {
        $a = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'Server 2025 Eval'
        $b = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'Server 2025 Eval'
        $a | Should -Be $b
    }

    It 'returns 16 hex characters by default' {
        $k = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'foo'
        $k.Length | Should -Be 16
        $k | Should -Match '^[0-9a-f]+$'
    }

    It 'returns 64 hex characters with -FullHash' {
        $k = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'foo' -FullHash
        $k.Length | Should -Be 64
        $k | Should -Match '^[0-9a-f]+$'
    }

    It 'changes when ImageIndex changes' {
        $a = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'foo'
        $b = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 5 -ImageName 'foo'
        $a | Should -Not -Be $b
    }

    It 'changes when ImageName changes' {
        $a = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'foo'
        $b = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'bar'
        $a | Should -Not -Be $b
    }

    It 'changes when LcuLevel changes' {
        $a = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'foo' -LcuLevel ''
        $b = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'foo' -LcuLevel 'KB5099999'
        $a | Should -Not -Be $b
    }

    It 'is path-agnostic when file size and LastWriteTime match' {
        # Copy preserves size; LastWriteTimeUtc is not preserved by Copy-Item
        # by default, so set it explicitly.
        $copy = Join-Path $TestDrive 'fake-copy.iso'
        Copy-Item $script:fakeIso $copy
        (Get-Item $copy).LastWriteTimeUtc = (Get-Item $script:fakeIso).LastWriteTimeUtc

        $a = Get-LabBaseImageCacheKey -IsoPath $script:fakeIso -ImageIndex 4 -ImageName 'foo'
        $b = Get-LabBaseImageCacheKey -IsoPath $copy        -ImageIndex 4 -ImageName 'foo'
        $a | Should -Be $b
    }

    It 'throws if the ISO does not exist' {
        { Get-LabBaseImageCacheKey -IsoPath (Join-Path $TestDrive 'nope.iso') -ImageIndex 1 -ImageName 'x' } |
            Should -Throw "*ISO not found*"
    }
}

Describe 'New-LabBaseUnattend' {

    BeforeEach {
        $script:outPath = Join-Path $TestDrive ('unattend-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
    }

    It 'writes a file at the specified path' {
        New-LabBaseUnattend -AdministratorPassword 'P@ssw0rd!' -OutputPath $script:outPath | Out-Null
        Test-Path $script:outPath | Should -BeTrue
    }

    It 'produces valid XML' {
        New-LabBaseUnattend -AdministratorPassword 'P@ssw0rd!' -OutputPath $script:outPath | Out-Null
        { [xml](Get-Content $script:outPath -Raw) } | Should -Not -Throw
    }

    It 'declares the unattend namespace' {
        New-LabBaseUnattend -AdministratorPassword 'P@ssw0rd!' -OutputPath $script:outPath | Out-Null
        [xml]$doc = Get-Content $script:outPath -Raw
        $doc.unattend.xmlns | Should -Be 'urn:schemas-microsoft-com:unattend'
    }

    It 'embeds both specialize and oobeSystem passes' {
        New-LabBaseUnattend -AdministratorPassword 'P@ssw0rd!' -OutputPath $script:outPath | Out-Null
        [xml]$doc = Get-Content $script:outPath -Raw
        @($doc.unattend.settings | ForEach-Object { $_.pass }) |
            Should -Contain 'oobeSystem'
        @($doc.unattend.settings | ForEach-Object { $_.pass }) |
            Should -Contain 'specialize'
    }

    It 'embeds the FirstLogonCommands sysprep call' {
        New-LabBaseUnattend -AdministratorPassword 'P@ssw0rd!' -OutputPath $script:outPath | Out-Null
        $content = Get-Content $script:outPath -Raw
        $content | Should -Match 'sysprep\.exe /generalize /oobe /shutdown /quiet'
    }

    It 'XML-escapes special characters in the password' {
        $tricky = "P@`"ss<wo>rd&'!"
        New-LabBaseUnattend -AdministratorPassword $tricky -OutputPath $script:outPath | Out-Null
        $raw = Get-Content $script:outPath -Raw
        # Raw special chars must NOT appear (after escape, & becomes &amp; etc)
        $raw | Should -Not -Match '<wo>'
        $raw | Should -Not -Match '&(?!(amp|lt|gt|apos|quot);)'
        # XML re-parse must succeed and decode back to the original.
        [xml]$doc = $raw
        $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
        $valNode = $doc.SelectSingleNode('//u:AdministratorPassword/u:Value', $ns)
        $valNode.InnerText | Should -Be $tricky
    }

    It 'writes a UTF-8 BOM (Windows Setup requires it for unattend.xml)' {
        New-LabBaseUnattend -AdministratorPassword 'P@ssw0rd!' -OutputPath $script:outPath | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($script:outPath)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }

    It 'rejects an empty password at parameter binding' {
        { New-LabBaseUnattend -AdministratorPassword '' -OutputPath $script:outPath } |
            Should -Throw "*null or empty*"
    }

    It 'accepts the architecture parameter' {
        New-LabBaseUnattend -AdministratorPassword 'p' -Architecture x86 -OutputPath $script:outPath | Out-Null
        (Get-Content $script:outPath -Raw) | Should -Match 'processorArchitecture="x86"'
    }
}
