<#
    Tests fuer scripts/lib/FFmpegPatch.psm1.

    Die Fixtures sind Ausschnitte aus FFmpeg n8.1.3 (LF, Tabs in library.mak
    als echte Tabs). Gedeckt sind beide Backports:
      * 93f653f95c  NVIDIA auf aarch64 Windows
      * 8512161c81  makedef bekommt die .objs-Response-Datei
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts/lib/FFmpegPatch.psm1") -Force

    $script:TAB = [char]9

    function New-FFmpegTree {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Force -Path (Join-Path $root "compat/windows") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $root "ffbuild") | Out-Null

        $configure = @(
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
            "fi",
            "        SLIB_CREATE_DEF_CMD='EXTERN_PREFIX=`"`$(EXTERN_PREFIX)`" AR=`"`$(AR_CMD)`" NM=`"`$(NM_CMD)`" `$(SRC_PATH)/compat/windows/makedef `$(SUBDIR)lib`$(NAME).ver `$(OBJS) > `$`$(@:`$(SLIBSUF)=.def)'",
            "        SLIB_CREATE_DEF_CMD='LDFLAGS=`"`$(LDFLAGS)`" EXTERN_PREFIX=`"`$(EXTERN_PREFIX)`" `$(SRC_PATH)/compat/windows/makedef `$(SUBDIR)lib`$(NAME).ver `$(OBJS) > `$`$(@:`$(SLIBSUF)=.def)'",
            "SLIBNAME_WITH_MAJOR=`${SLIBNAME_WITH_MAJOR}",
            "SLIB_CREATE_DEF_CMD=`${SLIB_CREATE_DEF_CMD}",
            "SLIB_EXTRA_CMD=`${SLIB_EXTRA_CMD}",
            ""
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $root "configure"), $configure)

        $makedef = @(
            "vscript=`$1",
            "shift",
            "",
            "for object in `"`$@`"; do",
            "    if [ ! -f `"`$object`" ]; then",
            "        echo `"Object does not exist: `${object}`" >&2",
            "        exit 1",
            "    fi",
            "done",
            ""
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $root "compat/windows/makedef"), $makedef)

        $lib = @(
            "`$(SUBDIR)`$(SLIBNAME_WITH_MAJOR): `$(OBJS) `$(SHLIBOBJS) `$(SUBDIR)lib`$(NAME).ver",
            "$($script:TAB)`$(SLIB_CREATE_DEF_CMD)",
            "ifeq (`$(RESPONSE_FILES),yes)",
            "$($script:TAB)`$(Q)echo `$`$(filter %.o,`$`$^) > `$`$@.objs",
            "$($script:TAB)`$`$(call LINK,`$`$(call `$(NAME)LINK_SO_ARGS) `$`$(LD_O) @`$`$@.objs `$`$(call `$(NAME)LINK_EXTRA))",
            "else",
            "$($script:TAB)`$`$(call LINK,`$`$(call `$(NAME)LINK_SO_ARGS) `$`$(LD_O) `$`$(filter %.o,`$`$^) `$`$(call `$(NAME)LINK_EXTRA))",
            "endif",
            "$($script:TAB)`$(SLIB_EXTRA_CMD)",
            ""
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $root "ffbuild/library.mak"), $lib)

        return $root
    }
}

Describe "Get-PatchedText" {
    It "meldet AlreadyPatched, wenn der Fix schon drin ist" {
        $r = Get-PatchedText -Text "b" -Before "a" -After "b" -Name "t"
        $r.Status | Should -Be "AlreadyPatched"
    }

    It "bricht ab, wenn die Fundstelle fehlt" {
        { Get-PatchedText -Text "nichts" -Before "a" -After "b" -Name "t" } |
            Should -Throw -ExpectedMessage "*Backport*"
    }

    It "bricht ab, wenn die Fundstelle nicht so oft vorkommt wie erwartet" {
        { Get-PatchedText -Text "a" -Before "a" -After "b" -Name "t" -Occurrence 2 } |
            Should -Throw -ExpectedMessage "*nicht eindeutig*"
    }
}

Describe "Invoke-FFmpegSourcePatches" {
    It "wendet alle fuenf Patches auf einen n8.1.3-Baum an" {
        $root = New-FFmpegTree
        $res = Invoke-FFmpegSourcePatches -SourceDir $root
        $res.Count | Should -Be 5
        @($res | Where-Object Status -eq "Patched").Count | Should -Be 5
    }

    It "ist idempotent" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $after = [System.IO.File]::ReadAllText((Join-Path $root "configure"))
        $res = Invoke-FFmpegSourcePatches -SourceDir $root
        @($res | Where-Object Status -eq "AlreadyPatched").Count | Should -Be 5
        [System.IO.File]::ReadAllText((Join-Path $root "configure")) | Should -BeExactly $after
    }

    It "schaltet NVIDIA fuer win32 frei, ohne den x86-Zweig anzutasten" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = [System.IO.File]::ReadAllText((Join-Path $root "configure"))
        $t | Should -Match ([regex]::Escape("        linux|mingw32*|mingw64*|win32|win64)"))
        ([regex]::Matches($t, [regex]::Escape("freebsd|mingw32*|mingw64*|win32|win64|linux|cygwin*)"))).Count | Should -Be 1
    }

    It "ersetzt `$(OBJS) in beiden SLIB_CREATE_DEF_CMD-Zweigen" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = [System.IO.File]::ReadAllText((Join-Path $root "configure"))
        ([regex]::Matches($t, [regex]::Escape('makedef $(SUBDIR)lib$(NAME).ver $(SLIB_CREATE_DEF_INPUTS)'))).Count | Should -Be 2
        $t | Should -Not -Match ([regex]::Escape('makedef $(SUBDIR)lib$(NAME).ver $(OBJS)'))
    }

    It "schreibt SLIB_CREATE_DEF_INPUTS in den config.mak-Heredoc" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = [System.IO.File]::ReadAllText((Join-Path $root "configure"))
        $t | Should -Match ([regex]::Escape('SLIB_CREATE_DEF_INPUTS=@\$\$@.objs'))
        $t | Should -Match ([regex]::Escape('ifeq (\$(RESPONSE_FILES),yes)'))
    }

    It "laesst makedef ein @response-Argument passieren" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = [System.IO.File]::ReadAllText((Join-Path $root "compat/windows/makedef"))
        $t | Should -Match ([regex]::Escape('object="${object#@}"'))
        # Der @-Strip muss VOR der Existenzpruefung stehen.
        $t.IndexOf('object="${object#@}"') | Should -BeLessThan $t.IndexOf('! -f "$object"')
    }

    It "erzeugt die .objs-Datei vor SLIB_CREATE_DEF_CMD" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = [System.IO.File]::ReadAllText((Join-Path $root "ffbuild/library.mak"))
        $t.IndexOf('.objs') | Should -BeLessThan $t.IndexOf('$(SLIB_CREATE_DEF_CMD)')
        # Tabs in den Rezeptzeilen muessen erhalten bleiben.
        $t | Should -Match ([regex]::Escape("$($script:TAB)`$(SLIB_CREATE_DEF_CMD)"))
    }

    It "schreibt .objs mit make-eigenem `$(file), nicht per echo-Umleitung" {
        # Mit ~1000 Objekten reisst echo plus Umleitung die Kommandozeilen-
        # Grenze; `$(file ...) schreibt ohne Shell.
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = [System.IO.File]::ReadAllText((Join-Path $root "ffbuild/library.mak"))
        $t | Should -Match ([regex]::Escape('$$(file >$$@.objs,$$(filter %.o,$$^))'))
        $t | Should -Match ([regex]::Escape('ifneq (,$(filter file,$(.FEATURES)))'))
        # Der $(file)-Zweig muss vor dem echo-Fallback stehen.
        $t.IndexOf('$$(file >') | Should -BeLessThan $t.IndexOf('echo $$(filter')
    }

    It "bricht ab, wenn eine Datei fehlt" {
        $root = New-FFmpegTree
        Remove-Item (Join-Path $root "ffbuild/library.mak")
        { Invoke-FFmpegSourcePatches -SourceDir $root } | Should -Throw -ExpectedMessage "*Datei fehlt*"
    }
}
