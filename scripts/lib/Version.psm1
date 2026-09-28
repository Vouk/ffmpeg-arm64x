<#
.SYNOPSIS
    Reinlogik-Modul für die FFmpeg-Versionsprüfung.

.DESCRIPTION
    Kapselt die pure, testbare Logik rund um das Version-Modell des Designs:

        FFmpegVersion := { major: int, minor: int, patch: int }
        Gültig für den Build gdw. major == 8   (R2.1)

    Enthält:
      - Get-FFmpegVersion : parst eine Versionszeichenkette (major.minor.patch)
                            in ein Objekt { Major, Minor, Patch, Raw }.
      - Test-FFmpegMajor8 : meldet genau bei Major == 8 Erfolg und liefert
                            andernfalls einen Fehler, der die erwartete (8) und
                            die tatsächlich aufgelöste Version nennt (R2.2).

    Das Modul ist frei von CI-/Netzwerk-/Toolchain-Aufrufen und damit lokal
    ohne Build-Umgebung testbar (Property 1, Testing Strategy).

.NOTES
    Requirements: 2.1, 2.2
    Design: Data Models -> Version-Modell; Correctness Properties -> Property 1
#>

Set-StrictMode -Version Latest

function Get-FFmpegVersion {
    <#
    .SYNOPSIS
        Parst eine FFmpeg-Versionszeichenkette in ihre Bestandteile.

    .DESCRIPTION
        Akzeptiert Versionszeichenketten der Form "major", "major.minor" oder
        "major.minor.patch" (jeweils mit nicht-negativen Ganzzahlen). Fehlende
        Minor-/Patch-Komponenten werden zu 0 aufgelöst. Ein optionales
        führendes 'v'/'V' sowie umgebende Leerzeichen werden toleriert.

        Kann die Eingabe nicht als Version geparst werden, wird ein Fehler
        (throw) mit der Roh-Eingabe ausgelöst.

    .PARAMETER Version
        Die zu parsende Versionszeichenkette, z. B. "8.0", "8.1.2", "v8".

    .OUTPUTS
        [pscustomobject] mit den Feldern Major, Minor, Patch (int) und Raw (string).

    .EXAMPLE
        Get-FFmpegVersion -Version '8.0.1'
        # Major = 8, Minor = 0, Patch = 1, Raw = '8.0.1'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Version
    )

    $raw = $Version
    if ($null -eq $raw) {
        throw "Ungültige FFmpeg-Version: <null>. Erwartet wird 'major[.minor[.patch]]'."
    }

    $trimmed = $raw.Trim()
    # Optionales führendes 'v' (z. B. "v8.0") tolerieren.
    $normalized = $trimmed -replace '^[vV]', ''

    # Genau major[.minor[.patch]] mit nicht-negativen Ganzzahlen.
    $match = [regex]::Match($normalized, '^(\d+)(?:\.(\d+))?(?:\.(\d+))?$')
    if (-not $match.Success) {
        throw "Ungültige FFmpeg-Version: '$raw'. Erwartet wird 'major[.minor[.patch]]'."
    }

    $major = [int] $match.Groups[1].Value
    $minor = if ($match.Groups[2].Success) { [int] $match.Groups[2].Value } else { 0 }
    $patch = if ($match.Groups[3].Success) { [int] $match.Groups[3].Value } else { 0 }

    return [pscustomobject]@{
        Major = $major
        Minor = $minor
        Patch = $patch
        Raw   = $raw
    }
}

function Test-FFmpegMajor8 {
    <#
    .SYNOPSIS
        Prüft, ob eine FFmpeg-Version die Major-Version 8 besitzt.

    .DESCRIPTION
        Akzeptiert die Version genau dann, wenn die geparste Major-Version
        gleich 8 ist (R2.1). Andernfalls wird ein Fehler ausgelöst, der die
        erwartete Major-Version (8) und die tatsächlich aufgelöste Version
        nennt (R2.2).

        Die Eingabe kann eine Versionszeichenkette oder ein bereits von
        Get-FFmpegVersion erzeugtes Objekt sein.

    .PARAMETER Version
        Versionszeichenkette (z. B. "8.0.1") ODER ein Objekt mit einer
        Major-Eigenschaft (Ausgabe von Get-FFmpegVersion).

    .OUTPUTS
        Bei Erfolg: das geparste [pscustomobject] mit Major/Minor/Patch/Raw.

    .EXAMPLE
        Test-FFmpegMajor8 -Version '8.0'       # Erfolg
        Test-FFmpegMajor8 -Version '7.1'       # Fehler: erwartet 8, ist 7.1
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Version
    )

    # Bereits geparstes Version-Objekt akzeptieren, sonst als String parsen.
    if ($Version -is [pscustomobject] -and ($Version.PSObject.Properties.Name -contains 'Major')) {
        $parsed = $Version
    }
    else {
        $parsed = Get-FFmpegVersion -Version ([string] $Version)
    }

    if ($parsed.Major -ne 8) {
        $actual = if ($parsed.PSObject.Properties.Name -contains 'Raw' -and $parsed.Raw) {
            $parsed.Raw
        }
        else {
            '{0}.{1}.{2}' -f $parsed.Major, $parsed.Minor, $parsed.Patch
        }
        throw "FFmpeg-Version nicht akzeptiert: erwartete Major-Version 8, tatsächlich aufgelöste Version '$actual' (Major $($parsed.Major))."
    }

    return $parsed
}

Export-ModuleMember -Function Get-FFmpegVersion, Test-FFmpegMajor8
