<#
    Tests fuer scripts/verify-arm64x.ps1.

    Teil A (Pure-Forwarder-Layout): prueft die reine Logik, welche Dateien als
    ARM64X-Hybrid verifiziert werden (nur die Forwarder-DLLs), dass die Praesenz
    der Tools erzwungen wird und dass Invoke-Arm64xVerification die echten
    Ansichts-DLLs ignoriert sowie die .lib-Paarung ueberspringt, wenn keine .lib
    vorhanden ist.

    Teil B (ABI-Gate / Pre-Merge): prueft die ABI-Erkennung allein anhand der
    Maschinenzeile (nicht am Pfad), den ARM64X-Gate (Standard) sowie die
    Pre-Merge-Gates (ExpectedAbi ARM64 / ARM64EC), die nachweisen, dass die
    arm64ec-Ansicht WIRKLICH ARM64EC ist und nicht still auf reines ARM64
    zurueckgefallen ist.

    dumpbin.exe laeuft nur auf CI; hier wird der Header-Provider gestubbt.

    Requirements: 2.4, 2.5
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    # Reine Logik per Dot-Sourcing laden, ohne den Skript-Rumpf auszufuehren
    # (der Rumpf prueft $MyInvocation.InvocationName -ne '.').
    . (Join-Path $script:RepoRoot 'scripts/verify-arm64x.ps1') -BinDir 'unused' 2>$null 6>$null

    # --- Teil A: Pure-Forwarder-Fixtures ----------------------------------

    # Namen eines typischen Forwarder-bin: je Lib 3 DLLs + Tools, keine .lib.
    $script:ForwarderNames = @(
        'avcodec-62.dll', 'avcodec-62_arm64.dll', 'avcodec-62_arm64ec.dll',
        'avutil-60.dll',  'avutil-60_arm64.dll',  'avutil-60_arm64ec.dll',
        'ffmpeg.exe', 'ffprobe.exe'
    )

    # Header-Stub: Forwarder sind ARM64X, _arm64 ist ARM64, _arm64ec ist ARM64EC.
    $script:HeaderProvider = {
        param([string] $Path)
        $leaf = Split-Path -Path $Path -Leaf
        if ($leaf -match '_arm64ec\.dll$') { return "FILE HEADER VALUES`n    A641 machine (ARM64EC)`n" }
        if ($leaf -match '_arm64\.dll$')   { return "FILE HEADER VALUES`n    AA64 machine (ARM64)`n" }
        if ($leaf -match '\.dll$')         { return "FILE HEADER VALUES`n    AA64 machine (ARM64) (ARM64X)`n" }
        return "FILE HEADER VALUES`n    AA64 machine (ARM64)`n"
    }

    # --- Teil B: Repraesentative erfasste `dumpbin /headers`-Maschinenzeilen

    # Reines ARM64 (Pre-Merge-arm64-Ansicht).
    $script:HeaderArm64 = @'
Microsoft (R) COFF/PE Dumper Version 14.39.33523.0

Dump of file avcodec.dll

PE signature found

File Type: DLL

FILE HEADER VALUES
            AA64 machine (ARM64)
               8 number of sections
'@

    # Reines ARM64EC (Pre-Merge-arm64ec-Ansicht): dumpbin meldet A641 (ARM64EC).
    $script:HeaderArm64ec = @'
Microsoft (R) COFF/PE Dumper Version 14.39.33523.0

Dump of file avcodec.dll

PE signature found

File Type: DLL

FILE HEADER VALUES
            A641 machine (ARM64EC)
               8 number of sections
'@

    # Gemergter ARM64X-Hybrid: Maschinenwert bleibt (ARM64), zusaetzlich (ARM64X).
    $script:HeaderArm64x = @'
Microsoft (R) COFF/PE Dumper Version 14.39.33523.0

Dump of file avcodec.dll

PE signature found

File Type: DLL

FILE HEADER VALUES
            AA64 machine (ARM64) (ARM64X)
               8 number of sections
'@

    # Negativ: Pfad enthaelt "arm64x", aber die Maschinenzeile ist reines ARM64.
    # Der Gate darf sich NICHT vom Pfad taeuschen lassen.
    $script:HeaderPathTrap = @'
Dump of file C:\out\gpl\arm64x\bin\avcodec.dll

FILE HEADER VALUES
            AA64 machine (ARM64)
'@
}

Describe 'Get-Arm64xTargetFiles (Pure-Forwarder)' {
    It 'waehlt NUR die Forwarder-DLLs (ohne _arm64/_arm64ec-Suffix)' {
        $lister = { param($d) $script:ForwarderNames }
        $targets = Get-Arm64xTargetFiles -BinDir 'C:\bin' -FileLister $lister
        $leaves = $targets | ForEach-Object { Split-Path $_ -Leaf }
        $leaves | Should -Contain 'avcodec-62.dll'
        $leaves | Should -Contain 'avutil-60.dll'
        $leaves | Should -Not -Contain 'avcodec-62_arm64.dll'
        $leaves | Should -Not -Contain 'avcodec-62_arm64ec.dll'
        # Tools werden NICHT als ARM64X-Ziel gefuehrt (nur Praesenz geprueft).
        $leaves | Should -Not -Contain 'ffmpeg.exe'
        @($targets).Count | Should -Be 2
    }

    It 'bricht fail-fast ab, wenn ffprobe.exe fehlt' {
        $lister = { param($d) @('avcodec-62.dll', 'avcodec-62_arm64.dll', 'avcodec-62_arm64ec.dll', 'ffmpeg.exe') }
        { Get-Arm64xTargetFiles -BinDir 'C:\bin' -FileLister $lister } |
            Should -Throw -ExpectedMessage "*ffprobe.exe*fehlt*"
    }
}

Describe 'Invoke-Arm64xVerification (Pure-Forwarder)' {
    It 'besteht: Forwarder sind ARM64X, Ansichts-DLLs werden ignoriert, Paarung uebersprungen' {
        $lister = { param($d) $script:ForwarderNames }
        $r = Invoke-Arm64xVerification -BinDir 'C:\bin' `
            -HeaderProvider $script:HeaderProvider -FileLister $lister
        $r.Success | Should -BeTrue -Because $r.Message
        # Es wurden genau die 2 Forwarder geprueft.
        @($r.Checked).Count | Should -Be 2
        ($r.Checked | ForEach-Object Abi) | Should -Not -Contain 'ARM64EC'
        # Keine .lib im bin -> keine Paarungspruefung.
        $r.Pairing | Should -BeNullOrEmpty
    }

    It 'schlaegt fehl, wenn ein Forwarder nur ARM64 ist (kein Hybrid)' {
        $lister = { param($d) @('avcodec-62.dll', 'avcodec-62_arm64.dll', 'avcodec-62_arm64ec.dll', 'ffmpeg.exe', 'ffprobe.exe') }
        $provider = { param($p) "FILE HEADER VALUES`n    AA64 machine (ARM64)`n" }
        $r = Invoke-Arm64xVerification -BinDir 'C:\bin' -HeaderProvider $provider -FileLister $lister
        $r.Success | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match 'ARM64X'
    }
}

Describe 'Get-DumpbinMachineAbi (Maschinenzeilen-Parser)' {
    It 'erkennt reines ARM64' {
        Get-DumpbinMachineAbi -HeaderText $script:HeaderArm64 | Should -Be 'ARM64'
    }

    It 'erkennt reines ARM64EC (A641)' {
        Get-DumpbinMachineAbi -HeaderText $script:HeaderArm64ec | Should -Be 'ARM64EC'
    }

    It 'erkennt den ARM64X-Hybrid (Vorrang vor ARM64)' {
        Get-DumpbinMachineAbi -HeaderText $script:HeaderArm64x | Should -Be 'ARM64X'
    }

    It 'laesst sich nicht vom Dateipfad taeuschen (arm64x im Pfad, ARM64 in der Maschinenzeile)' {
        Get-DumpbinMachineAbi -HeaderText $script:HeaderPathTrap | Should -Be 'ARM64'
    }

    It 'liefert Unknown fuer leeren Text' {
        Get-DumpbinMachineAbi -HeaderText '' | Should -Be 'Unknown'
    }
}

Describe 'Test-Arm64xHeader - Standard-Gate (ExpectedAbi ARM64X)' {
    It 'besteht fuer einen echten ARM64X-Hybrid' {
        $g = Test-Arm64xHeader -HeaderText $script:HeaderArm64x -FileName 'avcodec.dll'
        $g.IsExpected | Should -BeTrue -Because $g.Message
        $g.IsArm64x   | Should -BeTrue
        $g.Abi        | Should -Be 'ARM64X'
    }

    It 'lehnt ein reines ARM64-Image ab und benennt die fehlende ARM64EC-Ansicht' {
        $g = Test-Arm64xHeader -HeaderText $script:HeaderArm64 -FileName 'avcodec.dll'
        $g.IsExpected | Should -BeFalse
        $g.Message    | Should -Match 'ARM64EC-Ansicht'
    }

    It 'lehnt ein reines ARM64EC-Image ab und benennt die fehlende ARM64-Ansicht' {
        $g = Test-Arm64xHeader -HeaderText $script:HeaderArm64ec -FileName 'avcodec.dll'
        $g.IsExpected | Should -BeFalse
        $g.Message    | Should -Match 'ARM64-Ansicht'
    }
}

Describe 'Test-Arm64xHeader - Pre-Merge-Gate (ExpectedAbi ARM64EC)' {
    It 'besteht fuer ein echtes ARM64EC-Image' {
        $g = Test-Arm64xHeader -HeaderText $script:HeaderArm64ec -ExpectedAbi 'ARM64EC' -FileName 'avcodec.dll'
        $g.IsExpected  | Should -BeTrue -Because $g.Message
        $g.Abi         | Should -Be 'ARM64EC'
        $g.ExpectedAbi | Should -Be 'ARM64EC'
    }

    It 'lehnt ein reines ARM64-Image ab (arm64ec-Build auf ARM64 zurueckgefallen)' {
        $g = Test-Arm64xHeader -HeaderText $script:HeaderArm64 -ExpectedAbi 'ARM64EC' -FileName 'avcodec.dll'
        $g.IsExpected | Should -BeFalse
        $g.Message    | Should -Match 'erwartet ARM64EC'
        $g.Abi        | Should -Be 'ARM64'
    }

    It 'akzeptiert ein ARM64X-Image (cl /arm64EC-DLLs melden den (ARM64X)-Marker)' {
        # Ein mit cl /arm64EC + link /machine:arm64ec erzeugtes FFmpeg-Shared-DLL
        # meldet in dumpbin die Maschinenzeile "AA64 machine (ARM64) (ARM64X)".
        # Das ist ein gueltiges EC-faehiges Image; die EC-Erwartung gilt daher
        # auch bei erkannter ABI ARM64X als erfuellt. Nur reines ARM64 (siehe
        # vorheriger Test) wird abgelehnt.
        $g = Test-Arm64xHeader -HeaderText $script:HeaderArm64x -ExpectedAbi 'ARM64EC' -FileName 'avcodec.dll'
        $g.IsExpected | Should -BeTrue -Because $g.Message
        $g.Abi        | Should -Be 'ARM64X'
    }
}

Describe 'Test-Arm64xHeader - Pre-Merge-Gate (ExpectedAbi ARM64)' {
    It 'besteht fuer ein echtes ARM64-Image' {
        $g = Test-Arm64xHeader -HeaderText $script:HeaderArm64 -ExpectedAbi 'ARM64' -FileName 'avcodec.dll'
        $g.IsExpected | Should -BeTrue -Because $g.Message
        $g.Abi        | Should -Be 'ARM64'
    }

    It 'lehnt ein ARM64EC-Image ab' {
        $g = Test-Arm64xHeader -HeaderText $script:HeaderArm64ec -ExpectedAbi 'ARM64' -FileName 'avcodec.dll'
        $g.IsExpected | Should -BeFalse
        $g.Message    | Should -Match 'erwartet ARM64'
    }

    It 'lehnt einen ARM64X-Hybrid ab (ARM64X ist nicht reines ARM64)' {
        $g = Test-Arm64xHeader -HeaderText $script:HeaderArm64x -ExpectedAbi 'ARM64' -FileName 'avcodec.dll'
        $g.IsExpected | Should -BeFalse
        $g.Message    | Should -Match 'erwartet ARM64'
    }
}

Describe 'Invoke-Arm64xVerification - Pre-Merge-ABI mit injiziertem HeaderProvider' {
    BeforeAll {
        # Join-Path validiert den Laufwerksbuchstaben; daher einen existierenden,
        # aber hier nie gelesenen Pfad verwenden (Lister/HeaderProvider sind
        # injiziert, es findet kein echter Dateizugriff statt).
        $script:FakeBinDir = Join-Path $env:TEMP 'arm64ec\bin'
    }

    It 'besteht, wenn alle Zieldateien die erwartete ARM64EC-ABI haben' {
        # Pre-Merge-Einzelansicht: DLLs OHNE _arm64/_arm64ec-Suffix + Tools.
        $lister = { param($Dir) @('avcodec.dll', 'avutil.dll', 'ffmpeg.exe', 'ffprobe.exe') }
        $provider = { param($FilePath) $script:HeaderArm64ec }

        $r = Invoke-Arm64xVerification -BinDir $script:FakeBinDir `
            -HeaderProvider $provider -ExpectedAbi 'ARM64EC' -SkipLibPairing -FileLister $lister
        $r.Success     | Should -BeTrue -Because $r.Message
        $r.ExpectedAbi | Should -Be 'ARM64EC'
        $r.Checked.Count | Should -Be 2
    }

    It 'schlaegt fehl, wenn eine arm64ec-Zieldatei in Wahrheit reines ARM64 ist' {
        $lister = { param($Dir) @('avcodec.dll', 'ffmpeg.exe', 'ffprobe.exe') }
        # avcodec.dll ist (faelschlich) reines ARM64, der Rest korrekt ARM64EC.
        $provider = {
            param($FilePath)
            if ($FilePath -match 'avcodec') { return $script:HeaderArm64 }
            return $script:HeaderArm64ec
        }

        $r = Invoke-Arm64xVerification -BinDir $script:FakeBinDir `
            -HeaderProvider $provider -ExpectedAbi 'ARM64EC' -SkipLibPairing -FileLister $lister
        $r.Success | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match 'avcodec.dll'
        ($r.Failures -join ' ') | Should -Match 'erwartet ARM64EC'
    }

    It 'bricht ab, wenn eine erwartete Ausfuehrbare fehlt' {
        $lister = { param($Dir) @('avcodec.dll', 'ffmpeg.exe') }  # ffprobe.exe fehlt
        $provider = { param($FilePath) $script:HeaderArm64ec }

        { Invoke-Arm64xVerification -BinDir $script:FakeBinDir `
            -HeaderProvider $provider -ExpectedAbi 'ARM64EC' -SkipLibPairing -FileLister $lister } |
            Should -Throw -ExpectedMessage "*ffprobe.exe*"
    }
}
