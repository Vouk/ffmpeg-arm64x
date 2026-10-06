<#
.SYNOPSIS
    Baut die externen GPL-Encoder x264 und x265 STATISCH fuer ARM64 UND ARM64EC
    (MSVC-Cross). Nur fuer die GPL-Variante benoetigt.

.DESCRIPTION
    FFmpeg linkt x264/x265 als STATISCHE Archiv-Libs direkt in avcodec ein (kein
    DLL-Runtime). Im MERGED-ARM64X-Build landen diese .libs ueber die
    /LINKREPROFULLPATHRSP-Capture als externe Eingaben automatisch im
    ARM64X-Merge von avcodec. Es MUSS je ABI (arm64 + arm64ec) eine passende
    statische Lib existieren.

    Ergebnis-Layout je (Codec, Arch):
        <OutputDir>\<codec>\<arch>\include\...
        <OutputDir>\<codec>\<arch>\lib\{x264.lib|x265.lib, pkgconfig\*.pc}

    Build-Details (hart erarbeitet, aus der frueheren Pipeline uebernommen):
      * x264: CC=cl ./configure --enable-static --disable-shared --disable-cli
        --host=aarch64-w64-mingw32 --disable-asm --extra-cflags=-MT. Fuer
        arm64ec zusaetzlich -arm64EC / -MACHINE:arm64EC und ein config.mak-
        AR-Patch (-machine:arm64ec), sonst LNK1392.
      * x265: cmake/Ninja, ENABLE_SHARED=OFF, STATIC_LINK_CRT=ON (/MT),
        CROSS_COMPILE_ARM=ON, ASSEMBLY=OFF. Fuer arm64ec /arm64EC +
        /MACHINE:arm64EC. Lib wird auf x265.lib/libx265.lib aliasiert.
      * Statische CRT (/MT) bei beiden, passend zu FFmpegs statischer UCRT.

    Fail-fast: $ErrorActionPreference = 'Stop'.

.PARAMETER X264SourceDir
    Quellbaum von x264 (enthaelt ./configure).

.PARAMETER X265SourceDir
    Quellbaum von x265 (CMakeLists.txt i. d. R. im Unterordner 'source').

.PARAMETER OutputDir
    Wurzel fuer die gebauten Libs (<OutputDir>\<codec>\<arch>).

.PARAMETER Arch
    Zu bauende ABIs. Default: beide (arm64, arm64ec).

.PARAMETER Msys2Bash
    Pfad zur MSYS2-bash.exe (fuer x264s configure/make). Default
    'C:\msys64\usr\bin\bash.exe'.

.NOTES
    Nur GPL. Muss in der %VCVARS%-Umgebung (amd64->arm64-Cross) laufen.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $X264SourceDir,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $X265SourceDir,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputDir,
    [Parameter()][ValidateSet('arm64','arm64ec',IgnoreCase=$true)][string[]] $Arch = @('arm64','arm64ec'),
    [Parameter()][string] $Msys2Bash = 'C:\msys64\usr\bin\bash.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Msys2Path {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)
    $pp = $Path -replace '\\', '/'
    if ($pp -match '^([A-Za-z]):(/.*)?$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = if ($Matches[2]) { $Matches[2] } else { '/' }
        $pp = "/$drive$rest"
    }
    return $pp
}

function New-OutputDirectory {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Invoke-X264Build {
    <#
    .SYNOPSIS
        Baut x264 statisch via configure/make fuer eine Architektur.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourceDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][ValidateSet('arm64','arm64ec')][string] $Arch,
        [Parameter(Mandatory)][string] $Msys2Bash
    )
    New-OutputDirectory -Path $OutputDir
    $srcPosix    = ConvertTo-Msys2Path -Path $SourceDir
    $prefixPosix = ConvertTo-Msys2Path -Path $OutputDir

    $ecFlags = if ($Arch -eq 'arm64ec') { ' --extra-cflags=-arm64EC --extra-ldflags=-MACHINE:arm64EC' } else { '' }
    # Statisch + statische CRT (/MT), reiner C-Pfad (--disable-asm), kein CLI.
    $configure = "CC=cl ./configure --prefix='$prefixPosix' --enable-static --disable-shared --disable-cli " +
                 "--host=aarch64-w64-mingw32 --disable-asm --extra-cflags=-MT" + $ecFlags
    & $Msys2Bash -lc "cd '$srcPosix' && $configure" 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        $cfgLog = Join-Path $SourceDir 'config.log'
        if (Test-Path -LiteralPath $cfgLog) { Write-Host '----- x264 config.log (Tail 60) -----'; Get-Content -LiteralPath $cfgLog -Tail 60 | ForEach-Object { Write-Host $_ } }
        throw "x264 configure schlug fehl (Exit $LASTEXITCODE)."
    }
    # arm64ec: config.mak-AR-Zeile um -machine:arm64ec ergaenzen (sonst LNK1392).
    if ($Arch -eq 'arm64ec') {
        $patchAr = "cd '$srcPosix' && sed -i 's#^AR=lib.exe -nologo -out:#AR=lib.exe -nologo -machine:arm64ec -out:#' config.mak && grep -n '^AR=' config.mak"
        & $Msys2Bash -lc $patchAr 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "x264 config.mak AR-Patch schlug fehl (Exit $LASTEXITCODE)." }
    }
    & $Msys2Bash -lc "cd '$srcPosix' && make -j && make install" 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "x264 make/install schlug fehl (Exit $LASTEXITCODE)." }

    # Alias: FFmpegs MSVC-Wrapper sucht x264.lib bzw. libx264.lib.
    $libDir = Join-Path $OutputDir 'lib'
    $srcLib = $null
    foreach ($cand in @('libx264.lib','x264.lib','libx264.a')) { $cp = Join-Path $libDir $cand; if (Test-Path -LiteralPath $cp) { $srcLib = $cp; break } }
    if ($srcLib) {
        foreach ($alias in @('libx264.lib','x264.lib')) {
            $dest = Join-Path $libDir $alias
            if ([string]::Equals($dest, $srcLib, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            Copy-Item -LiteralPath $srcLib -Destination $dest -Force
        }
        Write-Host "x264 ($Arch): statische Lib -> Alias libx264.lib/x264.lib."
    } else { Write-Host "WARN: statische x264-Lib ($Arch) nicht gefunden." }
}

function Invoke-X265Build {
    <#
    .SYNOPSIS
        Baut x265 statisch via cmake/Ninja fuer eine Architektur.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourceDir,
        [Parameter(Mandatory)][string] $OutputDir,
        [Parameter(Mandatory)][ValidateSet('arm64','arm64ec')][string] $Arch
    )
    New-OutputDirectory -Path $OutputDir
    $buildDir = Join-Path $OutputDir 'cmake-build'
    $cmakeSource = Join-Path $SourceDir 'source'
    if (-not (Test-Path -LiteralPath (Join-Path $cmakeSource 'CMakeLists.txt'))) { $cmakeSource = $SourceDir }

    $cflags = if ($Arch -eq 'arm64ec') { '/arm64EC' } else { '' }
    $cmakeArgs = @(
        '-S', $cmakeSource, '-B', $buildDir, '-G', 'Ninja',
        "-DCMAKE_INSTALL_PREFIX=$OutputDir",
        '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_SYSTEM_NAME=Windows', '-DCMAKE_SYSTEM_PROCESSOR=ARM64',
        '-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl',
        '-DENABLE_SHARED=OFF', '-DENABLE_CLI=OFF', '-DENABLE_ASSEMBLY=OFF',
        '-DCROSS_COMPILE_ARM=ON', '-DSTATIC_LINK_CRT=ON'
    )
    if ($cflags) {
        $cmakeArgs += "-DCMAKE_C_FLAGS=$cflags"
        $cmakeArgs += "-DCMAKE_CXX_FLAGS=$cflags"
        $ldm = '/MACHINE:arm64EC'
        $cmakeArgs += "-DCMAKE_SHARED_LINKER_FLAGS=$ldm"
        $cmakeArgs += "-DCMAKE_EXE_LINKER_FLAGS=$ldm"
        $cmakeArgs += "-DCMAKE_STATIC_LINKER_FLAGS=$ldm"
    }
    & cmake @cmakeArgs 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "x265 cmake configure schlug fehl (Exit $LASTEXITCODE)." }
    & cmake --build $buildDir 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "x265 cmake build schlug fehl (Exit $LASTEXITCODE)." }
    & cmake --install $buildDir 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "x265 cmake install schlug fehl (Exit $LASTEXITCODE)." }

    # Alias: x265 installiert x265-static.lib; FFmpeg sucht x265.lib.
    $libDir = Join-Path $OutputDir 'lib'
    $srcLib = $null
    foreach ($cand in @('x265-static.lib','libx265-static.lib','libx265.lib','libx265.dll.lib','x265.lib')) { $cp = Join-Path $libDir $cand; if (Test-Path -LiteralPath $cp) { $srcLib = $cp; break } }
    if ($srcLib) {
        foreach ($alias in @('x265.lib','libx265.lib')) {
            $dest = Join-Path $libDir $alias
            if ([string]::Equals($dest, $srcLib, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            Copy-Item -LiteralPath $srcLib -Destination $dest -Force
        }
        Write-Host "x265 ($Arch): statische Lib -> Alias x265.lib/libx265.lib."
    } else { Write-Host "WARN: statische x265-Lib ($Arch) nicht gefunden." }
}

# ---------------------------------------------------------------------------
# Orchestrierung: x264 + x265 je Arch bauen.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Msys2Bash)) { throw "MSYS2-bash nicht gefunden: '$Msys2Bash'." }

foreach ($a in $Arch) {
    $ak = $a.ToLowerInvariant()
    Write-Host "==== x264 ($ak) ===="
    Invoke-X264Build -SourceDir $X264SourceDir -OutputDir (Join-Path (Join-Path $OutputDir 'x264') $ak) -Arch $ak -Msys2Bash $Msys2Bash
    Write-Host "==== x265 ($ak) ===="
    Invoke-X265Build -SourceDir $X265SourceDir -OutputDir (Join-Path (Join-Path $OutputDir 'x265') $ak) -Arch $ak
}
Write-Host "build-deps abgeschlossen: x264 + x265 (static) fuer $($Arch -join ', ') unter $OutputDir."
