<#
.SYNOPSIS
    Reinlogik zur Validierung des Installationspfads (Install_Path).

.DESCRIPTION
    Kapselt die pure, seiteneffektfreie Logik hinter Requirement 9 des Specs
    "arm64x-ffmpeg-build". Der MSI-Installer erlaubt dem Nutzer, den
    Installationspfad zu ändern (Standard C:\Program Files\FFmpeg 8). Ein Pfad
    ist genau dann gültig, wenn seine Länge zwischen 1 und 260 Zeichen liegt und
    er keine unzulässigen Zeichen enthält. Wird ein Pfad abgelehnt, bleibt der
    zuletzt gültige Pfad unverändert erhalten und der Ablehnungsgrund wird
    benannt.

    Diese Logik ist bewusst frei von WiX-/Win32-/UI-Aufrufen, damit sie lokal
    und property-basiert (Property 5) testbar bleibt.

.NOTES
    Design-Bezug: Correctness Property 5 (Installationspfad-Validierung).
    Requirements: 9.2, 9.4.
#>

Set-StrictMode -Version Latest

# Untere und obere Längengrenze eines gültigen Installationspfads (R9.2).
$script:MinInstallPathLength = 1
$script:MaxInstallPathLength = 260

<#
    Unzulässige Zeichen in einem Installationspfad.

    Erlaubt bleiben die Bestandteile eines vollständigen Windows-Pfads, also
    Laufwerksbuchstabe + Doppelpunkt (C:) und Backslash/Slash als Trenner.
    Abgelehnt werden die klassischen Windows-Pfad-Metazeichen sowie
    Steuerzeichen (U+0000..U+001F), die in Dateisystempfaden nicht zulässig sind.
#>
$script:InvalidPathCharacters = @('<', '>', '"', '|', '?', '*')

function Test-InstallPath {
    <#
    .SYNOPSIS
        Validiert einen vorgeschlagenen Installationspfad.

    .DESCRIPTION
        Prüft den Kandidatenpfad gegen die Regeln aus Requirement 9:
          * Länge 1..260 Zeichen,
          * keine unzulässigen Zeichen.
        Bei Erfolg wird der Kandidat zum neuen gültigen Pfad. Bei Ablehnung
        bleibt der zuvor gültige Pfad (LastValidPath) unverändert und der
        Ablehnungsgrund wird benannt.

    .PARAMETER Path
        Der vom Nutzer vorgeschlagene (Kandidaten-)Installationspfad.

    .PARAMETER LastValidPath
        Der zuletzt als gültig bestätigte Installationspfad. Wird bei einer
        Ablehnung unverändert als EffectivePath zurückgegeben (R9.4).

    .OUTPUTS
        [pscustomobject] mit den Feldern:
          IsValid       [bool]    - ob der Kandidatenpfad akzeptiert wurde
          Reason        [string]  - Ablehnungsgrund ($null bei Erfolg)
          EffectivePath [string]  - der weiterhin gültige Pfad:
                                     der Kandidat bei Erfolg, sonst LastValidPath

    .EXAMPLE
        Test-InstallPath -Path 'C:\Program Files\FFmpeg 8' -LastValidPath 'C:\FFmpeg'
        # IsValid = $true, EffectivePath = 'C:\Program Files\FFmpeg 8'

    .EXAMPLE
        Test-InstallPath -Path '' -LastValidPath 'C:\FFmpeg'
        # IsValid = $false, Reason = 'Der Pfad darf nicht leer sein ...',
        # EffectivePath = 'C:\FFmpeg'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Path,

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $LastValidPath
    )

    # $null wird von [string] auf '' normalisiert; beides als "leer" behandeln.
    $candidate = if ($null -eq $Path) { '' } else { $Path }

    $reason = $null

    if ($candidate.Length -lt $script:MinInstallPathLength) {
        $reason = "Der Pfad darf nicht leer sein; er muss mindestens $($script:MinInstallPathLength) Zeichen lang sein."
    }
    elseif ($candidate.Length -gt $script:MaxInstallPathLength) {
        $reason = "Der Pfad ist mit $($candidate.Length) Zeichen zu lang; erlaubt sind höchstens $($script:MaxInstallPathLength) Zeichen."
    }
    else {
        $foundInvalid = @(Get-InvalidPathCharacter -Path $candidate)
        if ($foundInvalid.Count -gt 0) {
            $rendered = ($foundInvalid | ForEach-Object { Format-InvalidCharacter -Character $_ }) -join ', '
            $reason = "Der Pfad enthält unzulässige Zeichen: $rendered."
        }
    }

    if ($null -eq $reason) {
        return [pscustomobject]@{
            IsValid       = $true
            Reason        = $null
            EffectivePath = $candidate
        }
    }

    return [pscustomobject]@{
        IsValid       = $false
        Reason        = $reason
        EffectivePath = $LastValidPath
    }
}

function Get-InvalidPathCharacter {
    <#
    .SYNOPSIS
        Liefert die im Pfad enthaltenen unzulässigen Zeichen (dedupliziert).

    .DESCRIPTION
        Findet sowohl die explizit verbotenen Metazeichen (< > " | ? *) als auch
        Steuerzeichen (U+0000..U+001F). Reine Hilfsfunktion für Test-InstallPath.
    #>
    [CmdletBinding()]
    [OutputType([char[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path
    )

    $seen = New-Object 'System.Collections.Generic.List[char]'
    foreach ($ch in $Path.ToCharArray()) {
        $isInvalid = ($script:InvalidPathCharacters -contains $ch) -or ([int][char]$ch -lt 32)
        if ($isInvalid -and (-not $seen.Contains($ch))) {
            $seen.Add($ch)
        }
    }
    return $seen.ToArray()
}

function Format-InvalidCharacter {
    <#
    .SYNOPSIS
        Bereitet ein unzulässiges Zeichen für die Fehlermeldung lesbar auf.

    .DESCRIPTION
        Druckbare Zeichen werden in Anführungszeichen gesetzt; Steuerzeichen
        werden als U+XXXX dargestellt, damit die Meldung eindeutig bleibt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [char] $Character
    )

    $code = [int][char]$Character
    if ($code -lt 32) {
        return ('U+{0:X4}' -f $code)
    }
    return "'$Character'"
}

Export-ModuleMember -Function Test-InstallPath, Get-InvalidPathCharacter
