<#
    Regressionstest fuer den Import-Lib-Alias in Invoke-X265Build
    (scripts/build-deps.ps1).

    Hintergrund: Installiert x265 bereits libx265.lib, darf der Alias-Schritt
    die Datei nicht auf sich selbst kopieren. Genau das liess einen CI-Lauf mit
    "Cannot overwrite the item ... with itself" abbrechen. cmake wird durch eine
    Stub-Funktion ersetzt, sodass nur die Alias-Logik nach dem Install laeuft.
#>

Describe "Invoke-X265Build: Import-Lib-Alias" {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repoRoot "scripts/build-deps.ps1") -Variant "gpl" -OutputDir $env:TEMP -AmfHeaderPath $env:TEMP -NvCodecHeaderPath $env:TEMP

        # Stub fuer das echte cmake: kein Build, nur Exit-Code 0.
        function cmake { $global:LASTEXITCODE = 0 }

        function New-X265Fixture {
            param([string] $InstalledLibName)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
            $src = Join-Path $root "src"
            $out = Join-Path $root "out"
            New-Item -ItemType Directory -Force -Path (Join-Path $src "source") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $out "lib") | Out-Null
            Set-Content -Path (Join-Path $src "source/CMakeLists.txt") -Value "stub"
            Set-Content -Path (Join-Path $out "lib/$InstalledLibName") -Value "implib"
            [pscustomobject]@{
                Codec       = "x265"
                BuildSystem = "cmake"
                SourceDir   = $src
                Arch        = "arm64"
                OutputDir   = $out
            }
        }
    }

    It "legt x265.lib an, wenn x265 <Installed> installiert hat" -ForEach @(
        @{ Installed = "libx265.lib" }
        @{ Installed = "libx265.dll.lib" }
        @{ Installed = "x265.lib" }
    ) {
        $ctx = New-X265Fixture -InstalledLibName $Installed
        { Invoke-X265Build -Ctx $ctx } | Should -Not -Throw
        Join-Path $ctx.OutputDir "lib/x265.lib" | Should -Exist
        Join-Path $ctx.OutputDir "lib/libx265.lib" | Should -Exist
    }
}
