<#
    Tests fuer scripts/build-ffmpeg.ps1 (Plan-Zusammensetzung im DryRun).

    Deckt vor allem ab, dass die MSVC-Dependency-Generierung abgeschaltet
    bleibt: ffbuild/common.mak ruft je Objekt $(call CCDEP,CC) auf, dessen
    awk-Programm bei FFmpeg <= 8.1.3 kaputt escaped ankommt und make abbricht.
#>

BeforeAll {
    $script:BuildFFmpeg = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts/build-ffmpeg.ps1"

    function New-Plan {
        param([string] $Variant = "gpl", [string] $Arch = "arm64", [switch] $WithHwHeaders)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N").Substring(0, 8))
        $deps = Join-Path $root "deps"
        New-Item -ItemType Directory -Force -Path $deps | Out-Null
        if ($WithHwHeaders) {
            New-Item -ItemType Directory -Force -Path (Join-Path $deps "hwheaders/include") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $deps "hwheaders/lib/pkgconfig") | Out-Null
        }
        & $script:BuildFFmpeg -Variant $Variant -Arch $Arch -SourceDir (Join-Path $root "src") `
            -OutputDir (Join-Path $root "out") -DepsDir $deps -DryRun 6>$null
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

    It "nutzt arch=arm64 und EC-Flags fuer die arm64ec-Ansicht" {
        $args = (New-Plan -Arch "arm64ec").ConfigureArgs -join " "
        $args | Should -Match "--arch=arm64(\s|$)"
        $args | Should -Not -Match "--arch=arm64ec"
        $args | Should -Match "extra-cflags=-arm64EC"
        $args | Should -Match "extra-ldflags=-MACHINE:arm64EC"
    }
}

Describe "build-ffmpeg: sauberer Rebuild je Arch" {
    It "fuehrt 'make distclean' VOR configure aus (geteilter Quellbaum)" {
        # Der Quellbaum wird fuer alle vier Builds wiederverwendet; ohne
        # distclean recompiliert make nicht und der arm64ec-Build erbt die
        # ARM64-Objekte des vorherigen Laufs.
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
    It "haengt -arm64EC und -MACHINE:arm64EC nach configure an config.mak an (arm64ec)" {
        # FFmpegs configure VERWIRFT -arm64EC/-MACHINE:arm64EC still (seine
        # check_cflags/check_ldflags-Probekompilate schlagen fehl), daher muessen
        # die Flags NACH configure direkt an ffbuild/config.mak angehaengt werden,
        # damit die arm64ec-DLLs wirklich ARM64EC sind.
        $bash = @((New-Plan -Arch "arm64ec").BashScript -split "`n")

        $append = [Array]::FindIndex($bash, [Predicate[string]] { param($l) $l -match "config\.mak" -and $l -match "arm64EC" })
        $append | Should -BeGreaterThan 0
        # Append nutzt "+=", nicht die rekursive Selbstreferenz "=$(CFLAGS)".
        ($bash -join "`n") | Should -Match "CFLAGS \+= -arm64EC"
        ($bash -join "`n") | Should -Match "LDFLAGS \+= -MACHINE:arm64EC"
        ($bash -join "`n") | Should -Not -Match 'CFLAGS=\$\(CFLAGS\)'
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
