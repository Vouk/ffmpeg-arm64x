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

Describe "Install-HwHeaders" {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repoRoot "scripts/build-deps.ps1") -Variant "gpl" -OutputDir $env:TEMP -AmfHeaderPath $env:TEMP -NvCodecHeaderPath $env:TEMP

        # Nachbau der Repo-Layouts: AMF (amf/public/include) und nv-codec-headers.
        function New-HwHeaderSources {
            param([string] $Root, [switch] $WithoutPcIn)
            $amf = Join-Path $Root "AMF/amf/public/include"
            New-Item -ItemType Directory -Force -Path (Join-Path $amf "core"), (Join-Path $amf "components") | Out-Null
            Set-Content -Path (Join-Path $amf "core/Version.h") -Value "#define AMF_VERSION_MAJOR 1"
            Set-Content -Path (Join-Path $amf "components/VideoEncoderVCE.h") -Value "// stub"
            $nvRoot = Join-Path $Root "nv-codec-headers"
            New-Item -ItemType Directory -Force -Path (Join-Path $nvRoot "include/ffnvcodec") | Out-Null
            Set-Content -Path (Join-Path $nvRoot "include/ffnvcodec/nvEncodeAPI.h") -Value "// stub"
            if (-not $WithoutPcIn) {
                Set-Content -Path (Join-Path $nvRoot "ffnvcodec.pc.in") -Value @(
                    "prefix=@@PREFIX@@",
                    "includedir=`${prefix}/include",
                    "Name: ffnvcodec",
                    "Version: 13.0.19.0",
                    "Cflags: -I`${includedir}"
                )
            }
            [pscustomobject]@{ Amf = $amf; NvInclude = (Join-Path $nvRoot "include"); Out = (Join-Path $Root "out") }
        }
    }

    It "legt AMF unter include/AMF und ffnvcodec samt .pc ab" {
        $src = New-HwHeaderSources -Root (Join-Path $TestDrive "ok")
        $prefix = Install-HwHeaders -AmfHeaderPath $src.Amf -NvCodecHeaderPath $src.NvInclude -OutputDir $src.Out

        Join-Path $prefix "include/AMF/core/Version.h" | Should -Exist
        Join-Path $prefix "include/AMF/components/VideoEncoderVCE.h" | Should -Exist
        Join-Path $prefix "include/ffnvcodec/nvEncodeAPI.h" | Should -Exist
        $pcPath = Join-Path $prefix "lib/pkgconfig/ffnvcodec.pc"
        $pcPath | Should -Exist
        $pc = Get-Content -Raw $pcPath
        $pc | Should -Not -Match "@@PREFIX@@"
        $expected = (Resolve-Path $prefix).Path.Replace([char]92, [char]47)
        $pc | Should -Match ("prefix=" + [regex]::Escape($expected))
        [System.IO.File]::ReadAllBytes($pcPath)[0] | Should -Not -Be 0xEF
    }

    It "bricht ab, wenn ffnvcodec.pc.in fehlt" {
        $src = New-HwHeaderSources -Root (Join-Path $TestDrive "nopc") -WithoutPcIn
        { Install-HwHeaders -AmfHeaderPath $src.Amf -NvCodecHeaderPath $src.NvInclude -OutputDir $src.Out } |
            Should -Throw -ExpectedMessage "*ffnvcodec.pc.in*"
    }
}
