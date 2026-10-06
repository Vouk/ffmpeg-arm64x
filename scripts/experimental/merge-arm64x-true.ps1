<#
.SYNOPSIS
    EXPERIMENT: Erzeugt eine ECHTE (voll verschmolzene) ARM64X-DLL fuer EINE
    FFmpeg-Bibliothek -- OHNE Forwarder. Prototyp fuer die Entscheidung
    "true merged ARM64X" vs. "pure forwarder".

.DESCRIPTION
    Microsoft-Rezept fuer eine voll verschmolzene ARM64X-Binary (siehe
    learn.microsoft.com "Arm64X PE Files" und das verbreitete arm64x.cmake-
    Muster): Der ARM64EC-Link erhaelt ZUSAETZLICH die ARM64-Objekte und
    -Import-Libs als Eingaben sowie die ARM64-.def ueber /defArm64Native: und
    laeuft unter /machine:arm64x. Ergebnis ist EINE DLL mit beiden Code-
    Ansichten (ARM64 + ARM64EC), kein Forwarder, keine Begleit-DLLs.

    FFmpeg linkt jede Shared-Lib aus:
      * einer Objekt-Response-Datei  lib<name>/<base>.dll.objs  (@-Datei)
      * einer generierten .def       lib<name>/<base>.def
    Beide liegen nach `make` im Quellbaum. Dieses Skript hat zwei Modi:

      -Capture : Nach einem `make` einer Architektur die Objekte, die .def und
                 (optional) die Import-Libs der Ziel-Bibliothek in ein
                 Arch-Stage-Verzeichnis kopieren (die Objekte werden aus der
                 .objs-Response-Datei aufgeloest). So ueberleben die Eingaben
                 den `make distclean` vor dem naechsten Arch-Build.

      -Merge   : Aus den beiden Stage-Verzeichnissen (arm64 + arm64ec) EINEN
                 /machine:arm64x-Link fahren und die verschmolzene DLL erzeugen.

    Beschraenkt auf EINE Bibliothek (Default avutil), weil avutil die
    FFmpeg-Basis ohne interne Lib-Abhaengigkeiten ist -- der sauberste erste
    Testfall. Fail-fast: $ErrorActionPreference = 'Stop'.

.PARAMETER Mode
    'Capture' oder 'Merge'.

.PARAMETER SourceDir
    (Capture) FFmpeg-Quellbaum nach `make` fuer die aktuelle Architektur.

.PARAMETER Arch
    (Capture) 'arm64' oder 'arm64ec' -- bestimmt das Ziel-Stage-Unterverzeichnis.

.PARAMETER StageDir
    Wurzel der Stage-Verzeichnisse. Capture legt <StageDir>\<arch>\ an; Merge
    liest <StageDir>\arm64\ und <StageDir>\arm64ec\.

.PARAMETER OutputDir
    (Merge) Zielverzeichnis fuer die verschmolzene ARM64X-DLL.

.PARAMETER LibBase
    Basisname der Bibliothek OHNE Erweiterung, inkl. Version, z. B. 'avutil-60'.
    Das zugehoerige lib-Verzeichnis ist 'libavutil'. Default: autodetektiert
    die avutil-*.dll.

.PARAMETER LinkExe
    Pfad zu link.exe (Default 'link.exe' aus der vcvars-Umgebung).

.NOTES
    EXPERIMENT -- nicht Teil der produktiven Pipeline. Dient der
    Machbarkeitsentscheidung (Task B).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Capture', 'Merge', IgnoreCase = $true)]
    [string] $Mode,

    [Parameter()] [string] $SourceDir,
    [Parameter()] [ValidateSet('arm64', 'arm64ec', IgnoreCase = $true)] [string] $Arch,
    [Parameter(Mandatory)] [string] $StageDir,
    [Parameter()] [string] $OutputDir,
    [Parameter()] [string] $LibBase = '',
    [Parameter()] [string] $LinkExe = 'link.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Gemeinsame Helfer
# ---------------------------------------------------------------------------

function Resolve-LibDirName {
    <#
    .SYNOPSIS
        Leitet aus dem Lib-Basisnamen (z. B. 'avutil-60') das FFmpeg-
        Quell-Unterverzeichnis ab (z. B. 'libavutil').
    #>
    param([Parameter(Mandatory)][string] $Base)
    $stem = $Base -replace '-\d+$', ''   # avutil-60 -> avutil
    return "lib$stem"                     # -> libavutil
}

function Find-DefaultLibBase {
    <#
    .SYNOPSIS
        Leitet den avutil-Basisnamen (z. B. 'avutil-60') aus dem Quellbaum ab.
    .DESCRIPTION
        Primaer ueber die erzeugte avutil-*.dll (robust, immer vorhanden nach
        dem Link). Faellt zurueck auf die .dll.objs-Response-Datei. KEIN
        -Filter (dessen Mehrfachpunkt-/8.3-Matching ist unzuverlaessig) --
        stattdessen volle Enumeration + Regex.
    #>
    param([Parameter(Mandatory)][string] $SourceDir)
    $libav = Join-Path $SourceDir 'libavutil'
    if (-not (Test-Path -LiteralPath $libav)) {
        throw "libavutil-Verzeichnis fehlt: '$libav'. Wurde 'make' ausgefuehrt?"
    }

    $all = Get-ChildItem -LiteralPath $libav -File -ErrorAction SilentlyContinue

    # 1) ueber die DLL (sichere Quelle): avutil-<ver>.dll
    $dll = $all | Where-Object { $_.Name -match '^(avutil-\d+)\.dll$' } | Select-Object -First 1
    if ($dll) { return ($dll.Name -replace '\.dll$', '') }

    # 2) Fallback: ueber die .dll.objs-Response-Datei.
    $objs = $all | Where-Object { $_.Name -match '^(avutil-\d+)\.dll\.objs$' } | Select-Object -First 1
    if ($objs) { return ($objs.Name -replace '\.dll\.objs$', '') }

    # Diagnose: zeigen, was tatsaechlich im Verzeichnis liegt.
    $listing = ($all | ForEach-Object { $_.Name }) -join ', '
    throw "Kein avutil-<ver>.dll / .dll.objs in '$libav' gefunden. Inhalt: $listing"
}

# ---------------------------------------------------------------------------
# Capture: Objekte + .def (+ Import-Lib) einer Architektur sichern
# ---------------------------------------------------------------------------

function Invoke-Capture {
    param(
        [Parameter(Mandatory)][string] $SourceDir,
        [Parameter(Mandatory)][string] $Arch,
        [Parameter(Mandatory)][string] $StageDir,
        [Parameter(Mandatory)][string] $LibBase
    )

    $archKey = $Arch.ToLowerInvariant()
    $libDirName = Resolve-LibDirName -Base $LibBase        # libavutil
    $srcLibDir = Join-Path $SourceDir $libDirName
    if (-not (Test-Path -LiteralPath $srcLibDir)) {
        throw "Lib-Quellverzeichnis fehlt: '$srcLibDir'."
    }

    $stage = Join-Path $StageDir $archKey
    $objStage = Join-Path $stage 'obj'
    New-Item -ItemType Directory -Force -Path $objStage | Out-Null

    # 1) Objektliste ermitteln. Bevorzugt aus der .objs-Response-Datei (sie
    #    enthaelt GENAU die Objekte, die FFmpeg in die DLL gelinkt hat --
    #    inkl. der korrekten Reihenfolge und ohne Test-/Hilfsobjekte). Fehlt
    #    sie, Fallback: alle *.o im lib-Verzeichnis.
    $objsFile = Join-Path $srcLibDir "$LibBase.dll.objs"
    $tokens = @()
    if (Test-Path -LiteralPath $objsFile) {
        $raw = [System.IO.File]::ReadAllText($objsFile)
        $tokens = @($raw -split '\s+' | Where-Object { $_ -match '\.o$' })
    }
    if ($tokens.Count -eq 0) {
        Write-Host "WARN: '$objsFile' fehlt/leer -- Fallback auf alle *.o in '$srcLibDir'."
        $tokens = @(Get-ChildItem -LiteralPath $srcLibDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.o$' } |
            ForEach-Object { Join-Path $libDirName $_.Name })  # relativ zum Quellbaum
    }
    if ($tokens.Count -eq 0) {
        $listing = ((Get-ChildItem -LiteralPath $srcLibDir -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }) -join ', ')
        throw "Keine Objekte fuer '$LibBase' gefunden (weder '$objsFile' noch *.o in '$srcLibDir'). Inhalt: $listing"
    }

    # Objekte flach ins Stage kopieren; dabei den relativen Pfad als Dateiname
    # kodieren (/ -> __), damit Namensgleichheit aus Unterordnern erhalten bleibt.
    $stagedObjs = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $tokens) {
        $objPath = $t
        if (-not [System.IO.Path]::IsPathRooted($objPath)) {
            $objPath = Join-Path $SourceDir $t
        }
        if (-not (Test-Path -LiteralPath $objPath)) {
            # Manche .objs listen Pfade relativ zum lib-Verzeichnis.
            $alt = Join-Path $srcLibDir $t
            if (Test-Path -LiteralPath $alt) { $objPath = $alt }
            else { throw "Objekt aus Response-Datei nicht gefunden: '$t' (weder '$objPath' noch '$alt')." }
        }
        $flat = ($t -replace '[\\/]', '__')
        $dest = Join-Path $objStage $flat
        Copy-Item -LiteralPath $objPath -Destination $dest -Force
        $stagedObjs.Add($dest)
    }

    # 2) .def kopieren (Export-Liste der Ansicht).
    $defSrc = Join-Path $srcLibDir "$LibBase.def"
    if (-not (Test-Path -LiteralPath $defSrc)) {
        throw ".def der Ansicht fehlt: '$defSrc'."
    }
    Copy-Item -LiteralPath $defSrc -Destination (Join-Path $stage "$LibBase.def") -Force

    # 3) Import-Lib der Ansicht (falls FFmpeg sie erzeugt hat) mitnehmen -- sie
    #    enthaelt KEINE Objekte, aber manche Links brauchen ihre Symbole.
    $libSrc = Get-ChildItem -LiteralPath $srcLibDir -Filter "*.lib" -File -ErrorAction SilentlyContinue
    foreach ($l in $libSrc) {
        Copy-Item -LiteralPath $l.FullName -Destination (Join-Path $stage $l.Name) -Force
    }

    # 4) Manifest schreiben, damit Merge die Objekte deterministisch findet.
    $manifest = [pscustomobject]@{
        LibBase = $LibBase
        Arch    = $archKey
        Def     = "$LibBase.def"
        Objs    = @($stagedObjs | ForEach-Object { Split-Path -Leaf $_ })
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8

    Write-Host "Capture ($archKey): $($stagedObjs.Count) Objekt(e) + $LibBase.def nach '$stage' gesichert."
    return $manifest
}

# ---------------------------------------------------------------------------
# Merge: EIN /machine:arm64x-Link aus beiden Ansichten
# ---------------------------------------------------------------------------

function Invoke-Merge {
    param(
        [Parameter(Mandatory)][string] $StageDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $LibBase,
        [Parameter(Mandatory)][string] $LinkExe
    )

    $arm64Stage   = Join-Path $StageDir 'arm64'
    $arm64ecStage = Join-Path $StageDir 'arm64ec'
    foreach ($s in @($arm64Stage, $arm64ecStage)) {
        if (-not (Test-Path -LiteralPath $s)) { throw "Stage-Verzeichnis fehlt: '$s' (Capture gelaufen?)." }
    }

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    $arm64Objs   = @(Get-ChildItem -LiteralPath (Join-Path $arm64Stage 'obj')   -File | Where-Object { $_.Name -match '\.o$' } | ForEach-Object FullName)
    $arm64ecObjs = @(Get-ChildItem -LiteralPath (Join-Path $arm64ecStage 'obj') -File | Where-Object { $_.Name -match '\.o$' } | ForEach-Object FullName)
    if ($arm64Objs.Count -eq 0 -or $arm64ecObjs.Count -eq 0) {
        throw "Objekte fehlen (arm64: $($arm64Objs.Count), arm64ec: $($arm64ecObjs.Count))."
    }

    # WICHTIG (CVT1100): FFmpeg kompiliert eine Windows-Versions-Ressource in
    # <lib>res.o (WINDRES). Beide Ansichten enthalten dieselbe VERSION-Ressource.
    # Gehen beide in EINEN /machine:arm64x-Link, lehnt cvtres das Duplikat ab
    # ("duplicate resource type:VERSION" -> LNK1123). Die Ressource ist
    # architekturneutrale Metadaten; sie darf nur EINMAL vorkommen. Daher das
    # Ressourcen-Objekt (*res.o) von der NATIVEN ARM64-Seite entfernen und nur
    # ueber die ARM64EC-Seite einbringen.
    $beforeNat = $arm64Objs.Count
    $arm64Objs = @($arm64Objs | Where-Object { $_ -notmatch '(?i)res\.o$' })
    $dropped = $beforeNat - $arm64Objs.Count
    if ($dropped -gt 0) {
        Write-Host "Merge: $dropped Ressourcen-Objekt(e) (*res.o) von der ARM64-Seite entfernt (Duplikat-VERSION, CVT1100)."
    }

    $arm64Def   = Join-Path $arm64Stage   "$LibBase.def"
    $arm64ecDef = Join-Path $arm64ecStage "$LibBase.def"
    foreach ($d in @($arm64Def, $arm64ecDef)) {
        if (-not (Test-Path -LiteralPath $d)) { throw ".def fehlt: '$d'." }
    }

    $outDll = Join-Path $OutputDir "$LibBase.dll"

    # /machine:arm64x-Link: EC-Objekte + EC-.def (/def:) UND native ARM64-
    # Objekte + ARM64-.def (/defArm64Native:) in EINEM Link. Response-Dateien
    # fuer die Objektlisten, weil libavcodec spaeter die Kommandozeilen-Grenze
    # reisst (avutil ist kurz, aber wir nutzen von Anfang an denselben Weg).
    $ecRsp    = Join-Path $OutputDir "$LibBase.arm64ec.objs.rsp"
    $natRsp   = Join-Path $OutputDir "$LibBase.arm64.objs.rsp"
    Set-Content -LiteralPath $ecRsp  -Value (($arm64ecObjs | ForEach-Object { '"' + $_ + '"' }) -join "`n") -Encoding Ascii
    Set-Content -LiteralPath $natRsp -Value (($arm64Objs   | ForEach-Object { '"' + $_ + '"' }) -join "`n") -Encoding Ascii

    $linkArgs = @(
        '/dll'
        '/machine:arm64x'
        '/nologo'
        "/out:$outDll"
        "/def:$arm64ecDef"
        "/defArm64Native:$arm64Def"
        "@$ecRsp"
        "@$natRsp"
    )

    Write-Host "Merge-Link ($LibBase): $($arm64Objs.Count) ARM64- + $($arm64ecObjs.Count) ARM64EC-Objekte -> $outDll"
    Write-Host "  link $($linkArgs -join ' ')"
    & $LinkExe @linkArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "MERGED ARM64X-Link fuer '$LibBase' fehlgeschlagen (Exit $LASTEXITCODE)."
    }
    if (-not (Test-Path -LiteralPath $outDll)) {
        throw "Merged ARM64X-DLL nicht erzeugt: '$outDll'."
    }
    Write-Host "MERGED ARM64X-DLL erzeugt: $outDll"
    return $outDll
}

# ---------------------------------------------------------------------------
# Einstieg
# ---------------------------------------------------------------------------

if ($Mode -ieq 'Capture') {
    if ([string]::IsNullOrWhiteSpace($SourceDir)) { throw "-SourceDir ist im Capture-Modus erforderlich." }
    if ([string]::IsNullOrWhiteSpace($Arch))      { throw "-Arch ist im Capture-Modus erforderlich." }
    $base = if ([string]::IsNullOrWhiteSpace($LibBase)) { Find-DefaultLibBase -SourceDir $SourceDir } else { $LibBase }
    Invoke-Capture -SourceDir $SourceDir -Arch $Arch -StageDir $StageDir -LibBase $base
}
else {
    if ([string]::IsNullOrWhiteSpace($OutputDir)) { throw "-OutputDir ist im Merge-Modus erforderlich." }
    $base = $LibBase
    if ([string]::IsNullOrWhiteSpace($base)) {
        # Aus dem arm64-Manifest ableiten.
        $mf = Join-Path (Join-Path $StageDir 'arm64') 'manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { throw "-LibBase nicht gesetzt und kein Manifest unter '$mf'." }
        $base = (Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json).LibBase
    }
    Invoke-Merge -StageDir $StageDir -OutputDir $OutputDir -LibBase $base -LinkExe $LinkExe
}
