<#
    Tests fuer scripts/build-ffmpeg.ps1 (Plan-Zusammensetzung im DryRun).

    Deckt vor allem ab, dass die MSVC-Dependency-Generierung abgeschaltet
    bleibt: ffbuild/common.mak ruft je Objekt $(call CCDEP,CC) auf, dessen
    awk-Programm bei FFmpeg <= 8.1.3 kaputt escaped ankommt und make abbricht.
    Zudem: LGPL-only, Shared, keine GPL-Encoder, aber MIT AMF + NVENC/NVDEC.
#>

BeforeAll {
    $script:BuildFFmpeg = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts/build-ffmpeg.ps1"

    function New-Plan {
        param([string] $Arch = "arm64", [switch] $WithHwHeaders)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N").Substring(0, 8))
        $hw = Join-Path $root "hwheaders"
        if ($WithHwHeaders) {
            New-Item -ItemType Directory -Force -Path (Join-Path $hw "include") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $hw "lib/pkgconfig") | Out-Null
        }
        & $script:BuildFFmpeg -Arch $Arch -SourceDir (Join-Path $root "src") `
            -OutputDir (Join-Path $root "out") -HwHeadersDir $hw -DryRun 6>$null
    }

    function New-GplPlan {
        param([string] $Arch = "arm64")
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N").Substring(0, 8))
        $hw = Join-Path $root "hwheaders"
        New-Item -ItemType Directory -Force -Path (Join-Path $hw "include") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $hw "lib/pkgconfig") | Out-Null
        # build-ffmpeg.ps1 (GPL) bricht ab, wenn <DepsDir>\<codec>\<arch> fehlt.
        # Fuer die reine Plan-Zusammensetzung genuegen die Verzeichnisse (die
        # Libs selbst werden erst beim echten Link gebraucht).
        $deps = Join-Path $root "deps"
        foreach ($codec in @("x264", "x265")) {
            New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path (Join-Path $deps $codec) $Arch) "include") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path (Join-Path $deps $codec) $Arch) "lib/pkgconfig") | Out-Null
        }
        & $script:BuildFFmpeg -Arch $Arch -Variant gpl -SourceDir (Join-Path $root "src") `
            -OutputDir (Join-Path $root "out") -HwHeadersDir $hw -DepsDir $deps -DryRun 6>$null
    }
}

Describe "build-ffmpeg: configure-Flags (LGPL, Shared, HW-Encoder)" {
    It "baut shared und nicht statisch" {
        $args = (New-Plan).ConfigureArgs -join " "
        $args | Should -Match "--enable-shared"
        $args | Should -Match "--disable-static"
    }

    It "aktiviert KEINE GPL-Komponenten (kein x264/x265)" {
        $args = (New-Plan).ConfigureArgs -join " "
        $args | Should -Not -Match "--enable-gpl"
        $args | Should -Not -Match "libx264"
        $args | Should -Not -Match "libx265"
    }

    It "aktiviert die Hardware-Encoder AMF + NVENC/NVDEC" {
        $args = (New-Plan).ConfigureArgs -join " "
        $args | Should -Match "--enable-amf"
        $args | Should -Match "--enable-nvenc"
        $args | Should -Match "--enable-nvdec"
    }
}

Describe "build-ffmpeg: configure-Flags (GPL, mit x264/x265 + HW-Encoder)" {
    It "aktiviert GPL und die Encoder libx264 + libx265" {
        $args = (New-GplPlan).ConfigureArgs -join " "
        $args | Should -Match "--enable-gpl"
        $args | Should -Match "--enable-libx264"
        $args | Should -Match "--enable-libx265"
    }

    It "aktiviert weiterhin die Hardware-Encoder AMF + NVENC/NVDEC" {
        $args = (New-GplPlan).ConfigureArgs -join " "
        $args | Should -Match "--enable-amf"
        $args | Should -Match "--enable-nvenc"
        $args | Should -Match "--enable-nvdec"
    }

    It "reicht include- und lib-Pfade der x264/x265-Deps weiter" {
        $args = (New-GplPlan).ConfigureArgs -join " "
        $args | Should -Match "x264/arm64/include"
        $args | Should -Match "x265/arm64/include"
        $args | Should -Match "LIBPATH:\S*x264/arm64/lib"
        $args | Should -Match "LIBPATH:\S*x265/arm64/lib"
    }

    It "bricht ab, wenn die x264/x265-Deps fuer die Arch fehlen" {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N").Substring(0, 8))
        $hw = Join-Path $root "hwheaders"
        New-Item -ItemType Directory -Force -Path $hw | Out-Null
        $deps = Join-Path $root "deps-empty"
        New-Item -ItemType Directory -Force -Path $deps | Out-Null
        { & $script:BuildFFmpeg -Arch arm64 -Variant gpl -SourceDir (Join-Path $root "src") `
            -OutputDir (Join-Path $root "out") -HwHeadersDir $hw -DepsDir $deps -DryRun 6>$null } |
            Should -Throw -ExpectedMessage "*x264-Deps*"
    }
}

Describe "build-ffmpeg: Hardware-Header" {
    It "reicht include und pkgconfig der hwheaders weiter, wenn vorhanden" {
        $plan = New-Plan -WithHwHeaders
        ($plan.ConfigureArgs -join " ") | Should -Match "extra-cflags=-I\S*hwheaders/include"
        $plan.BashScript | Should -Match "hwheaders/lib/pkgconfig"
    }

    It "laeuft ohne hwheaders-Verzeichnis durch" {
        $plan = New-Plan
        ($plan.ConfigureArgs -join " ") | Should -Not -Match "hwheaders"
    }
}

Describe "build-ffmpeg: make-Aufrufe" {
    It "schaltet die Dependency-Generierung bei make ab" {
        $bash = (New-Plan).BashScript -split "`n"
        $make = @($bash | Where-Object { $_ -match "^make -j" })
        $make.Count | Should -Be 1
        $make[0] | Should -Match "CCDEP= CXXDEP="
    }

    It "schaltet die Dependency-Generierung auch bei make install ab" {
        $bash = (New-Plan).BashScript -split "`n"
        $install = @($bash | Where-Object { $_ -match "^make install" })
        $install.Count | Should -Be 1
        $install[0] | Should -Match "CCDEP= CXXDEP="
    }

    It "gibt die CCDEP-Zeile aus config.mak zur Diagnose aus" {
        (New-Plan).BashScript | Should -Match "config\.mak"
    }

    It "fuehrt configure vor make aus" {
        $bash = @((New-Plan).BashScript -split "`n")
        $cfg = [Array]::FindIndex($bash, [Predicate[string]] { param($l) $l -match "^\./configure " })
        $mk  = [Array]::FindIndex($bash, [Predicate[string]] { param($l) $l -match "^make -j" })
        $cfg | Should -BeGreaterThan 0
        $mk  | Should -BeGreaterThan $cfg
    }
}

Describe "build-ffmpeg: ARM64EC-Ansicht" {
    It "nutzt arch=arm64 und EC-Flags fuer die arm64ec-Ansicht" {
        $args = (New-Plan -Arch "arm64ec").ConfigureArgs -join " "
        $args | Should -Match "--arch=arm64(\s|$)"
        $args | Should -Not -Match "--arch=arm64ec"
        $args | Should -Match "extra-cflags=-arm64EC"
        # Kleinschreibung ist zwingend: makedef matcht LDFLAGS case-sensitiv auf
        # "machine:arm64ec". Case-sensitiver Vergleich via cmatch.
        ($args -cmatch "extra-ldflags=-machine:arm64ec") | Should -BeTrue
        ($args -cmatch "MACHINE:arm64EC") | Should -BeFalse
    }
}

Describe "build-ffmpeg: sauberer Rebuild je Arch" {
    It "fuehrt 'make distclean' VOR configure aus (geteilter Quellbaum)" {
        # Der Quellbaum wird fuer beide Builds wiederverwendet; ohne distclean
        # recompiliert make nicht und der arm64ec-Build erbt die ARM64-Objekte
        # des vorherigen Laufs.
        $bash = @((New-Plan -Arch "arm64ec").BashScript -split "`n")
        $clean = [Array]::FindIndex($bash, [Predicate[string]] { param($l) $l -match "make distclean" })
        $cfg   = [Array]::FindIndex($bash, [Predicate[string]] { param($l) $l -match "^\./configure " })
        $clean | Should -BeGreaterThan 0
        $cfg   | Should -BeGreaterThan $clean
    }

    It "fuehrt 'make distclean' auch fuer die arm64-Ansicht aus" {
        $bash = @((New-Plan -Arch "arm64").BashScript -split "`n")
        ($bash -join "`n") | Should -Match "make distclean"
    }
}

Describe "build-ffmpeg: ARM64EC-Erzwingung ueber config.mak" {
    It "haengt -arm64EC und -machine:arm64ec nach configure an config.mak an (arm64ec)" {
        # Die Flags werden NACH configure direkt an ffbuild/config.mak
        # angehaengt, damit die arm64ec-DLLs wirklich ARM64EC sind. Der
        # LDFLAGS-Flag ist kleingeschrieben, weil makedef ihn case-sensitiv matcht.
        $bash = @((New-Plan -Arch "arm64ec").BashScript -split "`n")

        $append = [Array]::FindIndex($bash, [Predicate[string]] { param($l) $l -match "config\.mak" -and $l -match "arm64ec" })
        $append | Should -BeGreaterThan 0
        $joined = ($bash -join "`n")
        # Append nutzt "+=", nicht die rekursive Selbstreferenz "=$(CFLAGS)".
        $joined | Should -Match "CFLAGS \+= -arm64EC"
        ($joined -cmatch "LDFLAGS \+= -machine:arm64ec") | Should -BeTrue
        ($joined -cmatch "MACHINE:arm64EC") | Should -BeFalse
        $joined | Should -Not -Match 'CFLAGS=\$\(CFLAGS\)'
    }

    It "haengt die Flags NACH configure und VOR make an" {
        $bash = @((New-Plan -Arch "arm64ec").BashScript -split "`n")
        $cfg    = [Array]::FindIndex($bash, [Predicate[string]] { param($l) $l -match "^\./configure " })
        $append = [Array]::FindIndex($bash, [Predicate[string]] { param($l) $l -match "config\.mak" -and $l -match "arm64EC" })
        $mk     = [Array]::FindIndex($bash, [Predicate[string]] { param($l) $l -match "^make -j" })
        $append | Should -BeGreaterThan $cfg
        $mk     | Should -BeGreaterThan $append
    }

    It "haengt NICHTS an config.mak an fuer die reine arm64-Ansicht" {
        $bash = @((New-Plan -Arch "arm64").BashScript -split "`n")
        ($bash -join "`n") | Should -Not -Match "arm64EC"
    }
}
