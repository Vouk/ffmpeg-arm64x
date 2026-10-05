<#
.SYNOPSIS
    Erzeugt aus einer Klartext-Lizenz (z. B. licenses/LICENSE.GPL.txt) eine
    sauber formatierte RTF fuer die WiX-Installer-Lizenzseite.

.DESCRIPTION
    Die urspruenglichen Lizenz-RTFs nutzten Courier New in 9pt mit harten
    Zeilenumbruechen (\line) auf 70-Spalten-Basis. In der scrollbaren,
    skalierbaren WiX-Textbox wirkt das gequetscht und doppelt umgebrochen.

    Dieser Konverter erzeugt stattdessen eine gut lesbare RTF:
      * Proportionalschrift (Segoe UI) in angenehmer Groesse.
      * Absatz-Erkennung: Leerzeilen trennen Absaetze. Innerhalb eines Absatzes
        werden hart umbrochene Zeilen zu EINER fliessenden Zeile verbunden,
        sodass die Textbox selbst umbricht (kein ragged double-wrap).
      * Zentrierte Kopfzeilen (Titelblock) und einzeln stehende Zeilen
        (z. B. nummerierte Abschnitte) bleiben eigene Absaetze.
      * Absatzabstand fuer Luft zwischen den Bloecken.
      * Korrektes RTF-Escaping von \, {, } und Nicht-ASCII (als \uN).

    Reine Textverarbeitung, kein externes Werkzeug noetig. Die Kernfunktion
    ConvertTo-LicenseRtf ist seiteneffektfrei und damit testbar.

.PARAMETER InputPath
    Pfad zur Klartext-Lizenzdatei.

.PARAMETER OutputPath
    Zielpfad der RTF-Datei.

.EXAMPLE
    ./scripts/Convert-LicenseToRtf.ps1 -InputPath licenses/LICENSE.GPL.txt `
        -OutputPath installer/license/gpl-3.0.rtf
#>
[CmdletBinding()]
param(
    [string] $InputPath,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-RtfEscaped {
    <#
    .SYNOPSIS
        Escaped einen Textabschnitt fuer RTF (reine Logik).
    .DESCRIPTION
        \, { und } werden mit Backslash maskiert. Zeichen ausserhalb von ASCII
        werden als \uN? kodiert (RTF-Unicode mit ASCII-Fallback '?'). Tabs
        werden zu \tab.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '\' { [void]$sb.Append('\\') }
            '{' { [void]$sb.Append('\{') }
            '}' { [void]$sb.Append('\}') }
            "`t" { [void]$sb.Append('\tab ') }
            default {
                $code = [int][char]$ch
                if ($code -lt 128) {
                    [void]$sb.Append($ch)
                } else {
                    # RTF-Unicode: \uN mit Ersatzzeichen '?'. N als signed 16-bit.
                    $n = if ($code -gt 32767) { $code - 65536 } else { $code }
                    [void]$sb.Append('\u' + $n + '?')
                }
            }
        }
    }
    return $sb.ToString()
}

function ConvertTo-LicenseParagraph {
    <#
    .SYNOPSIS
        Zerlegt den Klartext in Absaetze (reine Logik).
    .DESCRIPTION
        Regeln:
          * Eine oder mehrere Leerzeilen trennen Absaetze.
          * Innerhalb eines Absatzes werden Zeilen mit einem Leerzeichen zu
            einer fliessenden Zeile verbunden (Trimmen der je Zeile fuehrenden/
            folgenden Spaces, damit die 70-Spalten-Einrueckung verschwindet).
          * Eine Zeile, die stark eingerueckt/zentriert ist (viel fuehrender
            Leerraum) ODER sehr kurz ist (Ueberschrift), bildet einen eigenen,
            zentrierten bzw. eigenstaendigen Absatz und wird NICHT mit
            Nachbarzeilen verschmolzen.
    .OUTPUTS
        [pscustomobject[]] je Absatz: Text, Centered [bool].
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $lines = $Text -split "`r?`n"
    $paras = [System.Collections.Generic.List[pscustomobject]]::new()
    $buf = [System.Collections.Generic.List[string]]::new()

    function Flush {
        param([System.Collections.Generic.List[string]] $Buffer,
              [System.Collections.Generic.List[pscustomobject]] $Out)
        if ($Buffer.Count -eq 0) { return }
        $joined = ($Buffer -join ' ')
        $Out.Add([pscustomobject]@{ Text = $joined; Centered = $false })
        $Buffer.Clear()
    }

    foreach ($raw in $lines) {
        $line = $raw -replace '\s+$', ''   # trailing whitespace weg
        if ([string]::IsNullOrWhiteSpace($line)) {
            Flush -Buffer $buf -Out $paras
            continue
        }

        $leading = 0
        if ($line -match '^(\s+)') { $leading = $Matches[1].Length }
        $trimmed = $line.Trim()

        # Zentrierte Kopfzeile: deutlich eingerueckt (>= 12 Spaces) -> eigener
        # zentrierter Absatz, nicht mit Fliesstext verschmelzen.
        if ($leading -ge 12) {
            Flush -Buffer $buf -Out $paras
            $paras.Add([pscustomobject]@{ Text = $trimmed; Centered = $true })
            continue
        }

        $buf.Add($trimmed)
    }
    Flush -Buffer $buf -Out $paras

    return , ([pscustomobject[]] $paras.ToArray())
}

function ConvertTo-LicenseRtf {
    <#
    .SYNOPSIS
        Baut das vollstaendige RTF-Dokument aus Klartext (reine Logik).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $paras = ConvertTo-LicenseParagraph -Text $Text

    $sb = [System.Text.StringBuilder]::new()
    # Kopf: Segoe UI, 10pt (\fs20 = 20 halbe Punkte). Absatzabstand \sa120.
    [void]$sb.Append('{\rtf1\ansi\ansicpg1252\deff0')
    [void]$sb.Append('{\fonttbl{\f0\fswiss\fcharset0 Segoe UI;}}')
    [void]$sb.Append("`r`n")
    [void]$sb.Append('\viewkind4\uc1\f0\fs20')
    [void]$sb.Append("`r`n")

    foreach ($p in $paras) {
        $escaped = ConvertTo-RtfEscaped -Text $p.Text
        if ($p.Centered) {
            [void]$sb.Append('\pard\qc\sa120\b ' + $escaped + '\b0\par')
        } else {
            [void]$sb.Append('\pard\ql\sa120 ' + $escaped + '\par')
        }
        [void]$sb.Append("`r`n")
    }

    [void]$sb.Append('}')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Einstiegspunkt (nur bei direktem Aufruf, nicht beim Dot-Sourcing durch Tests)
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $InputPath -or -not $OutputPath) {
        throw 'InputPath und OutputPath sind erforderlich.'
    }
    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "Eingabedatei nicht gefunden: '$InputPath'."
    }
    $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $InputPath))
    $rtf = ConvertTo-LicenseRtf -Text $text
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    # RTF ist ASCII (Nicht-ASCII als \uN kodiert); ohne BOM schreiben.
    $ascii = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllText($OutputPath, $rtf, $ascii)
    Write-Host "RTF geschrieben: $OutputPath ($($rtf.Length) Zeichen)"
}
