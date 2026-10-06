<#
.SYNOPSIS
    Reinlogik-Modul für die Validierung erzeugter Build-Artefakte.

.DESCRIPTION
    Kapselt die reine, testbare Logik zur Artefakt-Prüfung des ARM64X-FFmpeg-
    Builds:
      - Test-DllLibPairing  : jede erzeugte DLL besitzt genau eine namensgleiche
                              .lib-Import-Bibliothek (Property 2, R3.2/R3.3),
                              inklusive Prüfung der FFmpeg-CoreLibs-Erwartungs-
                              menge (R3.1).
      - Test-MsiCount       : genau zwei MSI-Installer (Property 4, R7.6) —
                              wird in einem separaten Task ergänzt.

    Das Modul enthält keine Datei-/CI-/WiX-Abhängigkeiten, damit es lokal ohne
    Build-Toolchain mit Pester + FsCheck getestet werden kann. Aufrufer reichen
    bereits ermittelte Basisnamen bzw. Zählwerte hinein.

.NOTES
    Feature: arm64x-ffmpeg-build
    Validiert: Requirements 3.1, 3.2, 3.3 (Test-DllLibPairing / CoreLibs)
#>

Set-StrictMode -Version Latest

# region Test-DllLibPairing (Task 3.1 — R3.1/R3.2/R3.3, Property 2)

# Die FFmpeg-Kernbibliotheken laut Design-Datenmodell (R3.1). Zu jeder muss der
# Build genau eine DLL + genau eine gleichnamige .lib erzeugen.
$script:CoreLibs = @(
    'avcodec',
    'avformat',
    'avutil',
    'avfilter',
    'avdevice',
    'swscale',
    'swresample'
)

function Get-CoreLibs {
    <#
    .SYNOPSIS
        Liefert die Erwartungsmenge der FFmpeg-Kernbibliotheken (R3.1).
    .DESCRIPTION
        Gibt eine Kopie der CoreLibs-Basisnamen zurück (avcodec, avformat,
        avutil, avfilter, avdevice, swscale, swresample).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return , ([string[]]$script:CoreLibs)
}

function ConvertTo-BaseNameSet {
    <#
    .SYNOPSIS
        Normalisiert eine Liste von Namen/Pfaden zu einer Menge von Basisnamen.
    .DESCRIPTION
        Interne Hilfsfunktion. Akzeptiert entweder blanke Basisnamen
        ("avcodec") oder Dateinamen/Pfade mit Endung ("avcodec.dll",
        "out\avcodec-60.lib" ...). Die Erweiterung sowie ein optionales
        Verzeichnis werden entfernt; der Vergleich erfolgt case-insensitiv.
    .PARAMETER Name
        Rohe Namensliste.
    .PARAMETER StripExtensions
        Zu entfernende Dateiendungen (z. B. '.dll', '.lib').
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]] $Name,
        [string[]] $StripExtensions
    )

    $result = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Name) { return , ([string[]]$result.ToArray()) }

    foreach ($raw in $Name) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        # Verzeichnisanteile entfernen (unterstützt / und \).
        $leaf = $raw -replace '.*[\\/]', ''
        $leaf = $leaf.Trim()

        foreach ($ext in $StripExtensions) {
            if ($leaf.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) {
                $leaf = $leaf.Substring(0, $leaf.Length - $ext.Length)
                break
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($leaf)) {
            $result.Add($leaf)
        }
    }

    return , ([string[]]$result.ToArray())
}

function Test-DllLibPairing {
    <#
    .SYNOPSIS
        Prüft, dass zu jedem erzeugten DLL-Basisnamen eine gleichnamige
        .lib-Import-Bibliothek existiert (Property 2, R3.2/R3.3).
    .DESCRIPTION
        Reine Logik ohne Dateisystemzugriff. Vergleicht die Menge der
        DLL-Basisnamen mit der Menge der .lib-Basisnamen (case-insensitiv,
        ohne Verzeichnis und ohne Endung). Erfolg genau dann, wenn zu jedem
        DLL-Basisnamen ein gleichnamiger .lib-Basisname existiert; andernfalls
        wird eine konkret fehlende Import-Bibliothek benannt.

        Optional wird zusätzlich geprüft, dass die FFmpeg-CoreLibs-
        Erwartungsmenge (R3.1) vollständig unter den DLLs vorhanden ist.
    .PARAMETER DllName
        Basisnamen oder Dateinamen der erzeugten DLLs (z. B. 'avcodec' oder
        'avcodec.dll').
    .PARAMETER LibName
        Basisnamen oder Dateinamen der erzeugten .lib-Import-Bibliotheken.
    .PARAMETER RequireCoreLibs
        Wenn gesetzt, muss die vollständige CoreLibs-Menge unter den DLLs
        vorhanden sein (R3.1). Fehlt eine CoreLib, schlägt die Prüfung fehl.
    .OUTPUTS
        PSCustomObject mit:
          Success        [bool]     — alle DLLs haben eine gleichnamige .lib
                                       (und, falls verlangt, alle CoreLibs
                                        vorhanden)
          MissingLibs    [string[]] — DLL-Basisnamen ohne zugehörige .lib
          MissingCoreLibs[string[]] — fehlende CoreLibs (nur mit -RequireCoreLibs)
          Message        [string]   — menschenlesbare Zusammenfassung; bei
                                       Fehler wird eine konkret fehlende
                                       Import-Bibliothek benannt (R3.3)
    .EXAMPLE
        Test-DllLibPairing -DllName 'avcodec','avutil' -LibName 'avcodec','avutil'
        # Success = $true
    .EXAMPLE
        Test-DllLibPairing -DllName 'avcodec','avutil' -LibName 'avcodec'
        # Success = $false; MissingLibs = @('avutil'); Message benennt avutil.lib
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $DllName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $LibName,

        [switch] $RequireCoreLibs
    )

    $dllBases = ConvertTo-BaseNameSet -Name $DllName -StripExtensions @('.dll')
    $libBases = ConvertTo-BaseNameSet -Name $LibName -StripExtensions @('.lib')

    # Case-insensitives Nachschlagewerk der vorhandenen .lib-Basisnamen.
    $libLookup = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($lib in $libBases) { [void]$libLookup.Add($lib) }

    # Reihenfolge- und duplikatstabil: jede DLL genau einmal betrachten.
    $seenDll = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $missingLibs = [System.Collections.Generic.List[string]]::new()

    foreach ($dll in $dllBases) {
        if (-not $seenDll.Add($dll)) { continue }
        if (-not $libLookup.Contains($dll)) {
            $missingLibs.Add($dll)
        }
    }

    # Optionale CoreLibs-Vollständigkeitsprüfung (R3.1).
    $missingCore = [System.Collections.Generic.List[string]]::new()
    if ($RequireCoreLibs) {
        $dllLookup = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($dll in $dllBases) { [void]$dllLookup.Add($dll) }
        foreach ($core in $script:CoreLibs) {
            if (-not $dllLookup.Contains($core)) {
                $missingCore.Add($core)
            }
        }
    }

    $success = ($missingLibs.Count -eq 0) -and ($missingCore.Count -eq 0)

    if ($success) {
        $message = 'Alle DLLs besitzen eine gleichnamige .lib-Import-Bibliothek.'
        if ($RequireCoreLibs) {
            $message += ' Alle FFmpeg-Kernbibliotheken sind vorhanden.'
        }
    }
    else {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($missingLibs.Count -gt 0) {
            # R3.3: konkret fehlende Import-Bibliothek(en) benennen.
            $named = ($missingLibs | ForEach-Object { "$_.lib" }) -join ', '
            $parts.Add("Fehlende Import-Bibliothek(en): $named")
        }
        if ($missingCore.Count -gt 0) {
            $namedCore = ($missingCore | ForEach-Object { "$_.dll" }) -join ', '
            $parts.Add("Fehlende FFmpeg-Kernbibliothek(en): $namedCore")
        }
        $message = $parts -join ' | '
    }

    return [pscustomobject]@{
        Success         = $success
        MissingLibs     = [string[]]$missingLibs.ToArray()
        MissingCoreLibs = [string[]]$missingCore.ToArray()
        Message         = $message
    }
}

Export-ModuleMember -Function Test-DllLibPairing, Get-CoreLibs

# endregion Test-DllLibPairing

# region Test-MsiCount

# Erwartete Anzahl erzeugter MSI-Installer: genau einer (nur LGPL).
$script:ExpectedMsiCount = 1

function Test-MsiCount {
    <#
    .SYNOPSIS
        Prüft, dass genau ein MSI-Installer erzeugt wurde (nur LGPL-Variante).
    .DESCRIPTION
        Reine Logik ohne Dateisystemzugriff. Der Aufrufer ermittelt die Anzahl
        der erzeugten MSI-Installer (z. B. per Datei-Enumeration) und reicht sie
        als Zählwert hinein. Erfolg genau dann, wenn die Anzahl == 1 ist. Bei
        jeder Abweichung (weniger oder mehr) meldet die Funktion einen Fehler
        und benennt sowohl die erwartete (1) als auch die tatsächliche Anzahl.
    .PARAMETER Count
        Tatsächlich erzeugte Anzahl an MSI-Installern. Muss >= 0 sein.
    .OUTPUTS
        PSCustomObject mit:
          Success  [bool] — genau dann $true, wenn Count == 1
          Expected [int]  — erwartete Anzahl (immer 1)
          Actual   [int]  — übergebene tatsächliche Anzahl
          Message  [string] — menschenlesbare Zusammenfassung; bei Abweichung
                              werden erwartete und tatsächliche Anzahl benannt
    .EXAMPLE
        Test-MsiCount -Count 1
        # Success = $true
    .EXAMPLE
        Test-MsiCount -Count 2
        # Success = $false; Message benennt erwartet 1 / tatsächlich 2
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Count
    )

    $expected = $script:ExpectedMsiCount
    $success = ($Count -eq $expected)

    if ($success) {
        $message = "Genau $expected MSI-Installer erzeugt."
    }
    else {
        # Abweichung mit erwarteter und tatsächlicher Anzahl benennen.
        $message = "Abweichende Anzahl MSI-Installer: erwartet $expected, " +
                   "tatsächlich $Count."
    }

    return [pscustomobject]@{
        Success  = $success
        Expected = $expected
        Actual   = $Count
        Message  = $message
    }
}

Export-ModuleMember -Function Test-MsiCount

# endregion Test-MsiCount
