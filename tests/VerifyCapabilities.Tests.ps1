<#
    Unit-/Beispieltests für die reine Parsing- und Assertion-Logik von
    scripts/verify-capabilities.ps1 (Task 9.4).

    Die echte ffmpeg.exe existiert nur auf dem CI-Runner. Diese Tests speisen
    daher REPRÄSENTATIVE, erfasste ffmpeg-Ausgaben (-encoders/-decoders/
    -hwaccels) in die reine Funktion Test-FFmpegCapabilities und prüfen die
    je Variante erwarteten Regeln (present/absent):

      - GPL  : libx264/libx265 vorhanden, dav1d/AV1 vorhanden, AMF+NVENC/NVDEC.
      - LGPL : libx264/libx265 ABWESEND, dav1d/AV1 vorhanden, AMF+NVENC/NVDEC.

    Requirements: 6.1, 6.2, 6.3, 6.5, 5.1, 5.2, 5.3, 5.4
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    # Reine Logik per Dot-Sourcing laden, ohne den Skript-Rumpf auszuführen
    # (der Rumpf prüft $MyInvocation.InvocationName -ne '.').
    . (Join-Path $script:RepoRoot 'scripts/verify-capabilities.ps1') `
        -FFmpegPath 'unused' -Variant 'gpl'

    # --- Repräsentative erfasste ffmpeg-Ausgaben --------------------------

    # -encoders: GPL-Variante (mit libx264/libx265 + AMF + NVENC).
    $script:EncodersGpl = @'
Encoders:
 V..... = Video
 A..... = Audio
 S..... = Subtitle
 .F.... = Frame-level multithreading
 ..S... = Slice-level multithreading
 ...X.. = Codec is experimental
 ....B. = Supports draw_horiz_band
 .....D = Supports direct rendering method 1
 ------
 V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC (codec h264)
 V....D libx265              libx265 H.265 / HEVC (codec hevc)
 V....D h264_amf             AMD AMF H.264 Encoder (codec h264)
 V....D hevc_amf             AMD AMF HEVC encoder (codec hevc)
 V....D av1_amf              AMD AMF AV1 encoder (codec av1)
 V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
 V....D hevc_nvenc           NVIDIA NVENC hevc encoder (codec hevc)
 A..... aac                  AAC (Advanced Audio Coding)
'@

    # -encoders: LGPL-Variante (OHNE libx264/libx265, aber AMF + NVENC).
    $script:EncodersLgpl = @'
Encoders:
 V..... = Video
 A..... = Audio
 ------
 V....D h264_amf             AMD AMF H.264 Encoder (codec h264)
 V....D hevc_amf             AMD AMF HEVC encoder (codec hevc)
 V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
 V....D hevc_nvenc           NVIDIA NVENC hevc encoder (codec hevc)
 A..... aac                  AAC (Advanced Audio Coding)
'@

    # -decoders: enthält den dav1d-basierten AV1-Decoder (beide Varianten).
    $script:DecodersWithDav1d = @'
Decoders:
 V..... = Video
 A..... = Audio
 ------
 V....D libdav1d             dav1d AV1 decoder by VideoLAN (codec av1)
 V....D h264                 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10
 A..... aac                  AAC (Advanced Audio Coding)
'@

    # -decoders: OHNE dav1d/AV1 (negativer Fall).
    $script:DecodersNoAv1 = @'
Decoders:
 V..... = Video
 ------
 V....D h264                 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10
 A..... aac                  AAC (Advanced Audio Coding)
'@

    # -hwaccels: mit CUDA/NVDEC (beide Varianten).
    $script:HwaccelsWithCuda = @'
Hardware acceleration methods:
d3d11va
dxva2
cuda
'@

    # -hwaccels: OHNE cuda/nvdec (negativer Fall).
    $script:HwaccelsNoNvdec = @'
Hardware acceleration methods:
d3d11va
dxva2
'@
}

Describe 'Get-FFmpegListedNames (Parser)' {
    It 'extrahiert Codec-Namen erst nach der ------ Trennlinie' {
        $names = Get-FFmpegListedNames -Text $script:EncodersGpl -Kind 'list'
        # Legende/Kopf ("Video", "Audio", Flag-Zeilen) darf nicht erscheinen.
        $names | Should -Contain 'libx264'
        $names | Should -Contain 'h264_amf'
        $names | Should -Not -Contain 'Video'
        $names | Should -Not -Contain '='
    }

    It 'parst hwaccels-Methoden ohne die Kopfzeile' {
        $names = Get-FFmpegListedNames -Text $script:HwaccelsWithCuda -Kind 'hwaccels'
        $names | Should -Contain 'cuda'
        $names | Should -Contain 'd3d11va'
        $names | Should -Not -Contain 'Hardware acceleration methods:'
    }

    It 'liefert eine leere Menge für leeren Text' {
        (Get-FFmpegListedNames -Text '' -Kind 'list').Count | Should -Be 0
    }
}

Describe 'Test-FFmpegCapabilities - GPL-Variante' {
    It 'besteht bei vorhandenen libx264/libx265 + dav1d + AMF + NVENC/NVDEC' {
        $r = Test-FFmpegCapabilities `
            -EncodersText $script:EncodersGpl `
            -DecodersText $script:DecodersWithDav1d `
            -HwaccelsText $script:HwaccelsWithCuda `
            -Variant 'gpl'
        $r.Success | Should -BeTrue -Because $r.Message
        $r.Violations.Count | Should -Be 0
    }

    It 'schlägt fehl und benennt libx264, wenn der GPL-Encoder fehlt' {
        $r = Test-FFmpegCapabilities `
            -EncodersText $script:EncodersLgpl `
            -DecodersText $script:DecodersWithDav1d `
            -HwaccelsText $script:HwaccelsWithCuda `
            -Variant 'gpl'
        $r.Success | Should -BeFalse
        ($r.Violations -join ' ') | Should -Match 'libx264'
        ($r.Violations -join ' ') | Should -Match 'libx265'
    }

    It 'schlägt fehl und benennt den fehlenden AV1/dav1d-Decoder' {
        $r = Test-FFmpegCapabilities `
            -EncodersText $script:EncodersGpl `
            -DecodersText $script:DecodersNoAv1 `
            -HwaccelsText $script:HwaccelsWithCuda `
            -Variant 'gpl'
        $r.Success | Should -BeFalse
        ($r.Violations -join ' ') | Should -Match 'AV1/dav1d'
    }
}

Describe 'Test-FFmpegCapabilities - LGPL-Variante' {
    It 'besteht ohne libx264/libx265, aber mit dav1d + AMF + NVENC/NVDEC' {
        $r = Test-FFmpegCapabilities `
            -EncodersText $script:EncodersLgpl `
            -DecodersText $script:DecodersWithDav1d `
            -HwaccelsText $script:HwaccelsWithCuda `
            -Variant 'lgpl'
        $r.Success | Should -BeTrue -Because $r.Message
        $r.Violations.Count | Should -Be 0
    }

    It 'schlägt fehl und benennt den unerwarteten GPL-Encoder libx264/libx265' {
        $r = Test-FFmpegCapabilities `
            -EncodersText $script:EncodersGpl `
            -DecodersText $script:DecodersWithDav1d `
            -HwaccelsText $script:HwaccelsWithCuda `
            -Variant 'lgpl'
        $r.Success | Should -BeFalse
        ($r.Violations -join ' ') | Should -Match 'libx264'
        ($r.Violations -join ' ') | Should -Match 'Unerwarteter'
    }
}

Describe 'Test-FFmpegCapabilities - Hardware-Fähigkeiten (beide Varianten)' {
    It 'schlägt fehl, wenn AMF-Encoder fehlen' {
        $encodersNoAmf = @'
Encoders:
 ------
 V....D libx264              libx264 H.264
 V....D libx265              libx265 H.265
 V....D h264_nvenc           NVIDIA NVENC H.264 encoder
'@
        $r = Test-FFmpegCapabilities `
            -EncodersText $encodersNoAmf `
            -DecodersText $script:DecodersWithDav1d `
            -HwaccelsText $script:HwaccelsWithCuda `
            -Variant 'gpl'
        $r.Success | Should -BeFalse
        ($r.Violations -join ' ') | Should -Match 'AMF'
    }

    It 'schlägt fehl, wenn NVENC-Encoder fehlen' {
        $encodersNoNvenc = @'
Encoders:
 ------
 V....D libx264              libx264 H.264
 V....D libx265              libx265 H.265
 V....D h264_amf             AMD AMF H.264 Encoder
'@
        $r = Test-FFmpegCapabilities `
            -EncodersText $encodersNoNvenc `
            -DecodersText $script:DecodersWithDav1d `
            -HwaccelsText $script:HwaccelsWithCuda `
            -Variant 'gpl'
        $r.Success | Should -BeFalse
        ($r.Violations -join ' ') | Should -Match 'NVENC'
    }

    It 'schlägt fehl, wenn NVDEC/CUDA-Hwaccel fehlt' {
        $r = Test-FFmpegCapabilities `
            -EncodersText $script:EncodersGpl `
            -DecodersText $script:DecodersWithDav1d `
            -HwaccelsText $script:HwaccelsNoNvdec `
            -Variant 'gpl'
        $r.Success | Should -BeFalse
        ($r.Violations -join ' ') | Should -Match 'NVDEC/NVENC'
    }
}
