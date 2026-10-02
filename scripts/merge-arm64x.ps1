<#
.SYNOPSIS
    Erzeugt ARM64X-"Pure Forwarder"-DLLs aus einer ARM64- und einer
    ARM64EC-Ansicht derselben FFmpeg-Bibliotheken.

.DESCRIPTION
    Hintergrund: Ein ARM64X-Image laesst sich NICHT durch Zusammenlinken zweier
    fertiger DLLs erzeugen (link.exe /MACHINE:ARM64X auf zwei DLLs scheitert mit
    LNK1107). Microsoft empfiehlt fuer Builds, bei denen ein voll verschmolzenes
    Binary schwierig ist (z. B. FFmpegs make-Build), den "Pure Forwarder":

        link /dll /noentry /machine:arm64x
             /defArm64Native:<arm64.def> /def:<arm64ec.def>
             empty_arm64.obj empty_arm64ec.obj
             /out:<name>.dll <arm64.lib> <arm64ec.lib>

    Das Ergebnis ist eine kleine ARM64X-DLL ohne eigenen Code. Beim Laden
    leitet Windows jeden Aufruf an die passende echte DLL weiter:
      * ARM64-Prozess        -> <name>_arm64.dll
      * x64/ARM64EC-Prozess  -> <name>_arm64ec.dll
    (Quelle: learn.microsoft.com "Build Arm64X Files" -> Pure Forwarder.)

    Ablauf je Bibliothek (avcodec, avformat, ...):
      1. Die echten DLLs der beiden Ansichten werden unter neuen Namen
         (<base>_arm64.dll / <base>_arm64ec.dll) ins Ausgabeverzeichnis kopiert.
      2. Aus den von FFmpeg erzeugten .def-Dateien beider Ansichten werden
         Forwarder-.defs gebaut: jede Zeile "Sym" wird zu
         "Sym=<base>_arm64.Sym" bzw. "Sym=<base>_arm64ec.Sym". Wichtig: der
         Zielmodulname darf KEINEN Punkt enthalten, sonst teilt der .def-Parser
         ihn falsch auf -- deshalb Unterstrich statt Punkt.
      3. Aus den Forwarder-.defs werden Import-Libs erzeugt (MS-Rezept):
         link /lib /machine:arm64 /def:<arm64.fwd.def> /out:<base>.arm64.fwd.lib
         link /lib /machine:x64   /def:<arm64ec.fwd.def> /out:<base>.arm64ec.fwd.lib
         Diese Libs -- NICHT die FFmpeg-Original-Libs -- gehen in den Link;
         nur so ist jeder Export als Weiterleitung definiert (sonst meldet der
         Linker die EC-Exporte als "unresolved external symbol (EC Symbol)").
      4. Zwei leere OBJs werden erzeugt (arm64 + arm64ec).
      5. Der Forwarder <base>.dll wird mit /MACHINE:ARM64X gelinkt:
         link /dll /noentry /machine:arm64x /defArm64Native:<arm64.fwd.def>
              /def:<arm64ec.fwd.def> empty_arm64.obj empty_arm64ec.obj
              /out:<base>.dll <base>.arm64.fwd.lib <base>.arm64ec.fwd.lib

    Lokale Testbarkeit: cl.exe/link.exe existieren nur auf dem CI-Runner. Die
    reine Logik (Forwarder-.def-Erzeugung und Kommando-Zusammenstellung) ist in
    ConvertTo-ForwarderDef und Get-Arm64xForwarderPlan gekapselt und ohne
    Toolchain pruefbar. -DryRun fuehrt nichts aus, gibt aber den Plan zurueck.

    Fail-fast: $ErrorActionPreference = 'Stop'.

.PARAMETER Arm64Dir
    bin-Verzeichnis der ARM64-Ansicht (enthaelt die echten *.dll).

.PARAMETER Arm64ecDir
    bin-Verzeichnis der ARM64EC-Ansicht.

.PARAMETER Arm64LibDir
    lib-Verzeichnis der ARM64-Ansicht (Import-Libs + .def je DLL).

.PARAMETER Arm64ecLibDir
    lib-Verzeichnis der ARM64EC-Ansicht.

.PARAMETER OutputDir
    Zielverzeichnis fuer Forwarder + die beiden echten DLLs je Bibliothek.

.PARAMETER LinkExe
    Pfad zu link.exe (Standard: 'link.exe' aus der vcvars-Umgebung).

.PARAMETER ClExe
    Pfad zu cl.exe (Standard: 'cl.exe').

.PARAMETER DryRun
    Nichts ausfuehren; nur den Plan ermitteln und zurueckgeben.

.NOTES
    Feature: arm64x-ffmpeg-build
    Requirements: 2.3, 2.4, 2.5, 3.2
    Design: ARM64X ueber Pure-Forwarder (MS-empfohlen fuer make-basierte Builds).
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Arm64Dir,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Arm64ecDir,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Arm64LibDir,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Arm64ecLibDir,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputDir,
    [Parameter()][ValidateNotNullOrEmpty()][string] $LinkExe = 'link.exe',
    [Parameter()][ValidateNotNullOrEmpty()][string] $ClExe = 'cl.exe',
    [Parameter()][switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Reine Logik (ohne Toolchain / Seiteneffekte, lokal testbar)
# ---------------------------------------------------------------------------

function ConvertTo-ForwarderDef {
    <#
    .SYNOPSIS
        Wandelt eine FFmpeg-.def (EXPORTS + ein Symbol je Zeile) in eine
        Forwarder-.def um: "Sym" -> "Sym=$ForwardTo.Sym".
    .DESCRIPTION
        Reine String-Transformation. $ForwardTo ist der Modulname OHNE
        Erweiterung und OHNE internen Punkt (z. B. "avcodec-62_arm64").
        Kommentare (;), leere Zeilen und
        die EXPORTS-Zeile bleiben erhalten; bereits weitergeleitete Zeilen
        (enthalten "=") werden unveraendert uebernommen. Attribute wie
        "@1", "PRIVATE", "DATA" nach dem Symbolnamen werden entfernt, da ein
        Forwarder nur Name=Ziel.Name braucht.
    .OUTPUTS
        [string] Der Inhalt der Forwarder-.def (LF-getrennt).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $DefContent,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ForwardTo
    )

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in ($DefContent -split "`r?`n")) {
        $line = $raw.TrimEnd()
        $trim = $line.Trim()
        if ($trim -eq '' -or $trim.StartsWith(';')) { $out.Add($line); continue }
        if ($trim -match '^(EXPORTS|LIBRARY|NAME|VERSION|HEAPSIZE|STACKSIZE|SECTIONS)\b') { $out.Add($line); continue }
        if ($trim -match '=') { $out.Add($line); continue }
        # Erstes Token ist der Symbolname; Rest (Ordinale/Attribute) verwerfen.
        $sym = ($trim -split '\s+')[0]
        if ($sym) { $out.Add("    $sym=$ForwardTo.$sym") }
    }
    return ($out -join "`n")
}

function Get-Arm64xForwarderPlan {
    <#
    .SYNOPSIS
        Stellt je gepaarter DLL den vollstaendigen Forwarder-Bauplan zusammen
        (reine Logik, keine Toolchain, keine Seiteneffekte).
    .DESCRIPTION
        Paart jede DLL der ARM64-Ansicht mit der gleichnamigen DLL der
        ARM64EC-Ansicht. Je Paar werden die Ziel-Pfade (echte DLLs, Forwarder,
        Forwarder-.defs, leere OBJs) und die Toolchain-Kommandos (cl fuer die
        OBJs, link fuer den Forwarder) ermittelt.
    .OUTPUTS
        [pscustomobject] mit Forwarders ([pscustomobject[]]).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Arm64Dir,
        [Parameter(Mandatory)][string] $Arm64ecDir,
        [Parameter(Mandatory)][string] $Arm64LibDir,
        [Parameter(Mandatory)][string] $Arm64ecLibDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $LinkExe,
        [Parameter(Mandatory)][string] $ClExe,
        [Parameter(Mandatory)][scriptblock] $DllLister
    )

    $arm64Dlls   = @(& $DllLister $Arm64Dir)
    $arm64ecSet  = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(& $DllLister $Arm64ecDir), [System.StringComparer]::OrdinalIgnoreCase)

    $fwds = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($base in ($arm64Dlls | Sort-Object)) {
        if (-not $arm64ecSet.Contains($base)) {
            throw "ARM64X-Forwarder nicht moeglich fuer '$base.dll': die " +
                  "ARM64EC-Ansicht fehlt in '$Arm64ecDir'. Beide Ansichten noetig."
        }

        # FFmpeg benennt die DLL versioniert (avcodec-62.dll), die Import-Lib
        # aber UNversioniert (avcodec.lib). Die .def wird versioniert erzeugt
        # (avcodec-62.def) und von build-ffmpeg.ps1 so kopiert. Fuer die .lib
        # daher die Trailing-Version "-<zahl>" vom Basisnamen entfernen.
        $libStem = $base -replace '-\d+$', ''

        $realArm64Name   = "${base}_arm64.dll"
        $realArm64ecName = "${base}_arm64ec.dll"
        $fwds.Add([pscustomobject]@{
            BaseName        = $base
            # Eingaben
            SrcArm64Dll     = Join-Path $Arm64Dir   "$base.dll"
            SrcArm64ecDll   = Join-Path $Arm64ecDir "$base.dll"
            SrcArm64Def     = Join-Path $Arm64LibDir   "$base.def"
            SrcArm64ecDef   = Join-Path $Arm64ecLibDir "$base.def"
            SrcArm64Lib     = Join-Path $Arm64LibDir   "$libStem.lib"
            SrcArm64ecLib   = Join-Path $Arm64ecLibDir "$libStem.lib"
            # Ausgaben
            RealArm64Dll    = Join-Path $OutputDir $realArm64Name
            RealArm64ecDll  = Join-Path $OutputDir $realArm64ecName
            ForwarderDll    = Join-Path $OutputDir "$base.dll"
            FwdArm64Def     = Join-Path $OutputDir "$base.arm64.fwd.def"
            FwdArm64ecDef   = Join-Path $OutputDir "$base.arm64ec.fwd.def"
            # Import-Libs werden AUS den Forwarder-.defs erzeugt (MS-Rezept):
            #   link /lib /machine:arm64 /def:<arm64.fwd.def> /out:<...arm64.fwd.lib>
            #   link /lib /machine:x64   /def:<arm64ec.fwd.def> /out:<...arm64ec.fwd.lib>
            # Diese -- NICHT die FFmpeg-Original-Libs -- gehen in den ARM64X-Link.
            FwdArm64Lib     = Join-Path $OutputDir "$base.arm64.fwd.lib"
            FwdArm64ecLib   = Join-Path $OutputDir "$base.arm64ec.fwd.lib"
            ForwardToArm64  = "${base}_arm64"
            ForwardToArm64ec= "${base}_arm64ec"
            EmptyArm64Obj   = Join-Path $OutputDir "$base.empty.arm64.obj"
            EmptyArm64ecObj = Join-Path $OutputDir "$base.empty.arm64ec.obj"
            LinkArgs        = $null  # wird nach .def-Erzeugung gesetzt
        })
    }

    return [pscustomobject]@{
        Arm64Dir   = $Arm64Dir
        Arm64ecDir = $Arm64ecDir
        OutputDir  = $OutputDir
        LinkExe    = $LinkExe
        ClExe      = $ClExe
        Forwarders = [pscustomobject[]] $fwds.ToArray()
    }
}

function Get-ForwarderLinkArgs {
    <#
    .SYNOPSIS
        Baut die link.exe-Argumentliste fuer einen ARM64X-Pure-Forwarder.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][pscustomobject] $Fwd)

    return [string[]] @(
        '/dll'
        '/noentry'
        '/machine:arm64x'
        "/defArm64Native:$($Fwd.FwdArm64Def)"
        "/def:$($Fwd.FwdArm64ecDef)"
        "/out:$($Fwd.ForwarderDll)"
        $Fwd.EmptyArm64Obj
        $Fwd.EmptyArm64ecObj
        $Fwd.FwdArm64Lib
        $Fwd.FwdArm64ecLib
    )
}

$script:DefaultDllLister = {
    param([string] $Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { throw "Verzeichnis nicht gefunden: '$Dir'." }
    Get-ChildItem -LiteralPath $Dir -Filter '*.dll' -File |
        Where-Object { $_.Name -notmatch '_arm64(ec)?\.dll$' } |
        ForEach-Object { $_.BaseName }
}

# ---------------------------------------------------------------------------
# Ausfuehrung (echte Toolchain, nur auf CI)
# ---------------------------------------------------------------------------

function New-ForwarderImportLib {
    <#
    .SYNOPSIS
        Erzeugt eine Import-Lib aus einer Forwarder-.def via link /lib.
    .DESCRIPTION
        MS-Rezept fuer ARM64X-Pure-Forwarder: die Import-Libs, die in den
        /machine:arm64x-Link eingehen, werden aus den Forwarder-.defs erzeugt
        (nicht aus den FFmpeg-Original-Libs). Nur so sind alle Exporte als
        Weiterleitung definiert und der Link meldet keine "unresolved external".
        ARM64-Seite: /machine:arm64, EC-Seite: /machine:x64.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LinkExe,
        [Parameter(Mandatory)][string] $Def,
        [Parameter(Mandatory)][string] $OutLib,
        [Parameter(Mandatory)][ValidateSet('arm64','x64')][string] $Machine
    )
    $libArgs = @('/lib', "/machine:$Machine", "/def:$Def", "/out:$OutLib")
    & $LinkExe @libArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { throw "link /lib ($Machine) fuer '$Def' schlug fehl (Exit $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath $OutLib)) { throw "Import-Lib nicht erzeugt: '$OutLib'." }
}

function New-EmptyObject {
    <#
    .SYNOPSIS
        Erzeugt ein leeres OBJ (arm64 oder arm64ec) via cl.exe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ClExe,
        [Parameter(Mandatory)][string] $OutObj,
        [switch] $Ec
    )
    $empty = [System.IO.Path]::ChangeExtension($OutObj, '.c')
    Set-Content -LiteralPath $empty -Value '' -Encoding Ascii
    $clArgs = @('/nologo', '/c')
    if ($Ec) { $clArgs += '/arm64EC' }
    $clArgs += @("/Fo$OutObj", $empty)
    & $ClExe @clArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { throw "cl.exe (leeres OBJ$(if($Ec){' arm64ec'}else{' arm64'})) schlug fehl (Exit $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath $OutObj)) { throw "Leeres OBJ nicht erzeugt: '$OutObj'." }
}

function Invoke-ForwarderBuild {
    <#
    .SYNOPSIS
        Baut einen einzelnen ARM64X-Forwarder (echte Toolchain, Fail-fast).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject] $Fwd,
        [Parameter(Mandatory)][string] $LinkExe,
        [Parameter(Mandatory)][string] $ClExe
    )

    Write-Host "  forwarder -> $($Fwd.BaseName).dll (-> _arm64.dll / _arm64ec.dll)"

    # Noetige Eingaben: die echten DLLs beider Ansichten und ihre .def-Dateien.
    # Die FFmpeg-Original-Import-Libs werden NICHT gebraucht -- die Import-Libs
    # fuer den ARM64X-Link werden frisch aus den Forwarder-.defs erzeugt.
    foreach ($src in @($Fwd.SrcArm64Dll, $Fwd.SrcArm64ecDll, $Fwd.SrcArm64Def, $Fwd.SrcArm64ecDef)) {
        if (-not (Test-Path -LiteralPath $src)) {
            throw "ARM64X-Forwarder '$($Fwd.BaseName)': Eingabe fehlt: '$src'."
        }
    }

    # 1) echte DLLs unter neuen Namen ablegen
    Copy-Item -LiteralPath $Fwd.SrcArm64Dll   -Destination $Fwd.RealArm64Dll   -Force
    Copy-Item -LiteralPath $Fwd.SrcArm64ecDll -Destination $Fwd.RealArm64ecDll -Force

    # 2) Forwarder-.defs erzeugen
    $arm64Def   = ConvertTo-ForwarderDef -DefContent ([System.IO.File]::ReadAllText($Fwd.SrcArm64Def))   -ForwardTo $Fwd.ForwardToArm64
    $arm64ecDef = ConvertTo-ForwarderDef -DefContent ([System.IO.File]::ReadAllText($Fwd.SrcArm64ecDef)) -ForwardTo $Fwd.ForwardToArm64ec
    [System.IO.File]::WriteAllText($Fwd.FwdArm64Def,   $arm64Def,   (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($Fwd.FwdArm64ecDef, $arm64ecDef, (New-Object System.Text.UTF8Encoding($false)))

    # 3) Import-Libs AUS den Forwarder-.defs erzeugen (MS-Rezept). Der ARM64X-
    #    Link bekommt diese Libs; sie definieren jeden Export als Weiterleitung.
    #    ARM64-Seite: /machine:arm64, EC-Seite: /machine:x64 (so im MS-Doc).
    New-ForwarderImportLib -LinkExe $LinkExe -Def $Fwd.FwdArm64Def   -OutLib $Fwd.FwdArm64Lib   -Machine arm64
    New-ForwarderImportLib -LinkExe $LinkExe -Def $Fwd.FwdArm64ecDef -OutLib $Fwd.FwdArm64ecLib -Machine x64

    # 4) leere OBJs
    New-EmptyObject -ClExe $ClExe -OutObj $Fwd.EmptyArm64Obj
    New-EmptyObject -ClExe $ClExe -OutObj $Fwd.EmptyArm64ecObj -Ec

    # 5) Forwarder linken
    $linkArgs = Get-ForwarderLinkArgs -Fwd $Fwd
    & $LinkExe @linkArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "ARM64X-Forwarder-Link fuer '$($Fwd.BaseName).dll' fehlgeschlagen (Exit $LASTEXITCODE)."
    }
    if (-not (Test-Path -LiteralPath $Fwd.ForwarderDll)) {
        throw "ARM64X-Forwarder nicht erzeugt: '$($Fwd.ForwarderDll)'."
    }

    # Aufraeumen: Zwischendateien (OBJs, .c, Forwarder-.defs) entfernen.
    foreach ($tmp in @($Fwd.EmptyArm64Obj, $Fwd.EmptyArm64ecObj,
                       [System.IO.Path]::ChangeExtension($Fwd.EmptyArm64Obj, '.c'),
                       [System.IO.Path]::ChangeExtension($Fwd.EmptyArm64ecObj, '.c'),
                       $Fwd.FwdArm64Lib, $Fwd.FwdArm64ecLib,
                       [System.IO.Path]::ChangeExtension($Fwd.FwdArm64Lib, '.exp'),
                       [System.IO.Path]::ChangeExtension($Fwd.FwdArm64ecLib, '.exp'),
                       [System.IO.Path]::ChangeExtension($Fwd.ForwarderDll, '.lib'),
                       [System.IO.Path]::ChangeExtension($Fwd.ForwarderDll, '.exp'),
                       $Fwd.FwdArm64Def, $Fwd.FwdArm64ecDef)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Ausfuehrbaren, die (als native ARM64-Binaries) in die ARM64X-Verteilung
# uebernommen werden. Sie sind KEINE ARM64X-Hybride: ein ARM64-Prozess startet
# sie und laedt dabei die ARM64X-Forwarder-DLLs, die auf die _arm64-DLLs zeigen.
$script:Arm64Executables = @('ffmpeg.exe', 'ffprobe.exe')

function Copy-Arm64Executables {
    <#
    .SYNOPSIS
        Kopiert die ARM64-Ausfuehrbaren (ffmpeg.exe/ffprobe.exe) in die
        ARM64X-Ausgabe. Pure Logik ueber einen injizierbaren Copier/Tester.
    .DESCRIPTION
        Im Pure-Forwarder-Modell werden die nativen ARM64-Tools mitgeliefert.
        Fehlt eine erwartete .exe im ARM64-bin, wird fail-fast abgebrochen.
    .OUTPUTS
        [string[]] -- die kopierten Ziel-Pfade.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $Arm64Dir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter()][scriptblock] $Copier,
        [Parameter()][scriptblock] $Tester
    )
    $test = if ($Tester) { $Tester } else { { param($x) Test-Path -LiteralPath $x } }
    $copy = if ($Copier) { $Copier } else { { param($src,$dst) Copy-Item -LiteralPath $src -Destination $dst -Force } }
    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($exe in $script:Arm64Executables) {
        $src = Join-Path $Arm64Dir $exe
        $dst = Join-Path $OutputDir $exe
        if (-not (& $test $src)) {
            throw "ARM64X-Forwarder: erwartete ARM64-Ausfuehrbare fehlt: '$src'."
        }
        & $copy $src $dst
        $copied.Add($dst)
    }
    return , ([string[]]$copied.ToArray())
}

function Invoke-Arm64xForwarder {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Arm64Dir,
        [Parameter(Mandatory)][string] $Arm64ecDir,
        [Parameter(Mandatory)][string] $Arm64LibDir,
        [Parameter(Mandatory)][string] $Arm64ecLibDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $LinkExe,
        [Parameter(Mandatory)][string] $ClExe,
        [switch] $DryRun,
        [scriptblock] $DllLister
    )

    $lister = if ($DllLister) { $DllLister } else { $script:DefaultDllLister }
    $plan = Get-Arm64xForwarderPlan -Arm64Dir $Arm64Dir -Arm64ecDir $Arm64ecDir `
        -Arm64LibDir $Arm64LibDir -Arm64ecLibDir $Arm64ecLibDir `
        -OutputDir $OutputDir -LinkExe $LinkExe -ClExe $ClExe -DllLister $lister

    if ($DryRun) {
        Write-Host "== DRY RUN: ARM64X-Forwarder =="
        Write-Host "ARM64   bin: $Arm64Dir"
        Write-Host "ARM64EC bin: $Arm64ecDir"
        Write-Host "Output     : $OutputDir"
        foreach ($fwd in $plan.Forwarders) {
            $fwd.LinkArgs = Get-ForwarderLinkArgs -Fwd $fwd
            Write-Host "  $($fwd.BaseName).dll:"
            Write-Host "    link $($fwd.LinkArgs -join ' ')"
        }
        return $plan
    }

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    Write-Host "ARM64X-Forwarder: $($plan.Forwarders.Count) Bibliothek(en) -> $OutputDir"
    foreach ($fwd in $plan.Forwarders) {
        Invoke-ForwarderBuild -Fwd $fwd -LinkExe $LinkExe -ClExe $ClExe
    }
    # Native ARM64-Tools (ffmpeg.exe/ffprobe.exe) mitliefern.
    $exes = Copy-Arm64Executables -Arm64Dir $Arm64Dir -OutputDir $OutputDir
    Write-Host "ARM64X-Forwarder: $($exes.Count) ARM64-Ausfuehrbare uebernommen."
    Write-Host "ARM64X-Forwarder abgeschlossen: $OutputDir"
    return $plan
}

# ---------------------------------------------------------------------------
# Einstiegspunkt
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Arm64xForwarder -Arm64Dir $Arm64Dir -Arm64ecDir $Arm64ecDir `
        -Arm64LibDir $Arm64LibDir -Arm64ecLibDir $Arm64ecLibDir `
        -OutputDir $OutputDir -LinkExe $LinkExe -ClExe $ClExe -DryRun:$DryRun
}