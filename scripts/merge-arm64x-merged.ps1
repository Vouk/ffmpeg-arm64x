<#
.SYNOPSIS
    Erzeugt ECHTE (voll verschmolzene) ARM64X-DLLs fuer alle sieben
    FFmpeg-Kernbibliotheken -- EIN File je Bibliothek, OHNE Forwarder.

.DESCRIPTION
    Gegenstueck zum Forwarder-Merge (scripts/merge-arm64x.ps1, Fallback). Hier
    wird je Bibliothek EIN /machine:arm64x-Link gefahren, der die ARM64- UND die
    ARM64EC-Objekte zusammenfuehrt (MS-Rezept "Arm64X PE Files"):

        link /dll /machine:arm64x /out:<lib>.dll
             /def:<arm64ec.def> /defArm64Native:<arm64.def>
             @<arm64ec-objs> @<arm64-objs>
             <abhaengige gemergte .lib> <externe .lib> <system .lib>

    Die EXAKTEN Linker-Eingaben (Objekte, externe Import-Libs, .def) stammen aus
    den /LINKREPROFULLPATHRSP-Dateien, die build-ffmpeg.ps1 im MERGED-Modus je
    DLL und Architektur geschrieben hat (<LinkReproDir>\<lib>.<arch>.rsp) --
    also direkt vom Linker, nicht aus make-Artefakten erraten.

    Reihenfolge nach Abhaengigkeit (jede Lib linkt gegen die bereits gemergten
    Import-Libs der Vorgaenger):
        avutil -> swscale, swresample -> avcodec -> avformat -> avfilter -> avdevice

    Ergebnis: <OutputDir>\<lib>-<ver>.dll (ARM64X-Hybrid) + <lib>-<ver>.lib
    (ARM64X-Import-Lib, als <stem>.lib gespiegelt fuer abhaengige Merges) sowie
    die nativen ffmpeg.exe/ffprobe.exe (aus der ARM64-Ansicht).

.PARAMETER LinkReproDir
    Verzeichnis mit den <lib>.<arch>.rsp-Dateien (von build-ffmpeg.ps1).

.PARAMETER Arm64SourceDir / Arm64ecSourceDir
    FFmpeg-Quellbaeume der beiden Ansichten (die rsp verweisen mit absoluten
    Pfaden auf Objekte darin). In der Praxis derselbe, wiederverwendete Baum --
    ABER: da build-ffmpeg.ps1 beide Ansichten nacheinander im GLEICHEN Baum
    baut, MUSS die Capture die Objekte bereits waehrend des Builds weggesichert
    haben. Dieses Skript erwartet die Objekte daher an den in der rsp genannten
    absoluten Pfaden; der Workflow sorgt dafuer, dass sie dort noch liegen
    (getrennte Quellbaeume je Ansicht).

.PARAMETER OutputDir
    Zielverzeichnis fuer die gemergten DLLs + Import-Libs + Tools.

.PARAMETER LinkExe
    Pfad zu link.exe (Default 'link.exe' aus der vcvars-Umgebung).

.PARAMETER Arm64BinDir
    bin-Verzeichnis der ARM64-Ansicht mit ffmpeg.exe/ffprobe.exe (native Tools).

.NOTES
    Feature: arm64x-ffmpeg-build (merged variant). Fail-fast.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $LinkReproDir,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputDir,
    [Parameter()][string] $Arm64BinDir,
    # Quellbaum der ARM64-Ansicht; im MERGED-Modus liegen ffmpeg.exe/ffprobe.exe
    # dort (kein 'make install'). Wird zusaetzlich zu -Arm64BinDir durchsucht.
    [Parameter()][string] $Arm64SourceDir,
    [Parameter()][ValidateNotNullOrEmpty()][string] $LinkExe = 'link.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Dependency-Reihenfolge + Stamm-Namen der Kernbibliotheken.
# ---------------------------------------------------------------------------
$script:MergeOrder = @('avutil', 'swscale', 'swresample', 'avcodec', 'avformat', 'avfilter', 'avdevice')
$script:FFmpegStems = @('avutil','avcodec','avformat','avfilter','avdevice','swscale','swresample')

function Read-LinkReproInputs {
    <#
    .SYNOPSIS
        Parst eine /LINKREPROFULLPATHRSP-Datei: liefert absolute Pfade der
        Objekte (.o/.obj), externen Import-Libs (.lib) und den .def-Pfad.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $RspPath)

    if (-not (Test-Path -LiteralPath $RspPath)) { throw "LinkRepro-Datei fehlt: '$RspPath'." }
    $raw = [System.IO.File]::ReadAllText($RspPath)

    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($raw, '"([^"]+)"|(\S+)')) {
        $t = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        if (-not [string]::IsNullOrWhiteSpace($t)) { $tokens.Add($t) }
    }

    $objs = [System.Collections.Generic.List[string]]::new()
    $libs = [System.Collections.Generic.List[string]]::new()
    $def = $null
    foreach ($t in $tokens) {
        if ($t -match '^[/-]') {
            if ($t -match '(?i)^[/-]def:(.+)$') { $def = $Matches[1].Trim('"') }
            continue
        }
        if     ($t -match '(?i)\.(o|obj)$') { $objs.Add($t) }
        elseif ($t -match '(?i)\.lib$')     { $libs.Add($t) }
        elseif ($t -match '(?i)\.def$')     { if (-not $def) { $def = $t } }
    }
    return [pscustomobject]@{
        Objs = [string[]]$objs.ToArray()
        Libs = [string[]]$libs.ToArray()
        Def  = $def
    }
}

function Test-IsFFmpegOwnLib {
    <#
    .SYNOPSIS
        True, wenn der Lib-Pfad eine FFmpeg-EIGENE Import-Lib ist (libavutil
        etc.) -- diese ersetzt der Merge durch die gemergten ARM64X-Import-Libs.
    #>
    param([Parameter(Mandatory)][string] $Path)
    foreach ($stem in $script:FFmpegStems) {
        if ($Path -match ('(?i)[\\/]lib' + [regex]::Escape($stem) + '[\\/]')) { return $true }
        if ($Path -match ('(?i)[\\/]' + [regex]::Escape($stem) + '\.lib$'))    { return $true }
    }
    return $false
}

function Convert-StemFromKey {
    param([Parameter(Mandatory)][string] $Key)   # avcodec-62 -> avcodec
    return ($Key -replace '-\d+$', '')
}

# Win32-System-Import-Libs (SDK) -- werden per NAME ueber $script:SysLibs
# gereicht (ARM64X waehlt je Seite die passende Variante). Daher NICHT
# zusaetzlich per vollem Pfad aus der rsp einbringen (sonst ABI-Mismatch, weil
# die rsp eine arch-spezifische SDK-Variante nennt).
#
# WICHTIG: Diese Liste MUSS JEDE System-Lib enthalten, die irgendeine der
# Kern-Libs beim Link braucht -- denn Namen aus dieser Liste werden aus den
# rsp-abgeleiteten $extLibs ENTFERNT (Test-IsSystemImportLib) und
# ausschliesslich ueber $script:SysLibs (unten, als .lib) wieder eingebracht.
# Fehlt eine hier, verschwindet sie komplett aus dem Link. avdevice z. B.
# zieht shlwapi (SHCreateStreamOnFileA, dshow) und vfw32 (capCreateCaptureWindowA,
# capGetDriverDescriptionA, vfwcap) -- beide MUESSEN enthalten sein.
$script:SystemImportLibNames = @(
    'bcrypt','user32','ole32','oleaut32','advapi32','ws2_32','secur32',
    'mfplat','mfuuid','strmiids','uuid','gdi32','kernel32',
    'shell32','shlwapi','d3d11','dxgi','d3d9','vfw32','psapi',
    'dxguid','winmm','version','ntdll','crypt32'
) | Sort-Object -Unique
function Test-IsSystemImportLib {
    param([Parameter(Mandatory)][string] $Path)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path).ToLowerInvariant()
    return ($script:SystemImportLibNames -contains $base)
}

function Resolve-LibKey {
    <#
    .SYNOPSIS
        Findet den versionierten Key (z. B. avcodec-62) eines Stamms aus den
        vorhandenen rsp-Dateien im LinkReproDir.
    #>
    param([Parameter(Mandatory)][string] $Stem, [Parameter(Mandatory)][string] $LinkReproDir)
    $rsp = Get-ChildItem -LiteralPath $LinkReproDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match ('^(' + [regex]::Escape($Stem) + '-\d+)\.arm64\.rsp$') } |
        Select-Object -First 1
    if (-not $rsp) { throw "Keine arm64-rsp fuer '$Stem' in '$LinkReproDir' gefunden." }
    return ($rsp.Name -replace '\.arm64\.rsp$', '')
}

# Win32-System-Import-Libs (Superset ueber alle Kern-Libs), die beim
# /machine:arm64x-Link per NAME uebergeben werden (der Linker waehlt je Seite
# die passende ARM64/ARM64EC-Variante aus den SDK-LIB-Pfaden). Direkt aus
# $script:SystemImportLibNames abgeleitet, damit die "aus $extLibs entfernt"-
# Menge und die "per Name wieder eingebracht"-Menge NIE auseinanderlaufen
# koennen. Nicht referenzierte Libs sind beim Link harmlos.
$script:SysLibs = @($script:SystemImportLibNames | ForEach-Object { "$_.lib" })

function Invoke-MergeOne {
    <#
    .SYNOPSIS
        Merged EINE Bibliothek zu einer ARM64X-DLL.
    .OUTPUTS
        [string] Pfad der erzeugten <stem>.lib (ARM64X-Import-Lib).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Key,            # z. B. avcodec-62
        [Parameter(Mandatory)][string] $LinkReproDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $LinkExe,
        [Parameter()][string[]] $DepLibs = @()          # gemergte Vorgaenger-.libs
    )

    $stem = Convert-StemFromKey -Key $Key
    $arm64Rsp   = Join-Path $LinkReproDir "$Key.arm64.rsp"
    $arm64ecRsp = Join-Path $LinkReproDir "$Key.arm64ec.rsp"
    foreach ($r in @($arm64Rsp, $arm64ecRsp)) {
        if (-not (Test-Path -LiteralPath $r)) { throw "rsp fehlt fuer '$Key': '$r'." }
    }

    $nat = Read-LinkReproInputs -RspPath $arm64Rsp
    $ec  = Read-LinkReproInputs -RspPath $arm64ecRsp
    if ($nat.Objs.Count -eq 0 -or $ec.Objs.Count -eq 0) {
        throw "Objektliste leer fuer '$Key' (arm64: $($nat.Objs.Count), arm64ec: $($ec.Objs.Count))."
    }
    if (-not $nat.Def -or -not $ec.Def) {
        throw ".def fehlt in rsp fuer '$Key' (arm64: '$($nat.Def)', arm64ec: '$($ec.Def)')."
    }

    # Duplikat-VERSION-Ressource (*res.o) nur EINMAL einbringen: von der nativen
    # ARM64-Seite entfernen (CVT1100), EC-Seite behaelt sie.
    $natObjs = @($nat.Objs | Where-Object { $_ -notmatch '(?i)res\.o$' })
    foreach ($o in @($natObjs + $ec.Objs)) {
        if (-not (Test-Path -LiteralPath $o)) { throw "Objekt aus rsp fehlt (nicht mehr auf Platte): '$o'." }
    }

    # Externe (nicht-FFmpeg) Import-/Archiv-Libs aus BEIDEN rsp-Dateien.
    # WICHTIG fuer statische Archiv-Libs mit ABI-spezifischem Code (x264/x265):
    # die arm64-Variante traegt ARM64-Objekte, die arm64ec-Variante
    # ARM64EC-Objekte. Fuer den /machine:arm64x-Link MUSS BEIDES eingehen,
    # damit die nativen ARM64-Referenzen gegen das arm64-Archiv und die
    # EC-Referenzen gegen das arm64ec-Archiv aufgeloest werden. Die Pfade
    # unterscheiden sich (\x264\arm64\lib vs \x264\arm64ec\lib), daher einfach
    # beide vollen Pfade uebergeben; der Linker nutzt je Seite das passende.
    # System-Import-Libs (bcrypt, user32, ...) kommen separat ueber $SysLibs
    # per Name (ARM64X loest die passende SDK-Variante je Seite auf), daher
    # hier NICHT per Pfad doppeln.
    $extLibs = @(
        @($nat.Libs) + @($ec.Libs) |
            Where-Object { -not (Test-IsFFmpegOwnLib -Path $_) } |
            Where-Object { -not (Test-IsSystemImportLib -Path $_) } |
            Sort-Object -Unique
    )
    foreach ($l in $extLibs) { if (-not (Test-Path -LiteralPath $l)) { throw "Externe Lib aus rsp fehlt: '$l'." } }

    $outDll = Join-Path $OutputDir "$Key.dll"
    $ecObjRsp  = Join-Path $OutputDir "$Key.arm64ec.objs.rsp"
    $natObjRsp = Join-Path $OutputDir "$Key.arm64.objs.rsp"
    Set-Content -LiteralPath $ecObjRsp  -Value (($ec.Objs | ForEach-Object { '"' + $_ + '"' }) -join "`n") -Encoding Ascii
    Set-Content -LiteralPath $natObjRsp -Value (($natObjs | ForEach-Object { '"' + $_ + '"' }) -join "`n") -Encoding Ascii

    $linkArgs = @(
        '/dll','/machine:arm64x','/nologo',
        "/out:$outDll",
        "/def:$($ec.Def)",
        "/defArm64Native:$($nat.Def)",
        "@$ecObjRsp","@$natObjRsp"
    ) + @($DepLibs) + @($extLibs) + $script:SysLibs

    Write-Host "merge ($Key): $($natObjs.Count) ARM64 + $($ec.Objs.Count) ARM64EC objs; dep-libs=$($DepLibs.Count); ext-libs=$($extLibs.Count)"
    & $LinkExe @linkArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { throw "MERGED ARM64X-Link fuer '$Key' fehlgeschlagen (Exit $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath $outDll)) { throw "Merged ARM64X-DLL nicht erzeugt: '$outDll'." }

    # Import-Lib <Key>.lib -> <stem>.lib spiegeln (abhaengige Merges linken
    # unversioniert gegen <stem>.lib).
    $prodLib = Join-Path $OutputDir "$Key.lib"
    $stemLib = Join-Path $OutputDir "$stem.lib"
    if ((Test-Path -LiteralPath $prodLib) -and -not [string]::Equals($prodLib, $stemLib, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $prodLib -Destination $stemLib -Force
    }
    # Zwischen-rsp aufraeumen.
    Remove-Item -LiteralPath $ecObjRsp, $natObjRsp -Force -ErrorAction SilentlyContinue
    Write-Host "MERGED ARM64X-DLL: $outDll"
    return $stemLib
}

# ---------------------------------------------------------------------------
# Orchestrierung: alle sieben in Abhaengigkeitsreihenfolge mergen.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    # Je Stamm der versionierte Key.
    $keyByStem = @{}
    foreach ($stem in $script:MergeOrder) {
        $keyByStem[$stem] = Resolve-LibKey -Stem $stem -LinkReproDir $LinkReproDir
    }

    # Abhaengigkeitskanten (FFmpeg-intern): welche bereits gemergten .libs eine
    # Lib beim Link zusaetzlich braucht.
    $deps = @{
        'avutil'      = @()
        'swscale'     = @('avutil')
        'swresample'  = @('avutil')
        'avcodec'     = @('avutil','swresample')
        'avformat'    = @('avutil','avcodec','swresample')
        'avfilter'    = @('avutil','avcodec','avformat','swscale','swresample')
        'avdevice'    = @('avutil','avcodec','avformat','avfilter','swscale','swresample')
    }

    $mergedLibOfStem = @{}
    foreach ($stem in $script:MergeOrder) {
        $key = $keyByStem[$stem]
        $depLibs = @()
        foreach ($d in $deps[$stem]) {
            if (-not $mergedLibOfStem.ContainsKey($d)) { throw "Abhaengigkeit '$d' fuer '$stem' noch nicht gemergt (Reihenfolge?)." }
            $depLibs += $mergedLibOfStem[$d]
        }
        $stemLib = Invoke-MergeOne -Key $key -LinkReproDir $LinkReproDir -OutputDir $OutputDir -LinkExe $LinkExe -DepLibs $depLibs
        $mergedLibOfStem[$stem] = $stemLib
    }

    # Native ARM64-Tools uebernehmen. Suchorte: -Arm64BinDir (falls doch
    # installiert) UND der ARM64-Quellbaum (MERGED: dort liegen die Tools nach
    # 'make ffmpeg.exe ffprobe.exe'). Beide Namensformen (.exe und ohne).
    $searchRoots = @()
    if ($Arm64BinDir     -and (Test-Path -LiteralPath $Arm64BinDir))     { $searchRoots += $Arm64BinDir }
    if ($Arm64SourceDir  -and (Test-Path -LiteralPath $Arm64SourceDir))  { $searchRoots += $Arm64SourceDir }
    foreach ($exe in @('ffmpeg.exe','ffprobe.exe')) {
        $found = $null
        foreach ($root in $searchRoots) {
            foreach ($cand in @($exe, ($exe -replace '\.exe$',''))) {
                $p = Join-Path $root $cand
                if (Test-Path -LiteralPath $p) { $found = $p; break }
            }
            if ($found) { break }
        }
        if ($found) {
            Copy-Item -LiteralPath $found -Destination (Join-Path $OutputDir $exe) -Force
            Write-Host "Tool uebernommen (native ARM64): $exe  <- $found"
        } else {
            Write-Host "WARN: $exe in keinem Suchort gefunden: $($searchRoots -join ', ')"
        }
    }

    Write-Host "MERGED ARM64X abgeschlossen: $($script:MergeOrder.Count) DLL(s) -> $OutputDir"
}
