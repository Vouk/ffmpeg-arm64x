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
      * ARM64-Prozess        -> <name>.arm64.dll
      * x64/ARM64EC-Prozess  -> <name>.arm64ec.dll
    (Quelle: learn.microsoft.com "Build Arm64X Files" -> Pure Forwarder.)

    Ablauf je Bibliothek (avcodec, avformat, ...):
      1. Die echten DLLs der beiden Ansichten werden unter neuen Namen
         (<base>.arm64.dll / <base>.arm64ec.dll) ins Ausgabeverzeichnis kopiert.
      2. Aus den von FFmpeg erzeugten .def-Dateien beider Ansichten werden
         Forwarder-.defs gebaut: jede Zeile "Sym" wird zu
         "Sym=<base>.arm64.Sym" bzw. "Sym=<base>.arm64ec.Sym".
      3. Zwei leere OBJs werden erzeugt (arm64 + arm64ec).
      4. Der Forwarder <base>.dll wird mit /MACHINE:ARM64X gelinkt.

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
        Erweiterung (z. B. "avcodec-62.arm64"). Kommentare (;), leere Zeilen und
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

        $realArm64Name   = "$base.arm64.dll"
        $realArm64ecName = "$base.arm64ec.dll"
        $fwds.Add([pscustomobject]@{
            BaseName        = $base
            # Eingaben
            SrcArm64Dll     = Join-Path $Arm64Dir   "$base.dll"
            SrcArm64ecDll   = Join-Path $Arm64ecDir "$base.dll"
            SrcArm64Def     = Join-Path $Arm64LibDir   "$base.def"
            SrcArm64ecDef   = Join-Path $Arm64ecLibDir "$base.def"
            SrcArm64Lib     = Join-Path $Arm64LibDir   "$base.lib"
            SrcArm64ecLib   = Join-Path $Arm64ecLibDir "$base.lib"
            # Ausgaben
            RealArm64Dll    = Join-Path $OutputDir $realArm64Name
            RealArm64ecDll  = Join-Path $OutputDir $realArm64ecName
            ForwarderDll    = Join-Path $OutputDir "$base.dll"
            FwdArm64Def     = Join-Path $OutputDir "$base.arm64.fwd.def"
            FwdArm64ecDef   = Join-Path $OutputDir "$base.arm64ec.fwd.def"
            ForwardToArm64  = "$base.arm64"
            ForwardToArm64ec= "$base.arm64ec"
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
        $Fwd.SrcArm64Lib
        $Fwd.SrcArm64ecLib
    )
}

$script:DefaultDllLister = {
    param([string] $Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { throw "Verzeichnis nicht gefunden: '$Dir'." }
    Get-ChildItem -LiteralPath $Dir -Filter '*.dll' -File |
        Where-Object { $_.Name -notmatch '\.arm64(ec)?\.dll$' } |
        ForEach-Object { $_.BaseName }
}

# ---------------------------------------------------------------------------
# Ausfuehrung (echte Toolchain, nur auf CI)
# ---------------------------------------------------------------------------

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

    Write-Host "  forwarder -> $($Fwd.BaseName).dll (-> .arm64.dll / .arm64ec.dll)"

    foreach ($pair in @(
        @{ Src = $Fwd.SrcArm64Dll;   Dst = $Fwd.RealArm64Dll },
        @{ Src = $Fwd.SrcArm64ecDll; Dst = $Fwd.RealArm64ecDll },
        @{ Src = $Fwd.SrcArm64Def;   Dst = $null },
        @{ Src = $Fwd.SrcArm64ecDef; Dst = $null },
        @{ Src = $Fwd.SrcArm64Lib;   Dst = $null },
        @{ Src = $Fwd.SrcArm64ecLib; Dst = $null }
    )) {
        if (-not (Test-Path -LiteralPath $pair.Src)) {
            throw "ARM64X-Forwarder '$($Fwd.BaseName)': Eingabe fehlt: '$($pair.Src)'."
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

    # 3) leere OBJs
    New-EmptyObject -ClExe $ClExe -OutObj $Fwd.EmptyArm64Obj
    New-EmptyObject -ClExe $ClExe -OutObj $Fwd.EmptyArm64ecObj -Ec

    # 4) Forwarder linken
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
                       $Fwd.FwdArm64Def, $Fwd.FwdArm64ecDef)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
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