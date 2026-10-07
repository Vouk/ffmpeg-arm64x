<#
.SYNOPSIS
    Backports fuer den FFmpeg-Quellbaum, die vor configure angewendet werden.

.DESCRIPTION
    FFmpeg 8.1.3 (und release/8.1) fehlt ein Upstream-Fix, der fuer einen
    MSVC-Build der Shared Libraries nach ARM64/ARM64EC noetig ist:

      1. Commit 8512161c81 "configure: Pass the .objs response file to
         makedef". Zwei Symptome derselben Ursache, der Windows-Grenze von
         32767 Zeichen pro Kommandozeile:
           - compat/windows/makedef bekam alle ~1000 Objekte von libavcodec
             als Argumente; das letzte kam abgeschnitten an:
                 Object does not exist: libavc
           - die Response-Datei wurde per "echo ... > datei" erzeugt; auch
             diese Zeile reisst die Grenze, die Umleitung am Ende fiel weg,
             echo schrieb nach stdout und die Datei entstand nie:
                 Object does not exist: libavcodec/avcodec-62.dll.objs
             Deshalb schreibt make die Datei mit der eingebauten Funktion
             $(file ...), die ohne Shell arbeitet.

    Alle Patches sind idempotent: enthaelt der Quellbaum den Fix schon (z. B.
    neuere FFmpeg-Version), bleibt die Datei unveraendert. Passt eine
    Fundstelle weder auf die alte noch auf die neue Form, wird abgebrochen --
    dann hat sich der Quellbaum geaendert und der Backport muss geprueft werden.

    Bezug: Shared Libraries (DLL + Import-.lib). Keine Hardware-Encoder.
#>

Set-StrictMode -Version Latest

function ConvertFrom-PatchTemplate {
    <#
    .SYNOPSIS
        Baut aus Zeilen einen Textblock mit LF; <TAB> wird zu einem echten Tab.
    .DESCRIPTION
        Tabs sind in Makefiles bedeutungstragend, deshalb werden sie im
        Patch-Text explizit als <TAB> geschrieben und erst hier ersetzt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line
    )

    return (($Line -join "`n") -replace '<TAB>', "`t")
}

function Get-FFmpegSourcePatch {
    <#
    .SYNOPSIS
        Liefert die anzuwendenden Patches (Name, Datei, Vorher, Nachher).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    $patches = @()

    # (Der fruehere NVIDIA-aarch64-Patch 93f653f95c entfiel mit AMF/NVENC/NVDEC.)

    # --- 8512161c81 (a): makedef nimmt $(SLIB_CREATE_DEF_INPUTS) ----------
    # Kommt in configure zweimal vor (mingw32- und win32-Zweig).
    $patches += [pscustomobject]@{
        Name       = '8512161c81a: SLIB_CREATE_DEF_CMD nutzt Response-Datei'
        File       = 'configure'
        Before     = 'makedef $(SUBDIR)lib$(NAME).ver $(OBJS) > $$(@:$(SLIBSUF)=.def)'
        After      = 'makedef $(SUBDIR)lib$(NAME).ver $(SLIB_CREATE_DEF_INPUTS) > $$(@:$(SLIBSUF)=.def)'
        Occurrence = 2
    }

    # --- 8512161c81 (b): SLIB_CREATE_DEF_INPUTS in config.mak schreiben ---
    # Unquoted Heredoc, daher muessen literale $ als \$ geschrieben werden.
    $patches += [pscustomobject]@{
        Name   = '8512161c81b: SLIB_CREATE_DEF_INPUTS in config.mak'
        File   = 'configure'
        Before = ConvertFrom-PatchTemplate @(
            'SLIB_CREATE_DEF_CMD=${SLIB_CREATE_DEF_CMD}',
            'SLIB_EXTRA_CMD=${SLIB_EXTRA_CMD}'
        )
        After  = ConvertFrom-PatchTemplate @(
            'SLIB_CREATE_DEF_CMD=${SLIB_CREATE_DEF_CMD}',
            'ifeq (\$(RESPONSE_FILES),yes)',
            'SLIB_CREATE_DEF_INPUTS=@\$\$@.objs',
            'else',
            'SLIB_CREATE_DEF_INPUTS=\$(OBJS)',
            'endif',
            'SLIB_EXTRA_CMD=${SLIB_EXTRA_CMD}'
        )
    }

    # --- 8512161c81 (c): makedef toleriert ein @response-Argument ---------
    $patches += [pscustomobject]@{
        Name   = '8512161c81c: makedef akzeptiert @response-Datei'
        File   = 'compat/windows/makedef'
        Before = ConvertFrom-PatchTemplate @(
            'for object in "$@"; do',
            '    if [ ! -f "$object" ]; then'
        )
        After  = ConvertFrom-PatchTemplate @(
            'for object in "$@"; do',
            '    case "$object" in',
            '    @*)',
            '        object="${object#@}"',
            '        ;;',
            '    esac',
            '    if [ ! -f "$object" ]; then'
        )
    }

    # --- 8512161c81 (d1): HAVE_BUILTIN_FILE erkennen ----------------------
    # Wortgleich mit Upstream. Die Pruefung nutzt die lexikalische Sortierung:
    # steht 4.0 vor $(MAKE_VERSION), ist make mindestens 4.0 und kennt damit
    # die eingebaute Funktion $(file ...). .FEATURES fuehrt "file" NICHT auf,
    # taugt also nicht zur Erkennung.
    $patches += [pscustomobject]@{
        Name   = '8512161c81d1: HAVE_BUILTIN_FILE (make >= 4.0) erkennen'
        File   = 'ffbuild/library.mak'
        Before = ConvertFrom-PatchTemplate @(
            'all-$(CONFIG_SHARED): $(SUBDIR)$(SLIBNAME) $(SUBDIR)lib$(FULLNAME).pc',
            '',
            'LIBOBJS := $(OBJS) $(SHLIBOBJS) $(STLIBOBJS) $(SUBDIR)%.h.o $(TESTOBJS)'
        )
        After  = ConvertFrom-PatchTemplate @(
            'all-$(CONFIG_SHARED): $(SUBDIR)$(SLIBNAME) $(SUBDIR)lib$(FULLNAME).pc',
            '',
            '# Make <4.0 does not support the built-in file function;',
            '# versions that do support it should use it, as it''s',
            '# faster and isn''t bound by command line length limits.',
            'ifeq (4.0,$(firstword $(sort 4.0 $(MAKE_VERSION))))',
            'HAVE_BUILTIN_FILE := yes',
            'else',
            'HAVE_BUILTIN_FILE := no',
            'endif',
            '',
            'LIBOBJS := $(OBJS) $(SHLIBOBJS) $(STLIBOBJS) $(SUBDIR)%.h.o $(TESTOBJS)'
        )
    }

    # --- 8512161c81 (d2): statische Lib schreibt .objs ohne Shell ---------
    # Greift nur mit --enable-static; wir bauen --disable-static. Trotzdem
    # mitgepatcht, damit die Grenze dort nicht spaeter zuschlaegt.
    $patches += [pscustomobject]@{
        Name   = '8512161c81d2: statische Lib schreibt .objs via $(file)'
        File   = 'ffbuild/library.mak'
        Before = ConvertFrom-PatchTemplate @(
            'ifeq ($(RESPONSE_FILES),yes)',
            '<TAB>$(Q)echo $^ > $@.objs',
            '<TAB>$(AR) $(ARFLAGS) $(AR_O) @$@.objs'
        )
        After  = ConvertFrom-PatchTemplate @(
            'ifeq ($(RESPONSE_FILES),yes)',
            'ifeq ($(HAVE_BUILTIN_FILE),yes)',
            '<TAB>$(file >$@.objs,$^)',
            'else',
            '<TAB>$(Q)echo $^ > $@.objs',
            'endif',
            '<TAB>$(AR) $(ARFLAGS) $(AR_O) @$@.objs'
        )
    }

    # --- 8512161c81 (d3): Shared-Lib: .objs via $(file), vor dem .def-Schritt
    # Zwei Aenderungen in einem Block:
    #  * .objs wird vor SLIB_CREATE_DEF_CMD erzeugt, weil makedef sie braucht.
    #  * geschrieben wird per $(file ...) statt per echo-Umleitung.
    $patches += [pscustomobject]@{
        Name   = '8512161c81d3: Shared-Lib schreibt .objs via $(file) vor .def'
        File   = 'ffbuild/library.mak'
        Before = ConvertFrom-PatchTemplate @(
            '<TAB>$(SLIB_CREATE_DEF_CMD)',
            'ifeq ($(RESPONSE_FILES),yes)',
            '<TAB>$(Q)echo $$(filter %.o,$$^) > $$@.objs',
            '<TAB>$$(call LINK,$$(call $(NAME)LINK_SO_ARGS) $$(LD_O) @$$@.objs $$(call $(NAME)LINK_EXTRA))'
        )
        After  = ConvertFrom-PatchTemplate @(
            'ifeq ($(RESPONSE_FILES),yes)',
            'ifeq ($(HAVE_BUILTIN_FILE),yes)',
            '<TAB>$$(file >$$@.objs,$$(filter %.o,$$^))',
            'else',
            '<TAB>$(Q)echo $$(filter %.o,$$^) > $$@.objs',
            'endif',
            'endif',
            '<TAB>$(SLIB_CREATE_DEF_CMD)',
            'ifeq ($(RESPONSE_FILES),yes)',
            '<TAB>$$(call LINK,$$(call $(NAME)LINK_SO_ARGS) $$(LD_O) @$$@.objs $$(call $(NAME)LINK_EXTRA))'
        )
    }

    return [pscustomobject[]] $patches
}

function Get-PatchedText {
    <#
    .SYNOPSIS
        Wendet einen Patch auf einen Text an (reine Logik, ohne Dateizugriff).
    .OUTPUTS
        [pscustomobject] mit Status ("Patched" / "AlreadyPatched") und Text.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [string] $Before,
        [Parameter(Mandatory)] [string] $After,
        [Parameter(Mandatory)] [string] $Name,
        [int] $Occurrence = 1
    )

    $found = [regex]::Matches($Text, [regex]::Escape($Before)).Count
    if ($found -eq $Occurrence) {
        return [pscustomobject]@{
            Status = 'Patched'
            Text   = $Text.Replace($Before, $After)
        }
    }

    $already = [regex]::Matches($Text, [regex]::Escape($After)).Count
    if ($found -eq 0 -and $already -ge $Occurrence) {
        return [pscustomobject]@{ Status = 'AlreadyPatched'; Text = $Text }
    }

    throw ("FFmpeg-Backport '$Name': Fundstelle nicht eindeutig " +
           "(alte Form: $found, erwartet: $Occurrence; neue Form: $already). " +
           'Der FFmpeg-Quellbaum hat sich geaendert; Backport pruefen.')
}

function Invoke-FFmpegSourcePatches {
    <#
    .SYNOPSIS
        Wendet alle Backports auf den FFmpeg-Quellbaum an.
    .DESCRIPTION
        Schreibt eine Datei nur, wenn sich ihr Inhalt aendert. Zeilenenden
        bleiben LF, es wird kein BOM geschrieben (die Dateien sind
        Shell-Skripte bzw. Makefiles).
    .OUTPUTS
        [pscustomobject[]] je Patch mit Name, File und Status.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)] [string] $SourceDir)

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $results = @()

    foreach ($patch in (Get-FFmpegSourcePatch)) {
        $path = Join-Path $SourceDir $patch.File
        if (-not (Test-Path -LiteralPath $path)) {
            throw "FFmpeg-Backport '$($patch.Name)': Datei fehlt: '$path'."
        }

        $occurrence = if ($patch.PSObject.Properties.Name -contains 'Occurrence') { $patch.Occurrence } else { 1 }
        $original = [System.IO.File]::ReadAllText($path)
        $result = Get-PatchedText -Text $original -Before $patch.Before `
            -After $patch.After -Name $patch.Name -Occurrence $occurrence

        if ($result.Status -eq 'Patched') {
            [System.IO.File]::WriteAllText($path, $result.Text, $utf8NoBom)
        }

        $results += [pscustomobject]@{
            Name   = $patch.Name
            File   = $patch.File
            Status = $result.Status
        }
    }

    return [pscustomobject[]] $results
}

Export-ModuleMember -Function ConvertFrom-PatchTemplate, Get-FFmpegSourcePatch, Get-PatchedText, Invoke-FFmpegSourcePatches
