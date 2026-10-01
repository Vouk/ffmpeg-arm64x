<#
.SYNOPSIS
    Backports fuer den FFmpeg-Quellbaum, die vor configure angewendet werden.

.DESCRIPTION
    FFmpeg 8.1.3 (und release/8.1) fehlen zwei Upstream-Fixes, die fuer einen
    MSVC-Build nach ARM64/ARM64EC noetig sind:

      1. Commit 93f653f95c "configure: enable ffnvcodec, nvenc, nvdec for
         aarch64 Windows". configure deaktiviert ffnvcodec/cuvid/nvdec/nvenc
         auf aarch64 fuer jedes target_os ausser linux. Mit --target-os=win32
         bricht configure sonst ab mit:
             ERROR: nvdec requested, but not all dependencies are satisfied:
             ffnvcodec

      2. Commit 8512161c81 "configure: Pass the .objs response file to
         makedef". compat/windows/makedef bekommt alle Objektdateien als
         Argumente. libavcodec hat ~1000 Objekte, womit die Kommandozeile die
         Windows-Grenze von 32767 Zeichen reisst; das letzte Argument kommt
         abgeschnitten an und makedef bricht ab mit:
             Object does not exist: libavc
         Der Fix reicht stattdessen die bereits fuer den Link erzeugte
         .objs-Response-Datei weiter.

    Beide Patches sind idempotent: enthaelt der Quellbaum den Fix schon (z. B.
    neuere FFmpeg-Version), bleibt die Datei unveraendert. Passt eine
    Fundstelle weder auf die alte noch auf die neue Form, wird abgebrochen --
    dann hat sich der Quellbaum geaendert und der Backport muss geprueft werden.

    Hinweis: Der library.mak-Teil ist an 8.1.3 angepasst. Upstream verschiebt
    dort einen Block, der zusaetzlich HAVE_BUILTIN_FILE kennt; das gibt es in
    8.1.3 noch nicht.

    Requirements: 5.2, 5.4 (NVENC/NVDEC), 3.1 (Shared Libraries)
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

    # --- 93f653f95c: NVIDIA auf aarch64 Windows freischalten ---------------
    $patches += [pscustomobject]@{
        Name   = '93f653f95c: NVIDIA (ffnvcodec/nvenc/nvdec) auf aarch64 Windows'
        File   = 'configure'
        Before = ConvertFrom-PatchTemplate @(
            'elif enabled_any aarch64 ppc64 && ! enabled bigendian; then',
            '    case $target_os in',
            '        linux)'
        )
        After  = ConvertFrom-PatchTemplate @(
            'elif enabled_any aarch64 ppc64 && ! enabled bigendian; then',
            '    case $target_os in',
            '        linux|mingw32*|mingw64*|win32|win64)'
        )
    }

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

    # --- 8512161c81 (d): .objs vor dem .def-Schritt erzeugen --------------
    # Zwei Aenderungen:
    #  1. In 8.1.3 steht SLIB_CREATE_DEF_CMD vor dem ifeq-Block, der die
    #     .objs-Datei schreibt. makedef braucht sie aber schon.
    #  2. Die Datei darf nicht per echo plus Umleitung entstehen: make gibt
    #     die Rezeptzeile an sh, und mit ~1000 Objekten (~35 kB) reisst
    #     schon dieser Aufruf die 32767-Zeichen-Grenze. Die Umleitung am
    #     Zeilenende fiel dabei weg, echo schrieb die Liste nach stdout und
    #     die .objs-Datei entstand nie. GNU makes eingebaute Funktion
    #     $(file ...) schreibt ohne Shell und kennt die Grenze nicht.
    #     Upstream guckt dafuer auf HAVE_BUILTIN_FILE (configure-Pruefung,
    #     die 8.1.3 nicht hat); wir pruefen .FEATURES, was dieselbe
    #     Faehigkeit meldet und ohne configure-Aenderung auskommt
    #     (GNU make >= 4.0).
    $patches += [pscustomobject]@{
        Name   = '8512161c81d: .objs via $(file) vor SLIB_CREATE_DEF_CMD'
        File   = 'ffbuild/library.mak'
        Before = ConvertFrom-PatchTemplate @(
            '<TAB>$(SLIB_CREATE_DEF_CMD)',
            'ifeq ($(RESPONSE_FILES),yes)',
            '<TAB>$(Q)echo $$(filter %.o,$$^) > $$@.objs',
            '<TAB>$$(call LINK,$$(call $(NAME)LINK_SO_ARGS) $$(LD_O) @$$@.objs $$(call $(NAME)LINK_EXTRA))'
        )
        After  = ConvertFrom-PatchTemplate @(
            'ifeq ($(RESPONSE_FILES),yes)',
            'ifneq (,$(filter file,$(.FEATURES)))',
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
