<#
.SYNOPSIS
    Dünner PowerShell-Wrapper um FsCheck für property-basierte Tests.

.DESCRIPTION
    Kapselt das Laden der FsCheck-Assembly und stellt eine einfache
    `Invoke-Property`-Funktion bereit, mit der ein Prädikat über zufällig
    generierte Eingaben geprüft wird. Standardmäßig laufen >= 100 Iterationen,
    wie im Design gefordert (siehe Testing Strategy).

    FsCheck wird lokal unter tests/.tools/fscheck bereitgestellt (siehe
    Install-FsCheck), damit die Tests ohne globale Installation laufen.

.NOTES
    Property-Tests referenzieren ihre Design-Property über das Tag-Format
    "Feature: arm64x-ffmpeg-build, Property N" im Describe/It-Namen.
#>

Set-StrictMode -Version Latest

$script:FsCheckAssemblyLoaded = $false

function Install-FsCheck {
    <#
    .SYNOPSIS
        Stellt die FsCheck-Assembly lokal unter tests/.tools bereit und lädt sie.
    .PARAMETER Version
        FsCheck-NuGet-Version (Default 2.16.6, netstandard2.0).
    #>
    [CmdletBinding()]
    param(
        [string] $Version = '2.16.6',
        [string] $ToolsRoot = (Join-Path $PSScriptRoot '.tools')
    )

    if ($script:FsCheckAssemblyLoaded) { return }

    $fscheckDir = Join-Path $ToolsRoot 'fscheck'
    $dllPath = Join-Path $fscheckDir "FsCheck.$Version/lib/netstandard2.0/FsCheck.dll"

    if (-not (Test-Path $dllPath)) {
        New-Item -ItemType Directory -Force -Path $fscheckDir | Out-Null
        $nupkg = Join-Path $fscheckDir "fscheck.$Version.nupkg"
        $url = "https://www.nuget.org/api/v2/package/FsCheck/$Version"
        Write-Verbose "Lade FsCheck $Version von $url"
        Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing
        Expand-Archive -Path $nupkg -DestinationPath (Join-Path $fscheckDir "FsCheck.$Version") -Force
    }

    # FSharp.Core wird von FsCheck benötigt; falls nicht vorhanden, mitliefern.
    Add-Type -Path $dllPath
    $script:FsCheckAssemblyLoaded = $true
}

function Invoke-Property {
    <#
    .SYNOPSIS
        Prüft ein Prädikat über viele zufällig generierte Eingaben.
    .DESCRIPTION
        Minimaler Runner: erzeugt mit dem übergebenen Generator-Skriptblock
        Eingaben und wertet das Prädikat aus. Schlägt beim ersten Gegenbeispiel
        fehl und meldet dieses. Standardmäßig >= 100 Iterationen.
    .PARAMETER Generator
        Skriptblock ohne Parameter, der EINE zufällige Eingabe zurückgibt.
    .PARAMETER Property
        Skriptblock mit einem Parameter (die Eingabe), der $true/$false liefert.
    .PARAMETER Iterations
        Anzahl der Iterationen (Default 100, Minimum laut Design).
    .EXAMPLE
        Invoke-Property -Generator { Get-Random -Min 0 -Max 100 } -Property { param($n) $n -ge 0 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Generator,
        [Parameter(Mandatory)] [scriptblock] $Property,
        [int] $Iterations = 100
    )

    if ($Iterations -lt 100) {
        throw "Property-Tests müssen mit mindestens 100 Iterationen laufen (angefordert: $Iterations)."
    }

    for ($i = 0; $i -lt $Iterations; $i++) {
        $input = & $Generator
        $result = & $Property $input
        if (-not $result) {
            $rendered = try { $input | ConvertTo-Json -Compress -Depth 5 } catch { "$input" }
            throw "Property-Verletzung bei Iteration $($i + 1). Gegenbeispiel: $rendered"
        }
    }
}

Export-ModuleMember -Function Install-FsCheck, Invoke-Property
