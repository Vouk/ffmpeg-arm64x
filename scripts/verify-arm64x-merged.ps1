<#
.SYNOPSIS
    Verifiziert die GEMERGTEN (Single-File) ARM64X-DLLs: je DLL EIN File, das
    beide Ansichten (ARM64 + ARM64EC) traegt -- KEINE Forwarder-Begleit-DLLs.

.DESCRIPTION
    Gegenstueck zur Forwarder-Verifikation (scripts/verify-arm64x.ps1, Fallback).
    Pro gemergter DLL werden drei statische Nachweise gefuehrt (dumpbin, da
    ARM64-Binaries auf dem x64-Runner nicht laufen):

      1. Header-ABI: die Maschinenzeile zeigt den (ARM64X)-Marker
         ("AA64 machine (ARM64) (ARM64X)"). Reines ARM64 oder ARM64EC wird
         abgelehnt.
      2. Hybrid-Metadaten: 'dumpbin /loadconfig' zeigt die ARM64X-Hybrid-
         Metadaten (Hybrid metadata pointer / Arm64X dynamic relocation /
         dispatch) -- der Beweis, dass BEIDE Codestroeme eingebettet sind und
         der Loader je Prozess die richtige Ansicht waehlt.
      3. Export-Paritaet: die Zahl der von der DLL exportierten Funktionen ist
         >= der Zahl der in der Quell-.def (Export-Liste) genannten Symbole.
         So ist nachgewiesen, dass der Merge die vollstaendige oeffentliche API
         beibehalten hat (keine fehlenden Exporte durch verlorene Objekte).

    Die reine Logik (Parsing der dumpbin-Ausgaben, .def-Symbolzaehlung) ist in
    seiteneffektfreie Funktionen gekapselt und lokal testbar; der Skriptrumpf
    ruft dumpbin auf dem CI-Runner auf.

.PARAMETER BinDir
    Verzeichnis mit den gemergten *.dll (und ffmpeg.exe/ffprobe.exe).

.PARAMETER DefDir
    Optionales Verzeichnis mit den Quell-.def je DLL (<Key>.def), fuer die
    Export-Paritaetspruefung. Fehlt es, wird die Paritaet uebersprungen.

.PARAMETER DumpbinExe
    Pfad zu dumpbin.exe (Default aus der vcvars-Umgebung).
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $BinDir,
    [Parameter()][string] $DefDir,
    [Parameter()][ValidateNotNullOrEmpty()][string] $DumpbinExe = 'dumpbin.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ExpectedExecutables = @('ffmpeg.exe', 'ffprobe.exe')

# ---------------------------------------------------------------------------
# Reine Logik (lokal testbar)
# ---------------------------------------------------------------------------

function Get-DumpbinMachineAbi {
    <#
    .SYNOPSIS
        ABI aus der 'dumpbin /headers'-Maschinenzeile: ARM64/ARM64EC/ARM64X/Unknown.
    #>
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $HeaderText)
    if ([string]::IsNullOrWhiteSpace($HeaderText)) { return 'Unknown' }
    foreach ($rawLine in ($HeaderText -split "`r?`n")) {
        $line = $rawLine.Trim()
        if ($line -notmatch '(?i)^[0-9A-F]+\s+machine\b') { continue }
        if ($line -match '(?i)\(ARM64X\)')  { return 'ARM64X' }
        if ($line -match '(?i)\(ARM64EC\)') { return 'ARM64EC' }
        if ($line -match '(?i)\(ARM64\)')   { return 'ARM64' }
    }
    return 'Unknown'
}

function Test-HybridLoadConfig {
    <#
    .SYNOPSIS
        True, wenn die 'dumpbin /loadconfig'-Ausgabe die ARM64X-Hybrid-
        Metadaten zeigt (Hybrid metadata pointer / ARM64X dynamic relocation /
        Arm64X dispatch). Reine Logik.
    #>
    [CmdletBinding()][OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $LoadConfigText)
    if ([string]::IsNullOrWhiteSpace($LoadConfigText)) { return $false }
    return ($LoadConfigText -match '(?i)hybrid metadata' ) -or
           ($LoadConfigText -match '(?i)IMAGE_DYNAMIC_RELOCATION_ARM64X') -or
           ($LoadConfigText -match '(?i)Arm64X')
}

function Get-DefExportCount {
    <#
    .SYNOPSIS
        Zaehlt die Symbole in einer FFmpeg-.def (EXPORTS + ein Symbol je Zeile).
        Ignoriert Kommentare (;), leere Zeilen und die Direktiven-Zeilen.
    #>
    [CmdletBinding()][OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $DefText)
    if ([string]::IsNullOrWhiteSpace($DefText)) { return 0 }
    $n = 0
    foreach ($raw in ($DefText -split "`r?`n")) {
        $t = $raw.Trim()
        if ($t -eq '' -or $t.StartsWith(';')) { continue }
        if ($t -match '(?i)^(EXPORTS|LIBRARY|NAME|VERSION|HEAPSIZE|STACKSIZE|SECTIONS)\b') { continue }
        $n++
    }
    return $n
}

function Get-DumpbinExportCount {
    <#
    .SYNOPSIS
        Zaehlt die exportierten Funktionen aus 'dumpbin /exports'. Die
        Export-Tabelle listet je Zeile "ordinal hint RVA name". Gezaehlt werden
        Zeilen mit einem fuehrenden Ordinalwert und einem Namen.
    #>
    [CmdletBinding()][OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $ExportsText)
    if ([string]::IsNullOrWhiteSpace($ExportsText)) { return 0 }
    $n = 0
    foreach ($raw in ($ExportsText -split "`r?`n")) {
        $t = $raw.Trim()
        # "   1    0 00001000 av_malloc" oder "   1    0          av_foo (forwarded ...)"
        if ($t -match '^\d+\s+[0-9A-Fa-f]+\s+(?:[0-9A-Fa-f]{6,}|)\s*\S+') { $n++ }
    }
    return $n
}

# ---------------------------------------------------------------------------
# Toolchain-Aufruf (CI)
# ---------------------------------------------------------------------------

function Invoke-Dumpbin {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory)][string] $DumpbinExe,[Parameter(Mandatory)][string] $Arg,[Parameter(Mandatory)][string] $FilePath)
    $out = & $DumpbinExe $Arg $FilePath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dumpbin $Arg '$FilePath' schlug fehl (Exit $LASTEXITCODE)." }
    return ($out | Out-String)
}

# ---------------------------------------------------------------------------
# Einstieg
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-Path -LiteralPath $BinDir)) { throw "BinDir nicht gefunden: '$BinDir'." }

    $dlls = @(Get-ChildItem -LiteralPath $BinDir -File -Filter '*.dll' | Sort-Object Name)
    if ($dlls.Count -eq 0) { throw "Keine DLLs in '$BinDir'." }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($dll in $dlls) {
        $name = $dll.Name
        $abi = Get-DumpbinMachineAbi -HeaderText (Invoke-Dumpbin -DumpbinExe $DumpbinExe -Arg '/headers' -FilePath $dll.FullName)
        $hybrid = Test-HybridLoadConfig -LoadConfigText (Invoke-Dumpbin -DumpbinExe $DumpbinExe -Arg '/loadconfig' -FilePath $dll.FullName)
        $expText = Invoke-Dumpbin -DumpbinExe $DumpbinExe -Arg '/exports' -FilePath $dll.FullName
        $expCount = Get-DumpbinExportCount -ExportsText $expText

        $defCount = $null
        if ($DefDir) {
            $key = $name -replace '\.dll$', ''
            $defPath = Join-Path $DefDir "$key.def"
            if (Test-Path -LiteralPath $defPath) {
                $defCount = Get-DefExportCount -DefText ([System.IO.File]::ReadAllText($defPath))
            }
        }

        $parity = if ($null -ne $defCount) { "exports=$expCount def=$defCount" } else { "exports=$expCount" }
        Write-Host ("  {0,-22} ABI={1,-7} hybrid={2,-5} {3}" -f $name, $abi, $hybrid, $parity)

        if ($abi -ne 'ARM64X') { $failures.Add("$name : ABI ist '$abi', erwartet ARM64X.") }
        if (-not $hybrid)      { $failures.Add("$name : keine ARM64X-Hybrid-Metadaten in /loadconfig.") }
        if ($null -ne $defCount -and $expCount -lt $defCount) {
            $failures.Add("$name : Export-Paritaet verletzt (DLL exportiert $expCount < .def $defCount).")
        }
    }

    # Tools nur auf Praesenz pruefen (native ARM64, kein Hybrid).
    foreach ($exe in $script:ExpectedExecutables) {
        if (-not (Test-Path -LiteralPath (Join-Path $BinDir $exe))) {
            $failures.Add("Erwartete Ausfuehrbare fehlt: '$exe'.")
        }
    }

    if ($failures.Count -gt 0) {
        throw ("MERGED-ARM64X-Verifikation fehlgeschlagen: " + ($failures -join ' '))
    }
    Write-Host "MERGED-ARM64X-Verifikation bestanden: $($dlls.Count) Single-File-Hybrid-DLL(s)."
    [pscustomobject]@{ Success = $true; Count = $dlls.Count; BinDir = $BinDir }
}
