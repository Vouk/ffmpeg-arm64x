<#
.SYNOPSIS
    Orchestriert den vollstaendigen MERGED-ARM64X-Build EINER Variante
    (lgpl|gpl): beide Ansichten bauen (mit /LINKREPROFULLPATHRSP-Capture),
    die 7 Kern-DLLs zu Single-File-ARM64X mergen, verifizieren,
    Faehigkeiten pruefen und die MSI bauen.

.DESCRIPTION
    Kapselt die je Variante identische Schrittfolge, damit der Workflow sie
    zweimal (lgpl, gpl) aufrufen kann, ohne ~150 Zeilen YAML zu duplizieren.
    MUSS in der %VCVARS%-Umgebung (amd64->arm64-Cross) laufen; ruft cmd/bash
    ueber die vorhandenen Skripte auf.

    Schritte:
      1. build-ffmpeg.ps1 -Arch arm64   (eigener Quellbaum, LinkReproDir)
      2. build-ffmpeg.ps1 -Arch arm64ec (eigener Quellbaum, LinkReproDir)
      3. merge-arm64x-merged.ps1  -> 7 Single-File-ARM64X-DLLs + Tools
      4. verify-arm64x-merged.ps1 -> Header/Hybrid/Export-Paritaet
      5. verify-capabilities.ps1  -> je Variante x264/x265; keine HW-Encoder
      6. candle/light             -> eine MSI (ffmpeg-<ver>-<variant>-arm64x.msi)

.PARAMETER Variant            'lgpl' oder 'gpl'.
.PARAMETER Arm64SourceDir     FFmpeg-Quellbaum fuer die arm64-Ansicht.
.PARAMETER Arm64ecSourceDir   FFmpeg-Quellbaum fuer die arm64ec-Ansicht.
.PARAMETER OutputDir          Arbeits-/Ausgabewurzel dieser Variante.
.PARAMETER LinkReproDir       Kurzer Pfad fuer die rsp-Dateien dieser Variante.
.PARAMETER DepsDir            (gpl) Wurzel der statischen x264/x265-Libs.
.PARAMETER DistDir            Zielordner fuer die MSI.
.PARAMETER ProductVersion     Anzeigeversion (MSI-Dateiname + candle -dProductVersion).
.PARAMETER InstallerDir       Pfad zu installer/ (Product.wxs + license + PathAction).
.PARAMETER WixBin             Pfad zu den WiX-Tools (heat/candle/light).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('lgpl','gpl',IgnoreCase=$true)][string] $Variant,
    [Parameter(Mandatory)][string] $Arm64SourceDir,
    [Parameter(Mandatory)][string] $Arm64ecSourceDir,
    [Parameter(Mandatory)][string] $OutputDir,
    [Parameter(Mandatory)][string] $LinkReproDir,
    [Parameter()][string] $DepsDir,
    [Parameter(Mandatory)][string] $DistDir,
    [Parameter(Mandatory)][string] $ProductVersion,
    [Parameter(Mandatory)][string] $InstallerDir,
    [Parameter(Mandatory)][string] $WixBin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$variant   = $Variant.ToLowerInvariant()
$ffOut     = Join-Path $OutputDir 'ffmpeg'          # <out>\ffmpeg\<arch>, \arm64x\bin
New-Item -ItemType Directory -Force -Path $OutputDir, $LinkReproDir, $DistDir | Out-Null

function Invoke-Checked {
    param([Parameter(Mandatory)][scriptblock] $Action, [Parameter(Mandatory)][string] $What)
    Write-Host "==== $What ($variant) ===="
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$What ($variant) fehlgeschlagen (Exit $LASTEXITCODE)." }
}

# --- 1/2: beide Ansichten bauen (mit Capture) -------------------------------
$depsArg = @()
if ($variant -eq 'gpl') {
    if (-not $DepsDir) { throw "GPL: -DepsDir (x264/x265) ist erforderlich." }
    $depsArg = @('-DepsDir', $DepsDir)
}

Invoke-Checked -What 'Build arm64' -Action {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'build-ffmpeg.ps1') `
        -Arch arm64 -Variant $variant -SourceDir $Arm64SourceDir -OutputDir $ffOut `
        -LinkReproDir $LinkReproDir @depsArg
}
Invoke-Checked -What 'Build arm64ec' -Action {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'build-ffmpeg.ps1') `
        -Arch arm64ec -Variant $variant -SourceDir $Arm64ecSourceDir -OutputDir $ffOut `
        -LinkReproDir $LinkReproDir @depsArg
}

# --- 3: True-Merge der 7 Kern-DLLs ------------------------------------------
$arm64xBin = Join-Path $ffOut 'arm64x\bin'
Invoke-Checked -What 'Merge ARM64X' -Action {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'merge-arm64x-merged.ps1') `
        -LinkReproDir $LinkReproDir -OutputDir $arm64xBin `
        -Arm64BinDir (Join-Path $ffOut 'arm64\bin') -Arm64SourceDir $Arm64SourceDir
}

# --- 4: ARM64X-Single-File-Verifikation -------------------------------------
Invoke-Checked -What 'Verify ARM64X' -Action {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'verify-arm64x-merged.ps1') `
        -BinDir $arm64xBin
}

# --- 5: Faehigkeitspruefung (statisch aus config.h) -------------------------
Invoke-Checked -What 'Verify capabilities' -Action {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'verify-capabilities.ps1') `
        -ConfigPath (Join-Path $ffOut 'arm64') -Variant $variant
}

# --- 6: MSI bauen (heat harvest + candle + light) ---------------------------
$heat   = Join-Path $WixBin 'heat.exe'
$candle = Join-Path $WixBin 'candle.exe'
$light  = Join-Path $WixBin 'light.exe'
foreach ($t in @($heat,$candle,$light)) { if (-not (Test-Path -LiteralPath $t)) { throw "WiX-Werkzeug fehlt: '$t'." } }

$variantUpper = $variant.ToUpperInvariant()
$productWxs = Join-Path $InstallerDir 'Product.wxs'
$work = Join-Path $OutputDir 'wix'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$ffmpegFilesWxs = Join-Path $work 'FfmpegFiles.wxs'
$outMsi = Join-Path $DistDir ("ffmpeg-$ProductVersion-$variant-arm64x.msi")

Invoke-Checked -What 'heat harvest' -Action {
    & $heat dir $arm64xBin -cg FfmpegFiles -dr INSTALLDIR -srd -sfrag `
        -var var.BinSourceDir -gg -scom -sreg -out $ffmpegFilesWxs
}
Invoke-Checked -What 'candle' -Action {
    & $candle -arch x64 "-dVariant=$variantUpper" "-dProductVersion=$ProductVersion" `
        "-dBinSourceDir=$arm64xBin" -ext WixUtilExtension -out ($work + '\') `
        $productWxs $ffmpegFilesWxs
}
Invoke-Checked -What 'light' -Action {
    & $light (Join-Path $work 'Product.wixobj') (Join-Path $work 'FfmpegFiles.wixobj') `
        -ext WixUIExtension -ext WixUtilExtension -b $InstallerDir -o $outMsi
}
if (-not (Test-Path -LiteralPath $outMsi)) { throw "MSI ($variant) nicht erzeugt: '$outMsi'." }
Write-Host "MSI ($variant) erzeugt: $outMsi"
