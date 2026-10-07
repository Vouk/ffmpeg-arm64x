<#
    Tests fuer scripts/lib/FFmpegPatch.psm1.

    Die Fixtures sind Ausschnitte aus FFmpeg n8.1.3 (LF; Tabs in library.mak
    als echte Tabs). Gedeckt ist der verbliebene Backport:
      * 8512161c81  makedef bekommt die .objs-Response-Datei, und die Datei
                    wird per make-eigenem $(file ...) geschrieben
    (Der fruehere NVIDIA-aarch64-Patch 93f653f95c entfiel mit AMF/NVENC/NVDEC.)
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

        $T = $script:TAB
        $lib = @(
            "all-`$(CONFIG_STATIC): `$(SUBDIR)`$(LIBNAME)  `$(SUBDIR)lib`$(FULLNAME).pc",
            "all-`$(CONFIG_SHARED): `$(SUBDIR)`$(SLIBNAME) `$(SUBDIR)lib`$(FULLNAME).pc",
            "",
            "LIBOBJS := `$(OBJS) `$(SHLIBOBJS) `$(STLIBOBJS) `$(SUBDIR)%.h.o `$(TESTOBJS)",
            "",
            "`$(SUBDIR)`$(LIBNAME): `$(OBJS) `$(STLIBOBJS)",
            "$T`$(RM) `$@",
            "ifeq (`$(RESPONSE_FILES),yes)",
            "$T`$(Q)echo `$^ > `$@.objs",
            "$T`$(AR) `$(ARFLAGS) `$(AR_O) @`$@.objs",
            "else",
            "$T`$(AR) `$(ARFLAGS) `$(AR_O) `$^",
            "endif",
            "$T`$(RANLIB) `$@",
            "",
            "`$(SUBDIR)`$(SLIBNAME_WITH_MAJOR): `$(OBJS) `$(SHLIBOBJS) `$(SUBDIR)lib`$(NAME).ver",
            "$T`$(SLIB_CREATE_DEF_CMD)",
            "ifeq (`$(RESPONSE_FILES),yes)",
            "$T`$(Q)echo `$`$(filter %.o,`$`$^) > `$`$@.objs",
            "$T`$`$(call LINK,`$`$(call `$(NAME)LINK_SO_ARGS) `$`$(LD_O) @`$`$@.objs `$`$(call `$(NAME)LINK_EXTRA))",
            "else",
            "$T`$`$(call LINK,`$`$(call `$(NAME)LINK_SO_ARGS) `$`$(LD_O) `$`$(filter %.o,`$`$^) `$`$(call `$(NAME)LINK_EXTRA))",
            "endif",
            "$T`$(SLIB_EXTRA_CMD)",
            ""
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $root "ffbuild/library.mak"), $lib)

        return $root
    }

    function Get-Patched { param([string] $Root, [string] $RelPath) [System.IO.File]::ReadAllText((Join-Path $Root $RelPath)) }
}

Describe "Get-PatchedText" {
    It "meldet AlreadyPatched, wenn der Fix schon drin ist" {
        (Get-PatchedText -Text "b" -Before "a" -After "b" -Name "t").Status | Should -Be "AlreadyPatched"
    }

    It "bricht ab, wenn die Fundstelle fehlt" {
        { Get-PatchedText -Text "nichts" -Before "a" -After "b" -Name "t" } | Should -Throw -ExpectedMessage "*Backport*"
    }

    It "bricht ab, wenn die Fundstelle nicht so oft vorkommt wie erwartet" {
        { Get-PatchedText -Text "a" -Before "a" -After "b" -Name "t" -Occurrence 2 } | Should -Throw -ExpectedMessage "*nicht eindeutig*"
    }
}

Describe "Invoke-FFmpegSourcePatches" {
    It "wendet alle sechs Patches auf einen n8.1.3-Baum an" {
        $res = Invoke-FFmpegSourcePatches -SourceDir (New-FFmpegTree)
        $res.Count | Should -Be 6
        @($res | Where-Object Status -eq "Patched").Count | Should -Be 6
    }

    It "ist idempotent" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $before = @{}
        foreach ($f in "configure", "compat/windows/makedef", "ffbuild/library.mak") { $before[$f] = Get-Patched $root $f }
        $res = Invoke-FFmpegSourcePatches -SourceDir $root
        @($res | Where-Object Status -eq "AlreadyPatched").Count | Should -Be 6
        foreach ($f in $before.Keys) { Get-Patched $root $f | Should -BeExactly $before[$f] }
    }

    It "ersetzt OBJS in beiden SLIB_CREATE_DEF_CMD-Zweigen" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = Get-Patched $root "configure"
        ([regex]::Matches($t, [regex]::Escape('makedef $(SUBDIR)lib$(NAME).ver $(SLIB_CREATE_DEF_INPUTS)'))).Count | Should -Be 2
        $t | Should -Not -Match ([regex]::Escape('makedef $(SUBDIR)lib$(NAME).ver $(OBJS)'))
    }

    It "schreibt SLIB_CREATE_DEF_INPUTS in den config.mak-Heredoc" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = Get-Patched $root "configure"
        $t | Should -Match ([regex]::Escape('SLIB_CREATE_DEF_INPUTS=@\$\$@.objs'))
        $t | Should -Match ([regex]::Escape('ifeq (\$(RESPONSE_FILES),yes)'))
    }

    It "laesst makedef ein @response-Argument passieren" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = Get-Patched $root "compat/windows/makedef"
        $t | Should -Match ([regex]::Escape('object="${object#@}"'))
        $t.IndexOf('object="${object#@}"') | Should -BeLessThan $t.IndexOf('! -f "$object"')
    }

    It "erkennt HAVE_BUILTIN_FILE ueber MAKE_VERSION, nicht ueber .FEATURES" {
        # .FEATURES fuehrt "file" nicht auf; eine Pruefung darauf waere immer
        # falsch und wuerde still auf die kaputte echo-Variante zurueckfallen.
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = Get-Patched $root "ffbuild/library.mak"
        $t | Should -Match ([regex]::Escape('ifeq (4.0,$(firstword $(sort 4.0 $(MAKE_VERSION))))'))
        $t | Should -Match ([regex]::Escape('HAVE_BUILTIN_FILE := yes'))
        $t | Should -Match ([regex]::Escape('HAVE_BUILTIN_FILE := no'))
        $t | Should -Not -Match ([regex]::Escape('.FEATURES'))
        # Die Erkennung muss vor ihrer ersten Verwendung stehen.
        $t.IndexOf('HAVE_BUILTIN_FILE := yes') | Should -BeLessThan $t.IndexOf('ifeq ($(HAVE_BUILTIN_FILE),yes)')
    }

    It "schreibt die Shared-Lib-Response-Datei per file-Funktion vor dem .def-Schritt" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = Get-Patched $root "ffbuild/library.mak"
        $t | Should -Match ([regex]::Escape('$$(file >$$@.objs,$$(filter %.o,$$^))'))
        $t.IndexOf('$$(file >$$@.objs') | Should -BeLessThan $t.IndexOf('$(SLIB_CREATE_DEF_CMD)')
        # Tab am Rezeptanfang muss erhalten bleiben.
        $t | Should -Match ([regex]::Escape("$($script:TAB)`$(SLIB_CREATE_DEF_CMD)"))
    }

    It "schreibt die Static-Lib-Response-Datei per file-Funktion" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = Get-Patched $root "ffbuild/library.mak"
        $t | Should -Match ([regex]::Escape('$(file >$@.objs,$^)'))
    }

    It "behaelt die echo-Variante als Fallback fuer make < 4.0" {
        $root = New-FFmpegTree
        Invoke-FFmpegSourcePatches -SourceDir $root | Out-Null
        $t = Get-Patched $root "ffbuild/library.mak"
        $t | Should -Match ([regex]::Escape('$(Q)echo $$(filter %.o,$$^) > $$@.objs'))
        $t | Should -Match ([regex]::Escape('$(Q)echo $^ > $@.objs'))
    }

    It "bricht ab, wenn eine Datei fehlt" {
        $root = New-FFmpegTree
        Remove-Item (Join-Path $root "ffbuild/library.mak")
        { Invoke-FFmpegSourcePatches -SourceDir $root } | Should -Throw -ExpectedMessage "*Datei fehlt*"
    }
}
