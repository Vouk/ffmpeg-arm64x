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
    [Parameter()] [string] $LinkExe = 'link.exe',

    # (Capture) Wenn gesetzt: die exakte Objektliste MUSS aus FFmpegs
    # <base>.dll.objs-Response-Datei stammen. Fehlt sie, bricht die Capture ab
    # (KEIN Glob-Fallback) -- so ist die Objektmenge garantiert identisch mit
    # dem, was FFmpeg selbst gelinkt hat (verhindert fehlende Objekte wie
    # ff_aac_sbr_vlc beim grossen avcodec).
    [Parameter()] [switch] $RequireObjsFile,

    # (Capture) Pfad zu einer /LINKREPROFULLPATHRSP-Datei, die link.exe beim
    # ARM64-/ARM64EC-Link GESCHRIEBEN hat. Sie enthaelt die ABSOLUTEN Pfade
    # ALLER Linker-Eingaben (Objekte, Import-Libs, .def) -- also GENAU das, was
    # FFmpeg gelinkt hat, direkt vom Linker (nicht aus make-Artefakten
    # erraten). Ist dieser Pfad gesetzt, ist er die autoritative Quelle fuer
    # die Objekt- und Lib-Liste.
    [Parameter()] [string] $LinkReproRsp = '',

    # (Merge) Zusaetzliche Import-Libs, gegen die gelinkt wird -- insbesondere
    # die bereits GEMERGTEN ARM64X-Import-Libs der Abhaengigkeiten (z. B. das
    # avutil.lib aus dem avutil-Merge, wenn avcodec gemergt wird). Eine
    # ARM64X-Import-Lib enthaelt beide ABI-Varianten und loest daher sowohl die
    # EC- als auch die nativen Referenzen auf.
    [Parameter()] [string[]] $ExtraLibs = @()
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

function Resolve-LibStem {
    <#
    .SYNOPSIS
        Lib-Stamm (ohne Version) aus einem Basisnamen: 'avcodec-62' -> 'avcodec'.
    #>
    param([Parameter(Mandatory)][string] $Base)
    return ($Base -replace '-\d+$', '')
}

function Find-DefaultLibBase {
    <#
    .SYNOPSIS
        Leitet den versionierten Basisnamen (z. B. 'avutil-60') aus dem
        Quellbaum fuer einen gegebenen Lib-Stamm ab (Default avutil).
    .DESCRIPTION
        Primaer ueber die erzeugte <stem>-*.dll (robust, immer vorhanden nach
        dem Link). Faellt zurueck auf die .dll.objs-Response-Datei. KEIN
        -Filter (dessen Mehrfachpunkt-/8.3-Matching ist unzuverlaessig) --
        stattdessen volle Enumeration + Regex.
    #>
    param(
        [Parameter(Mandatory)][string] $SourceDir,
        [Parameter()][string] $Stem = 'avutil'
    )
    $libDir = Join-Path $SourceDir "lib$Stem"
    if (-not (Test-Path -LiteralPath $libDir)) {
        throw "lib$Stem-Verzeichnis fehlt: '$libDir'. Wurde 'make' ausgefuehrt?"
    }

    $all = Get-ChildItem -LiteralPath $libDir -File -ErrorAction SilentlyContinue

    # 1) ueber die DLL (sichere Quelle): <stem>-<ver>.dll
    $dll = $all | Where-Object { $_.Name -match ('^(' + [regex]::Escape($Stem) + '-\d+)\.dll$') } | Select-Object -First 1
    if ($dll) { return ($dll.Name -replace '\.dll$', '') }

    # 2) Fallback: ueber die .dll.objs-Response-Datei.
    $objs = $all | Where-Object { $_.Name -match ('^(' + [regex]::Escape($Stem) + '-\d+)\.dll\.objs$') } | Select-Object -First 1
    if ($objs) { return ($objs.Name -replace '\.dll\.objs$', '') }

    $listing = ($all | ForEach-Object { $_.Name }) -join ', '
    throw "Kein $Stem-<ver>.dll / .dll.objs in '$libDir' gefunden. Inhalt: $listing"
}

# ---------------------------------------------------------------------------
# Capture: Objekte + .def (+ Import-Lib) einer Architektur sichern
# ---------------------------------------------------------------------------

function Read-LinkReproInputs {
    <#
    .SYNOPSIS
        Parst eine /LINKREPROFULLPATHRSP-Datei und liefert die absoluten Pfade
        der Linker-Eingaben, getrennt nach Objekten (.o/.obj), Import-Libs
        (.lib) und .def. Reine Logik (nur Dateilesen).
    .DESCRIPTION
        Die .rsp enthaelt je Eintrag einen (ggf. gequoteten) absoluten Pfad,
        teils mehrere pro Zeile. Pfade koennen Leerzeichen enthalten -> nur
        gequotete Tokens UND nackte Tokens beruecksichtigen.
    .OUTPUTS
        [pscustomobject] mit Objs ([string[]]), Libs ([string[]]), Def ([string]).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $RspPath)

    if (-not (Test-Path -LiteralPath $RspPath)) {
        throw "LinkRepro-Datei nicht gefunden: '$RspPath'."
    }
    $raw = [System.IO.File]::ReadAllText($RspPath)

    # Tokens: entweder "..." (gequotet, darf Leerzeichen enthalten) oder
    # Whitespace-getrennte nackte Tokens.
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($raw, '"([^"]+)"|(\S+)')) {
        $t = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        if (-not [string]::IsNullOrWhiteSpace($t)) { $tokens.Add($t) }
    }

    $objs = [System.Collections.Generic.List[string]]::new()
    $libs = [System.Collections.Generic.List[string]]::new()
    $def = $null
    foreach ($t in $tokens) {
        # Linker-Optionen (beginnen mit / oder -) ueberspringen -- ausser die
        # eingebettete /def:, aus der wir den .def-Pfad ziehen.
        if ($t -match '^[/-]') {
            if ($t -match '(?i)^[/-]def:(.+)$') { $def = $Matches[1].Trim('"') }
            continue
        }
        switch -regex ($t) {
            '(?i)\.(o|obj)$' { $objs.Add($t); break }
            '(?i)\.lib$'     { $libs.Add($t); break }
            '(?i)\.def$'     { if (-not $def) { $def = $t }; break }
            default          { }
        }
    }

    return [pscustomobject]@{
        Objs = [string[]]$objs.ToArray()
        Libs = [string[]]$libs.ToArray()
        Def  = $def
    }
}

function Invoke-Capture {
    param(
        [Parameter(Mandatory)][string] $SourceDir,
        [Parameter(Mandatory)][string] $Arch,
        [Parameter(Mandatory)][string] $StageDir,
        [Parameter(Mandatory)][string] $LibBase,
        [switch] $RequireObjsFile,
        [string] $LinkReproRsp = ''
    )

    $archKey = $Arch.ToLowerInvariant()
    $libDirName = Resolve-LibDirName -Base $LibBase        # libavutil
    $stem = Resolve-LibStem -Base $LibBase                 # avutil
    $srcLibDir = Join-Path $SourceDir $libDirName
    if (-not (Test-Path -LiteralPath $srcLibDir)) {
        throw "Lib-Quellverzeichnis fehlt: '$srcLibDir'."
    }

    # Pro Bibliothek EIGENES Stage-Unterverzeichnis (<StageDir>\<stem>\<arch>),
    # damit mehrere Libs (avutil, avcodec, ...) nebeneinander gestaged werden.
    $stage = Join-Path (Join-Path $StageDir $stem) $archKey
    $objStage = Join-Path $stage 'obj'
    New-Item -ItemType Directory -Force -Path $objStage | Out-Null

    # ============================================================
    # Autoritativer Pfad: /LINKREPROFULLPATHRSP vom Linker.
    # ============================================================
    if (-not [string]::IsNullOrWhiteSpace($LinkReproRsp)) {
        $repro = Read-LinkReproInputs -RspPath $LinkReproRsp
        if ($repro.Objs.Count -eq 0) {
            throw "LinkRepro '$LinkReproRsp' enthaelt keine Objekte."
        }
        Write-Host "Capture ($archKey/$LibBase): LinkRepro -> $($repro.Objs.Count) Objekt(e), $($repro.Libs.Count) Lib(s)."

        # Objekte flach ins Stage kopieren (absolute Pfade; Namenskollisionen
        # ueber einen Index vermeiden).
        $stagedObjs = [System.Collections.Generic.List[string]]::new()
        $i = 0
        foreach ($o in $repro.Objs) {
            if (-not (Test-Path -LiteralPath $o)) { throw "LinkRepro-Objekt fehlt: '$o'." }
            $flat = ('{0:D4}_' -f $i) + (Split-Path -Leaf $o)
            $dest = Join-Path $objStage $flat
            Copy-Item -LiteralPath $o -Destination $dest -Force
            $stagedObjs.Add($dest)
            $i++
        }

        # .def: bevorzugt die aus der .rsp; sonst die neben der DLL.
        $defDest = Join-Path $stage "$LibBase.def"
        $defSrc = if ($repro.Def -and (Test-Path -LiteralPath $repro.Def)) { $repro.Def } else { Join-Path $srcLibDir "$LibBase.def" }
        if (-not (Test-Path -LiteralPath $defSrc)) { throw ".def nicht gefunden (weder LinkRepro noch '$srcLibDir'): '$defSrc'." }
        Copy-Item -LiteralPath $defSrc -Destination $defDest -Force

        # Externe (nicht-FFmpeg) Import-Libs aus der .rsp mitnehmen -- die
        # FFmpeg-eigenen Lib-Verweise (libavutil etc.) ersetzt der Merge durch
        # die gemergten ARM64X-Import-Libs, daher hier ausfiltern.
        $libStage = Join-Path $stage 'extralib'
        New-Item -ItemType Directory -Force -Path $libStage | Out-Null
        foreach ($l in $repro.Libs) {
            if ($l -match '(?i)[\\/]lib(avutil|avcodec|avformat|avfilter|avdevice|swscale|swresample)[\\/]') { continue }
            if (Test-Path -LiteralPath $l) {
                Copy-Item -LiteralPath $l -Destination (Join-Path $libStage (Split-Path -Leaf $l)) -Force
            }
        }

        $manifest = [pscustomobject]@{
            LibBase = $LibBase; Arch = $archKey; Def = "$LibBase.def"
            Objs = @($stagedObjs | ForEach-Object { Split-Path -Leaf $_ }); Source = 'linkrepro'
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
        Write-Host "Capture ($archKey/$LibBase): $($stagedObjs.Count) Objekt(e) + $LibBase.def (LinkRepro) nach '$stage'."
        return $manifest
    }

    # 1) Objektliste ermitteln. Quelle der Wahrheit ist FFmpegs
    #    <base>.dll.objs-Response-Datei: sie enthaelt GENAU die Objekte (inkl.
    #    Reihenfolge), die FFmpeg in die DLL gelinkt hat -- ohne Test-/
    #    Hilfsobjekte und MIT generierten Tabellen-Objekten aus Unterordnern.
    #    `.objs.keep` (falls vorhanden) wird bevorzugt, dann `.objs`.
    $objsKeep = Join-Path $srcLibDir "$LibBase.dll.objs.keep"
    $objsFile = Join-Path $srcLibDir "$LibBase.dll.objs"
    $usedObjs = $null
    $tokens = @()
    foreach ($cand in @($objsKeep, $objsFile)) {
        if (Test-Path -LiteralPath $cand) {
            $raw = [System.IO.File]::ReadAllText($cand)
            $t = @($raw -split '\s+' | Where-Object { $_ -match '\.o$' })
            if ($t.Count -gt 0) { $tokens = $t; $usedObjs = $cand; break }
        }
    }

    if ($tokens.Count -gt 0) {
        Write-Host "Capture: Objektliste aus Response-Datei '$usedObjs' ($($tokens.Count) Objekte)."
    }
    elseif ($RequireObjsFile) {
        # Fail-closed: KEIN Glob-Fallback. Die exakte FFmpeg-Objektliste ist
        # Pflicht, sonst fehlen beim grossen avcodec einzelne Objekte.
        $listing = ((Get-ChildItem -LiteralPath $srcLibDir -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }) -join ', ')
        throw "Response-Datei '$objsFile'(.keep) fehlt/leer und -RequireObjsFile ist gesetzt. " +
              "Ohne die exakte FFmpeg-Objektliste wird NICHT gegliobt. Inhalt '$srcLibDir': $listing"
    }
    else {
        Write-Host "WARN: '$objsFile' fehlt/leer -- Fallback auf alle *.o in '$srcLibDir'."
        $tokens = @(Get-ChildItem -LiteralPath $srcLibDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.o$' } |
            ForEach-Object { Join-Path $libDirName $_.Name })  # relativ zum Quellbaum
        if ($tokens.Count -eq 0) {
            $listing = ((Get-ChildItem -LiteralPath $srcLibDir -File -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name }) -join ', ')
            throw "Keine Objekte fuer '$LibBase' gefunden (weder '$objsFile' noch *.o in '$srcLibDir'). Inhalt: $listing"
        }
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
        [Parameter(Mandatory)][string] $LinkExe,
        [Parameter()][string[]] $ExtraLibs = @()
    )

    $stem = Resolve-LibStem -Base $LibBase
    $arm64Stage   = Join-Path (Join-Path $StageDir $stem) 'arm64'
    $arm64ecStage = Join-Path (Join-Path $StageDir $stem) 'arm64ec'
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

    # System-Import-Libs: FFmpegs eigener Link reicht ueber EXTRALIBS die Win32-
    # Bibliotheken ein (bcrypt, user32, ...). Unser Stand-alone-/machine:arm64x-
    # Link muss sie ebenfalls uebergeben, sonst LNK2019 "unresolved external
    # symbol ... (EC Symbol)" / "(Arm64 Native Symbol)". Fuer /machine:arm64x
    # loest der Linker Namen aus den SDK-LIB-Pfaden auf -- je Seite die passende
    # ARM64- bzw. ARM64EC-Variante (das Win11-SDK liefert beide). Die Liste
    # entspricht FFmpegs avutil-Abhaengigkeiten auf Windows.
    # Superset der Win32-System-Import-Libs ueber alle FFmpeg-Kern-Libs. Nicht
    # referenzierte Importe sind fuer den Link harmlos (sie ziehen nichts rein).
    # Fuer /machine:arm64x waehlt der Linker je Seite die ARM64- bzw.
    # ARM64EC-Variante aus den SDK-LIB-Pfaden (Win11-SDK liefert beide).
    $sysLibs = @(
        'bcrypt.lib'      # BCryptGenRandom (avutil/random_seed)
        'user32.lib'      # GetDesktopWindow (dxva2)
        'ole32.lib'       # COM (hwcontext_d3d11va/dxva2/mf)
        'oleaut32.lib'
        'advapi32.lib'
        'ws2_32.lib'      # Sockets (avformat)
        'secur32.lib'     # TLS (avformat)
        'mfplat.lib'      # Media Foundation (avcodec mf*)
        'mfuuid.lib'
        'strmiids.lib'    # DirectShow GUIDs (avdevice)
        'uuid.lib'
        'gdi32.lib'
        'kernel32.lib'
    )

    # Aus der LinkRepro gestagte EXTERNE Import-Libs (z. B. HW-Encoder- oder
    # andere Nicht-FFmpeg-Libs), die FFmpeg beim Original-Link verwendet hat.
    # Von der ARM64EC-Seite nehmen (dort ist der vollstaendige Satz); der
    # Linker waehlt fuer /machine:arm64x je Seite die passende Variante.
    $stagedExtra = @()
    $extraDir = Join-Path $arm64ecStage 'extralib'
    if (Test-Path -LiteralPath $extraDir) {
        $stagedExtra = @(Get-ChildItem -LiteralPath $extraDir -File -Filter '*.lib' |
            ForEach-Object { $_.Name } | Sort-Object -Unique)
        if ($stagedExtra.Count -gt 0) {
            Write-Host "Merge: $($stagedExtra.Count) externe Import-Lib(s) aus LinkRepro: $($stagedExtra -join ', ')"
        }
    }

    # Zusaetzliche (gemergte) Abhaengigkeits-Import-Libs, z. B. avutil.lib beim
    # avcodec-Merge. Eine ARM64X-Import-Lib deckt beide ABI-Seiten ab.
    $depLibs = @()
    foreach ($el in $ExtraLibs) {
        if ([string]::IsNullOrWhiteSpace($el)) { continue }
        if (-not (Test-Path -LiteralPath $el)) { throw "ExtraLib nicht gefunden: '$el'." }
        $depLibs += (Resolve-Path -LiteralPath $el).Path
    }
    if ($depLibs.Count -gt 0) {
        Write-Host "Merge: $($depLibs.Count) Abhaengigkeits-Import-Lib(s): $($depLibs -join ', ')"
    }

    $extraLibPaths = @($stagedExtra | ForEach-Object { Join-Path $extraDir $_ })

    $linkArgs = @(
        '/dll'
        '/machine:arm64x'
        '/nologo'
        "/out:$outDll"
        "/def:$arm64ecDef"
        "/defArm64Native:$arm64Def"
        "@$ecRsp"
        "@$natRsp"
    ) + $depLibs + $extraLibPaths + $sysLibs

    Write-Host "Merge-Link ($LibBase): $($arm64Objs.Count) ARM64- + $($arm64ecObjs.Count) ARM64EC-Objekte -> $outDll"
    Write-Host "  link $($linkArgs -join ' ')"
    & $LinkExe @linkArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "MERGED ARM64X-Link fuer '$LibBase' fehlgeschlagen (Exit $LASTEXITCODE)."
    }
    if (-not (Test-Path -LiteralPath $outDll)) {
        throw "Merged ARM64X-DLL nicht erzeugt: '$outDll'."
    }

    # Die beim Link erzeugte Import-Lib heisst <LibBase>.lib (z. B.
    # avutil-60.lib). Fuer dependente Merges (avcodec linkt gegen avutil) als
    # stabilen Stamm-Namen <stem>.lib (avutil.lib) spiegeln -- so, wie FFmpeg
    # die Import-Lib unversioniert sucht.
    $prodLib = Join-Path $OutputDir "$LibBase.lib"
    $stemLib = Join-Path $OutputDir "$stem.lib"
    if ((Test-Path -LiteralPath $prodLib) -and -not [string]::Equals($prodLib, $stemLib, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $prodLib -Destination $stemLib -Force
        Write-Host "Merge: Import-Lib-Alias $LibBase.lib -> $stem.lib angelegt."
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
    # Default: avutil. Fuer andere Libs -LibBase (z. B. avcodec-62) uebergeben.
    $base = if ([string]::IsNullOrWhiteSpace($LibBase)) { Find-DefaultLibBase -SourceDir $SourceDir -Stem 'avutil' } else { $LibBase }
    Invoke-Capture -SourceDir $SourceDir -Arch $Arch -StageDir $StageDir -LibBase $base `
        -RequireObjsFile:$RequireObjsFile -LinkReproRsp $LinkReproRsp
}
else {
    if ([string]::IsNullOrWhiteSpace($OutputDir)) { throw "-OutputDir ist im Merge-Modus erforderlich." }
    $base = $LibBase
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "-LibBase ist im Merge-Modus erforderlich (z. B. avutil-60 oder avcodec-62)."
    }
    Invoke-Merge -StageDir $StageDir -OutputDir $OutputDir -LibBase $base -LinkExe $LinkExe -ExtraLibs $ExtraLibs
}
