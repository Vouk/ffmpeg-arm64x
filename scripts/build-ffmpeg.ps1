<#
.SYNOPSIS
    Baut FFmpeg (LGPL) für genau eine Architektur als Shared Libraries
    (DLL + .lib) samt ffmpeg.exe/ffprobe.exe.

.DESCRIPTION
    Ein `configure`/`make`-Durchlauf für FFmpeg unter MSYS2 mit der
    MSVC-Toolchain (`--toolchain=msvc`). Das Skript kapselt genau EINEN
    Build-Durchlauf; die zwei Durchläufe der Build-Matrix (arm64/arm64ec)
    werden vom Workflow durch zwei separate Aufrufe dieses Skripts realisiert.
    Der anschließende ARM64X-Merge über beide Architektur-Ansichten ist NICHT
    Teil dieses Skripts (siehe scripts/merge-arm64x.ps1).

    Gebaut wird ausschliesslich die LGPL-Variante, als Shared Libraries, OHNE
    GPL-Komponenten (kein x264/x265), aber MIT den Hardware-Encodern AMF und
    NVENC/NVDEC (header-only SDK-Integrationen, LGPL-vertraeglich).

    Ablauf je Durchlauf:
      1. Reinlogik-Modul scripts/lib/BuildConfig.psm1 importieren und die
         `configure`-Flags über Get-ConfigureFlags -Arch beziehen.
      2. Vollständigen `configure`-Befehl zusammensetzen: die Flags plus
         Quell-/Prefix-Pfade (`--prefix`, optional `--bindir`/`--libdir`).
      3. FFmpegs `configure` und danach `make`/`make install` unter MSYS2-bash
         ausführen. Die MSVC-Umgebung (INCLUDE, LIB, PATH aus
         `vcvarsamd64_arm64.bat`) wird über `MSYS2_PATH_TYPE=inherit` an die
         bash-Session durchgereicht, sodass `cl.exe`/`link.exe`/`lib.exe` dort
         auffindbar sind.
      4. Ergebnis: Shared Libraries (DLL + gleichnamige .lib) sowie
         ffmpeg.exe/ffprobe.exe im arch-spezifischen Ausgabe-Prefix.

    Die eigentliche Build-Toolchain (MSYS2 + MSVC-Cross-Tools) existiert nur auf
    dem CI-Runner. Damit die Argument-Zusammensetzungs-Logik lokal ohne diese
    Toolchain überprüfbar bleibt, bietet das Skript einen -DryRun-Schalter: er
    setzt genau denselben `configure`/`make`-Aufruf zusammen und gibt ihn aus,
    ohne einen Prozess zu starten. Der reale Build läuft ausschließlich in CI.

    Fail-fast: $ErrorActionPreference = 'Stop'; jeder von Null verschiedene
    Exit-Code eines Build-Schritts bricht das Skript ab.

.PARAMETER Arch
    Ziel-Architektur: 'arm64' oder 'arm64ec' (case-insensitiv). Bestimmt die
    ARM64EC-Flags und den Namen des Ausgabe-Unterverzeichnisses.

.PARAMETER SourceDir
    Pfad zum ausgepackten FFmpeg-Quellbaum (enthält das `configure`-Skript).

.PARAMETER OutputDir
    Basis-Ausgabeverzeichnis. Der tatsächliche Installations-Prefix ist
    "<OutputDir>/<arch>", sodass die zwei Durchläufe der Build-Matrix
    kollisionsfrei nebeneinander liegen.

.PARAMETER Msys2Bash
    Pfad zur MSYS2-`bash.exe`. Parametrisiert, damit das Skript ohne feste
    Installationsannahme konfigurierbar und testbar bleibt.
    Standard: 'C:\msys64\usr\bin\bash.exe'.

.PARAMETER Jobs
    Anzahl paralleler make-Jobs (`make -j`). Standard: Anzahl logischer
    Prozessoren.

.PARAMETER DryRun
    Wenn gesetzt, wird kein Build ausgeführt. Stattdessen werden die
    zusammengesetzten `configure`- und `make`-Befehlszeilen ermittelt, als
    Objekt zurückgegeben und ausgegeben. Dient der lokalen Verifikation der
    Argument-Zusammensetzung.

.EXAMPLE
    ./build-ffmpeg.ps1 -Arch arm64 -SourceDir C:\src\ffmpeg -OutputDir C:\out

.EXAMPLE
    ./build-ffmpeg.ps1 -Arch arm64ec -SourceDir C:\src\ffmpeg -OutputDir C:\out -DryRun

.NOTES
    Design: Architecture -> Runner-/Toolchain-Strategie (MSYS2 mit MSVC via
            --toolchain=msvc), Components -> C2 Build-Skripte
            (scripts/build-ffmpeg.ps1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('arm64', 'arm64ec', IgnoreCase = $true)]
    [string] $Arch,

    [Parameter(Mandatory)]
    [string] $SourceDir,

    [Parameter(Mandatory)]
    [string] $OutputDir,

    # Prefix mit den abgelegten Hardware-Headern (AMF + nv-codec), so wie
    # scripts/lib/HwHeaders.psm1 ihn erzeugt: <HwHeadersDir>\include\AMF,
    # <HwHeadersDir>\include\ffnvcodec und
    # <HwHeadersDir>\lib\pkgconfig\ffnvcodec.pc. Fehlt der Pfad, bricht
    # configure fuer --enable-amf/--enable-nvenc/--enable-nvdec ab.
    [Parameter()]
    [string] $HwHeadersDir,

    [Parameter()]
    [string] $Msys2Bash = 'C:\msys64\usr\bin\bash.exe',

    [Parameter()]
    [ValidateRange(1, 1024)]
    [int] $Jobs = [Environment]::ProcessorCount,

    [Parameter()]
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Reinlogik-Modul für die configure-Flags importieren.
Import-Module (Join-Path $PSScriptRoot 'lib/BuildConfig.psm1') -Force
# Backports fuer den FFmpeg-Quellbaum (makedef-Response-Datei fuer Shared Libs).
Import-Module (Join-Path $PSScriptRoot 'lib/FFmpegPatch.psm1') -Force

function ConvertTo-Msys2Path {
    <#
    .SYNOPSIS
        Wandelt einen Windows-Pfad in einen MSYS2/POSIX-Pfad um
        (z. B. C:\src\ffmpeg -> /c/src/ffmpeg).
    .DESCRIPTION
        Reine String-Transformation ohne Dateisystemzugriff, damit sie auch im
        -DryRun ohne existierende Pfade und ohne MSYS2 funktioniert.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    # Backslashes zu Slashes, Laufwerksbuchstabe "C:" -> "/c".
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(/.*)?$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = if ($Matches[2]) { $Matches[2] } else { '/' }
        $p = "/$drive$rest"
    }
    return $p
}

function ConvertTo-BashSingleQuoted {
    <#
    .SYNOPSIS
        Umgibt eine Zeichenkette sicher mit einfachen Anführungszeichen für bash,
        sodass Sonderzeichen (Leerzeichen usw.) nicht interpretiert werden.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    # In bash: ' beenden, mit "'\''" ein wörtliches ' einfügen, wieder öffnen.
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Get-FFmpegBuildPlan {
    <#
    .SYNOPSIS
        Setzt den vollständigen configure/make-Ablauf für eine Architektur
        zusammen (reine Logik).

    .DESCRIPTION
        Kapselt die gesamte Argument-Zusammensetzung ohne Seiteneffekte, damit
        sie lokal (auch im -DryRun) überprüfbar ist. Nutzt Get-ConfigureFlags
        für die Architektur-Flags und ergänzt Quell-/Prefix-Pfade.

    .OUTPUTS
        [pscustomobject] mit:
          Arch, Prefix (Windows), PrefixPosix,
          SourceDirPosix, ConfigureFlags (string[]),
          ConfigureArgs (string[]), BashScript (string),
          Msys2Bash, Env (hashtable der zu setzenden Umgebungsvariablen).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Arch,
        [Parameter(Mandatory)][string] $SourceDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $Msys2Bash,
        [Parameter(Mandatory)][int] $Jobs,
        [string] $HwHeadersDir
    )

    $archKey = $Arch.ToLowerInvariant()

    # Architektur-Flags aus dem Reinlogik-Modul (LGPL, Shared, HW-Encoder).
    $configureFlags = Get-ConfigureFlags -Arch $archKey

    # Arch-spezifischer Installations-Prefix, kollisionsfrei je Durchlauf der
    # Build-Matrix.
    $prefix = Join-Path $OutputDir $archKey
    $prefixPosix = ConvertTo-Msys2Path -Path $prefix
    $sourcePosix = ConvertTo-Msys2Path -Path $SourceDir

    # Vollständige configure-Argumentliste: Flags + Pfad-Optionen.
    $configureArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $configureFlags) { $configureArgs.Add($f) }
    $configureArgs.Add("--prefix=$prefixPosix")
    # bin/ (ffmpeg.exe/ffprobe.exe + DLLs) und lib/ (.lib) explizit verankern.
    $configureArgs.Add("--bindir=$prefixPosix/bin")
    $configureArgs.Add("--libdir=$prefixPosix/lib")
    $configureArgs.Add("--incdir=$prefixPosix/include")

    # Hardware-Header (AMF + nv-codec, von scripts/install-hwheaders.ps1
    # abgelegt): AMF ueber den include-Pfad (FFmpeg inkludiert <AMF/core/
    # Version.h>), ffnvcodec ueber seine .pc-Datei (configure prueft ffnvcodec
    # nur per pkg-config). Beide Pfade in configure und PKG_CONFIG_PATH reichen.
    $pkgConfigDirs = [System.Collections.Generic.List[string]]::new()
    if ($HwHeadersDir -and (Test-Path -LiteralPath $HwHeadersDir)) {
        $hwIncPosix = ConvertTo-Msys2Path -Path (Join-Path $HwHeadersDir 'include')
        $configureArgs.Add("--extra-cflags=-I$hwIncPosix")
        $hwPcDir = Join-Path (Join-Path $HwHeadersDir 'lib') 'pkgconfig'
        if (Test-Path -LiteralPath $hwPcDir) {
            $pkgConfigDirs.Add((ConvertTo-Msys2Path -Path $hwPcDir))
        }
    }

    $configureArgsArr = [string[]]$configureArgs.ToArray()

    # bash-Skript zusammensetzen: fail-fast (set -euo pipefail), in den
    # Quellbaum wechseln, configure ausführen, dann make + make install.
    $quotedConfigureArgs = ($configureArgsArr | ForEach-Object { ConvertTo-BashSingleQuoted $_ }) -join ' '
    $quotedSource = ConvertTo-BashSingleQuoted $sourcePosix

    # PKG_CONFIG_PATH fuer ffnvcodec.pc setzen (sonst findet configure
    # ffnvcodec nicht und --enable-nvenc/--enable-nvdec brechen ab). Ohne
    # HW-Header bleibt die Zeile ein No-op (":").
    $pkgPathLine = if ($pkgConfigDirs.Count -gt 0) {
        "export PKG_CONFIG_PATH='" + ($pkgConfigDirs -join ':') + "'"
    } else { ':' }
    # Diagnose: zeigt im CI-Log, ob pkg-config ffnvcodec findet und warum.
    # Laeuft nicht-fatal (|| true), damit set -e hier nicht abbricht.
    $pkgDiag = 'echo PKG_CONFIG_PATH=$PKG_CONFIG_PATH; which pkg-config pkgconf 2>/dev/null || true; for L in ffnvcodec; do echo -- $L --; pkg-config --exists $L && echo found || echo missing; pkg-config --cflags --libs $L 2>&1 || true; done'

    # MSVC-Dependency-Generierung abschalten (CCDEP/CXXDEP leer).
    # ffbuild/common.mak ruft je Objekt $(call CCDEP,CC) als eigenen Lauf auf;
    # dessen awk-Programm kommt bei FFmpeg <= 8.1.3 mit kaputtem
    # Backslash-Escaping an (awk: syntax error bei gsub(/\/, \"/\")) und
    # bricht make ab. Die .d-Dateien dienen nur inkrementellen Rebuilds; CI
    # baut immer frisch. Upstream hat diesen Pfad inzwischen ersetzt
    # (FFmpeg-Commit cb5a63736a). Leere Werte auf der make-Kommandozeile
    # ueberschreiben die Zuweisung aus config.mak, sodass $(call CCDEP,CC) zu
    # nichts expandiert. Der Compile-Aufruf selbst bleibt unveraendert.
    $makeOverrides = 'CCDEP= CXXDEP='

    # Diagnose: zeigt die CCDEP-Zeile aus config.mak im CI-Log.
    $cfgMakDiag = 'grep -n "^CCDEP" ffbuild/config.mak || true'

    # WICHTIG - sauberer Rebuild je Arch: Der FFmpeg-Quellbaum wird
    # fuer BEIDE Builds (arm64 + arm64ec) WIEDERVERWENDET. make
    # entscheidet anhand der Zeitstempel, ob eine .o neu gebaut wird. Nach dem
    # arm64-Build existieren alle Objekte bereits und sind neuer als die
    # Quellen -- der nachfolgende arm64ec-Build kompiliert daher NICHT neu,
    # sondern verlinkt die ARM64-Objekte des vorherigen Laufs nur neu. Ergebnis
    # (in CI 37290208404 / 37294268893 / 37298727949 beobachtet): die
    # arm64ec-DLLs blieben reines ARM64, obwohl -arm64EC in config.mak stand.
    #
    # Loesung: vor configure IMMER distclean, damit jede Arch-Ansicht mit
    # frischen Objekten und den fuer sie geltenden Flags baut.
    # Beim allerersten Lauf gibt es noch keine config.mak -> distclean ist dann
    # ein No-op; daher "|| true" (set -e nicht ausloesen).
    $distclean = 'make distclean 2>/dev/null || true'

    # ARM64EC-Flags: configure legt -arm64EC in CFLAGS und den Maschinen-Flag in
    # LDFLAGS bereits in config.mak ab. Zur Sicherheit haengen wir sie zusaetzlich
    # per "+=" an -- schadet nicht und haelt die Erzwingung robust. "+=" statt
    # "=$(CFLAGS) ..." (letzteres waere eine rekursive Selbstreferenz).
    #
    # Der LDFLAGS-Maschinen-Flag MUSS kleingeschrieben sein (-machine:arm64ec):
    # compat/windows/makedef matcht LDFLAGS case-sensitiv auf den Teilstring
    # "machine:arm64ec", um sein lib.exe mit -machine:arm64ec aufzurufen. Fehlt
    # der Match, baut makedef die temporaere Symbol-Lib als reines ARM64 aus
    # ARM64EC-Objekten -> "Could not create temporary library" (CI 37302790749).
    $ecForce = if ($archKey -eq 'arm64ec') {
        @(
            '# ARM64EC absichern: Flags zusaetzlich an config.mak anhaengen (LDFLAGS kleingeschrieben fuer makedef).'
            "printf '\nCFLAGS += -arm64EC\nLDFLAGS += -machine:arm64ec\n' >> ffbuild/config.mak"
            'echo "---- config.mak CFLAGS/LDFLAGS nach ARM64EC-Append ----"'
            'grep -nE "^(CFLAGS|LDFLAGS)" ffbuild/config.mak || true'
        )
    } else { @() }

    $bashLines = @(
        'set -euo pipefail'
        $pkgPathLine
        $pkgDiag
        "cd $quotedSource"
        $distclean
        "./configure $quotedConfigureArgs"
        $cfgMakDiag
    ) + $ecForce + @(
        "make -j$Jobs $makeOverrides"
        "make install $makeOverrides"
    )
    $bashScript = ($bashLines -join "`n")

    # Umgebungsvariablen für den bash-Aufruf. MSYS2_PATH_TYPE=inherit reicht die
    # MSVC-Umgebung (INCLUDE/LIB/PATH aus vcvarsamd64_arm64.bat) durch.
    #
    # Hinweis: Ein frueherer Versuch, ARM64EC ueber _CL_/_LINK_ zu erzwingen,
    # griff NICHT -- die Login-Shell (bash -lc) bzw. MSYS2 reichte diese
    # Variablen nicht bis cl.exe/link.exe durch, die arm64ec-DLLs blieben reines
    # ARM64. Die Erzwingung erfolgt daher zuverlaessig ueber das Anhaengen der
    # Flags an ffbuild/config.mak (siehe $ecForce oben), nicht ueber die Umgebung.
    $envVars = @{ 'MSYS2_PATH_TYPE' = 'inherit' }

    return [pscustomobject]@{
        Arch           = $archKey
        Prefix         = $prefix
        PrefixPosix    = $prefixPosix
        SourceDir      = $SourceDir
        SourceDirPosix = $sourcePosix
        ConfigureFlags = $configureFlags
        ConfigureArgs  = $configureArgsArr
        BashScript     = $bashScript
        Msys2Bash      = $Msys2Bash
        Jobs           = $Jobs
        Env            = $envVars
    }
}

# --- Ablauf -----------------------------------------------------------------

$plan = Get-FFmpegBuildPlan `
    -Arch $Arch `
    -SourceDir $SourceDir `
    -OutputDir $OutputDir `
    -Msys2Bash $Msys2Bash `
    -Jobs $Jobs `
    -HwHeadersDir $HwHeadersDir

Write-Verbose "FFmpeg-Build-Plan: Arch=$($plan.Arch) Prefix=$($plan.Prefix)"

if ($DryRun) {
    # Lokale Verifikation: Nur den zusammengesetzten Aufruf ausgeben, nichts
    # ausführen. Gibt das Plan-Objekt zurück, damit Tests es inspizieren können.
    Write-Host "== DRY RUN: FFmpeg (LGPL)/$($plan.Arch) =="
    Write-Host "MSYS2 bash : $($plan.Msys2Bash)"
    Write-Host "Env        : $(( $plan.Env.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')"
    Write-Host "Source     : $($plan.SourceDirPosix)"
    Write-Host "Prefix     : $($plan.PrefixPosix)"
    Write-Host "configure  : ./configure $($plan.ConfigureArgs -join ' ')"
    Write-Host "make       : make -j$($plan.Jobs) && make install"
    return $plan
}

# --- Realer Build (nur auf dem CI-Runner mit MSYS2 + MSVC) -------------------

if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "FFmpeg-Quellverzeichnis nicht gefunden: '$SourceDir'."
}
if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'configure'))) {
    throw "Kein 'configure'-Skript im Quellverzeichnis: '$SourceDir'."
}
if (-not (Test-Path -LiteralPath $Msys2Bash)) {
    throw "MSYS2-bash nicht gefunden: '$Msys2Bash'. Pfad über -Msys2Bash setzen."
}

# Backports auf den FFmpeg-Quellbaum (siehe scripts/lib/FFmpegPatch.psm1):
#   * NVENC/NVDEC auf aarch64 Windows freischalten (93f653f95c) -- sonst
#     bricht configure mit --enable-nvdec/--enable-nvenc ab.
#   * makedef die .objs-Response-Datei reichen (8512161c81) -- ohne das
#     reisst libavcodec mit ~1000 Objekten die Kommandozeilen-Grenze.
# Idempotent: enthaelt die Quelle einen Fix bereits, bleibt sie unveraendert.
foreach ($patch in (Invoke-FFmpegSourcePatches -SourceDir $SourceDir)) {
    Write-Host ("FFmpeg-Backport [{0}] {1}: {2}" -f $patch.File, $patch.Name, $patch.Status)
}

# Ausgabe-Prefix vorbereiten.
New-Item -ItemType Directory -Force -Path $plan.Prefix | Out-Null

# Umgebungsvariablen setzen (MSYS2_PATH_TYPE=inherit) und den bash-Durchlauf
# starten. -lc führt das zusammengesetzte Skript in einer Login-Shell aus.
foreach ($kv in $plan.Env.GetEnumerator()) {
    Set-Item -Path ("Env:" + $kv.Key) -Value $kv.Value
}

Write-Host "Baue FFmpeg (LGPL)/$($plan.Arch) unter MSYS2 ..."
& $plan.Msys2Bash '-lc' $plan.BashScript
if ($LASTEXITCODE -ne 0) {
    # Bei configure-/Build-Fehler FFmpegs config.log ausgeben -- dort steht
    # die konkrete Ursache (z. B. warum pkg-config ffnvcodec nicht akzeptiert).
    $ffCfgLog = Join-Path $SourceDir 'ffbuild/config.log'
    if (Test-Path -LiteralPath $ffCfgLog) {
        Write-Host '----- FFmpeg ffbuild/config.log (letzte 120 Zeilen) -----'
        Get-Content -LiteralPath $ffCfgLog -Tail 120 | ForEach-Object { Write-Host $_ }
        Write-Host '---------------------------------------------------------'
    }
    throw "FFmpeg-Build fehlgeschlagen (LGPL/$($plan.Arch)): bash-Exit-Code $LASTEXITCODE."
}

# Sanity-Check: ffmpeg.exe/ffprobe.exe und mindestens eine DLL erzeugt?
$binDir = Join-Path $plan.Prefix 'bin'
foreach ($exe in @('ffmpeg.exe', 'ffprobe.exe')) {
    $exePath = Join-Path $binDir $exe
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Erwartete Ausführbare fehlt nach dem Build: '$exePath'."
    }
}

# ARM64X-Vorbereitung: FFmpegs make install installiert nur die DLLs (und
# Header), NICHT die je Shared-Lib erzeugte Import-.lib und .def. Beide
# bleiben im Quellbaum unter lib<name>/. Der ARM64X-Forwarder
# (merge-arm64x.ps1) braucht beides: die .def (Export-Liste) und die
# Import-.lib. Also aus dem Quellbaum nach <prefix>/lib/ kopieren.
#   DLL/.def: versioniert (avcodec-62.dll / avcodec-62.def)
#   .lib    : UNversioniert (avcodec.lib) -- Trailing -<zahl> entfernen.
$libOut = Join-Path $plan.Prefix 'lib'
New-Item -ItemType Directory -Force -Path $libOut | Out-Null
$dllBases = Get-ChildItem -LiteralPath $binDir -Filter '*.dll' -File | ForEach-Object { $_.BaseName }
$defCount = 0
$libCount = 0
foreach ($base in $dllBases) {
    $libStem = $base -replace '-\d+$', ''

    $defSrc = Get-ChildItem -LiteralPath $SourceDir -Recurse -Filter "$base.def" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($defSrc) {
        Copy-Item -LiteralPath $defSrc.FullName -Destination (Join-Path $libOut "$base.def") -Force
        $defCount++
    } else {
        Write-Host "WARN: keine .def fuer $base.dll im Quellbaum gefunden."
    }

    $libSrc = Get-ChildItem -LiteralPath $SourceDir -Recurse -Filter "$libStem.lib" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($libSrc) {
        Copy-Item -LiteralPath $libSrc.FullName -Destination (Join-Path $libOut "$libStem.lib") -Force
        $libCount++
    } else {
        Write-Host "WARN: keine Import-Lib ($libStem.lib) fuer $base.dll im Quellbaum gefunden."
    }
}
Write-Host "ARM64X-Vorbereitung: $defCount .def- und $libCount .lib-Datei(en) nach $libOut kopiert."

# Statische Faehigkeitspruefung: FFmpeg verteilt die CONFIG_-Schalter auf ZWEI
# generierte Header: ffbuild/config.h (HW-Libs: CONFIG_AMF, CONFIG_CUDA,
# CONFIG_NVDEC, CONFIG_FFNVCODEC ...) und ffbuild/config_components.h (die
# Komponenten-Schalter CONFIG_*_ENCODER/_DECODER/_HWACCEL ...). Da ARM64-
# ffmpeg.exe auf dem x64-Runner NICHT ausfuehrbar ist, pruefen wir die
# Faehigkeiten statisch aus BEIDEN Headern. Der Quellbaum wird fuer beide
# Builds wiederverwendet, daher beide Header je Arch-Prefix sichern,
# bevor der naechste Build sie ueberschreibt.
$cfgCopied = 0
foreach ($cfgName in @('config.h', 'config_components.h')) {
    $cfgSrc = Get-ChildItem -LiteralPath $SourceDir -Recurse -Filter $cfgName -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match ('(?i)[\\/]ffbuild[\\/]' + [regex]::Escape($cfgName) + '$') } | Select-Object -First 1
    if (-not $cfgSrc) {
        $cfgSrc = Get-ChildItem -LiteralPath $SourceDir -Filter $cfgName -File -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($cfgSrc) {
        Copy-Item -LiteralPath $cfgSrc.FullName -Destination (Join-Path $plan.Prefix $cfgName) -Force
        Write-Host "ARM64X-Vorbereitung: $cfgName aus '$($cfgSrc.FullName)' gesichert."
        $cfgCopied++
    } else {
        Write-Host "WARN: $cfgName nicht gefunden."
    }
}
if ($cfgCopied -eq 0) {
    Write-Host "WARN: Keine config*.h gesichert -- statische Faehigkeitspruefung koennte scheitern."
}

Write-Host "FFmpeg-Build abgeschlossen: $($plan.Prefix)"
return $plan
