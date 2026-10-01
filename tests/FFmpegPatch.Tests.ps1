<#
    Tests fuer scripts/lib/FFmpegPatch.psm1 (Backport von FFmpeg-Commit
    93f653f95c: ffnvcodec/nvenc/nvdec auf aarch64 Windows).
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot "scripts/lib/FFmpegPatch.psm1") -Force

    # Ausschnitt aus configure von n8.1.3 (vor dem Fix), LF-Zeilenenden.
    $script:Gate813 = (@(
        "if enabled x86; then",
        "    case `$target_os in",
        "        freebsd|mingw32*|mingw64*|win32|win64|linux|cygwin*)",
        "            ;;",
        "        *)",
        "            disable ffnvcodec cuvid nvdec nvenc",
        "            ;;",
        "    esac",
        "elif enabled_any aarch64 ppc64 && ! enabled bigendian; then",
        "    case `$target_os in",
        "        linux)",
        "            ;;",
        "        *)",
        "            disable ffnvcodec cuvid nvdec nvenc",
        "            ;;",
        "    esac",
        "else",
        "    disable ffnvcodec cuvid nvdec nvenc",
        "fi",
        ""
    ) -join "`n")
    $script:FixedLine = "        linux|mingw32*|mingw64*|win32|win64)"
}

Describe "Get-PatchedFFmpegConfigure" {
    It "hebt die aarch64-Sperre fuer Windows auf (Stand n8.1.3)" {
        $r = Get-PatchedFFmpegConfigure -Text $script:Gate813
        $r.Status | Should -Be "Patched"
        ($r.Text -split "`n")[10] | Should -Be $script:FixedLine
    }

    It "aendert nur die aarch64-Zeile, nicht den x86-Zweig" {
        $old = $script:Gate813 -split "`n"
        $new = (Get-PatchedFFmpegConfigure -Text $script:Gate813).Text -split "`n"
        $new.Count | Should -Be $old.Count
        $changed = @(0..($old.Count - 1) | Where-Object { $old[$_] -ne $new[$_] })
        $changed.Count | Should -Be 1
        $changed[0] | Should -Be 10
    }

    It "laesst bereits gepatchtes configure unveraendert" {
        $once = (Get-PatchedFFmpegConfigure -Text $script:Gate813).Text
        $r = Get-PatchedFFmpegConfigure -Text $once
        $r.Status | Should -Be "AlreadyPatched"
        $r.Text | Should -BeExactly $once
    }

    It "bricht ab, wenn die Stelle fehlt" {
        { Get-PatchedFFmpegConfigure -Text "echo nothing here" } | Should -Throw -ExpectedMessage "*93f653f95c*"
    }
}
