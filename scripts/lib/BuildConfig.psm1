<#
.SYNOPSIS
    Reine Logik zur Zusammensetzung der FFmpeg-`configure`-Flags.

.DESCRIPTION
    Kapselt die `configure`-Flag-Zusammensetzung fuer den LGPL-Build und die
    Ziel-Architektur (arm64 vs. arm64ec) als reine, testbare Funktion ohne
    Seiteneffekte. Das Ergebnis ist die Menge der `configure`-Flags, die der
    Build-Schritt (siehe scripts/build-ffmpeg.ps1) an FFmpegs `configure`
    weiterreicht.

    Es wird AUSSCHLIESSLICH die LGPL-Variante gebaut, als Shared Libraries
    (DLL + Import-.lib) und OHNE GPL-Komponenten (kein --enable-gpl, kein
    libx264/libx265). Die Hardware-Encoder AMF (AMD) und NVENC/NVDEC (NVIDIA)
    sind eingebunden -- sie sind header-only SDK-Integrationen, die zur Laufzeit
    geladen werden und LGPL-vertraeglich sind.

    Zusammensetzung:
        --toolchain=msvc --target-os=win32
        --enable-cross-compile --pkg-config-flags=--static
        --disable-asm --disable-filter=gfxcapture
        --enable-shared --disable-static
        --arch=arm64  (die arm64ec-Ansicht entsteht ueber cl /arm64EC +
                       link /machine:arm64ec, nicht ueber --arch)
        --enable-amf                    (AMF-Header)
        --enable-nvenc --enable-nvdec   (nv-codec-headers)
        fuer arm64ec zusaetzlich:
          --extra-cflags=-arm64EC --extra-ldflags=-machine:arm64ec
#>

Set-StrictMode -Version Latest

function Get-ConfigureFlags {
    <#
    .SYNOPSIS
        Liefert die FFmpeg-`configure`-Flags fuer eine Architektur (LGPL).

    .PARAMETER Arch
        Ziel-Architektur: 'arm64' oder 'arm64ec' (case-insensitiv). Bestimmt die
        ARM64EC-Compiler-/Linker-Flags.

    .OUTPUTS
        [string[]] Die Liste der `configure`-Flags. Enthaelt immer
        `--enable-shared --disable-static` sowie `--enable-amf`,
        `--enable-nvenc`, `--enable-nvdec` und NIE `--enable-gpl`,
        `--enable-libx264` oder `--enable-libx265`.

    .EXAMPLE
        Get-ConfigureFlags -Arch arm64
    .EXAMPLE
        Get-ConfigureFlags -Arch arm64ec
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('arm64', 'arm64ec', IgnoreCase = $true)]
        [string] $Arch
    )

    $archKey = $Arch.ToLowerInvariant()

    # Flags (LGPL, Shared, HW-Encoder AMF+NVENC/NVDEC). Reihenfolge deterministisch.
    $flags = [System.Collections.Generic.List[string]]::new()
    $flags.Add('--toolchain=msvc')
    $flags.Add('--target-os=win32')
    # Cross-Compile auf x64-Host nach ARM64: der ARM64-cl.exe kann kein auf
    # dem Host lauffaehiges Testprogramm erzeugen; --enable-cross-compile
    # ueberspringt FFmpegs "run a test binary"-Pruefung (sonst: C compiler
    # test failed / cl.exe is unable to create an executable file).
    $flags.Add('--enable-cross-compile')
    # pkg-config im Static-Modus. Fuer den LGPL-Build ohne externe Codecs ist
    # das Flag folgenlos, bleibt aber als sichere Vorgabe erhalten.
    $flags.Add('--pkg-config-flags=--static')
    # ARM64-NEON-Assembler via MSVC braeuchte gas-preprocessor.pl + armasm64
    # (configure sonst: "GNU assembler not found, install/update
    # gas-preprocessor"). Es wird der reine C-Pfad gebaut.
    $flags.Add('--disable-asm')
    # gfxcapture-Filter deaktivieren (beide Ansichten): Der Filter besteht aus
    # vsrc_gfxcapture.o (C) + vsrc_gfxcapture_winrt.o (C++/WinRT). Unter ARM64EC
    # exportiert das C++-WinRT-Objekt die vom C-Teil erwarteten Symbole nicht in
    # der EC-Mangling-Form -> Linkfehler LNK2001 "unresolved external symbol
    # #ff_gfxcapture_init (EC Symbol)". gfxcapture ist eine
    # Windows-Graphics-Capture-Bildschirmquelle, kein Kern-Codec; sie wird fuer
    # BEIDE Architekturen deaktiviert, damit arm64 und arm64ec denselben
    # Filter-/Symbolsatz haben (sauberer ARM64X-Merge je Basisname).
    $flags.Add('--disable-filter=gfxcapture')
    # Shared/DLL-only: FFmpeg wird ausschliesslich als DLL + Import-.lib gebaut.
    $flags.Add('--enable-shared')
    $flags.Add('--disable-static')
    # FFmpeg kennt KEINE arch 'arm64ec' -- fuer beide Ansichten ist die
    # FFmpeg-Arch arm64. Die ARM64EC-Ansicht entsteht ueber cl /arm64EC und
    # link /MACHINE:arm64EC, nicht ueber --arch.
    $flags.Add('--arch=arm64')
    if ($archKey -eq 'arm64ec') {
        $flags.Add('--extra-cflags=-arm64EC')
        # WICHTIG: Der Linker-Maschinen-Flag MUSS kleingeschrieben sein
        # (-machine:arm64ec). compat/windows/makedef erzeugt eine temporaere
        # Lib, um Symbole fuer die .def zu extrahieren, und haengt an sein
        # lib.exe nur dann -machine:arm64ec an, wenn LDFLAGS den WORTWOERTLICHEN,
        # KLEINGESCHRIEBENEN Teilstring "machine:arm64ec" enthaelt (shell-case,
        # case-sensitiv). link.exe akzeptiert die Option case-insensitiv.
        $flags.Add('--extra-ldflags=-machine:arm64ec')
    }

    # Hardware-Encoder (LGPL-vertraeglich, header-only SDK-Integrationen).
    $flags.Add('--enable-amf')       # AMD AMF (AMF-Header)
    $flags.Add('--enable-nvenc')     # NVIDIA NVENC (nv-codec-headers)
    $flags.Add('--enable-nvdec')     # NVIDIA NVDEC (nv-codec-headers)

    # Als string[] zurueckgeben (nicht als einzelne Pipeline-Elemente, damit der
    # Aufrufer eine stabile Array-Semantik erhaelt).
    return , [string[]]$flags.ToArray()
}

Export-ModuleMember -Function Get-ConfigureFlags
