<#
.SYNOPSIS
    Baut FFmpeg für genau eine (Variante, Architektur)-Kombination als Shared
    Libraries (DLL + .lib) samt ffmpeg.exe/ffprobe.exe.

.DESCRIPTION
    Ein `configure`/`make`-Durchlauf für FFmpeg unter MSYS2 mit der
    MSVC-Toolchain (`--toolchain=msvc`). Das Skript kapselt genau EINEN
    Build-Durchlauf; die vier Durchläufe der Build-Matrix
    (GPL/LGPL × arm64/arm64ec) werden vom Workflow durch vier separate Aufrufe
    dieses Skripts realisiert. Der anschließende ARM64X-Merge über beide
    Architektur-Ansichten ist NICHT Teil dieses Skripts (siehe
    scripts/merge-arm64x.ps1).

    Ablauf je Durchlauf:
      1. Reinlogik-Modul scripts/lib/BuildConfig.psm1 importieren und die
         `configure`-Flags über Get-ConfigureFlags -Variant -Arch beziehen.
      2. Vollständigen `configure`-Befehl zusammensetzen: die Flags plus
         Quell-/Prefix-Pfade (`--prefix`, optional `--bindir`/`--libdir`).
      3. FFmpegs `configure` und danach `make`/`make install` unter MSYS2-bash
         ausführen. Die MSVC-Umgebung (INCLUDE, LIB, PATH aus
         `vcvarsamd64_arm64.bat`) wird über `MSYS2_PATH_TYPE=inherit` an die
         bash-Session durchgereicht, sodass `cl.exe`/`link.exe`/`lib.exe` dort
         auffindbar sind.
      4. Ergebnis: Shared Libraries (DLL + gleichnamige .lib) sowie
         ffmpeg.exe/ffprobe.exe im arch-/varianten-spezifischen Ausgabe-Prefix.

    Die eigentliche Build-Toolchain (MSYS2 + MSVC-Cross-Tools) existiert nur auf
    dem CI-Runner. Damit die Argument-Zusammensetzungs-Logik lokal ohne diese
    Toolchain überprüfbar bleibt, bietet das Skript einen -DryRun-Schalter: er
    setzt genau denselben `configure`/`make`-Aufruf zusammen und gibt ihn aus,
    ohne einen Prozess zu starten. Der reale Build läuft ausschließlich in CI.

    Fail-fast: $ErrorActionPreference = 'Stop'; jeder von Null verschiedene
    Exit-Code eines Build-Schritts bricht das Skript ab.

.PARAMETER Variant
    Lizenz-Variante: 'gpl' oder 'lgpl' (case-insensitiv). Steuert die
    GPL-Komponenten über Get-ConfigureFlags.

.PARAMETER Arch
    Ziel-Architektur: 'arm64' oder 'arm64ec' (case-insensitiv). Bestimmt das
    `--arch=<...>`-Flag und den Namen des Ausgabe-Unterverzeichnisses.

.PARAMETER SourceDir
    Pfad zum ausgepackten FFmpeg-Quellbaum (enthält das `configure`-Skript).

.PARAMETER OutputDir
    Basis-Ausgabeverzeichnis. Der tatsächliche Installations-Prefix ist
    "<OutputDir>/<variant>/<arch>", sodass die vier Durchläufe der Build-Matrix
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
    ./build-ffmpeg.ps1 -Variant gpl -Arch arm64 -SourceDir C:\src\ffmpeg -OutputDir C:\out

.EXAMPLE
    ./build-ffmpeg.ps1 -Variant lgpl -Arch arm64ec -SourceDir C:\src\ffmpeg -OutputDir C:\out -DryRun

.NOTES
    Requirements: 2.3, 3.1, 3.2, 4.1, 4.2, 4.3, 5.1, 5.2, 5.3, 5.4,
                  6.1, 6.2, 6.3, 6.5
    Design: Architecture -> Runner-/Toolchain-Strategie (MSYS2 mit MSVC via
            --toolchain=msvc), Components -> C2 Build-Skripte
            (scripts/build-ffmpeg.ps1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('gpl', 'lgpl', IgnoreCase = $true)]
    [string] $Variant,

    [Parameter(Mandatory)]
    [ValidateSet('arm64', 'arm64ec', IgnoreCase = $true)]
    [string] $Arch,

    [Parameter(Mandatory)]
    [string] $SourceDir,

    [Parameter(Mandatory)]
    [string] $OutputDir,

    # Wurzel der gebauten externen Libs (x264/x265) je Variante,
    # z. B. <OUT>\deps\gpl mit <codec>\<arch>\{include,lib,lib/pkgconfig}.
    # Fuer LGPL leer (keine externen Codecs).
    [Parameter()]
    [string] $DepsDir,

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

# Reinlogik-Modul für die configure-Flags importieren (COMPLETE, siehe Task 2.3).
Import-Module (Join-Path $PSScriptRoot 'lib/BuildConfig.psm1') -Force
# Backport fuer configure (NVIDIA auf aarch64 Windows, FFmpeg-Commit 93f653f95c).
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
        Setzt den vollständigen configure/make-Ablauf für eine
        (Variante, Architektur)-Kombination zusammen (reine Logik).

    .DESCRIPTION
        Kapselt die gesamte Argument-Zusammensetzung ohne Seiteneffekte, damit
        sie lokal (auch im -DryRun) überprüfbar ist. Nutzt Get-ConfigureFlags
        für die Varianten-/Architektur-Flags und ergänzt Quell-/Prefix-Pfade.

    .OUTPUTS
        [pscustomobject] mit:
          Variant, Arch, Prefix (Windows), PrefixPosix,
          SourceDirPosix, ConfigureFlags (string[]),
          ConfigureArgs (string[]), BashScript (string),
          Msys2Bash, Env (hashtable der zu setzenden Umgebungsvariablen).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Variant,
        [Parameter(Mandatory)][string] $Arch,
        [Parameter(Mandatory)][string] $SourceDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $Msys2Bash,
        [Parameter(Mandatory)][int] $Jobs,
        [string] $DepsDir
    )

    $variantKey = $Variant.ToLowerInvariant()
    $archKey = $Arch.ToLowerInvariant()

    # Varianten-/Architektur-Flags aus dem Reinlogik-Modul (COMPLETE).
    $configureFlags = Get-ConfigureFlags -Variant $variantKey -Arch $archKey

    # Arch-/varianten-spezifischer Installations-Prefix, kollisionsfrei je
    # Durchlauf der Build-Matrix.
    $prefix = Join-Path (Join-Path $OutputDir $variantKey) $archKey
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

    # Externe Codecs (nur GPL): FFmpegs configure findet x264/x265
    # ueber pkg-config. Je Codec include/lib hineinreichen (MSVC-Stil)
    # und die pkgconfig-Verzeichnisse fuer PKG_CONFIG_PATH sammeln.
    $pkgConfigDirs = [System.Collections.Generic.List[string]]::new()
    if ($DepsDir -and (Test-Path -LiteralPath $DepsDir)) {
        foreach ($codec in @('x264', 'x265')) {
            $codecRoot = Join-Path (Join-Path $DepsDir $codec) $archKey
            if (-not (Test-Path -LiteralPath $codecRoot)) { continue }
            $incPosix = ConvertTo-Msys2Path -Path (Join-Path $codecRoot 'include')
            $libWin   = Join-Path $codecRoot 'lib'
            $libPosix = ConvertTo-Msys2Path -Path $libWin
            $configureArgs.Add("--extra-cflags=-I$incPosix")
            $configureArgs.Add("--extra-ldflags=-LIBPATH:$libPosix")
            $pcDir = Join-Path $libWin 'pkgconfig'
            if (Test-Path -LiteralPath $pcDir) { $pkgConfigDirs.Add((ConvertTo-Msys2Path -Path $pcDir)) }
        }

        # Hardware-Header (beide Varianten, von build-deps.ps1 abgelegt):
        # AMF ueber den include-Pfad (<AMF/core/Version.h>), ffnvcodec ueber
        # seine .pc-Datei (configure prueft ffnvcodec nur per pkg-config).
        $hwPrefix = Join-Path $DepsDir 'hwheaders'
        if (Test-Path -LiteralPath $hwPrefix) {
            $hwIncPosix = ConvertTo-Msys2Path -Path (Join-Path $hwPrefix 'include')
            $configureArgs.Add("--extra-cflags=-I$hwIncPosix")
            $hwPcDir = Join-Path (Join-Path $hwPrefix 'lib') 'pkgconfig'
            if (Test-Path -LiteralPath $hwPcDir) { $pkgConfigDirs.Add((ConvertTo-Msys2Path -Path $hwPcDir)) }
        }
    }

    $configureArgsArr = [string[]]$configureArgs.ToArray()

    # bash-Skript zusammensetzen: fail-fast (set -euo pipefail), in den
    # Quellbaum wechseln, configure ausführen, dann make + make install.
    $quotedConfigureArgs = ($configureArgsArr | ForEach-Object { ConvertTo-BashSingleQuoted $_ }) -join ' '
    $quotedSource = ConvertTo-BashSingleQuoted $sourcePosix

    $pkgPathLine = if ($pkgConfigDirs.Count -gt 0) {
        "export PKG_CONFIG_PATH='" + ($pkgConfigDirs -join ':') + "'"
    } else { ':' }
    # Diagnose: zeigt im CI-Log, ob pkg-config x264/x265 findet und warum.
    # Laeuft nicht-fatal (|| true), damit set -e hier nicht abbricht.
    $pkgDiag = 'echo PKG_CONFIG_PATH=$PKG_CONFIG_PATH; which pkg-config pkgconf 2>/dev/null || true; for L in x264 x265 ffnvcodec; do echo -- $L --; pkg-config --exists $L && echo found || echo missing; pkg-config --cflags --libs $L 2>&1 || true; done'
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

    $bashLines = @(
        'set -euo pipefail'
        $pkgPathLine
        $pkgDiag
        "cd $quotedSource"
        "./configure $quotedConfigureArgs"
        $cfgMakDiag
        "make -j$Jobs $makeOverrides"
        "make install $makeOverrides"
    )
    $bashScript = ($bashLines -join "`n")

    # Umgebungsvariablen für den bash-Aufruf. MSYS2_PATH_TYPE=inherit reicht die
    # MSVC-Umgebung (INCLUDE/LIB/PATH aus vcvarsamd64_arm64.bat) durch.
    $envVars = @{ 'MSYS2_PATH_TYPE' = 'inherit' }

    # ARM64EC-Ansicht: FFmpegs configure reicht --extra-cflags/--extra-ldflags
    # NICHT zuverlaessig an die eigentliche Objekt-Kompilierung und den
    # Shared-Lib-Link (SLIB_CREATE_DEF_CMD/LD) weiter -- im CI-Lauf 37290208404
    # kamen die arm64ec-DLLs daher als reines ARM64 heraus (die Maschinenzeile
    # zeigte (ARM64) statt (ARM64EC)). cl.exe und link.exe honorieren jedoch IMMER
    # die Umgebungsvariablen _CL_ (an jeden cl-Aufruf angehaengt) und _LINK_ (an
    # jeden link-Aufruf angehaengt). Darueber erzwingen wir -arm64EC fuer jede
    # Kompilierung und -MACHINE:arm64EC fuer jeden Link, unabhaengig von FFmpegs
    # Flag-Weiterleitung. Fuer die reine ARM64-Ansicht bleibt die Umgebung leer.
    if ($archKey -eq 'arm64ec') {
        $envVars['_CL_']   = '-arm64EC'
        $envVars['_LINK_'] = '-MACHINE:arm64EC'
    }

    return [pscustomobject]@{
        Variant        = $variantKey
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
    -Variant $Variant `
    -Arch $Arch `
    -SourceDir $SourceDir `
    -OutputDir $OutputDir `
    -Msys2Bash $Msys2Bash `
    -Jobs $Jobs `
    -DepsDir $DepsDir

Write-Verbose "FFmpeg-Build-Plan: Variant=$($plan.Variant) Arch=$($plan.Arch) Prefix=$($plan.Prefix)"

if ($DryRun) {
    # Lokale Verifikation: Nur den zusammengesetzten Aufruf ausgeben, nichts
    # ausführen. Gibt das Plan-Objekt zurück, damit Tests es inspizieren können.
    Write-Host "== DRY RUN: FFmpeg $($plan.Variant)/$($plan.Arch) =="
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
#   * NVENC/NVDEC auf aarch64 Windows freischalten (93f653f95c)
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

Write-Host "Baue FFmpeg ($($plan.Variant)/$($plan.Arch)) unter MSYS2 ..."
& $plan.Msys2Bash '-lc' $plan.BashScript
if ($LASTEXITCODE -ne 0) {
    # Bei configure-/Build-Fehler FFmpegs config.log ausgeben -- dort steht
    # die konkrete Ursache (z. B. warum pkg-config x264 nicht akzeptiert).
    $ffCfgLog = Join-Path $SourceDir 'ffbuild/config.log'
    if (Test-Path -LiteralPath $ffCfgLog) {
        Write-Host '----- FFmpeg ffbuild/config.log (letzte 120 Zeilen) -----'
        Get-Content -LiteralPath $ffCfgLog -Tail 120 | ForEach-Object { Write-Host $_ }
        Write-Host '---------------------------------------------------------'
    }
    throw "FFmpeg-Build fehlgeschlagen ($($plan.Variant)/$($plan.Arch)): bash-Exit-Code $LASTEXITCODE."
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
# generierte Header: ffbuild/config.h (externe Libs/HW: CONFIG_LIBX264,
# CONFIG_CUDA, CONFIG_NVDEC ...) und ffbuild/config_components.h (die
# Komponenten-Schalter CONFIG_*_ENCODER/_DECODER/_HWACCEL ...). Da ARM64-
# ffmpeg.exe auf dem x64-Runner NICHT ausfuehrbar ist, pruefen wir die
# Faehigkeiten statisch aus BEIDEN Headern. Der Quellbaum wird fuer alle vier
# Builds wiederverwendet, daher beide Header je (Variante,Arch)-Prefix sichern,
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
