<#
.SYNOPSIS
    EXPERIMENT-ONLY: Fuegt in FFmpegs ffbuild/library.mak eine durable Kopie der
    <dll>.objs-Response-Liste ein ("$@.objs" -> "$@.objs.keep"), damit die
    exakte, von FFmpeg gelinkte Objektliste nach dem Build erhalten bleibt.

.DESCRIPTION
    make loescht die per $(file ...) erzeugte <dll>.objs direkt nach dem Link
    (sie ist ein Nebenprodukt, kein Target -- .SECONDARY greift NICHT). Diese
    Funktion haengt im Shared-Lib-Rezept unmittelbar VOR der Zeile
    "$(SLIB_CREATE_DEF_CMD)" eine Tab-Rezeptzeile an, die $@.objs nach
    $@.objs.keep kopiert (zu diesem Zeitpunkt existiert $@.objs bereits, da der
    d3-Backport sie vor dem .def-Schritt schreibt).

    Veraendert NUR den FFmpeg-Quellbaum im CI-Lauf -- nicht das produktive
    scripts/lib/FFmpegPatch.psm1.

.PARAMETER SourceDir
    FFmpeg-Quellbaum (enthaelt ffbuild/library.mak).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mak = Join-Path $SourceDir 'ffbuild/library.mak'
if (-not (Test-Path -LiteralPath $mak)) {
    throw "ffbuild/library.mak nicht gefunden: '$mak'."
}

$text = [System.IO.File]::ReadAllText($mak)
$tab = [char]9

# Idempotent: schon gepatcht?
if ($text -match [regex]::Escape('$@.objs.keep')) {
    Write-Host "patch-keep-objs: bereits vorhanden -- nichts zu tun."
    return
}

# Zeilen durchgehen; vor der ERSTEN Zeile, die '$(SLIB_CREATE_DEF_CMD)'
# enthaelt, die Keep-Kopie einfuegen (gleiche Tab-Einrueckung, mit $(Q)).
$lines = $text -split "`n"
$out = [System.Collections.Generic.List[string]]::new()
$inserted = $false
foreach ($line in $lines) {
    if (-not $inserted -and $line -match '\$\(SLIB_CREATE_DEF_CMD\)') {
        # $@.objs -> $@.objs.keep. '|| true', damit ein evtl. fehlendes
        # .objs (anderer Rezeptpfad) den Build nicht abbricht.
        $out.Add("$tab`$(Q)cp `$@.objs `$@.objs.keep 2>/dev/null || true")
        $inserted = $true
    }
    $out.Add($line)
}

if (-not $inserted) {
    throw "patch-keep-objs: Zeile mit '`$(SLIB_CREATE_DEF_CMD)' nicht gefunden -- library.mak-Struktur geaendert?"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($mak, ($out -join "`n"), $utf8NoBom)
Write-Host "patch-keep-objs: Keep-Kopie vor `$(SLIB_CREATE_DEF_CMD) eingefuegt."
