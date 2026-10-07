<#
    Tests fuer die reine Logik der TRUE-merged ARM64X-Skripte:
      * scripts/merge-arm64x-merged.ps1  (Read-LinkReproInputs, Helfer)
      * scripts/verify-arm64x-merged.ps1 (Parser)
      * scripts/build-ffmpeg.ps1         (MERGED-DryRun-Flags)

    Die echte Toolchain (link.exe/dumpbin.exe) existiert nur auf dem CI-Runner;
    hier wird ausschliesslich die seiteneffektfreie Logik geprueft.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    # Reine Funktionen per Dot-Sourcing laden (die Skript-Ruempfe laufen nur
    # bei direktem Aufruf, nicht beim Dot-Sourcing).
    . (Join-Path $script:RepoRoot 'scripts/merge-arm64x-merged.ps1') `
        -LinkReproDir $TestDrive -OutputDir $TestDrive 6>$null
    . (Join-Path $script:RepoRoot 'scripts/verify-arm64x-merged.ps1') `
        -BinDir $TestDrive 6>$null
}

Describe 'Read-LinkReproInputs (LINKREPROFULLPATHRSP-Parser)' {
    It 'trennt Objekte, externe Libs und .def; quotierte Pfade mit Leerzeichen' {
        $rsp = Join-Path $TestDrive 'x.rsp'
        $content = @(
            '"C:\a\libavutil\log.o"',
            '"C:\a\libavutil\mem.o"',
            '/def:"C:\a\libavutil\avutil-60.def"',
            '"C:\Program Files\x\bcrypt.lib"',
            '/machine:arm64',
            '"C:\a\libavutil\avutilres.o"'
        ) -join "`n"
        Set-Content -LiteralPath $rsp -Value $content -Encoding Ascii
        $r = Read-LinkReproInputs -RspPath $rsp
        $r.Objs.Count | Should -Be 3
        $r.Objs | Should -Contain 'C:\a\libavutil\avutilres.o'
        $r.Libs.Count | Should -Be 1
        $r.Libs[0] | Should -Be 'C:\Program Files\x\bcrypt.lib'
        $r.Def | Should -Be 'C:\a\libavutil\avutil-60.def'
    }

    It 'wirft bei fehlender Datei' {
        { Read-LinkReproInputs -RspPath (Join-Path $TestDrive 'nope.rsp') } | Should -Throw
    }
}

Describe 'Test-IsFFmpegOwnLib' {
    It 'erkennt FFmpeg-eigene Import-Libs' {
        Test-IsFFmpegOwnLib -Path 'C:\a\libavutil\avutil.lib' | Should -BeTrue
        Test-IsFFmpegOwnLib -Path 'C:\a\libavcodec\avcodec.lib' | Should -BeTrue
    }
    It 'laesst externe/System-Libs durch' {
        Test-IsFFmpegOwnLib -Path 'C:\sdk\bcrypt.lib' | Should -BeFalse
        Test-IsFFmpegOwnLib -Path 'C:\sdk\mfplat.lib' | Should -BeFalse
    }
}

Describe 'Test-IsSystemImportLib' {
    It 'erkennt SDK-System-Import-Libs (nach Basisname, pfad-/case-unabhaengig)' {
        Test-IsSystemImportLib -Path 'C:\WindowsKits\10\lib\arm64\user32.lib' | Should -BeTrue
        Test-IsSystemImportLib -Path 'C:\sdk\BCRYPT.LIB' | Should -BeTrue
    }
    It 'erkennt avdevice-System-Libs shlwapi + vfw32 (Regression)' {
        # avdevice (dshow/vfwcap) braucht SHCreateStreamOnFileA (shlwapi) und
        # capCreateCaptureWindowA/capGetDriverDescriptionA (vfw32). Fehlen diese
        # Namen in $SystemImportLibNames, werden sie aus $extLibs entfernt UND
        # nicht ueber $SysLibs wieder eingebracht -> LNK2019 beim avdevice-Merge.
        Test-IsSystemImportLib -Path 'C:\sdk\shlwapi.lib' | Should -BeTrue
        Test-IsSystemImportLib -Path 'C:\sdk\vfw32.lib'   | Should -BeTrue
    }
    It 'behandelt externe Nicht-System-Libs (x264/x265) NICHT als System-Lib' {
        Test-IsSystemImportLib -Path 'C:\deps\x264\arm64\lib\x264.lib' | Should -BeFalse
        Test-IsSystemImportLib -Path 'C:\deps\x265\arm64ec\lib\x265.lib' | Should -BeFalse
    }
}

Describe 'Select-UnneededArtifact (bin-Ordner-Bereinigung)' {
    It 'behaelt .dll und .exe, verwirft .lib/.exp/.pdb' {
        $files = @(
            'avcodec-62.dll','avutil-60.dll','ffmpeg.exe','ffprobe.exe',
            'avcodec-62.lib','avcodec.lib','avcodec-62.exp','avcodec-62.pdb'
        )
        $drop = Select-UnneededArtifact -Name $files
        $drop | Should -Contain 'avcodec-62.lib'
        $drop | Should -Contain 'avcodec.lib'
        $drop | Should -Contain 'avcodec-62.exp'
        $drop | Should -Contain 'avcodec-62.pdb'
        $drop | Should -Not -Contain 'avcodec-62.dll'
        $drop | Should -Not -Contain 'ffmpeg.exe'
        $drop.Count | Should -Be 4
    }
    It 'ist case-insensitiv bei der Endung' {
        $drop = Select-UnneededArtifact -Name @('AVUTIL-60.DLL','TOOL.EXE','x.LIB')
        $drop | Should -Be @('x.LIB')
    }
    It 'liefert eine leere Menge, wenn nur Laufzeitdateien vorliegen' {
        (Select-UnneededArtifact -Name @('a.dll','b.exe')).Count | Should -Be 0
    }
    It 'kommt mit leerer Eingabe klar' {
        (Select-UnneededArtifact -Name @()).Count | Should -Be 0
    }
}

Describe 'Remove-NonRuntimeArtifact (loescht nur Nicht-Laufzeit-Dateien)' {
    It 'entfernt .lib/.exp/.pdb und behaelt .dll/.exe im Verzeichnis' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($n in @('avcodec-62.dll','ffmpeg.exe','avcodec-62.lib','avcodec.lib','avcodec-62.exp','avcodec-62.pdb')) {
            Set-Content -LiteralPath (Join-Path $dir $n) -Value 'x'
        }
        Remove-NonRuntimeArtifact -Directory $dir 6>$null
        $left = @(Get-ChildItem -LiteralPath $dir -File | Select-Object -ExpandProperty Name | Sort-Object)
        $left | Should -Be @('avcodec-62.dll','ffmpeg.exe')
    }
}

Describe 'Convert-StemFromKey' {
    It 'entfernt die Versionsnummer' {
        Convert-StemFromKey -Key 'avcodec-62' | Should -Be 'avcodec'
        Convert-StemFromKey -Key 'swresample-6' | Should -Be 'swresample'
    }
}

Describe 'verify-arm64x-merged: Get-DumpbinMachineAbi' {
    It 'erkennt ARM64X vor ARM64' {
        Get-DumpbinMachineAbi -HeaderText '            AA64 machine (ARM64) (ARM64X)' | Should -Be 'ARM64X'
    }
    It 'erkennt reines ARM64' {
        Get-DumpbinMachineAbi -HeaderText '            AA64 machine (ARM64)' | Should -Be 'ARM64'
    }
    It 'erkennt ARM64EC' {
        Get-DumpbinMachineAbi -HeaderText '            A641 machine (ARM64EC)' | Should -Be 'ARM64EC'
    }
}

Describe 'verify-arm64x-merged: Test-HybridLoadConfig' {
    It 'erkennt Hybrid-Metadaten' {
        Test-HybridLoadConfig -LoadConfigText '    000000018016E420 Hybrid metadata pointer' | Should -BeTrue
        Test-HybridLoadConfig -LoadConfigText 'IMAGE_DYNAMIC_RELOCATION_ARM64X' | Should -BeTrue
    }
    It 'lehnt leere/irrelevante Ausgabe ab' {
        Test-HybridLoadConfig -LoadConfigText '' | Should -BeFalse
        Test-HybridLoadConfig -LoadConfigText 'Section contains the following imports' | Should -BeFalse
    }
}

Describe 'verify-arm64x-merged: Get-DefExportCount' {
    It 'zaehlt nur Symbolzeilen (ohne EXPORTS/Kommentare/leer)' {
        $def = @(
            'EXPORTS',
            '    av_malloc',
            '    av_free',
            '; ein Kommentar',
            '',
            '    av_log'
        ) -join "`n"
        Get-DefExportCount -DefText $def | Should -Be 3
    }
}

Describe 'verify-arm64x-merged: Get-DumpbinExportCount' {
    It 'zaehlt Export-Tabellenzeilen (ordinal hint RVA name)' {
        $exp = @(
            '    ordinal hint RVA      name',
            '',
            '          1    0 00001000 av_malloc',
            '          2    1 00001010 av_free',
            '          3    2 00001020 av_log'
        ) -join "`n"
        Get-DumpbinExportCount -ExportsText $exp | Should -Be 3
    }
}

Describe 'build-ffmpeg: MERGED-Modus (DryRun-Flags)' {
    BeforeAll {
        $script:BuildFFmpeg = Join-Path $script:RepoRoot 'scripts/build-ffmpeg.ps1'
        function New-MergedPlan {
            param([string] $Arch = 'arm64')
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0,8))
            & $script:BuildFFmpeg -Arch $Arch -SourceDir (Join-Path $root 'src') `
                -OutputDir (Join-Path $root 'out') -LinkReproDir (Join-Path $root 'lr') -DryRun 6>$null
        }
    }

    It 'setzt /LINKREPROFULLPATHRSP in den configure-Flags' {
        ($(New-MergedPlan).ConfigureArgs -join ' ') | Should -Match 'LINKREPROFULLPATHRSP'
    }
    It 'erzwingt KEIN --pkg-config per Default (FFmpeg-Default nutzen)' {
        ($(New-MergedPlan).ConfigureArgs -join ' ') | Should -Not -Match '--pkg-config='
    }
    It 'markiert den Plan als Merged' {
        (New-MergedPlan).Merged | Should -BeTrue
    }
}
