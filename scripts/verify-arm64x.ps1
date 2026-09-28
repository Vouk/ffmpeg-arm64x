<#
.SYNOPSIS
    Verifiziert, dass alle erzeugten FFmpeg-DLLs sowie `ffmpeg.exe`/`ffprobe.exe`
    echte ARM64X-Hybrid-Binärdateien sind (ARM64- UND ARM64EC-Ansicht) und dass
    zu jeder DLL eine gleichnamige `.lib`-Import-Bibliothek existiert.

.DESCRIPTION
    Dieses Skript setzt Task 9.2 um (Design: Testing Strategy ->
    "ARM64X-Dual-View-Verifikation", Schnittstelle -> "Verifikation der
    ARM64X-Ansicht", Components -> C2 scripts/verify-arm64x.ps1). Nach dem
    ARM64X-Merge (merge-arm64x.ps1) läuft es über ALLE erzeugten FFmpeg-DLLs
    sowie `ffmpeg.exe`/`ffprobe.exe` und prüft je Datei per `dumpbin /headers`
    den Marker `(ARM64X)` an der Maschinenzeile des PE-Headers:

      - Ein ARM64X-Hybrid zeigt `AA64 machine (ARM64) (ARM64X)`.
      - Ein reines ARM64-Image zeigt nur `... machine (ARM64)` (ohne `(ARM64X)`).
      - Ein reines ARM64EC-Image zeigt `... machine (ARM64EC)`.

    Der Gate matcht EXAKT `(ARM64X)`, verankert an der Header-Maschinenzeile —
    nicht am Dateipfad —, sodass eine falsche ABI (reines ARM64 oder ARM64EC)
    zuverlässig abgelehnt wird (R2.4/R2.5). Fehlt der Marker bei einer Datei,
    bricht das Skript fail-fast ab und benennt die betroffene Datei sowie die
    fehlende Ansicht.

    Zusätzlich prüft das Skript über `Test-DllLibPairing` (aus
    scripts/lib/ArtifactCheck.psm1), dass zu jeder erzeugten DLL genau eine
    gleichnamige `.lib`-Import-Bibliothek vorliegt (R3.3).

    Testbarkeit: Das echte `dumpbin.exe` existiert nur auf dem CI-Runner. Damit
    der Ausgabe-Parser lokal ohne echte Toolchain geprüft werden kann, ist die
    reine ABI-Erkennung vollständig in die seiteneffektfreie Funktion
    `Get-DumpbinMachineAbi` (bzw. das Gate `Test-Arm64xHeader`) gekapselt. Diese
    nimmt die erfasste `dumpbin /headers`-Ausgabe entgegen und liefert die ABI
    (ARM64 / ARM64EC / ARM64X / Unknown) allein anhand der Maschinenzeile. Der
    Skript-Rumpf erfasst auf CI die echte dumpbin-Ausgabe und reicht sie hinein.

.PARAMETER BinDir
    Verzeichnis mit den erzeugten ARM64X-Artefakten (die gemergten *.dll, *.lib
    sowie `ffmpeg.exe`/`ffprobe.exe`). Auf CI erforderlich.

.PARAMETER DumpbinExe
    Pfad zu `dumpbin.exe` (MSVC). Parametrisiert, damit der Aufruf lokal ohne
    echte Toolchain umgeleitet werden kann. Standard: 'dumpbin.exe' (aus dem
    PATH der vcvars-Umgebung).

.PARAMETER SkipLibPairing
    Wenn gesetzt, wird die `.lib`-Paarungsprüfung (Test-DllLibPairing)
    übersprungen. Standardmäßig aktiv.

.OUTPUTS
    [pscustomobject] mit dem Verifikationsergebnis (Success, geprüfte Dateien je
    ABI, benannte Verstöße, .lib-Paarungsergebnis). Bei einer Abweichung wird
    zusätzlich ein terminierender Fehler ausgelöst (fail-fast).

.EXAMPLE
    ./scripts/verify-arm64x.ps1 -BinDir C:\out\gpl\arm64x\bin

.EXAMPLE
    # Nur ARM64X-Ansicht prüfen, .lib-Paarung überspringen.
    ./scripts/verify-arm64x.ps1 -BinDir .\a64x -SkipLibPairing

.NOTES
    Feature: arm64x-ffmpeg-build
    Task: 9.2
    Requirements: 2.4, 2.5, 3.3
    Design: Testing Strategy -> "ARM64X-Dual-View-Verifikation (Integration)";
            Components -> "Schnittstelle: Verifikation der ARM64X-Ansicht"
            (dumpbin /headers, Marker `(ARM64X)` an der Maschinenzeile),
            C2 (scripts/verify-arm64x.ps1); Error Handling -> "Binärdatei nicht
            ARM64X" (R2.5). Nutzt Test-DllLibPairing aus ArtifactCheck.psm1 (R3.3).
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $BinDir,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $DumpbinExe = 'dumpbin.exe',

    [Parameter()]
    [switch] $SkipLibPairing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Reine Parsing-/Assertion-Logik (lokal testbar, ohne echtes dumpbin.exe)
# ---------------------------------------------------------------------------

function Get-DumpbinMachineAbi {
    <#
    .SYNOPSIS
        Bestimmt die ABI (ARM64 / ARM64EC / ARM64X / Unknown) einer erfassten
        `dumpbin /headers`-Ausgabe allein anhand der Maschinenzeile (reine Logik).
    .DESCRIPTION
        `dumpbin /headers` gibt im FILE HEADER eine Maschinenzeile aus, z. B.:

            FILE HEADER VALUES
                        AA64 machine (ARM64)
            ... oder ...
                        AA64 machine (ARM64) (ARM64X)
            ... oder ...
                        A641 machine (ARM64EC)

        Die Erkennung ist AUSSCHLIESSLICH an dieser Maschinenzeile verankert,
        nicht am Dateipfad oder an anderem Text (ein Pfad wie
        C:\arm64x\avcodec.dll darf die Erkennung nicht beeinflussen). Es gilt:

          * ARM64X : die Maschinenzeile enthält den Marker `(ARM64X)`.
                     (Der Maschinenwert selbst bleibt `(ARM64)`; dumpbin hängt
                      für den Hybrid zusätzlich `(ARM64X)` an.)
          * ARM64EC: die Maschinenzeile enthält `(ARM64EC)` (ohne `(ARM64X)`).
          * ARM64  : die Maschinenzeile enthält `(ARM64)` (ohne `(ARM64X)` und
                     ohne `(ARM64EC)`).
          * Unknown: keine erkennbare ARM64/ARM64EC/ARM64X-Maschinenzeile.

        Die Prüfung auf `(ARM64X)` hat Vorrang, weil die ARM64X-Zeile den
        `(ARM64)`-Text ebenfalls enthält.

        Seiteneffektfrei: kein Datei-/dumpbin-Zugriff.
    .PARAMETER HeaderText
        Die erfasste, mehrzeilige `dumpbin /headers`-Ausgabe.
    .OUTPUTS
        [string] — 'ARM64', 'ARM64EC', 'ARM64X' oder 'Unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $HeaderText
    )

    if ([string]::IsNullOrWhiteSpace($HeaderText)) {
        return 'Unknown'
    }

    # Zeilenweise, unabhängig vom Zeilenende-Stil. Nur die Maschinenzeile(n)
    # betrachten: "<hex> machine (<ABI>)[ (ARM64X)]". Damit ist die Erkennung an
    # der Header-Maschinenzeile verankert, nicht am Dateipfad.
    $lines = $HeaderText -split "`r?`n"

    foreach ($rawLine in $lines) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Maschinenzeile: ein Hex-Token, das Wort "machine" und mindestens ein
        # geklammertes ABI-Kürzel.
        if ($line -notmatch '(?i)^[0-9A-F]+\s+machine\b') { continue }

        # Vorrang: ARM64X-Hybrid (die Zeile enthält zusätzlich `(ARM64X)`).
        if ($line -match '(?i)\(ARM64X\)') {
            return 'ARM64X'
        }
        if ($line -match '(?i)\(ARM64EC\)') {
            return 'ARM64EC'
        }
        if ($line -match '(?i)\(ARM64\)') {
            return 'ARM64'
        }
    }

    return 'Unknown'
}

function Test-Arm64xHeader {
    <#
    .SYNOPSIS
        Gate: meldet genau dann Erfolg, wenn die erfasste `dumpbin /headers`-
        Ausgabe eine ARM64X-Hybrid-Maschinenzeile zeigt (reine Logik, R2.4).
    .DESCRIPTION
        Dünner Wrapper um Get-DumpbinMachineAbi. Der Gate matcht EXAKT `(ARM64X)`
        an der Maschinenzeile: reines ARM64 und reines ARM64EC werden abgelehnt.
        Liefert ein Ergebnisobjekt mit der erkannten ABI und einer
        menschenlesbaren Meldung, damit der Aufrufer bei fehlender ARM64X-Ansicht
        fail-fast mit klarer Nennung der fehlenden Ansicht abbrechen kann (R2.5).
    .PARAMETER HeaderText
        Die erfasste `dumpbin /headers`-Ausgabe.
    .PARAMETER FileName
        Optionaler Name der geprüften Datei (nur für die Meldung, R2.5).
    .OUTPUTS
        PSCustomObject mit:
          IsArm64x [bool]   — $true gdw ABI == 'ARM64X'
          Abi      [string] — erkannte ABI (ARM64/ARM64EC/ARM64X/Unknown)
          File     [string] — geprüfte Datei (falls angegeben)
          Message  [string] — menschenlesbare Zusammenfassung; bei Fehler wird
                              die fehlende Ansicht benannt
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $HeaderText,

        [Parameter()]
        [string] $FileName = ''
    )

    $abi = Get-DumpbinMachineAbi -HeaderText $HeaderText
    $isArm64x = ($abi -eq 'ARM64X')
    $label = if ([string]::IsNullOrWhiteSpace($FileName)) { 'Binärdatei' } else { "'$FileName'" }

    if ($isArm64x) {
        $message = "$label ist ein ARM64X-Hybrid (enthält ARM64- und ARM64EC-Ansicht)."
    }
    else {
        # R2.5: fehlende Ansicht konkret benennen. Ein ARM64X-Hybrid benötigt
        # beide Ansichten; welche fehlt, ergibt sich aus der erkannten ABI.
        $missing = switch ($abi) {
            'ARM64'   { 'ARM64EC-Ansicht' }              # nur ARM64 vorhanden
            'ARM64EC' { 'ARM64-Ansicht' }                # nur ARM64EC vorhanden
            default   { 'ARM64- und ARM64EC-Ansicht' }   # Unknown: keine Hybrid-Zeile
        }
        $message = "$label ist kein ARM64X-Hybrid (erkannte ABI: $abi); " +
                   "es fehlt die $missing. Der ARM64X-Marker '(ARM64X)' " +
                   "an der Maschinenzeile ist nicht vorhanden."
    }

    return [pscustomobject]@{
        IsArm64x = $isArm64x
        Abi      = $abi
        File     = $FileName
        Message  = $message
    }
}

# ---------------------------------------------------------------------------
# Toolchain-Aufruf (echtes dumpbin, nur auf CI) + Datei-Enumeration
# ---------------------------------------------------------------------------

function Invoke-DumpbinHeaders {
    <#
    .SYNOPSIS
        Ruft `dumpbin /headers <Datei>` auf und liefert die erfasste Ausgabe
        (nur auf dem CI-Runner; nicht Teil der reinen Logik).
    .DESCRIPTION
        Erfasst stdout und stderr als vereinten Text, damit die Parser-Logik
        robust bleibt. Ein von Null verschiedener Exit-Code bricht fail-fast ab.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $DumpbinExe,
        [Parameter(Mandatory)] [string] $FilePath
    )

    $output = & $DumpbinExe '/headers' $FilePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Aufruf von '$DumpbinExe /headers $FilePath' schlug fehl (Exit $LASTEXITCODE)."
    }
    return ($output | Out-String)
}

# Zu prüfende Ausführbaren neben allen erzeugten DLLs.
$script:ExpectedExecutables = @('ffmpeg.exe', 'ffprobe.exe')

function Get-Arm64xTargetFiles {
    <#
    .SYNOPSIS
        Ermittelt die zu verifizierenden Dateien in -BinDir: alle *.dll sowie
        `ffmpeg.exe`/`ffprobe.exe` (reine Logik über einen injizierbaren Lister).
    .DESCRIPTION
        Die Datei-Aufzählung erfolgt über den injizierbaren -FileLister, damit
        die Auswahl-Logik ohne echtes Dateisystem testbar bleibt. Fehlt eine der
        erwarteten Ausführbaren (ffmpeg.exe/ffprobe.exe), wird fail-fast mit
        Benennung der Datei abgebrochen.
    .OUTPUTS
        [string[]] — vollständige Pfade der zu prüfenden Dateien.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $BinDir,
        [Parameter(Mandatory)] [scriptblock] $FileLister
    )

    # Der Lister liefert die Leaf-Dateinamen (mit Endung) im Verzeichnis.
    $names = @(& $FileLister $BinDir)

    $nameSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$names, [System.StringComparer]::OrdinalIgnoreCase)

    $targets = [System.Collections.Generic.List[string]]::new()

    # Alle DLLs.
    foreach ($n in $names) {
        if ($n -match '(?i)\.dll$') {
            $targets.Add((Join-Path $BinDir $n))
        }
    }

    # Erwartete Ausführbaren; fehlt eine, fail-fast mit Benennung.
    foreach ($exe in $script:ExpectedExecutables) {
        if (-not $nameSet.Contains($exe)) {
            throw "ARM64X-Verifikation: erwartete Ausführbare '$exe' fehlt in '$BinDir'."
        }
        $targets.Add((Join-Path $BinDir $exe))
    }

    return , ([string[]]$targets.ToArray())
}

# Standard-Dateiaufzählung (echtes Dateisystem): liefert die Leaf-Namen aller
# Dateien im Verzeichnis.
$script:DefaultFileLister = {
    param([string] $Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        throw "Verzeichnis nicht gefunden: '$Dir'."
    }
    Get-ChildItem -LiteralPath $Dir -File | ForEach-Object { $_.Name }
}

# ---------------------------------------------------------------------------
# Orchestrierung
# ---------------------------------------------------------------------------

function Invoke-Arm64xVerification {
    <#
    .SYNOPSIS
        Verifiziert alle Zieldateien als ARM64X-Hybrid und prüft die
        DLL/`.lib`-Paarung (Task 9.2, R2.4/R2.5/R3.3).
    .DESCRIPTION
        Läuft über alle erzeugten DLLs sowie ffmpeg.exe/ffprobe.exe, erfasst je
        Datei die `dumpbin /headers`-Ausgabe (über den injizierbaren
        -HeaderProvider) und wertet sie über die reine Logik Test-Arm64xHeader
        aus. Bei fehlendem ARM64X-Marker wird die Datei und die fehlende Ansicht
        gesammelt. Zusätzlich wird — sofern nicht -SkipLibPairing — die
        DLL/`.lib`-Paarung über Test-DllLibPairing geprüft (R3.3).

        Fail-fast: schlägt mindestens eine Datei durch (oder fehlt eine .lib),
        löst der Aufrufer einen terminierenden Fehler aus.
    .PARAMETER HeaderProvider
        Scriptblock, der zu einem Dateipfad die erfasste dumpbin-Ausgabe liefert.
        Auf CI die echte dumpbin-Anbindung; in Tests ein reiner Stub.
    .PARAMETER FileLister
        Optionaler Datei-Lister (Standard: echtes Dateisystem).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $BinDir,
        [Parameter(Mandatory)] [scriptblock] $HeaderProvider,
        [switch] $SkipLibPairing,
        [scriptblock] $FileLister
    )

    $lister = if ($FileLister) { $FileLister } else { $script:DefaultFileLister }

    $targets = Get-Arm64xTargetFiles -BinDir $BinDir -FileLister $lister

    $checked = [System.Collections.Generic.List[pscustomobject]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $targets) {
        $leaf = Split-Path -Path $file -Leaf
        $headerText = & $HeaderProvider $file
        $gate = Test-Arm64xHeader -HeaderText $headerText -FileName $leaf

        $checked.Add([pscustomobject]@{
            File     = $leaf
            Path     = $file
            Abi      = $gate.Abi
            IsArm64x = $gate.IsArm64x
        })

        if (-not $gate.IsArm64x) {
            # R2.5: betroffene Datei + fehlende Ansicht benennen.
            $failures.Add($gate.Message)
        }
    }

    # --- DLL/`.lib`-Paarung (R3.3) über Test-DllLibPairing -------------------
    $pairing = $null
    if (-not $SkipLibPairing) {
        $allNames = @(& $lister $BinDir)
        $dllNames = @($allNames | Where-Object { $_ -match '(?i)\.dll$' })
        $libNames = @($allNames | Where-Object { $_ -match '(?i)\.lib$' })

        $pairing = Test-DllLibPairing -DllName $dllNames -LibName $libNames
        if (-not $pairing.Success) {
            $failures.Add($pairing.Message)
        }
    }

    $success = ($failures.Count -eq 0)
    if ($success) {
        $message = "ARM64X-Verifikation bestanden: $($checked.Count) Datei(en) " +
                   "sind ARM64X-Hybride" +
                   $(if (-not $SkipLibPairing) { " und alle DLLs besitzen eine gleichnamige .lib." } else { "." })
    }
    else {
        $message = "ARM64X-Verifikation fehlgeschlagen: " + ($failures -join ' ')
    }

    return [pscustomobject]@{
        Success  = $success
        BinDir   = $BinDir
        Checked  = [pscustomobject[]]$checked.ToArray()
        Failures = [string[]]$failures.ToArray()
        Pairing  = $pairing
        Message  = $message
    }
}

# ---------------------------------------------------------------------------
# Modul-Abhängigkeit: Test-DllLibPairing aus ArtifactCheck.psm1 (R3.3).
# Beim Dot-Sourcing durch Tests wird das Modul ebenfalls verfügbar gemacht.
# ---------------------------------------------------------------------------

if (-not (Get-Command -Name 'Test-DllLibPairing' -ErrorAction SilentlyContinue)) {
    $script:ArtifactCheckModule = Join-Path $PSScriptRoot 'lib\ArtifactCheck.psm1'
    if (Test-Path -LiteralPath $script:ArtifactCheckModule) {
        Import-Module -Name $script:ArtifactCheckModule -Force
    }
}

# ---------------------------------------------------------------------------
# Einstiegspunkt: nur ausführen, wenn direkt aufgerufen (nicht beim Dot-Sourcing
# durch Tests, die nur die reine Logik prüfen wollen).
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-Path -LiteralPath $BinDir)) {
        throw "ARM64X-Ausgabeverzeichnis nicht gefunden: '$BinDir'."
    }

    # Echte dumpbin-Anbindung: erfasst je Datei die /headers-Ausgabe.
    $headerProvider = {
        param([string] $FilePath)
        Invoke-DumpbinHeaders -DumpbinExe $DumpbinExe -FilePath $FilePath
    }

    $result = Invoke-Arm64xVerification -BinDir $BinDir `
        -HeaderProvider $headerProvider -SkipLibPairing:$SkipLibPairing

    foreach ($c in $result.Checked) {
        Write-Host ("  {0,-24} {1}" -f $c.File, $c.Abi)
    }
    Write-Host $result.Message

    if (-not $result.Success) {
        # Fail-fast: klare Meldung mit den benannten Abweichungen (R2.5).
        throw $result.Message
    }

    $result
}
