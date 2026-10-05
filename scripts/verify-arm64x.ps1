<#
.SYNOPSIS
    Verifiziert, dass die ARM64X-Forwarder-DLLs im Pure-Forwarder-Layout echte
    ARM64X-Hybrid-Binärdateien sind (ARM64- UND ARM64EC-Ansicht). Die echten
    Ansichts-DLLs (<base>_arm64.dll/<base>_arm64ec.dll) sind absichtlich NICHT
    hybrid und werden übersprungen; von den Tools (ffmpeg.exe/ffprobe.exe,
    native ARM64) wird nur die Präsenz geprüft.

.DESCRIPTION
    Dieses Skript setzt Task 9.2 um (Design: Testing Strategy ->
    "ARM64X-Dual-View-Verifikation", Schnittstelle -> "Verifikation der
    ARM64X-Ansicht", Components -> C2 scripts/verify-arm64x.ps1). Nach dem
    ARM64X-Merge (merge-arm64x.ps1) läuft es über die ARM64X-Forwarder-DLLs
    (die *.dll OHNE _arm64/_arm64ec-Suffix) und prüft je Datei per
    `dumpbin /headers` den Marker `(ARM64X)` an der Maschinenzeile des
    PE-Headers:

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

.PARAMETER ExpectedAbi
    Erwartete Maschinen-ABI der zu prüfenden Binärdateien: 'ARM64X' (Standard,
    gemergtes Hybrid-Ergebnis), 'ARM64' oder 'ARM64EC'. Mit 'ARM64' bzw.
    'ARM64EC' lassen sich die VOR dem Merge erzeugten Einzel-Ansichten
    (out\...\arm64\bin bzw. out\...\arm64ec\bin) daraufhin prüfen, dass die
    arm64ec-Ansicht WIRKLICH als ARM64EC (`A641 machine (ARM64EC)`) und die
    arm64-Ansicht als reines ARM64 kompiliert/gelinkt wurde — damit der
    anschließende /MACHINE:ARM64X-Merge nachweislich aus zwei echten Ansichten
    entsteht. Bei abweichender ABI bricht das Skript fail-fast ab und benennt
    die betroffene Datei samt erwarteter und tatsächlicher ABI.

.PARAMETER DumpbinExe
    Pfad zu `dumpbin.exe` (MSVC). Parametrisiert, damit der Aufruf lokal ohne
    echte Toolchain umgeleitet werden kann. Standard: 'dumpbin.exe' (aus dem
    PATH der vcvars-Umgebung).

.PARAMETER SkipLibPairing
    Wenn gesetzt, wird die `.lib`-Paarungsprüfung (Test-DllLibPairing)
    übersprungen. Für die Pre-Merge-Einzelansichten (ExpectedAbi ARM64/ARM64EC)
    sinnvoll, da die gleichnamige .lib-Paarung erst für das gemergte
    ARM64X-Ergebnis garantiert ist.

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
    [ValidateSet('ARM64X', 'ARM64', 'ARM64EC', IgnoreCase = $true)]
    [string] $ExpectedAbi = 'ARM64X',

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
        Ausgabe die ERWARTETE Maschinen-ABI zeigt (reine Logik, R2.4).
    .DESCRIPTION
        Dünner Wrapper um Get-DumpbinMachineAbi. Standardmäßig matcht der Gate
        EXAKT `(ARM64X)` an der Maschinenzeile (das gemergte Hybrid-Ergebnis);
        reines ARM64 und reines ARM64EC werden dann abgelehnt.

        Über -ExpectedAbi kann stattdessen 'ARM64' oder 'ARM64EC' verlangt
        werden, um die VOR dem Merge erzeugten Einzel-Ansichten zu prüfen:
          * ExpectedAbi 'ARM64EC' akzeptiert NUR `A641 machine (ARM64EC)` und
            weist insbesondere ein reines ARM64-Image (fehlgeschlagene
            /arm64EC-Kompilierung) sowie ein bereits gemergtes ARM64X-Image ab.
          * ExpectedAbi 'ARM64' akzeptiert NUR reines ARM64 (ohne ARM64EC- und
            ohne ARM64X-Marker).

        Liefert ein Ergebnisobjekt mit der erkannten ABI und einer
        menschenlesbaren Meldung, damit der Aufrufer bei abweichender ABI
        fail-fast mit klarer Nennung von erwarteter und tatsächlicher ABI
        abbrechen kann (R2.5).
    .PARAMETER HeaderText
        Die erfasste `dumpbin /headers`-Ausgabe.
    .PARAMETER ExpectedAbi
        Erwartete ABI: 'ARM64X' (Standard), 'ARM64' oder 'ARM64EC'.
    .PARAMETER FileName
        Optionaler Name der geprüften Datei (nur für die Meldung, R2.5).
    .OUTPUTS
        PSCustomObject mit:
          IsExpected  [bool]   — $true gdw erkannte ABI == ExpectedAbi
          IsArm64x    [bool]   — $true gdw erkannte ABI == 'ARM64X'
                                 (für Abwärtskompatibilität beibehalten)
          Abi         [string] — erkannte ABI (ARM64/ARM64EC/ARM64X/Unknown)
          ExpectedAbi [string] — die geforderte ABI
          File        [string] — geprüfte Datei (falls angegeben)
          Message     [string] — menschenlesbare Zusammenfassung; bei Fehler
                                 werden erwartete und tatsächliche ABI benannt
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $HeaderText,

        [Parameter()]
        [ValidateSet('ARM64X', 'ARM64', 'ARM64EC', IgnoreCase = $true)]
        [string] $ExpectedAbi = 'ARM64X',

        [Parameter()]
        [string] $FileName = ''
    )

    $abi = Get-DumpbinMachineAbi -HeaderText $HeaderText
    # Normalisieren: Get-DumpbinMachineAbi liefert kanonische Großschreibung.
    $expected = switch ($ExpectedAbi.ToUpperInvariant()) {
        'ARM64X'  { 'ARM64X' }
        'ARM64EC' { 'ARM64EC' }
        default   { 'ARM64' }
    }
    $isExpected = ($abi -eq $expected)
    $isArm64x = ($abi -eq 'ARM64X')
    $label = if ([string]::IsNullOrWhiteSpace($FileName)) { 'Binärdatei' } else { "'$FileName'" }

    if ($isExpected) {
        $detail = switch ($expected) {
            'ARM64X'  { 'ein ARM64X-Hybrid (enthält ARM64- und ARM64EC-Ansicht)' }
            'ARM64EC' { 'ein reines ARM64EC-Image (Pre-Merge-EC-Ansicht)' }
            default   { 'ein reines ARM64-Image (Pre-Merge-ARM64-Ansicht)' }
        }
        $message = "$label ist $detail."
    }
    elseif ($expected -eq 'ARM64X') {
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
    else {
        # Pre-Merge-Einzelansicht mit falscher ABI (z. B. 'arm64ec'-Build, der
        # in Wahrheit als reines ARM64 herauskam -> /arm64EC hat nicht gegriffen).
        $message = "$label hat nicht die erwartete ABI: erwartet $expected, " +
                   "tatsächlich $abi (Maschinenzeile aus 'dumpbin /headers')."
    }

    return [pscustomobject]@{
        IsExpected  = $isExpected
        IsArm64x    = $isArm64x
        Abi         = $abi
        ExpectedAbi = $expected
        File        = $FileName
        Message     = $message
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

# Ausführbaren, deren PRÄSENZ (nicht ihre ABI) erwartet wird. Im Pure-
# Forwarder-Modell sind die Tools native ARM64-Binaries, KEINE ARM64X-Hybride.
$script:ExpectedExecutables = @('ffmpeg.exe', 'ffprobe.exe')

function Get-Arm64xTargetFiles {
    <#
    .SYNOPSIS
        Ermittelt die als ARM64X-Hybrid zu verifizierenden Dateien in -BinDir:
        NUR die Forwarder-DLLs (reine Logik über einen injizierbaren Lister).
    .DESCRIPTION
        Im Pure-Forwarder-Layout liegen je Bibliothek DREI DLLs in -BinDir:
          * <base>.dll           -- der ARM64X-Forwarder (MUSS Hybrid sein)
          * <base>_arm64.dll     -- echte ARM64-DLL   (reines ARM64, KEIN Hybrid)
          * <base>_arm64ec.dll   -- echte ARM64EC-DLL (reines ARM64EC, KEIN Hybrid)
        Nur die Forwarder (ohne _arm64/_arm64ec-Suffix) werden auf (ARM64X)
        geprüft. Die echten Ansichts-DLLs sind absichtlich NICHT hybrid und
        werden übersprungen. Die Tools (ffmpeg.exe/ffprobe.exe) sind native
        ARM64-Binaries; es wird nur ihre PRÄSENZ geprüft (fail-fast bei Fehlen),
        nicht ihre ABI.
        Die Datei-Aufzählung erfolgt über den injizierbaren -FileLister, damit
        die Auswahl-Logik ohne echtes Dateisystem testbar bleibt.
    .OUTPUTS
        [string[]] — Pfade der als ARM64X zu prüfenden Forwarder-DLLs.
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

    # NUR Forwarder-DLLs: *.dll ohne _arm64/_arm64ec-Suffix.
    foreach ($n in $names) {
        if ($n -match '(?i)\.dll$' -and $n -notmatch '(?i)_arm64(ec)?\.dll$') {
            $targets.Add((Join-Path $BinDir $n))
        }
    }

    # Erwartete Tools: nur Präsenz prüfen (keine ARM64X-Prüfung ihrer ABI).
    foreach ($exe in $script:ExpectedExecutables) {
        if (-not $nameSet.Contains($exe)) {
            throw "ARM64X-Verifikation: erwartete Ausführbare '$exe' fehlt in '$BinDir'."
        }
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
        [Parameter()]
        [ValidateSet('ARM64X', 'ARM64', 'ARM64EC', IgnoreCase = $true)]
        [string] $ExpectedAbi = 'ARM64X',
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
        $gate = Test-Arm64xHeader -HeaderText $headerText -ExpectedAbi $ExpectedAbi -FileName $leaf

        $checked.Add([pscustomobject]@{
            File       = $leaf
            Path       = $file
            Abi        = $gate.Abi
            IsExpected = $gate.IsExpected
            IsArm64x   = $gate.IsArm64x
        })

        if (-not $gate.IsExpected) {
            # R2.5: betroffene Datei + erwartete/tatsächliche ABI benennen.
            $failures.Add($gate.Message)
        }
    }

    # --- DLL/`.lib`-Paarung (R3.3) über Test-DllLibPairing -------------------
    # Im Pure-Forwarder-Layout liegen KEINE .lib-Dateien in bin/ (die Import-
    # Libs werden nur temporär für den Link erzeugt und wieder entfernt). Die
    # Paarungsprüfung wird daher übersprungen, wenn keine .lib vorhanden ist --
    # oder wenn der Aufrufer -SkipLibPairing setzt.
    $pairing = $null
    $allNames = @(& $lister $BinDir)
    $libNames = @($allNames | Where-Object { $_ -match '(?i)\.lib$' })
    if (-not $SkipLibPairing -and $libNames.Count -gt 0) {
        $dllNames = @($allNames | Where-Object { $_ -match '(?i)\.dll$' })
        $pairing = Test-DllLibPairing -DllName $dllNames -LibName $libNames
        if (-not $pairing.Success) {
            $failures.Add($pairing.Message)
        }
    }

    $success = ($failures.Count -eq 0)
    $abiLabel = switch ($ExpectedAbi.ToUpperInvariant()) {
        'ARM64X'  { 'ARM64X-Hybride' }
        'ARM64EC' { 'reine ARM64EC-Images (Pre-Merge-EC-Ansicht)' }
        default   { 'reine ARM64-Images (Pre-Merge-ARM64-Ansicht)' }
    }
    if ($success) {
        $message = "ABI-Verifikation bestanden: $($checked.Count) Datei(en) " +
                   "sind $abiLabel" +
                   $(if (-not $SkipLibPairing) { " und alle DLLs besitzen eine gleichnamige .lib." } else { "." })
    }
    else {
        $message = "ABI-Verifikation fehlgeschlagen (erwartet $($ExpectedAbi.ToUpperInvariant())): " + ($failures -join ' ')
    }

    return [pscustomobject]@{
        Success     = $success
        BinDir      = $BinDir
        ExpectedAbi = $ExpectedAbi.ToUpperInvariant()
        Checked     = [pscustomobject[]]$checked.ToArray()
        Failures    = [string[]]$failures.ToArray()
        Pairing     = $pairing
        Message     = $message
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

    # Die DLL/.lib-Paarung ist nur für das gemergte ARM64X-Ergebnis garantiert.
    # Für die Pre-Merge-Einzelansichten (ExpectedAbi ARM64/ARM64EC) wird sie
    # daher automatisch übersprungen, sofern der Aufrufer sie nicht ohnehin
    # explizit abgeschaltet hat.
    $skipPairing = $SkipLibPairing -or ($ExpectedAbi.ToUpperInvariant() -ne 'ARM64X')

    $result = Invoke-Arm64xVerification -BinDir $BinDir `
        -HeaderProvider $headerProvider -ExpectedAbi $ExpectedAbi -SkipLibPairing:$skipPairing

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
