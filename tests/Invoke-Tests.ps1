<#
.SYNOPSIS
    Bootstrap-Runner für die PowerShell-Tests (Pester + FsCheck).

.DESCRIPTION
    Stellt sicher, dass eine ausreichend neue Pester-Version (>= 5) lokal
    verfügbar ist, und führt anschließend alle Tests unter tests/ aus.
    Pester wird bei Bedarf in den CurrentUser-Scope installiert, ohne
    vorhandene Systemmodule zu verändern.

.PARAMETER Path
    Test-Pfad (Default: das tests/-Verzeichnis dieses Skripts).
#>
[CmdletBinding()]
param(
    [string] $Path = $PSScriptRoot,
    [string] $MinimumPesterVersion = '5.5.0'
)

$ErrorActionPreference = 'Stop'

function Ensure-Pester {
    param([string] $Minimum)
    $existing = Get-Module -ListAvailable Pester |
        Where-Object { $_.Version -ge [version]$Minimum } |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $existing) {
        Write-Host "Pester >= $Minimum nicht gefunden - installiere in CurrentUser-Scope..."
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        }
        Install-Module Pester -MinimumVersion $Minimum -Scope CurrentUser -Force -SkipPublisherCheck
    }
    Remove-Module Pester -ErrorAction SilentlyContinue
    Import-Module Pester -MinimumVersion $Minimum -Force
}

Ensure-Pester -Minimum $MinimumPesterVersion

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $Path 'TestResults/testResults.xml'

Invoke-Pester -Configuration $config
