<#
.SYNOPSIS
    Prüft die gemeldeten Encoder-/Decoder-/Hardware-Fähigkeiten eines gebauten
    `ffmpeg.exe` je Lizenz-Variante (gpl|lgpl).

.DESCRIPTION
    Dieses Skript setzt Task 9.4 um (Design: Testing Strategy ->
    "Encoder-/Decoder-Fähigkeitsprüfung", Components -> C2
    scripts/verify-capabilities.ps1). Es ruft das gebaute `ffmpeg.exe` je
    Variante mit `-encoders`, `-decoders` und `-hwaccels` auf, parst die
    Ausgabe und stellt sicher, dass die je Variante erwarteten Fähigkeiten
    vorhanden (bzw. bei der LGPL-Variante die GPL-Codecs abwesend) sind:

      - GPL  (R6.1/R6.2):
          * `-encoders` listet `libx264` UND `libx265`
      - LGPL (R6.5):
          * `libx264`/`libx265` erscheinen NICHT
      - Beide (R5.1–R5.4):
          * `-encoders`/`-hwaccels` listet AMF- UND NVENC/NVDEC-Einträge

    Bei einer Abweichung bricht das Skript fail-fast ab und benennt die konkret
    fehlende oder unerwartet vorhandene Fähigkeit.

    Testbarkeit: Das echte `ffmpeg.exe` existiert nur auf dem CI-Runner. Damit
    die OUTPUT-PARSING- und Assertion-Logik lokal ohne echtes Binary geprüft
    werden kann, ist sie vollständig in die reine Funktion
    `Test-FFmpegCapabilities` gekapselt. Diese nimmt die erfassten Texte von
    `-encoders`/`-decoders`/`-hwaccels` plus die Variante entgegen und liefert
    ein Ergebnisobjekt (Success + benannte Abweichungen), ohne Seiteneffekte.
    Der Skript-Rumpf erfasst auf CI die echte ffmpeg-Ausgabe und reicht sie an
    diese Funktion weiter.

.PARAMETER FFmpegPath
    Pfad zum gebauten `ffmpeg.exe`, das aufgerufen wird. Auf CI erforderlich.

.PARAMETER Variant
    Lizenz-Variante: 'gpl' oder 'lgpl' (case-insensitiv).

.OUTPUTS
    [pscustomobject] mit dem Ergebnis von Test-FFmpegCapabilities. Bei einer
    Abweichung wird zusätzlich ein terminierender Fehler ausgelöst (fail-fast).

.EXAMPLE
    ./scripts/verify-capabilities.ps1 -FFmpegPath C:\out\gpl\arm64\bin\ffmpeg.exe -Variant gpl

.NOTES
    Feature: arm64x-ffmpeg-build
    Task: 9.4
    Requirements: 6.1, 6.2, 6.3, 6.5, 5.1, 5.2, 5.3, 5.4
    Design: Testing Strategy -> Encoder-/Decoder-Fähigkeitsprüfung (Integration),
            Components -> C2 (scripts/verify-capabilities.ps1),
            C3 (Externe-Bibliotheken-Layer / LGPL-Zusammensetzung).
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $FFmpegPath,

    [Parameter(Mandatory)]
    [ValidateSet('gpl', 'lgpl', IgnoreCase = $true)]
    [string] $Variant
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Reine Parsing-/Assertion-Logik (lokal testbar, ohne echtes ffmpeg.exe)
# ---------------------------------------------------------------------------

function Get-FFmpegListedNames {
    <#
    .SYNOPSIS
        Extrahiert die gelisteten Codec-/Methoden-Namen aus einer erfassten
        `ffmpeg -encoders|-decoders|-hwaccels`-Ausgabe (reine Logik).
    .DESCRIPTION
        `ffmpeg -encoders`/`-decoders` geben eine Kopfzeile, eine Legende und
        eine `------`-Trennlinie aus, danach je Codec eine Zeile der Form
        " V..... libx264   libx264 H.264 ...". Der erste Whitespace-getrennte
        Token nach den Fähigkeits-Flags ist der Codec-Name.

        `ffmpeg -hwaccels` gibt "Hardware acceleration methods:" gefolgt von je
        einer Methode pro Zeile aus (z. B. "cuda", "d3d11va").

        Diese Funktion liefert für beide Formate die Menge der gelisteten Namen
        als String-Array (Reihenfolge erhalten, Duplikate entfernt). Sie greift
        nicht auf das Dateisystem oder ffmpeg zu.
    .PARAMETER Text
        Die erfasste, mehrzeilige ffmpeg-Ausgabe.
    .PARAMETER Kind
        'list'    : Encoder-/Decoder-Format (Flags-Spalte + Name),
        'hwaccels': einfache Methodenliste unter einer Kopfzeile.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory)]
        [ValidateSet('list', 'hwaccels')]
        [string] $Kind
    )

    $names = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return , ([string[]]$names.ToArray())
    }

    # Zeilenweise, unabhängig vom Zeilenende-Stil.
    $lines = $Text -split "`r?`n"

    $pastSeparator = $false
    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($Kind -eq 'list') {
            # Alles vor der "------"-Trennlinie ist Kopf/Legende und wird
            # übersprungen. Ab der Trennlinie folgen die Codec-Zeilen.
            if (-not $pastSeparator) {
                if ($line -match '^\s*-{3,}\s*$') {
                    $pastSeparator = $true
                }
                continue
            }

            # Codec-Zeile: führende Flags-Spalte (z. B. "V....D" / "A......"),
            # dann Whitespace, dann der Codec-Name.
            if ($line -match '^\s*([A-Z\.]{4,})\s+(\S+)') {
                $name = $Matches[2]
                if ($seen.Add($name)) { $names.Add($name) }
            }
        }
        else {
            # hwaccels: Kopfzeile überspringen, danach je Zeile eine Methode.
            if ($line -match '(?i)hardware acceleration methods') { continue }
            $method = $line.Trim()
            if (-not [string]::IsNullOrWhiteSpace($method)) {
                if ($seen.Add($method)) { $names.Add($method) }
            }
        }
    }

    return , ([string[]]$names.ToArray())
}

function Test-FFmpegCapabilities {
    <#
    .SYNOPSIS
        Reine Assertion-Logik: prüft die erfassten
        `-encoders`/`-decoders`/`-hwaccels`-Texte gegen die je Variante
        erwarteten Fähigkeiten (Task 9.4, R5.1–R5.4, R6.1–R6.2, R6.5).
    .DESCRIPTION
        Nimmt die drei erfassten ffmpeg-Ausgabetexte und die Variante entgegen,
        parst sie über Get-FFmpegListedNames und wertet die Regeln aus:

          GPL:
            * libx264 UND libx265 in -encoders vorhanden (R6.1/R6.2)
          LGPL:
            * libx264/libx265 in -encoders ABWESEND (R6.5)
          Beide:
            * AMF-Encoder (*_amf) in -encoders vorhanden (R5.1/R5.3)
            * NVENC-Encoder (*_nvenc) in -encoders vorhanden (R5.2)
            * NVDEC/CUDA-Hardware-Beschleunigung in -hwaccels vorhanden
              (R5.4)

        Die Funktion hat keine Seiteneffekte und ruft weder ffmpeg noch das
        Dateisystem auf. Sie liefert ein Ergebnisobjekt mit Success und einer
        Liste benannter Verstöße (fehlend oder unerwartet vorhanden), damit der
        Aufrufer fail-fast mit klarer Meldung abbrechen kann.
    .PARAMETER EncodersText
        Erfasster Text von `ffmpeg -encoders`.
    .PARAMETER DecodersText
        Erfasster Text von `ffmpeg -decoders`.
    .PARAMETER HwaccelsText
        Erfasster Text von `ffmpeg -hwaccels`.
    .PARAMETER Variant
        'gpl' oder 'lgpl' (case-insensitiv).
    .OUTPUTS
        PSCustomObject mit:
          Success    [bool]     — alle Regeln der Variante erfüllt
          Variant    [string]   — normalisierte Variante
          Violations [string[]] — benannte Verstöße (fehlend/unerwartet)
          Encoders   [string[]] — geparste Encoder-Namen
          Decoders   [string[]] — geparste Decoder-Namen
          Hwaccels   [string[]] — geparste Hardware-Beschleunigungsmethoden
          Message    [string]   — menschenlesbare Zusammenfassung
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $EncodersText,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $DecodersText,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $HwaccelsText,
        [Parameter(Mandatory)]
        [ValidateSet('gpl', 'lgpl', IgnoreCase = $true)]
        [string] $Variant
    )

    $variantKey = $Variant.ToLowerInvariant()

    $encoders = Get-FFmpegListedNames -Text $EncodersText -Kind 'list'
    $decoders = Get-FFmpegListedNames -Text $DecodersText -Kind 'list'
    $hwaccels = Get-FFmpegListedNames -Text $HwaccelsText -Kind 'hwaccels'

    # Case-insensitive Nachschlagewerke für schnelle Prüfungen.
    $encSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$encoders, [System.StringComparer]::OrdinalIgnoreCase)

    $violations = [System.Collections.Generic.List[string]]::new()

    # --- GPL-only Codecs: libx264/libx265 (R6.1/R6.2 vs. R6.5) ---------------
    $hasX264 = $encSet.Contains('libx264')
    $hasX265 = $encSet.Contains('libx265')

    if ($variantKey -eq 'gpl') {
        if (-not $hasX264) {
            $violations.Add("Fehlender H.264-Encoder 'libx264' in -encoders (GPL, R6.1).")
        }
        if (-not $hasX265) {
            $violations.Add("Fehlender H.265-Encoder 'libx265' in -encoders (GPL, R6.2).")
        }
    }
    else {
        # LGPL: x264/x265 dürfen NICHT erscheinen (R6.5).
        if ($hasX264) {
            $violations.Add("Unerwarteter GPL-Encoder 'libx264' in der LGPL-Variante (R6.5).")
        }
        if ($hasX265) {
            $violations.Add("Unerwarteter GPL-Encoder 'libx265' in der LGPL-Variante (R6.5).")
        }
    }

    # --- AMF-Hardware-Encoder (beide Varianten, R5.1/R5.3) -------------------
    # AMF-Encoder folgen dem Namensschema "<codec>_amf" (z. B. h264_amf).
    $amfEncoders = @($encoders | Where-Object { $_ -match '(?i)_amf$' })
    if ($amfEncoders.Count -eq 0) {
        $violations.Add("Fehlende AMF-Hardware-Encoder in -encoders (erwartet z. B. 'h264_amf', R5.1/R5.3).")
    }

    # --- NVENC-Hardware-Encoder (beide Varianten, R5.2) ----------------------
    # NVENC-Encoder folgen dem Namensschema "<codec>_nvenc" (z. B. h264_nvenc).
    $nvencEncoders = @($encoders | Where-Object { $_ -match '(?i)_nvenc$' })
    if ($nvencEncoders.Count -eq 0) {
        $violations.Add("Fehlende NVENC-Hardware-Encoder in -encoders (erwartet z. B. 'h264_nvenc', R5.2).")
    }

    # --- NVDEC/CUDA-Hardware-Beschleunigung (beide Varianten, R5.4) ----------
    # NVDEC wird als hwaccel "cuda" bzw. "nvdec" gemeldet.
    $hwSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$hwaccels, [System.StringComparer]::OrdinalIgnoreCase)
    $hasNvdec = $hwSet.Contains('cuda') -or $hwSet.Contains('nvdec')
    if (-not $hasNvdec) {
        $violations.Add("Fehlende NVDEC/NVENC-Hardware-Beschleunigung in -hwaccels (erwartet 'cuda' oder 'nvdec', R5.4).")
    }

    $success = ($violations.Count -eq 0)
    if ($success) {
        $message = "Fähigkeitsprüfung für Variante '$variantKey' bestanden: " +
                   "alle erwarteten Encoder/Decoder/Hardware-Fähigkeiten vorhanden."
    }
    else {
        $message = "Fähigkeitsprüfung für Variante '$variantKey' fehlgeschlagen: " +
                   ($violations -join ' ')
    }

    return [pscustomobject]@{
        Success    = $success
        Variant    = $variantKey
        Violations = [string[]]$violations.ToArray()
        Encoders   = [string[]]$encoders
        Decoders   = [string[]]$decoders
        Hwaccels   = [string[]]$hwaccels
        Message    = $message
    }
}

function Invoke-FFmpegCapability {
    <#
    .SYNOPSIS
        Ruft `ffmpeg <switch>` auf und liefert die erfasste Standardausgabe
        (nur auf dem CI-Runner; nicht Teil der reinen Logik).
    .DESCRIPTION
        `ffmpeg` schreibt die Fähigkeitslisten nach stdout und Banner-/Log-
        Informationen nach stderr. Wir erfassen beide Ströme und geben den
        vereinten Text zurück, damit die Parser-Logik robust bleibt. Ein von
        Null verschiedener Exit-Code bricht fail-fast ab.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $FFmpegPath,
        [Parameter(Mandatory)] [string] $Switch
    )

    $output = & $FFmpegPath '-hide_banner' $Switch 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Aufruf von '$FFmpegPath $Switch' schlug fehl (Exit $LASTEXITCODE)."
    }
    return ($output | Out-String)
}

# ---------------------------------------------------------------------------
# Einstiegspunkt: nur ausführen, wenn direkt aufgerufen (nicht beim Dot-Sourcing
# durch Tests, die nur die reine Logik prüfen wollen).
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-Path -LiteralPath $FFmpegPath)) {
        throw "ffmpeg.exe nicht gefunden: '$FFmpegPath'."
    }

    # Echte ffmpeg-Ausgaben erfassen ...
    $encodersText = Invoke-FFmpegCapability -FFmpegPath $FFmpegPath -Switch '-encoders'
    $decodersText = Invoke-FFmpegCapability -FFmpegPath $FFmpegPath -Switch '-decoders'
    $hwaccelsText = Invoke-FFmpegCapability -FFmpegPath $FFmpegPath -Switch '-hwaccels'

    # ... und an die reine Assertion-Logik weiterreichen.
    $result = Test-FFmpegCapabilities `
        -EncodersText $encodersText `
        -DecodersText $decodersText `
        -HwaccelsText $hwaccelsText `
        -Variant $Variant

    Write-Host $result.Message

    if (-not $result.Success) {
        # Fail-fast: klare Meldung mit den benannten Abweichungen.
        throw $result.Message
    }

    $result
}
