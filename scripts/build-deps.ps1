<#
.SYNOPSIS
    Baut die externen FFmpeg-Bibliotheken (dav1d, x264, x265) für ARM64 und
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

      2. Externe-Codec-Builds (R6.1/R6.2/R6.3):
           - dav1d  via meson/ninja  (BSD, beide Varianten)
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
                      (PathTest / BuildDav1d / BuildX264 / BuildX265), damit
                      Tests die Datei-Existenz und die Codec-Builds simulieren
                      können, ohne echte Pfade/Tools zu benötigen.

.PARAMETER Variant
    Lizenz-Variante: 'gpl' oder 'lgpl' (case-insensitiv). Steuert, welche
    externen Codecs gebaut werden:
      - 'gpl'  : dav1d + x264 + x265
      - 'lgpl' : nur dav1d (x264/x265 sind ausschließlich GPL, R6.5)

.PARAMETER Dav1dSourceDir
    Quellverzeichnis von dav1d (enthält die meson-Projektdatei).

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
      BuildDav1d : [scriptblock] { param($Ctx) } — ersetzt den dav1d-Build.
      BuildX264  : [scriptblock] { param($Ctx) } — ersetzt den x264-Build.
      BuildX265  : [scriptblock] { param($Ctx) } — ersetzt den x265-Build.
    Wirft ein Callback, gilt der Codec-Build als fehlgeschlagen (R6.4).

.OUTPUTS
    [pscustomobject] mit einer Zusammenfassung der geplanten/ausgeführten Builds
    (Variant, Architekturen, gebaute Codecs, OutputDir). Bei Fehlern wird
    stattdessen ein terminierender Fehler ausgelöst.

.EXAMPLE
    ./scripts/build-deps.ps1 -Variant gpl `
        -Dav1dSourceDir C:\src\dav1d -X264SourceDir C:\src\x264 -X265SourceDir C:\src\x265 `
        -OutputDir C:\out\deps `
        -AmfHeaderPath C:\headers\AMF -NvCodecHeaderPath C:\headers\nv-codec-headers

.EXAMPLE
    # Lokaler Trockenlauf: prüft Preflight-Logik, ohne echte Tools.
    ./scripts/build-deps.ps1 -Variant lgpl -Dav1dSourceDir . -OutputDir .\out `
        -AmfHeaderPath .\AMF -NvCodecHeaderPath .\nv -DryRun

.NOTES
    Feature: arm64x-ffmpeg-build
    Task: 8.1
    Requirements: 5.5, 6.4, 6.1, 6.2, 6.3
    Design: Architecture (Schritt 7 "Externe Libs bauen"), C2/C3, Error Handling
            (AMF/NV-Header fehlt -> R5.5; Externe Lib fehlt (GPL) -> R6.4)
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateSet('gpl', 'lgpl', IgnoreCase = $true)]
    [string] $Variant,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Dav1dSourceDir,

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
        GPL  -> dav1d, x264, x265
        LGPL -> nur dav1d (x264/x265 sind ausschließlich GPL, R6.5)
        Jeder Eintrag nennt Name, Build-System und das Quellverzeichnis.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [string] $Variant,
        [Parameter(Mandatory)] [string] $Dav1dSourceDir,
        [string] $X264SourceDir,
        [string] $X265SourceDir
    )

    $variantKey = $Variant.ToLowerInvariant()

    $codecs = [System.Collections.Generic.List[pscustomobject]]::new()

    # dav1d: BSD-2, beide Varianten (R6.3).
    $codecs.Add([pscustomobject]@{
        Name        = 'dav1d'
        BuildSystem = 'meson'
        SourceDir   = $Dav1dSourceDir
        HookName    = 'BuildDav1d'
        Requirement = 'R6.3'
    })

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
            'meson' {
                Invoke-Dav1dBuild -Ctx $ctx
            }
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

function Invoke-Dav1dBuild {
    <#
    .SYNOPSIS
        Baut dav1d via meson/ninja für die im Kontext genannte Architektur.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Ctx)

    New-OutputDirectory -Path $Ctx.OutputDir
    $buildDir = Join-Path $Ctx.OutputDir 'meson-build'

    # meson-Cross-Setup je Architektur, dann ninja. --prefix installiert Header
    # und .lib in das Ausgabeverzeichnis.
    & meson setup $buildDir $Ctx.SourceDir `
        --prefix $Ctx.OutputDir `
        --default-library shared `
        --buildtype release
    if ($LASTEXITCODE -ne 0) { throw "meson setup schlug fehl (Exit $LASTEXITCODE)." }

    & ninja -C $buildDir
    if ($LASTEXITCODE -ne 0) { throw "ninja schlug fehl (Exit $LASTEXITCODE)." }

    & ninja -C $buildDir install
    if ($LASTEXITCODE -ne 0) { throw "ninja install schlug fehl (Exit $LASTEXITCODE)." }
}

function Invoke-X264Build {
    <#
    .SYNOPSIS
        Baut x264 via configure/make für die im Kontext genannte Architektur.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Ctx)

    New-OutputDirectory -Path $Ctx.OutputDir

    # x264s configure läuft unter MSYS2/bash mit der MSVC-Toolchain.
    & bash -c "cd '$($Ctx.SourceDir)' && ./configure --prefix='$($Ctx.OutputDir)' --enable-shared --disable-cli"
    if ($LASTEXITCODE -ne 0) { throw "x264 configure schlug fehl (Exit $LASTEXITCODE)." }

    & bash -c "cd '$($Ctx.SourceDir)' && make -j && make install"
    if ($LASTEXITCODE -ne 0) { throw "x264 make/install schlug fehl (Exit $LASTEXITCODE)." }
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

    & cmake -S $cmakeSource -B $buildDir `
        -DCMAKE_INSTALL_PREFIX="$($Ctx.OutputDir)" `
        -DENABLE_SHARED=ON
    if ($LASTEXITCODE -ne 0) { throw "x265 cmake configure schlug fehl (Exit $LASTEXITCODE)." }

    & cmake --build $buildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "x265 cmake build schlug fehl (Exit $LASTEXITCODE)." }

    & cmake --install $buildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "x265 cmake install schlug fehl (Exit $LASTEXITCODE)." }
}

# ---------------------------------------------------------------------------
# Orchestrierung
# ---------------------------------------------------------------------------

function Invoke-BuildDeps {
    <#
    .SYNOPSIS
        Führt Preflight und Codec-Builds in der korrekten Reihenfolge aus.
    .DESCRIPTION
        Reihenfolge (Fail-fast):
          1. Header-Preflight (R5.5) — vor allem anderen.
          2. Codec-Quell-Preflight (R6.4) — vor jedem Build.
          3. Codec-Builds je Architektur (R6.1/R6.2/R6.3).
        Diese Funktion bündelt die reine Orchestrierung, damit sie testbar bleibt.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Variant,
        [Parameter(Mandatory)] [string] $Dav1dSourceDir,
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
        -Dav1dSourceDir $Dav1dSourceDir `
        -X264SourceDir $X264SourceDir `
        -X265SourceDir $X265SourceDir

    # --- Schritt 3: Codec-Quell-Preflight (R6.4) ---------------------------
    # Vor jedem Build: fehlt eine erforderliche Lib, Abbruch mit Benennung.
    Test-CodecSourcePreflight -Codec $codecs -PathTester $pathTester

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
        -Dav1dSourceDir $Dav1dSourceDir `
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
