<#
.SYNOPSIS
    Verschmilzt die arm64- und die arm64ec-Ansicht einer Build-Ausgabe zu
    ARM64X-Hybrid-Artefakten (DLL via `link.exe /MACHINE:ARM64X`, Import-Lib via
    `lib.exe /MACHINE:ARM64X`).

.DESCRIPTION
    Dritter Schritt des ARM64X-Herstellungsmusters (Design: Architecture ->
    "ARM64X-Merge je Bibliothek" und die 3-Schritt-Beschreibung). Nachdem
    `build-ffmpeg.ps1`/`build-deps.ps1` je eine vollständige ARM64- UND eine
    vollständige ARM64EC-Ansicht erzeugt haben, verschmilzt dieses Skript die
    korrespondierenden Artefakte paarweise zu einem einzigen ARM64X-Hybrid:

      - DLLs : `link.exe /MACHINE:ARM64X <arm64.dll-Beitrag> <arm64ec.dll-Beitrag>`
               verschmilzt die beiden Ansichten zu einer Hybrid-DLL.
      - .lib : `lib.exe  /MACHINE:ARM64X <arm64.lib> <arm64ec.lib>`
               verschmilzt die beiden Import-Bibliotheken zu einer
               ARM64X-Import-Lib.

    Das Skript arbeitet je Ausgabe: es paart JEDE DLL der arm64-Ansicht mit der
    gleichnamigen DLL der arm64ec-Ansicht und JEDE .lib der arm64-Ansicht mit der
    gleichnamigen .lib der arm64ec-Ansicht. Damit ist es sowohl je Variante
    (GPL/LGPL, jeweils über beide Architektur-Ansichten) als auch je externer
    Bibliothek (x264/x265) anwendbar — der Aufrufer richtet einfach
    -Arm64Dir und -Arm64ecDir auf die jeweiligen Ausgabeverzeichnisse.

    Lokale Testbarkeit: Die echten MSVC-Werkzeuge (`link.exe`, `lib.exe`)
    existieren nur auf dem CI-Runner. Die reine Kommando-Zusammensetzung
    (Paarung + Argumentlisten) ist in Get-Arm64xMergePlan gekapselt und ohne
    Toolchain überprüfbar. Zusätzlich:

      -DryRun  : gibt für jedes gemergte Artefakt die exakte
                 link.exe/lib.exe-Befehlszeile aus, OHNE einen Prozess zu
                 starten; gibt das Plan-Objekt zur Inspektion zurück.

    Fail-fast: `$ErrorActionPreference = 'Stop'`; jeder von Null verschiedene
    Exit-Code eines Merge-Aufrufs bricht das Skript ab.

.PARAMETER Arm64Dir
    Verzeichnis mit der ARM64-Ansicht der Ausgabe (enthält *.dll und *.lib der
    arm64-Kompilierung).

.PARAMETER Arm64ecDir
    Verzeichnis mit der ARM64EC-Ansicht der Ausgabe (enthält die gleichnamigen
    *.dll und *.lib der arm64ec-Kompilierung).

.PARAMETER OutputDir
    Zielverzeichnis für die ARM64X-Hybrid-Artefakte. Je gemergter DLL/.lib
    entsteht hier eine gleichnamige Ausgabedatei.

.PARAMETER LinkExe
    Pfad zu `link.exe` (MSVC-Linker). Parametrisiert, damit die
    Kommando-Zusammensetzung lokal ohne echte Toolchain überprüfbar ist.
    Standard: 'link.exe' (aus dem PATH der vcvars-Umgebung).

.PARAMETER LibExe
    Pfad zu `lib.exe` (MSVC-Bibliothekar). Parametrisiert wie -LinkExe.
    Standard: 'lib.exe'.

.PARAMETER DryRun
    Wenn gesetzt, wird nichts ausgeführt. Für jedes zu mergende Artefakt wird die
    exakte `link.exe`/`lib.exe`-Befehlszeile ausgegeben und das Plan-Objekt
    zurückgegeben. Dient der lokalen Verifikation der Kommando-Zusammensetzung.

.OUTPUTS
    [pscustomobject] mit:
      Arm64Dir, Arm64ecDir, OutputDir, LinkExe, LibExe,
      DllMerges  ([pscustomobject[]] je DLL: Name, Arm64, Arm64ec, Output, Tool, Arguments, CommandLine),
      LibMerges  ([pscustomobject[]] je .lib entsprechend),
      DryRun.

.EXAMPLE
    ./scripts/merge-arm64x.ps1 -Arm64Dir C:\out\gpl\arm64\bin -Arm64ecDir C:\out\gpl\arm64ec\bin -OutputDir C:\out\gpl\arm64x\bin

.EXAMPLE
    # Lokaler Trockenlauf: zeigt die /MACHINE:ARM64X-Aufrufe, ohne zu bauen.
    ./scripts/merge-arm64x.ps1 -Arm64Dir .\a64 -Arm64ecDir .\a64ec -OutputDir .\a64x -DryRun

.NOTES
    Feature: arm64x-ffmpeg-build
    Task: 9.1
    Requirements: 2.3, 3.2
    Design: Architecture -> "ARM64X-Merge je Bibliothek" (link.exe/lib.exe
            /MACHINE:ARM64X), 3-Schritt-Ansatz Schritt 3; Components -> C2
            Build-Skripte (scripts/merge-arm64x.ps1).
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Arm64Dir,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Arm64ecDir,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDir,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $LinkExe = 'link.exe',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $LibExe = 'lib.exe',

    [Parameter()]
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Reine Logik (ohne Toolchain / Seiteneffekte, lokal testbar)
# ---------------------------------------------------------------------------

function Format-CommandLine {
    <#
    .SYNOPSIS
        Setzt eine anzeigbare, korrekt gequotete Befehlszeile aus Programm +
        Argumenten zusammen (reine String-Transformation).
    .DESCRIPTION
        Argumente mit Leerzeichen werden in doppelte Anführungszeichen gesetzt,
        damit die ausgegebene Zeile exakt dem entspricht, was ausgeführt würde.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Arguments
    )

    $quote = {
        param($token)
        if ($token -match '\s') { return '"' + $token + '"' }
        return $token
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((& $quote $FilePath))
    foreach ($a in $Arguments) { $parts.Add((& $quote $a)) }
    return ($parts -join ' ')
}

function Get-MergePairsByExtension {
    <#
    .SYNOPSIS
        Paart Dateien einer Erweiterung zwischen der arm64- und der
        arm64ec-Ansicht anhand des Basisnamens (reine Logik).
    .DESCRIPTION
        Für jede Datei mit der angegebenen Erweiterung in -Arm64Dir wird die
        gleichnamige Datei in -Arm64ecDir gesucht. Fehlt das Gegenstück, wird ein
        terminierender Fehler ausgelöst, der die betroffene Datei und die
        fehlende Ansicht benennt (Fail-fast; ein ARM64X-Hybrid setzt beide
        Ansichten voraus).

        Die Dateiaufzählung erfolgt über den injizierbaren -FileLister, damit die
        Paarungslogik ohne echtes Dateisystem testbar bleibt. Standard ist eine
        Get-ChildItem-basierte Aufzählung der Basisnamen.
    .OUTPUTS
        [pscustomobject[]] je Paar: BaseName, Arm64 (Pfad), Arm64ec (Pfad).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string] $Arm64Dir,
        [Parameter(Mandatory)][string] $Arm64ecDir,
        [Parameter(Mandatory)][string] $Extension,
        [Parameter(Mandatory)][scriptblock] $FileLister
    )

    # Basisnamen (ohne Verzeichnis) je Ansicht auflisten.
    $arm64Names = @(& $FileLister $Arm64Dir $Extension)
    $arm64ecNames = @(& $FileLister $Arm64ecDir $Extension)

    # Für schnelle, case-insensitive Gegenstück-Suche.
    $ecSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]] $arm64ecNames, [System.StringComparer]::OrdinalIgnoreCase)

    $pairs = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($name in ($arm64Names | Sort-Object)) {
        if (-not $ecSet.Contains($name)) {
            throw "ARM64X-Merge nicht moeglich fuer '$name$Extension': " +
                  "die ARM64EC-Ansicht fehlt in '$Arm64ecDir'. Ein ARM64X-Hybrid " +
                  "setzt sowohl die ARM64- als auch die ARM64EC-Ansicht voraus."
        }
        $pairs.Add([pscustomobject]@{
            BaseName = $name
            Arm64    = (Join-Path $Arm64Dir   ($name + $Extension))
            Arm64ec  = (Join-Path $Arm64ecDir ($name + $Extension))
        })
    }

    return , ([pscustomobject[]] $pairs.ToArray())
}

function Get-Arm64xMergePlan {
    <#
    .SYNOPSIS
        Setzt die vollständige ARM64X-Merge-Kommandozusammenstellung zusammen
        (reine Logik, ohne Toolchain-Aufruf).
    .DESCRIPTION
        Baut je DLL-Paar die `link.exe /MACHINE:ARM64X ...`-Argumentliste und je
        .lib-Paar die `lib.exe /MACHINE:ARM64X ...`-Argumentliste. Der arm64- und
        der arm64ec-Beitrag werden als Eingaben, das Zielartefakt als
        `/OUT:<OutputDir>\<Basisname><ext>` angegeben. Vollständig
        seiteneffektfrei, damit sie lokal (auch im -DryRun) überprüfbar ist.
    .OUTPUTS
        [pscustomobject] mit DllMerges und LibMerges (siehe Skript-OUTPUTS).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Arm64Dir,
        [Parameter(Mandatory)][string] $Arm64ecDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $LinkExe,
        [Parameter(Mandatory)][string] $LibExe,
        [Parameter(Mandatory)][scriptblock] $FileLister
    )

    # --- DLL-Paare: link.exe /MACHINE:ARM64X --------------------------------
    $dllPairs = Get-MergePairsByExtension -Arm64Dir $Arm64Dir -Arm64ecDir $Arm64ecDir `
        -Extension '.dll' -FileLister $FileLister

    $dllMerges = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($p in $dllPairs) {
        $outPath = Join-Path $OutputDir ($p.BaseName + '.dll')
        $args = [string[]] @(
            '/MACHINE:ARM64X'
            '/DLL'
            "/OUT:$outPath"
            $p.Arm64
            $p.Arm64ec
        )
        $dllMerges.Add([pscustomobject]@{
            Name        = $p.BaseName + '.dll'
            Arm64       = $p.Arm64
            Arm64ec     = $p.Arm64ec
            Output      = $outPath
            Tool        = $LinkExe
            Arguments   = $args
            CommandLine = (Format-CommandLine -FilePath $LinkExe -Arguments $args)
        })
    }

    # --- .lib-Paare: lib.exe /MACHINE:ARM64X --------------------------------
    $libPairs = Get-MergePairsByExtension -Arm64Dir $Arm64Dir -Arm64ecDir $Arm64ecDir `
        -Extension '.lib' -FileLister $FileLister

    $libMerges = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($p in $libPairs) {
        $outPath = Join-Path $OutputDir ($p.BaseName + '.lib')
        $args = [string[]] @(
            '/MACHINE:ARM64X'
            "/OUT:$outPath"
            $p.Arm64
            $p.Arm64ec
        )
        $libMerges.Add([pscustomobject]@{
            Name        = $p.BaseName + '.lib'
            Arm64       = $p.Arm64
            Arm64ec     = $p.Arm64ec
            Output      = $outPath
            Tool        = $LibExe
            Arguments   = $args
            CommandLine = (Format-CommandLine -FilePath $LibExe -Arguments $args)
        })
    }

    return [pscustomobject]@{
        Arm64Dir   = $Arm64Dir
        Arm64ecDir = $Arm64ecDir
        OutputDir  = $OutputDir
        LinkExe    = $LinkExe
        LibExe     = $LibExe
        DllMerges  = [pscustomobject[]] $dllMerges.ToArray()
        LibMerges  = [pscustomobject[]] $libMerges.ToArray()
    }
}

# Standard-Dateiaufzählung (echtes Dateisystem). Liefert die Basisnamen (ohne
# Verzeichnis, ohne Erweiterung) aller Dateien mit der Erweiterung im Verzeichnis.
$script:DefaultFileLister = {
    param([string] $Dir, [string] $Ext)
    if (-not (Test-Path -LiteralPath $Dir)) {
        throw "Verzeichnis nicht gefunden: '$Dir'."
    }
    Get-ChildItem -LiteralPath $Dir -Filter ("*" + $Ext) -File |
        ForEach-Object { $_.BaseName }
}

# ---------------------------------------------------------------------------
# Ausführung eines einzelnen Merge-Aufrufs (echte Toolchain, nur auf CI)
# ---------------------------------------------------------------------------

function Invoke-Merge {
    <#
    .SYNOPSIS
        Führt einen einzelnen link.exe/lib.exe-Merge aus (Fail-fast).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Merge)

    Write-Host "  merge -> $($Merge.Name)"
    Write-Verbose $Merge.CommandLine
    & $Merge.Tool @($Merge.Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "ARM64X-Merge fehlgeschlagen fuer '$($Merge.Name)': " +
              "'$($Merge.Tool)' Exit-Code $LASTEXITCODE. Befehl: $($Merge.CommandLine)"
    }
    if (-not (Test-Path -LiteralPath $Merge.Output)) {
        throw "ARM64X-Merge lieferte keine Ausgabedatei: '$($Merge.Output)'."
    }
}

# ---------------------------------------------------------------------------
# Orchestrierung
# ---------------------------------------------------------------------------

function Invoke-Arm64xMerge {
    <#
    .SYNOPSIS
        Erstellt den Merge-Plan und führt ihn (außerhalb von -DryRun) aus.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Arm64Dir,
        [Parameter(Mandatory)][string] $Arm64ecDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][string] $LinkExe,
        [Parameter(Mandatory)][string] $LibExe,
        [switch] $DryRun,
        [scriptblock] $FileLister
    )

    $lister = if ($FileLister) { $FileLister } else { $script:DefaultFileLister }

    $plan = Get-Arm64xMergePlan -Arm64Dir $Arm64Dir -Arm64ecDir $Arm64ecDir `
        -OutputDir $OutputDir -LinkExe $LinkExe -LibExe $LibExe -FileLister $lister

    $allMerges = @($plan.DllMerges) + @($plan.LibMerges)

    if ($DryRun) {
        Write-Host "== DRY RUN: ARM64X-Merge =="
        Write-Host "ARM64   : $Arm64Dir"
        Write-Host "ARM64EC : $Arm64ecDir"
        Write-Host "Output  : $OutputDir"
        Write-Host "link.exe: $LinkExe"
        Write-Host "lib.exe : $LibExe"
        Write-Host "-- DLL-Merges (link.exe /MACHINE:ARM64X): $($plan.DllMerges.Count) --"
        foreach ($m in $plan.DllMerges) { Write-Host "  $($m.CommandLine)" }
        Write-Host "-- .lib-Merges (lib.exe /MACHINE:ARM64X): $($plan.LibMerges.Count) --"
        foreach ($m in $plan.LibMerges) { Write-Host "  $($m.CommandLine)" }
    }
    else {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        Write-Host "ARM64X-Merge: $($plan.DllMerges.Count) DLL(s), $($plan.LibMerges.Count) .lib -> $OutputDir"
        foreach ($m in $allMerges) { Invoke-Merge -Merge $m }
        Write-Host "ARM64X-Merge abgeschlossen: $OutputDir"
    }

    return ([pscustomobject]@{
        Arm64Dir   = $plan.Arm64Dir
        Arm64ecDir = $plan.Arm64ecDir
        OutputDir  = $plan.OutputDir
        LinkExe    = $plan.LinkExe
        LibExe     = $plan.LibExe
        DllMerges  = $plan.DllMerges
        LibMerges  = $plan.LibMerges
        DryRun     = [bool] $DryRun
    })
}

# ---------------------------------------------------------------------------
# Einstiegspunkt: nur ausführen, wenn das Skript direkt aufgerufen wird
# (nicht beim Dot-Sourcing durch Tests).
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $summary = Invoke-Arm64xMerge -Arm64Dir $Arm64Dir -Arm64ecDir $Arm64ecDir `
        -OutputDir $OutputDir -LinkExe $LinkExe -LibExe $LibExe -DryRun:$DryRun

    $summary
}
