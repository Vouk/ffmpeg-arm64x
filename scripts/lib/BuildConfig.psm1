<#
.SYNOPSIS
    Reine Logik zur Zusammensetzung der FFmpeg-`configure`-Flags je Build-Variante.

.DESCRIPTION
    Kapselt die Varianten-Flag-Zusammensetzung (GPL vs. LGPL) und die
    Ziel-Architektur (arm64 vs. arm64ec) als reine, testbare Funktion ohne
    Seiteneffekte. Das Ergebnis ist die Menge der `configure`-Flags, die der
    Build-Schritt (siehe scripts/build-ffmpeg.ps1) an FFmpegs `configure`
    weiterreicht.

    Design-Bezug: Data Models -> "configure-Flags je Variante" sowie
    Correctness Property 3 ("Die LGPL-Konfiguration schließt GPL-Komponenten
    immer aus").

    Requirements: 4.2, 4.3, 6.5, 5.1, 5.2, 5.3, 5.4

    Zusammensetzung:
      Gemeinsam (beide Varianten):
        --toolchain=msvc --target-os=win32
        --enable-shared --disable-static
        --arch=<arm64|arm64ec>
        --enable-amf                    (AMF-Header)        R5.1/R5.3
        --enable-nvenc --enable-nvdec   (nv-codec-headers)  R5.2/R5.4
      Nur GPL (zusätzlich):
        --enable-gpl                    R4.2
        --enable-libx264                R6.1
        --enable-libx265                R6.2
      LGPL: wie "Gemeinsam", ohne die GPL-Flags (R4.3, R6.5).
#>

Set-StrictMode -Version Latest

function Get-ConfigureFlags {
    <#
    .SYNOPSIS
        Liefert die FFmpeg-`configure`-Flags für eine (Variante, Architektur)-Kombination.

    .PARAMETER Variant
        Lizenz-Variante: 'gpl' oder 'lgpl' (case-insensitiv).

    .PARAMETER Arch
        Ziel-Architektur: 'arm64' oder 'arm64ec' (case-insensitiv). Bestimmt das
        `--arch=<...>`-Flag.

    .OUTPUTS
        [string[]] Die Liste der `configure`-Flags. Die GPL-Variante enthält
        `--enable-gpl`, `--enable-libx264` und `--enable-libx265`; die
        LGPL-Variante enthält keines dieser Flags.

    .EXAMPLE
        Get-ConfigureFlags -Variant gpl -Arch arm64
    .EXAMPLE
        Get-ConfigureFlags -Variant lgpl -Arch arm64ec
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('gpl', 'lgpl', IgnoreCase = $true)]
        [string] $Variant,

        [Parameter(Mandatory)]
        [ValidateSet('arm64', 'arm64ec', IgnoreCase = $true)]
        [string] $Arch
    )

    $variantKey = $Variant.ToLowerInvariant()
    $archKey = $Arch.ToLowerInvariant()

    # Gemeinsame Flags (beide Varianten). Reihenfolge ist deterministisch.
    $flags = [System.Collections.Generic.List[string]]::new()
    $flags.Add('--toolchain=msvc')
    $flags.Add('--target-os=win32')
    # Cross-Compile auf x64-Host nach ARM64: der ARM64-cl.exe kann kein auf
    # dem Host lauffaehiges Testprogramm erzeugen; --enable-cross-compile
    # ueberspringt FFmpegs "run a test binary"-Pruefung (sonst: C compiler
    # test failed / cl.exe is unable to create an executable file).
    $flags.Add('--enable-cross-compile')
    # x264/x265 werden STATISCH gebaut und direkt in avcodec eingelinkt (keine
    # x264/x265-DLL zur Laufzeit). Damit FFmpegs configure beim pkg-config-
    # Linktest die privaten Abhaengigkeiten der statischen Libs (Libs.private
    # aus x264.pc/x265.pc) beruecksichtigt, pkg-config im Static-Modus fahren.
    # Fuer die LGPL-Variante ohne externe Codecs ist das Flag folgenlos.
    $flags.Add('--pkg-config-flags=--static')
    # ARM64-NEON-Assembler via MSVC braeuchte gas-preprocessor.pl + armasm64
    # (configure sonst: "GNU assembler not found, install/update
    # gas-preprocessor"). Wie bei x264/x265 wird der reine C-Pfad gebaut.
    $flags.Add('--disable-asm')
    # gfxcapture-Filter deaktivieren (beide Ansichten): Der Filter besteht aus
    # vsrc_gfxcapture.o (C) + vsrc_gfxcapture_winrt.o (C++/WinRT). Unter ARM64EC
    # exportiert das C++-WinRT-Objekt die vom C-Teil erwarteten Symbole nicht in
    # der EC-Mangling-Form -> Linkfehler LNK2001 "unresolved external symbol
    # #ff_gfxcapture_init (EC Symbol)" (CI 37317832940). gfxcapture ist eine
    # Windows-Graphics-Capture-Bildschirmquelle, kein Kern-Codec; sie wird fuer
    # BEIDE Architekturen deaktiviert, damit arm64 und arm64ec denselben
    # Filter-/Symbolsatz haben (sauberer ARM64X-Merge je Basisname).
    $flags.Add('--disable-filter=gfxcapture')
    $flags.Add('--enable-shared')
    $flags.Add('--disable-static')
    # FFmpeg kennt KEINE arch 'arm64ec' -- fuer beide Ansichten ist die
    # FFmpeg-Arch arm64. Die ARM64EC-Ansicht entsteht ueber cl /arm64EC und
    # link /MACHINE:arm64EC (wie bei x264/x265), nicht ueber --arch.
    $flags.Add('--arch=arm64')
    if ($archKey -eq 'arm64ec') {
        $flags.Add('--extra-cflags=-arm64EC')
        # WICHTIG: Der Linker-Maschinen-Flag MUSS kleingeschrieben sein
        # (-machine:arm64ec). compat/windows/makedef erzeugt eine temporaere
        # Lib, um Symbole fuer die .def zu extrahieren, und haengt an sein
        # lib.exe nur dann -machine:arm64ec an, wenn LDFLAGS den WORTWOERTLICHEN,
        # KLEINGESCHRIEBENEN Teilstring "machine:arm64ec" enthaelt (shell-case,
        # case-sensitiv). Mit "-MACHINE:arm64EC" griff das NICHT -> makedef rief
        # lib.exe ohne EC-Maschine auf -> "Could not create temporary library"
        # (CI 37302790749). link.exe akzeptiert die Option case-insensitiv,
        # daher ist die Kleinschreibung fuer beide korrekt.
        $flags.Add('--extra-ldflags=-machine:arm64ec')
    }
    $flags.Add('--enable-amf')       # R5.1 / R5.3
    $flags.Add('--enable-nvenc')     # R5.2 / R5.4
    $flags.Add('--enable-nvdec')     # R5.2 / R5.4

    # GPL-spezifische Flags (nur GPL-Variante).
    if ($variantKey -eq 'gpl') {
        $flags.Add('--enable-gpl')      # R4.2
        $flags.Add('--enable-libx264')  # R6.1
        $flags.Add('--enable-libx265')  # R6.2
    }

    # Als string[] zurückgeben (nicht als einzelne Pipeline-Elemente, damit der
    # Aufrufer eine stabile Array-Semantik erhält).
    return , [string[]]$flags.ToArray()
}

Export-ModuleMember -Function Get-ConfigureFlags
