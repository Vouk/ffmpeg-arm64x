<#
.SYNOPSIS
    Backports fuer den FFmpeg-Quellbaum, die vor configure angewendet werden.

.DESCRIPTION
    FFmpeg bis einschliesslich n8.1.3 (ebenso release/8.1) deaktiviert in
    configure ffnvcodec, cuvid, nvdec und nvenc auf aarch64 fuer jedes
    target_os ausser linux. Mit --target-os=win32 und --enable-nvenc/-nvdec
    bricht configure deshalb ab mit:
        ERROR: nvdec requested, but not all dependencies are satisfied: ffnvcodec

    Upstream hat genau diese Sperre mit Commit 93f653f95c ("configure: enable
    ffnvcodec, nvenc, nvdec for aarch64 Windows", 2026-06-01) aufgehoben. Der
    Commit ist in keinem 8.1.x-Tag enthalten; dieses Modul spielt die eine
    geaenderte Zeile nach. Enthaelt der Quellbaum den Fix bereits (neuere
    FFmpeg-Version), bleibt configure unveraendert.

    Requirements: 5.2, 5.4
#>

Set-StrictMode -Version Latest

# Kontext der aarch64-Sperre exakt wie in configure (LF-Zeilenenden).
$script:Arm64NvidiaGateBefore = "elif enabled_any aarch64 ppc64 && ! enabled bigendian; then`n    case `$target_os in`n        linux)`n"
$script:Arm64NvidiaGateAfter  = "elif enabled_any aarch64 ppc64 && ! enabled bigendian; then`n    case `$target_os in`n        linux|mingw32*|mingw64*|win32|win64)`n"

function Get-PatchedFFmpegConfigure {
    <#
    .SYNOPSIS
        Wendet den aarch64-Windows-NVIDIA-Backport auf den Text von configure
        an (reine Logik, ohne Dateizugriff).
    .OUTPUTS
        [pscustomobject] mit Status ("Patched" oder "AlreadyPatched") und Text.
        Wirft, wenn die Stelle weder in alter noch in neuer Form vorkommt.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $before = [regex]::Matches($Text, [regex]::Escape($script:Arm64NvidiaGateBefore)).Count
    if ($before -eq 1) {
        return [pscustomobject]@{
            Status = "Patched"
            Text   = $Text.Replace($script:Arm64NvidiaGateBefore, $script:Arm64NvidiaGateAfter)
        }
    }
    if ($before -eq 0 -and $Text.Contains($script:Arm64NvidiaGateAfter)) {
        return [pscustomobject]@{ Status = "AlreadyPatched"; Text = $Text }
    }
    throw ("FFmpeg-configure: aarch64-NVIDIA-Sperre nicht eindeutig gefunden " +
           "(Treffer alte Form: $before). configure hat sich geaendert; " +
           "Backport von Commit 93f653f95c pruefen.")
}

function Invoke-FFmpegConfigurePatch {
    <#
    .SYNOPSIS
        Wendet Get-PatchedFFmpegConfigure auf <SourceDir>/configure an und
        schreibt die Datei nur bei Aenderung zurueck (LF bleibt, kein BOM).
    .OUTPUTS
        [string] "Patched" oder "AlreadyPatched".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $SourceDir)

    $path = Join-Path $SourceDir "configure"
    $result = Get-PatchedFFmpegConfigure -Text ([System.IO.File]::ReadAllText($path))
    if ($result.Status -eq "Patched") {
        [System.IO.File]::WriteAllText($path, $result.Text, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $result.Status
}

Export-ModuleMember -Function Get-PatchedFFmpegConfigure, Invoke-FFmpegConfigurePatch
