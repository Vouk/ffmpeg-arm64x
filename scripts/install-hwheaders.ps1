<#
.SYNOPSIS
    Legt die Hardware-Encoding-Header (AMD AMF + NVIDIA nv-codec-headers) so ab,
    wie FFmpegs `configure` sie fuer --enable-amf/--enable-nvenc/--enable-nvdec
    sucht.

.DESCRIPTION
    FFmpeg bindet die Hardware-Encoder header-only ein (die eigentlichen
    Treiber-DLLs werden erst zur Laufzeit geladen). configure findet die Header
    so:
      * AMF: FFmpeg inkludiert <AMF/core/Version.h>. Im AMF-Repo liegen die
        Header unter amf/public/include. Ziel: <OutputDir>\include\AMF.
      * nv-codec-headers: FFmpeg findet ffnvcodec NUR ueber pkg-config. Ziel:
        <OutputDir>\include\ffnvcodec plus
        <OutputDir>\lib\pkgconfig\ffnvcodec.pc aus ffnvcodec.pc.in (Prefix in
        gemischter Form D:/..., wie es das Repo per cygpath -m erzeugt).

    Das Ergebnis-Layout entspricht exakt dem, was build-ffmpeg.ps1 ueber
    -HwHeadersDir erwartet.

    Fail-fast: `$ErrorActionPreference = 'Stop'`; fehlt ein erwarteter Header,
    bricht das Skript mit Benennung ab, ohne Teil-Artefakte zu hinterlassen.

.PARAMETER AmfHeaderPath
    Pfad zur AMF-Header-Wurzel (das Verzeichnis amf/public/include im AMF-Repo).

.PARAMETER NvCodecHeaderPath
    Pfad zur nv-codec-headers-include-Wurzel (das Verzeichnis `include` im
    nv-codec-headers-Repo, enthaelt den Unterordner ffnvcodec).

.PARAMETER OutputDir
    Zielverzeichnis (HwHeadersDir). Darunter entstehen include\ und
    lib\pkgconfig\.

.OUTPUTS
    [string] Der Ausgabepfad (== OutputDir).

.EXAMPLE
    ./scripts/install-hwheaders.ps1 `
        -AmfHeaderPath C:\src\AMF\amf\public\include `
        -NvCodecHeaderPath C:\src\nv-codec-headers\include `
        -OutputDir C:\out\hwheaders
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AmfHeaderPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $NvCodecHeaderPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Install-HwHeaders {
    <#
    .SYNOPSIS
        Legt AMF- und nv-codec-Header ab, wie FFmpegs configure sie sucht.
    .OUTPUTS
        [string] Der Ausgabepfad.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $AmfHeaderPath,
        [Parameter(Mandatory)] [string] $NvCodecHeaderPath,
        [Parameter(Mandatory)] [string] $OutputDir
    )

    $include = Join-Path $OutputDir 'include'
    $amfDest = Join-Path $include 'AMF'
    $nvDest  = Join-Path $include 'ffnvcodec'
    $pcDir   = Join-Path (Join-Path $OutputDir 'lib') 'pkgconfig'
    foreach ($d in @($amfDest, $nvDest, $pcDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    # AMF: Inhalt von amf/public/include nach include/AMF.
    if (-not (Test-Path -LiteralPath $AmfHeaderPath)) {
        throw "AMF-Header-Pfad nicht gefunden: '$AmfHeaderPath'."
    }
    Copy-Item -Path (Join-Path $AmfHeaderPath '*') -Destination $amfDest -Recurse -Force
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $amfDest 'core') 'Version.h'))) {
        throw "AMF-Header unvollstaendig: core/Version.h fehlt unter '$AmfHeaderPath'."
    }

    # nv-codec-headers: include/ffnvcodec/*.h nach include/ffnvcodec.
    $nvSrc = Join-Path $NvCodecHeaderPath 'ffnvcodec'
    if (-not (Test-Path -LiteralPath (Join-Path $nvSrc 'nvEncodeAPI.h'))) {
        throw "nv-codec-headers unvollstaendig: ffnvcodec/nvEncodeAPI.h fehlt unter '$NvCodecHeaderPath'."
    }
    Copy-Item -Path (Join-Path $nvSrc '*') -Destination $nvDest -Recurse -Force

    # ffnvcodec.pc aus ffnvcodec.pc.in (liegt in der Repo-Wurzel, also im
    # Elternordner von include). Ohne .pc meldet configure fuer nvdec/nvenc
    # "not all dependencies are satisfied: ffnvcodec".
    $pcIn = Join-Path (Split-Path -Parent $NvCodecHeaderPath) 'ffnvcodec.pc.in'
    if (-not (Test-Path -LiteralPath $pcIn)) {
        throw "ffnvcodec.pc.in nicht gefunden: '$pcIn'."
    }
    $prefixMixed = (Resolve-Path -LiteralPath $OutputDir).Path.Replace('\', '/')
    $pc = [System.IO.File]::ReadAllText($pcIn).Replace('@@PREFIX@@', $prefixMixed)
    [System.IO.File]::WriteAllText(
        (Join-Path $pcDir 'ffnvcodec.pc'),
        $pc,
        (New-Object System.Text.UTF8Encoding($false)))

    return $OutputDir
}

# Einstiegspunkt: nur ausfuehren, wenn direkt aufgerufen (nicht beim
# Dot-Sourcing durch Tests, die nur die reine Logik pruefen wollen).
if ($MyInvocation.InvocationName -ne '.') {
    $prefix = Install-HwHeaders -AmfHeaderPath $AmfHeaderPath `
        -NvCodecHeaderPath $NvCodecHeaderPath -OutputDir $OutputDir
    Write-Host "Hardware-Header abgelegt: $prefix"
    $prefix
}
