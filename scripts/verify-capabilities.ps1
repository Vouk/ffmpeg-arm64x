<#
.SYNOPSIS
    Prüft die Build-Fähigkeiten eines gebauten FFmpeg (LGPL) anhand von FFmpegs
    config.h/config_components.h.

.DESCRIPTION
    Gebaut werden LGPL und GPL als Shared Libraries, beide OHNE Hardware-
    Encoder (kein AMF/NVENC/NVDEC). Diese Pruefung stellt sicher, dass der Build:
      * im LGPL-Fall KEINE GPL-Encoder (libx264/libx265) enthaelt bzw. im GPL-
        Fall libx264/libx265 WIRKLICH enthaelt, und
      * KEINE Hardware-Encoder (AMF/NVENC) und KEINE NVIDIA-Hardware-
        Beschleunigung (CUDA/NVDEC/ffnvcodec) enthaelt -- diese wurden entfernt,
        weil ihre Laufzeit-Probes einen ARM64EC-Host (Windows-on-ARM) beim
        Plugin-Init minutenlang blockieren.

    Da ARM64-ffmpeg.exe auf dem x64-Runner NICHT ausfuehrbar ist, erfolgt die
    Pruefung STATISCH aus den von configure erzeugten Headern config.h und
    config_components.h. Die reine Assertion-Logik ist in
    `Test-FFmpegConfigCapabilities` gekapselt und ohne echtes Binary testbar.

    Bei einer Abweichung bricht das Skript fail-fast ab und benennt die konkret
    fehlende oder unerwartet vorhandene Fähigkeit.

.PARAMETER ConfigPath
    Pfad zu FFmpegs config.h bzw. zu einem Verzeichnis, das config.h und
    config_components.h enthaelt. Auf CI erforderlich.

.OUTPUTS
    [pscustomobject] mit dem Ergebnis von Test-FFmpegConfigCapabilities. Bei
    einer Abweichung wird zusätzlich ein terminierender Fehler ausgelöst.

.EXAMPLE
    ./scripts/verify-capabilities.ps1 -ConfigPath C:\out\ffmpeg\arm64

.NOTES
    Feature: arm64x-ffmpeg-build
    Design: Testing Strategy -> Fähigkeitsprüfung (statisch aus config.h),
            Components -> C2 (scripts/verify-capabilities.ps1).
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    # Pfad zu FFmpegs config.h (statische Faehigkeitspruefung). ARM64-ffmpeg.exe
    # laeuft nicht auf dem x64-Runner, daher der statische Weg.
    [Parameter()]
    [string] $ConfigPath,

    # Lizenz-Variante: 'lgpl' (Default) verbietet libx264/libx265; 'gpl'
    # verlangt sie. Beide verbieten AMF/NVENC/NVDEC (entfernt).
    [Parameter()]
    [ValidateSet('lgpl', 'gpl', IgnoreCase = $true)]
    [string] $Variant = 'lgpl'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Reine Parsing-/Assertion-Logik (lokal testbar, ohne echtes ffmpeg.exe)
# ---------------------------------------------------------------------------

function Get-FFmpegConfigFlags {
    <#
    .SYNOPSIS
        Liest die aktivierten CONFIG_*-Schalter aus FFmpegs config.h (reine
        Logik). Liefert die auf 1 gesetzten CONFIG_-Namen als String-Array
        (ohne CONFIG_-Praefix, lowercase, Duplikate entfernt).
    .DESCRIPTION
        config.h enthaelt je Komponente eine Zeile "#define CONFIG_<NAME> 1"
        oder "... 0". Keine Seiteneffekte. Rueckgabe als Array (nicht HashSet),
        damit die PowerShell-Pipeline leere Mengen nicht zu $null entpackt.
    .OUTPUTS
        [string[]] -- aktivierte Komponentennamen (lowercase).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $ConfigText)

    $names = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not [string]::IsNullOrWhiteSpace($ConfigText)) {
        foreach ($raw in ($ConfigText -split "`r?`n")) {
            $line = $raw.Trim()
            if ($line -match '^#define\s+CONFIG_([A-Za-z0-9_]+)\s+1\s*$') {
                $name = $Matches[1].ToLowerInvariant()
                if ($seen.Add($name)) { $names.Add($name) }
            }
        }
    }
    return [string[]]$names.ToArray()
}

function Test-FFmpegConfigCapabilities {
    <#
    .SYNOPSIS
        Statische Faehigkeitspruefung je Variante (mit HW-Encodern) anhand von
        FFmpegs config.h (reine Logik, kein ffmpeg-Aufruf).
    .DESCRIPTION
        ARM64-ffmpeg.exe laeuft nicht auf dem x64-Runner; deshalb wird statt
        der Laufzeitausgabe die Build-Konfiguration geprueft:
          * LGPL: CONFIG_LIBX264_ENCODER / CONFIG_LIBX265_ENCODER duerfen NICHT
            vorhanden sein.
          * GPL : CONFIG_LIBX264_ENCODER UND CONFIG_LIBX265_ENCODER MUESSEN
            vorhanden sein.
          * beide: KEIN *_AMF_ENCODER, KEIN *_NVENC_ENCODER und kein
            CONFIG_CUDA/CONFIG_NVDEC/CONFIG_FFNVCODEC (HW-Encoder entfernt).
    .OUTPUTS
        PSCustomObject (Success, Variant, Violations, Message).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $ConfigText,
        [Parameter()][ValidateSet('lgpl','gpl',IgnoreCase=$true)][string] $Variant = 'lgpl'
    )

    $variantKey = $Variant.ToLowerInvariant()
    $flagItems = @(Get-FFmpegConfigFlags -ConfigText $ConfigText)
    $flags = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$flagItems, [System.StringComparer]::OrdinalIgnoreCase)
    $violations = [System.Collections.Generic.List[string]]::new()

    # --- GPL-Encoder: je Variante erforderlich bzw. verboten ----------------
    $hasX264 = $flags.Contains('libx264_encoder')
    $hasX265 = $flags.Contains('libx265_encoder')
    if ($variantKey -eq 'gpl') {
        if (-not $hasX264) { $violations.Add("Fehlender GPL-Encoder 'libx264' im GPL-Build.") }
        if (-not $hasX265) { $violations.Add("Fehlender GPL-Encoder 'libx265' im GPL-Build.") }
    } else {
        if ($hasX264) { $violations.Add("Unerwarteter GPL-Encoder 'libx264' im LGPL-Build.") }
        if ($hasX265) { $violations.Add("Unerwarteter GPL-Encoder 'libx265' im LGPL-Build.") }
    }

    # --- Hardware-Encoder: AUSDRUECKLICH VERBOTEN (beide Varianten) ---------
    # AMF/NVENC/NVDEC wurden aus dem Build entfernt (ARM64EC-Haenger auf WoA).
    # Taucht trotzdem ein solcher Schalter in config.h auf, ist versehentlich
    # wieder HW-Encoding aktiviert -> Verstoss.
    $amf = @($flagItems | Where-Object { $_ -match '(?i)_amf_encoder$' })
    if ($amf.Count -gt 0) {
        $violations.Add("Unerwartete AMF-Hardware-Encoder in config.h (AMF wurde entfernt): " + ($amf -join ', '))
    }
    $nvenc = @($flagItems | Where-Object { $_ -match '(?i)_nvenc_encoder$' })
    if ($nvenc.Count -gt 0) {
        $violations.Add("Unerwartete NVENC-Hardware-Encoder in config.h (NVENC wurde entfernt): " + ($nvenc -join ', '))
    }
    if ($flags.Contains('cuda') -or $flags.Contains('nvdec') -or $flags.Contains('cuvid') -or $flags.Contains('ffnvcodec')) {
        $violations.Add("Unerwartete NVDEC/CUDA/ffnvcodec-Hardware-Beschleunigung in config.h (NVIDIA-Stack wurde entfernt).")
    }

    $success = ($violations.Count -eq 0)
    $message = if ($success) {
        "Statische Faehigkeitspruefung (config.h) bestanden: $variantKey-Build ohne Hardware-Encoder" +
        $(if ($variantKey -eq 'gpl') { ', mit libx264/libx265.' } else { ', ohne GPL-Encoder.' })
    } else {
        "Statische Faehigkeitspruefung (config.h, $variantKey) fehlgeschlagen: " + ($violations -join ' ')
    }
    return [pscustomobject]@{
        Success    = $success
        Variant    = $variantKey
        Violations = [string[]]$violations.ToArray()
        Message    = $message
    }
}

# ---------------------------------------------------------------------------
# Einstiegspunkt: nur ausführen, wenn direkt aufgerufen (nicht beim Dot-Sourcing
# durch Tests, die nur die reine Logik prüfen wollen).
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    # Statische Pruefung aus FFmpegs config.h + config_components.h (ARM64-
    # ffmpeg.exe laeuft nicht auf x64). -ConfigPath darf eine DATEI oder ein
    # VERZEICHNIS sein; bei einem Verzeichnis werden config.h UND
    # config_components.h (sofern vorhanden) zusammengefuehrt.
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        throw "Parameter -ConfigPath (Datei oder Verzeichnis mit FFmpegs config*.h) ist erforderlich."
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "FFmpeg-Konfigurationspfad nicht gefunden: '$ConfigPath'."
    }

    $configFiles = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $ConfigPath -PathType Container) {
        foreach ($name in @('config.h', 'config_components.h')) {
            $cand = Join-Path $ConfigPath $name
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $configFiles.Add($cand) }
        }
        if ($configFiles.Count -eq 0) {
            throw "Keine config.h/config_components.h in Verzeichnis '$ConfigPath' gefunden."
        }
    } else {
        $configFiles.Add($ConfigPath)
        # Falls die Datei config.h ist, auch das Nachbar-config_components.h lesen.
        $sibling = Join-Path (Split-Path -Parent $ConfigPath) 'config_components.h'
        if (($ConfigPath -match '(?i)[\\/]config\.h$') -and (Test-Path -LiteralPath $sibling -PathType Leaf)) {
            $configFiles.Add($sibling)
        }
    }
    $configText = ($configFiles | ForEach-Object { [System.IO.File]::ReadAllText($_) }) -join "`n"
    Write-Host ("Statische Pruefung ($Variant) aus: " + ($configFiles -join ', '))
    $result = Test-FFmpegConfigCapabilities -ConfigText $configText -Variant $Variant

    Write-Host $result.Message

    if (-not $result.Success) {
        # Diagnose: die tatsaechlich gefundenen codec-relevanten Schalter zeigen.
        $found = @(Get-FFmpegConfigFlags -ConfigText $configText |
            Where-Object { $_ -match '(?i)(libx26[45]|_amf|_nvenc|nvdec|cuda|cuvid|ffnvcodec)' } | Sort-Object)
        Write-Host ("Gefundene relevante CONFIG_-Schalter (" + $found.Count + "): " + ($found -join ', '))
        # Fail-fast: klare Meldung mit den benannten Abweichungen.
        throw $result.Message
    }

    $result
}
