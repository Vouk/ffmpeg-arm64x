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
    $flags.Add('--enable-shared')
    $flags.Add('--disable-static')
    $flags.Add("--arch=$archKey")
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
