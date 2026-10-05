<#
.SYNOPSIS
    Baut die externen FFmpeg-Bibliotheken (x264, x265) für ARM64 und
    ARM64EC und prüft die Hardware-Encoding-Header (AMF, nv-codec-headers) im
    Preflight.

.DESCRIPTION
    Dieses Skript kapselt den Build der externen-Bibliotheken-Layer (Design C3)
    und wird vom GitHub-Workflow aufgerufen, bevor FFmpeg selbst gebaut wird.
    Es setzt die drei Verantwortlichkeiten aus Task 8.1 um:

      1. Header-Preflight (R5.5):
         Prüft, dass die AMF_Headers UND die nv-codec-headers vorhanden sind,
         BEVOR irgendein externer Codec gebaut wird. Fehlt einer der beiden
         Header, bricht das Skript ab, benennt den konkret fehlenden Header und
         erzeugt keine Teil-Artefakte (kein Codec-Build läuft an).

      2. Externe-Codec-Builds (R6.1/R6.2):
           - x264   via configure    (GPL, nur GPL-Variante)
           - x265   via cmake        (GPL, nur GPL-Variante)
         Jeder Codec wird je Ziel-Architektur (arm64 und arm64ec) gebaut.

      3. Fehlende-Lib-Abbruch (R6.4):
         Kann eine erforderliche externe Bibliothek nicht gefunden/gebaut
         werden, bricht das Skript ab und benennt die konkret fehlende
         Bibliothek — ohne ein unvollständiges Artefakt zu hinterlassen.

    Fail-fast: `$ErrorActionPreference = 'Stop'`; jeder fehlgeschlagene Schritt
    beendet den Lauf mit von Null verschiedenem Exit-Status.

    Lokale Testbarkeit: Die eigentliche MSVC/MSYS2/meson-Toolchain existiert nur
    auf dem CI-Runner. Damit die Preflight- und Orchestrierungslogik dennoch
    lokal überprüfbar ist, sind Quell-/Ausgabe-/Header-Pfade parametrisiert und
    das Skript unterstützt zwei Injektionspunkte:
      -DryRun       : plant die Builds, ohne echte Toolchain-Kommandos
                      auszuführen (Header-Preflight und Lib-Preflight laufen
                      trotzdem vollständig).
      -TestHooks    : eine Hashtable mit austauschbaren Callbacks
                      (PathTest / BuildX264 / BuildX265), damit
                      Tests die Datei-Existenz und die Codec-Builds simulieren
                      können, ohne echte Pfade/Tools zu benötigen.

.PARAMETER Variant
    Lizenz-Variante: 'gpl' oder 'lgpl' (case-insensitiv). Steuert, welche
    externen Codecs gebaut werden:
      - 'gpl'  : x264 + x265
      - 'lgpl' : keine externen Codec-Libs (x264/x265 sind ausschließlich GPL, R6.5)

.PARAMETER X264SourceDir
    Quellverzeichnis von x264 (enthält `configure`). Nur für die GPL-Variante
    erforderlich.

.PARAMETER X265SourceDir
    Quellverzeichnis von x265 (enthält `CMakeLists.txt`, i. d. R. im
    `source`-Unterordner). Nur für die GPL-Variante erforderlich.

.PARAMETER OutputDir
    Ausgabe-Wurzelverzeichnis. Je (Codec, Architektur) wird darunter ein
    Unterordner angelegt, in den Header und `.lib`/`.dll` der externen Libs
    installiert werden.

.PARAMETER AmfHeaderPath
    Pfad zur AMF-Header-Wurzel (muss existieren, R5.1/R5.3/R5.5). Erwartet wird
    entweder ein Verzeichnis oder eine repräsentative Header-Datei.

.PARAMETER NvCodecHeaderPath
    Pfad zur nv-codec-headers-Wurzel (muss existieren, R5.2/R5.4/R5.5). Erwartet
    wird entweder ein Verzeichnis oder eine repräsentative Header-Datei.

.PARAMETER Arch
    Zu bauende Ziel-Architekturen. Standard: beide ('arm64', 'arm64ec').

.PARAMETER DryRun
    Plant alle Schritte und führt Preflight-Prüfungen vollständig aus, ohne echte
    Toolchain-Kommandos zu starten. Für lokale Verifikation der Orchestrierung.

.PARAMETER TestHooks
    Optionale Hashtable mit Callbacks zur lokalen Testbarkeit:
      PathTest   : [scriptblock] { param($Path) [bool] } — ersetzt die
                   Datei-/Verzeichnis-Existenzprüfung (Test-Path).
      BuildX264  : [scriptblock] { param($Ctx) } — ersetzt den x264-Build.
      InstallHwHeaders : [scriptblock] { param($Prefix) } - ersetzt das Ablegen
                   der AMF-/nv-codec-Header (Schritt 3b).
      BuildX265  : [scriptblock] { param($Ctx) } — ersetzt den x265-Build.
    Wirft ein Callback, gilt der Codec-Build als fehlgeschlagen (R6.4).

.OUTPUTS
    [pscustomobject] mit einer Zusammenfassung der geplanten/ausgeführten Builds
    (Variant, Architekturen, gebaute Codecs, OutputDir). Bei Fehlern wird
    stattdessen ein terminierender Fehler ausgelöst.

.EXAMPLE
    ./scripts/build-deps.ps1 -Variant gpl `
        -X264SourceDir C:\src\x264 -X265SourceDir C:\src\x265 `
        -OutputDir C:\out\deps `
        -AmfHeaderPath C:\headers\AMF -NvCodecHeaderPath C:\headers\nv-codec-headers

.EXAMPLE
    # Lokaler Trockenlauf: prüft Preflight-Logik, ohne echte Tools.
    ./scripts/build-deps.ps1 -Variant lgpl -OutputDir .\out `
        -AmfHeaderPath .\AMF -NvCodecHeaderPath .\nv -DryRun

.NOTES
    Feature: arm64x-ffmpeg-build
    Task: 8.1
    Requirements: 5.5, 6.4, 6.1, 6.2
    Design: Architecture (Schritt 7 "Externe Libs bauen"), C2/C3, Error Handling
            (AMF/NV-Header fehlt -> R5.5; Externe Lib fehlt (GPL) -> R6.4)
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateSet('gpl', 'lgpl', IgnoreCase = $true)]
    [string] $Variant,

    [string] $X264SourceDir,

    [string] $X265SourceDir,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDir,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $AmfHeaderPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $NvCodecHeaderPath,

    [ValidateSet('arm64', 'arm64ec', IgnoreCase = $true)]
    [string[]] $Arch = @('arm64', 'arm64ec'),

    [switch] $DryRun,

    [hashtable] $TestHooks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Hilfsfunktionen (reine Orchestrierungslogik, injizierbar für lokale Tests)
# ---------------------------------------------------------------------------

function ConvertTo-Msys2Path {
    <#
    .SYNOPSIS
        Wandelt einen Windows-Pfad in einen MSYS2/POSIX-Pfad um
        (z. B. C:\src\x264 -> /c/src/x264). Reine String-Transformation.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)
    $pp = $Path -replace '\\', '/'
    if ($pp -match '^([A-Za-z]):(/.*)?$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = if ($Matches[2]) { $Matches[2] } else { '/' }
        $pp = "/$drive$rest"
    }
    return $pp
}

function Resolve-PathTester {
    <#
    .SYNOPSIS
        Liefert die zu verwendende Existenzprüfung (echt oder injiziert).
    #>
    [OutputType([scriptblock])]
    param([hashtable] $Hooks)

    if ($Hooks -and $Hooks.ContainsKey('PathTest') -and $Hooks.PathTest) {
        return [scriptblock] $Hooks.PathTest
    }
    return { param($Path) Test-Path -LiteralPath $Path }
}

function Test-HeaderPreflight {
    <#
    .SYNOPSIS
        Preflight-Prüfung der Hardware-Encoding-Header (R5.5).
    .DESCRIPTION
        Prüft, dass sowohl die AMF_Headers als auch die nv-codec-headers
        vorhanden sind. Fehlt einer, wird ein terminierender Fehler ausgelöst,
        der den konkret fehlenden Header benennt. Diese Prüfung läuft VOR jedem
        Codec-Build, sodass bei fehlendem Header keine Teil-Artefakte entstehen.
    .OUTPUTS
        Nichts bei Erfolg; wirft bei fehlendem Header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AmfHeaderPath,
        [Parameter(Mandatory)] [string] $NvCodecHeaderPath,
        [Parameter(Mandatory)] [scriptblock] $PathTester
    )

    # Reihenfolge fixiert (AMF vor nv-codec), damit die Benennung deterministisch
    # ist. Es werden ALLE fehlenden Header gesammelt und gemeinsam benannt.
    $required = [ordered]@{
        'AMF_Headers'      = $AmfHeaderPath
        'nv-codec-headers' = $NvCodecHeaderPath
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $required.Keys) {
        $path = $required[$name]
        $exists = [bool] (& $PathTester $path)
        if (-not $exists) {
            $missing.Add("$name (erwartet unter '$path')")
        }
    }

    if ($missing.Count -gt 0) {
        # R5.5: Abbruch mit Benennung des/der fehlenden Header, keine Teil-Artefakte.
        $named = $missing -join '; '
        throw "Header-Preflight fehlgeschlagen: fehlende Hardware-Encoding-Header: $named. " +
              "Der Build wird vor jeder Codec-Kompilierung abgebrochen; es werden keine " +
              "Teil-Artefakte erzeugt (R5.5)."
    }
}

function Get-RequiredCodec {
    <#
    .SYNOPSIS
        Liefert die je Variante zu bauenden externen Codecs (Design C3).
    .DESCRIPTION
        GPL  -> x264, x265
        LGPL -> keine externen Codec-Libs (x264/x265 sind ausschließlich GPL, R6.5)
        Jeder Eintrag nennt Name, Build-System und das Quellverzeichnis.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [string] $Variant,
        [string] $X264SourceDir,
        [string] $X265SourceDir
    )

    $variantKey = $Variant.ToLowerInvariant()

    $codecs = [System.Collections.Generic.List[pscustomobject]]::new()

    if ($variantKey -eq 'gpl') {
        # x264: GPL, configure (R6.1).
        $codecs.Add([pscustomobject]@{
            Name        = 'x264'
            BuildSystem = 'configure'
            SourceDir   = $X264SourceDir
            HookName    = 'BuildX264'
            Requirement = 'R6.1'
        })
        # x265: GPL, cmake (R6.2).
        $codecs.Add([pscustomobject]@{
            Name        = 'x265'
            BuildSystem = 'cmake'
            SourceDir   = $X265SourceDir
            HookName    = 'BuildX265'
            Requirement = 'R6.2'
        })
    }

    return , ([pscustomobject[]] $codecs.ToArray())
}

function Test-CodecSourcePreflight {
    <#
    .SYNOPSIS
        Prüft, dass zu jedem erforderlichen Codec das Quellverzeichnis existiert
        (R6.4).
    .DESCRIPTION
        Läuft VOR den Codec-Builds. Fehlt das Quellverzeichnis einer
        erforderlichen externen Bibliothek (oder ist es leer/nicht gesetzt),
        wird ein terminierender Fehler mit Benennung der Bibliothek ausgelöst,
        ohne dass ein Build angelaufen ist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [pscustomobject[]] $Codec,
        [Parameter(Mandatory)] [scriptblock] $PathTester
    )

    foreach ($c in $Codec) {
        if ([string]::IsNullOrWhiteSpace($c.SourceDir)) {
            throw "Externe Bibliothek '$($c.Name)' fehlt: kein Quellverzeichnis angegeben " +
                  "(erforderlich für die $($c.Requirement)-Einbindung). Abbruch ohne " +
                  "Teil-Artefakt (R6.4)."
        }
        $exists = [bool] (& $PathTester $c.SourceDir)
        if (-not $exists) {
            throw "Externe Bibliothek '$($c.Name)' fehlt: Quellverzeichnis " +
                  "'$($c.SourceDir)' nicht gefunden. Abbruch ohne Teil-Artefakt (R6.4)."
        }
    }
}

function Invoke-CodecBuild {
    <#
    .SYNOPSIS
        Führt den Build eines Codecs für eine Architektur aus (oder plant ihn im
        DryRun / delegiert an einen Test-Hook).
    .DESCRIPTION
        Auf dem CI-Runner ruft diese Funktion die echte Toolchain je Build-System
        auf (meson/ninja, configure/make, cmake). Lokal (DryRun oder TestHooks)
        wird stattdessen geplant bzw. an einen injizierten Callback delegiert.
        Schlägt der Build fehl, wird ein terminierender Fehler mit Benennung der
        Bibliothek ausgelöst (R6.4).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Codec,
        [Parameter(Mandatory)] [string] $Arch,
        [Parameter(Mandatory)] [string] $OutputDir,
        [switch] $DryRun,
        [hashtable] $Hooks
    )

    $ctx = [pscustomobject]@{
        Codec       = $Codec.Name
        BuildSystem = $Codec.BuildSystem
        SourceDir   = $Codec.SourceDir
        Arch        = $Arch
        OutputDir   = (Join-Path $OutputDir (Join-Path $Codec.Name $Arch))
    }

    # 1) Test-Hook hat Vorrang (lokale Simulation).
    if ($Hooks -and $Hooks.ContainsKey($Codec.HookName) -and $Hooks[$Codec.HookName]) {
        try {
            & ([scriptblock] $Hooks[$Codec.HookName]) $ctx
        }
        catch {
            throw "Externe Bibliothek '$($Codec.Name)' konnte für Architektur " +
                  "'$Arch' nicht gebaut werden: $($_.Exception.Message) (R6.4)."
        }
        return $ctx
    }

    # 2) Trockenlauf: nur planen.
    if ($DryRun) {
        Write-Verbose ("[DryRun] {0} ({1}) -> {2}" -f $Codec.Name, $Codec.BuildSystem, $ctx.OutputDir)
        return $ctx
    }

    # 3) Echter Build auf dem CI-Runner. Die konkreten Toolchain-Kommandos je
    #    Build-System werden hier ausgeführt; jeder Fehler ist terminierend
    #    (ErrorActionPreference = Stop) und wird als "Lib fehlt/baubar nicht"
    #    (R6.4) berichtet.
    try {
        switch ($Codec.BuildSystem) {
            'configure' {
                Invoke-X264Build -Ctx $ctx
            }
            'cmake' {
                Invoke-X265Build -Ctx $ctx
            }
            default {
                throw "Unbekanntes Build-System '$($Codec.BuildSystem)' für '$($Codec.Name)'."
            }
        }
    }
    catch {
        throw "Externe Bibliothek '$($Codec.Name)' konnte für Architektur '$Arch' " +
              "nicht gebaut werden: $($_.Exception.Message) (R6.4)."
    }

    return $ctx
}

function New-OutputDirectory {
    <#
    .SYNOPSIS
        Legt (falls nötig) das Ausgabe-Verzeichnis für eine (Codec, Arch)-Einheit an.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Echte Toolchain-Aufrufe (nur auf dem CI-Runner; lokal via DryRun/Hooks ersetzt)
# ---------------------------------------------------------------------------

function Invoke-X264Build {
    <#
    .SYNOPSIS
        Baut x264 via configure/make für die im Kontext genannte Architektur.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Ctx)

    New-OutputDirectory -Path $Ctx.OutputDir

    $srcPosix    = ConvertTo-Msys2Path -Path $Ctx.SourceDir
    $prefixPosix = ConvertTo-Msys2Path -Path $Ctx.OutputDir

    # ARM64-Cross-Kompilierung mit MSVC. ENTSCHEIDEND: CC=cl, damit x264s
    # configure den ARM64-cl.exe (aus vcvarsamd64_arm64.bat) nutzt und per
    # _M_ARM64 ARCH=AARCH64 setzt. Ohne CC=cl faellt configure auf MSYS2s
    # natives x86_64-gcc zurueck und kompiliert x86-SSE-Code (common/x86,
    # __m128/v4si) -> Build bricht fuer ARM64 ab. --disable-asm: reiner C-Pfad.
    # ARM64EC-Ansicht: cl kompiliert mit /arm64EC, UND der Linker muss mit
    # /MACHINE:arm64EC gefuettert werden -- sonst lehnt link.exe die EC-Objekte
    # als "Incompatible object type" ab (LNK1392), weil er sonst nach reinem
    # ARM64 linkt. Compile- UND Link-Maschine muessen uebereinstimmen.
    # ARM64EC: cl kompiliert mit -arm64EC, der DLL-/EXE-Linker braucht
    # -MACHINE:arm64EC. ZUSAETZLICH beim STATISCHEN Build der Archivar:
    # x264 archiviert unter MSVC mit `AR="lib.exe -nologo -out:"` -- OHNE
    # /machine. lib.exe lehnt dann die EC-Objekte mit LNK1392 ab
    # ("Incompatible object type ... /machine:arm64ec?", CI 37350015929).
    # Daher AR fuer die EC-Ansicht ueberschreiben und /machine:arm64ec an den
    # Archivar reichen. x264s configure uebernimmt ein von aussen gesetztes AR
    # (configure nutzt AR="${AR-...}"). Fuer die reine ARM64-Ansicht bleibt AR
    # ungesetzt (x264-Default).
    if ($Ctx.Arch -eq 'arm64ec') {
        $ecFlags = ' --extra-cflags=-arm64EC --extra-ldflags=-MACHINE:arm64EC'
        $arOverride = "AR='lib.exe -nologo -machine:arm64ec -out:' "
    } else {
        $ecFlags = ''
        $arOverride = ''
    }
    # STATISCH bauen: --enable-static --disable-shared erzeugt die statische
    # Archiv-Lib libx264.lib (KEINE DLL + Import-Lib). FFmpeg linkt sie dann
    # direkt in avcodec ein, sodass zur Laufzeit KEINE libx264-*.dll noetig ist.
    $configure = "${arOverride}CC=cl ./configure --prefix='$prefixPosix' --enable-static --disable-shared --disable-cli " +
                 "--host=aarch64-w64-mingw32 --disable-asm" + $ecFlags
    # cl.exe muss im bash-PATH sichtbar sein (vcvars + MSYS2 PATH-inherit).
    & bash -lc "cd '$srcPosix' && $configure" 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        $cfgLog = Join-Path $Ctx.SourceDir 'config.log'
        if (Test-Path -LiteralPath $cfgLog) {
            Write-Host '----- x264 config.log (letzte 60 Zeilen) -----'
            Get-Content -LiteralPath $cfgLog -Tail 60 | ForEach-Object { Write-Host $_ }
        }
        throw "x264 configure schlug fehl (Exit $LASTEXITCODE)."
    }
    & bash -lc "cd '$srcPosix' && make -j && make install" 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "x264 make/install schlug fehl (Exit $LASTEXITCODE)." }
    # Statischer Build: x264 installiert die Archiv-Lib als libx264.lib (bei
    # MSVC ggf. ohne lib-Praefix als x264.lib). FFmpegs MSVC-Wrapper sucht fuer
    # -lx264 nach x264.lib bzw. libx264.lib. Sicherstellen, dass beide Namen
    # existieren (Alias der tatsaechlich installierten Archiv-Lib), sonst
    # LNK1181. Die alte DLL-Import-Lib (libx264.dll.lib) entfaellt im
    # statischen Build.
    $libDir = Join-Path $Ctx.OutputDir 'lib'
    $srcLib = $null
    foreach ($cand in @('libx264.lib', 'x264.lib', 'libx264.a')) {
        $cp = Join-Path $libDir $cand
        if (Test-Path -LiteralPath $cp) { $srcLib = $cp; break }
    }
    if ($srcLib) {
        foreach ($alias in @('libx264.lib', 'x264.lib')) {
            $dest = Join-Path $libDir $alias
            if ([string]::Equals($dest, $srcLib, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            Copy-Item -LiteralPath $srcLib -Destination $dest -Force
        }
        Write-Host "x264: statische Archiv-Lib ($([System.IO.Path]::GetFileName($srcLib))) -> Alias libx264.lib/x264.lib."
    } else {
        Write-Host 'WARN: statische x264-Lib nicht gefunden; kein Alias angelegt.'
    }
}

function Invoke-X265Build {
    <#
    .SYNOPSIS
        Baut x265 via cmake für die im Kontext genannte Architektur.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Ctx)

    New-OutputDirectory -Path $Ctx.OutputDir
    $buildDir = Join-Path $Ctx.OutputDir 'cmake-build'
    # x265 hält seine CMakeLists.txt üblicherweise im 'source'-Unterordner.
    $cmakeSource = Join-Path $Ctx.SourceDir 'source'
    if (-not (Test-Path -LiteralPath (Join-Path $cmakeSource 'CMakeLists.txt'))) {
        $cmakeSource = $Ctx.SourceDir
    }

    # ARM64-Cross-Kompilierung mit MSVC ueber Ninja + dem via %VCVARS%
    # gesetzten cl.exe (kein VS-ARM64-Generator auf dem Image). SYSTEM_NAME/
    # PROCESSOR deklarieren das ARM64-Ziel; CROSS_COMPILE_ARM aktiviert x265s
    # ARM-Pfad; ASSEMBLY aus (arm-asm braucht gas, nicht MSVC-armasm).
    $cflags = if ($Ctx.Arch -eq 'arm64ec') { '/arm64EC' } else { '' }
    $cmakeArgs = @(
        '-S', $cmakeSource, '-B', $buildDir,
        '-G', 'Ninja',
        "-DCMAKE_INSTALL_PREFIX=$($Ctx.OutputDir)",
        '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_SYSTEM_NAME=Windows',
        '-DCMAKE_SYSTEM_PROCESSOR=ARM64',
        '-DCMAKE_C_COMPILER=cl',
        '-DCMAKE_CXX_COMPILER=cl',
        # STATISCH bauen: ENABLE_SHARED=OFF erzeugt die statische Archiv-Lib
        # libx265.lib (KEINE x265-*.dll + Import-Lib). FFmpeg linkt sie direkt
        # in avcodec ein -> zur Laufzeit KEINE x265-DLL noetig.
        '-DENABLE_SHARED=OFF',
        '-DENABLE_CLI=OFF',
        '-DENABLE_ASSEMBLY=OFF',
        '-DCROSS_COMPILE_ARM=ON'
    )
    if ($cflags) {
        $cmakeArgs += "-DCMAKE_C_FLAGS=$cflags"
        $cmakeArgs += "-DCMAKE_CXX_FLAGS=$cflags"
        # Link-Maschine muss zur Compile-Maschine passen, sonst LNK1392
        # (Incompatible object type) wie bei x264. /MACHINE:arm64EC fuer alle
        # Link-Arten (shared/exe/static-lib).
        $ldm = '/MACHINE:arm64EC'
        $cmakeArgs += "-DCMAKE_SHARED_LINKER_FLAGS=$ldm"
        $cmakeArgs += "-DCMAKE_EXE_LINKER_FLAGS=$ldm"
        $cmakeArgs += "-DCMAKE_STATIC_LINKER_FLAGS=$ldm"
    }
    & cmake @cmakeArgs 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "x265 cmake configure schlug fehl (Exit $LASTEXITCODE)." }
    & cmake --build $buildDir 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "x265 cmake build schlug fehl (Exit $LASTEXITCODE)." }
    & cmake --install $buildDir 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "x265 cmake install schlug fehl (Exit $LASTEXITCODE)." }
    # x265 installiert libx265.lib; FFmpegs MSVC-Wrapper sucht fuer -lx265
    # jedoch x265.lib (LNK1181: cannot open input file x265.lib). Alias der
    # vorhandenen Import-Lib auf x265.lib (und libx265.lib) anlegen.
    $libDir = Join-Path $Ctx.OutputDir 'lib'
    $srcLib = $null
    foreach ($cand in @('libx265.lib', 'libx265.dll.lib', 'x265.lib')) {
        $cp = Join-Path $libDir $cand
        if (Test-Path -LiteralPath $cp) { $srcLib = $cp; break }
    }
    if ($srcLib) {
        foreach ($alias in @('x265.lib', 'libx265.lib')) {
            $dest = Join-Path $libDir $alias
            # Nicht auf sich selbst kopieren: Copy-Item wirft sonst
            # Cannot overwrite the item ... with itself.
            if ([string]::Equals($dest, $srcLib, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            Copy-Item -LiteralPath $srcLib -Destination $dest -Force
        }
        Write-Host 'x265: Import-Lib-Alias x265.lib/libx265.lib angelegt.'
    } else {
        Write-Host 'WARN: x265 Import-Lib nicht gefunden; kein Alias angelegt.'
    }
}

# ---------------------------------------------------------------------------
# Orchestrierung
# ---------------------------------------------------------------------------

function Install-HwHeaders {
    <#
    .SYNOPSIS
        Legt AMF- und nv-codec-Header so ab, wie FFmpegs configure sie sucht
        (R5.1-R5.4).
    .DESCRIPTION
        * AMF: FFmpeg inkludiert <AMF/core/Version.h>; im AMF-Repo liegen die
          Header unter amf/public/include. Ziel: <Prefix>/include/AMF.
        * nv-codec-headers: FFmpeg findet ffnvcodec NUR ueber pkg-config.
          Ziel: <Prefix>/include/ffnvcodec plus <Prefix>/lib/pkgconfig/
          ffnvcodec.pc aus ffnvcodec.pc.in. Entspricht make install des Repos
          (Prefix in gemischter Form D:/..., wie dort per cygpath -m).
        Prefix ist <OutputDir>/hwheaders.
    .OUTPUTS
        [string] Der Prefix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $AmfHeaderPath,
        [Parameter(Mandatory)] [string] $NvCodecHeaderPath,
        [Parameter(Mandatory)] [string] $OutputDir
    )

    $prefix  = Join-Path $OutputDir 'hwheaders'
    $include = Join-Path $prefix 'include'
    $amfDest = Join-Path $include 'AMF'
    $nvDest  = Join-Path $include 'ffnvcodec'
    $pcDir   = Join-Path (Join-Path $prefix 'lib') 'pkgconfig'
    foreach ($d in @($amfDest, $nvDest, $pcDir)) { New-OutputDirectory -Path $d }

    # AMF: Inhalt von amf/public/include nach include/AMF.
    Copy-Item -Path (Join-Path $AmfHeaderPath '*') -Destination $amfDest -Recurse -Force
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $amfDest 'core') 'Version.h'))) {
        throw "AMF-Header unvollstaendig: core/Version.h fehlt unter '$AmfHeaderPath'."
    }

    # nv-codec-headers: include/ffnvcodec/*.h nach include/ffnvcodec.
    $nvSrc = Join-Path $NvCodecHeaderPath 'ffnvcodec'
    if (-not (Test-Path -LiteralPath (Join-Path $nvSrc 'nvEncodeAPI.h'))) {
        throw "nv-codec-headers unvollstaendig: ffnvcodec/nvEncodeAPI.h fehlt unter '$NvCodecHeaderPath'."
    }
    Copy-Item -Path (Join-Path $nvSrc '*') -Destination $nvDest -Recurse -Force

    # ffnvcodec.pc aus ffnvcodec.pc.in (liegt in der Repo-Wurzel, also im
    # Elternordner von include). Ohne .pc meldet configure fuer nvdec/nvenc
    # not all dependencies are satisfied: ffnvcodec.
    $pcIn = Join-Path (Split-Path -Parent $NvCodecHeaderPath) 'ffnvcodec.pc.in'
    if (-not (Test-Path -LiteralPath $pcIn)) {
        throw "ffnvcodec.pc.in nicht gefunden: '$pcIn'."
    }
    $prefixMixed = (Resolve-Path -LiteralPath $prefix).Path.Replace('\', '/')
    $pc = [System.IO.File]::ReadAllText($pcIn).Replace('@@PREFIX@@', $prefixMixed)
    [System.IO.File]::WriteAllText((Join-Path $pcDir 'ffnvcodec.pc'), $pc, (New-Object System.Text.UTF8Encoding($false)))

    return $prefix
}

function Invoke-BuildDeps {
    <#
    .SYNOPSIS
        Führt Preflight und Codec-Builds in der korrekten Reihenfolge aus.
    .DESCRIPTION
        Reihenfolge (Fail-fast):
          1. Header-Preflight (R5.5) — vor allem anderen.
          2. Codec-Quell-Preflight (R6.4) — vor jedem Build.
          3. Codec-Builds je Architektur (R6.1/R6.2).
        Diese Funktion bündelt die reine Orchestrierung, damit sie testbar bleibt.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Variant,
        [string] $X264SourceDir,
        [string] $X265SourceDir,
        [Parameter(Mandatory)] [string] $OutputDir,
        [Parameter(Mandatory)] [string] $AmfHeaderPath,
        [Parameter(Mandatory)] [string] $NvCodecHeaderPath,
        [Parameter(Mandatory)] [string[]] $Arch,
        [switch] $DryRun,
        [hashtable] $Hooks
    )

    $pathTester = Resolve-PathTester -Hooks $Hooks

    # --- Schritt 1: Header-Preflight (R5.5) --------------------------------
    # Läuft vor jeder Kompilierung; bei fehlendem Header Abbruch, keine Teil-Artefakte.
    Test-HeaderPreflight -AmfHeaderPath $AmfHeaderPath `
        -NvCodecHeaderPath $NvCodecHeaderPath -PathTester $pathTester

    # --- Schritt 2: erforderliche Codecs je Variante ermitteln -------------
    $codecs = Get-RequiredCodec -Variant $Variant `
        -X264SourceDir $X264SourceDir `
        -X265SourceDir $X265SourceDir

    # --- Schritt 3: Codec-Quell-Preflight (R6.4) ---------------------------
    # Vor jedem Build: fehlt eine erforderliche Lib, Abbruch mit Benennung.
    Test-CodecSourcePreflight -Codec $codecs -PathTester $pathTester

    # --- Schritt 3b: Hardware-Header fuer FFmpeg ablegen (R5.1-R5.4) -------
    # Erst nach beiden Preflights, damit bei einem Abbruch keine
    # Teil-Artefakte entstehen. Im DryRun wird nichts geschrieben; Tests
    # koennen den Schritt ueber den Hook InstallHwHeaders ersetzen.
    $hwPrefix = Join-Path $OutputDir 'hwheaders'
    if ($Hooks -and $Hooks.ContainsKey('InstallHwHeaders') -and $Hooks.InstallHwHeaders) {
        & ([scriptblock] $Hooks.InstallHwHeaders) $hwPrefix
    }
    elseif (-not $DryRun) {
        $hwPrefix = Install-HwHeaders -AmfHeaderPath $AmfHeaderPath `
            -NvCodecHeaderPath $NvCodecHeaderPath -OutputDir $OutputDir
        Write-Host "Hardware-Header abgelegt: $hwPrefix"
    }

    # --- Schritt 4: Builds je (Codec, Architektur) -------------------------
    $built = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($codec in $codecs) {
        foreach ($a in $Arch) {
            $result = Invoke-CodecBuild -Codec $codec -Arch $a.ToLowerInvariant() `
                -OutputDir $OutputDir -DryRun:$DryRun -Hooks $Hooks
            $built.Add($result)
        }
    }

    return [pscustomobject]@{
        Variant     = $Variant.ToLowerInvariant()
        Arch        = [string[]] ($Arch | ForEach-Object { $_.ToLowerInvariant() })
        Codecs      = [string[]] ($codecs | ForEach-Object { $_.Name })
        OutputDir   = $OutputDir
        HwHeaders   = $hwPrefix
        BuiltUnits  = [pscustomobject[]] $built.ToArray()
        DryRun      = [bool] $DryRun
    }
}

# ---------------------------------------------------------------------------
# Einstiegspunkt: nur ausführen, wenn das Skript direkt aufgerufen wird
# (nicht beim Dot-Sourcing durch Tests).
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $summary = Invoke-BuildDeps -Variant $Variant `
        -X264SourceDir $X264SourceDir `
        -X265SourceDir $X265SourceDir `
        -OutputDir $OutputDir `
        -AmfHeaderPath $AmfHeaderPath `
        -NvCodecHeaderPath $NvCodecHeaderPath `
        -Arch $Arch `
        -DryRun:$DryRun `
        -Hooks $TestHooks

    $dryRunNote = if ($summary.DryRun) { ' (DryRun)' } else { '' }
    $codecList = $summary.Codecs -join ', '
    $archList = $summary.Arch -join ', '
    Write-Host ("build-deps: Variante '{0}' - Codecs [{1}] fuer Architekturen [{2}]{3}." -f $summary.Variant, $codecList, $archList, $dryRunNote)

    $summary
}
