<#
    Tests fuer scripts/verify-arm64x.ps1 im Pure-Forwarder-Layout.

    Geprueft wird die reine Logik: welche Dateien als ARM64X-Hybrid verifiziert
    werden (nur die Forwarder-DLLs), dass die Praesenz der Tools erzwungen wird
    und dass Invoke-Arm64xVerification die echten Ansichts-DLLs ignoriert sowie
    die .lib-Paarung ueberspringt, wenn keine .lib vorhanden ist. dumpbin.exe
    laeuft nur auf CI; hier wird der Header-Provider gestubbt.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'scripts/verify-arm64x.ps1') -BinDir x 2>$null 6>$null

    # Namen eines typischen Forwarder-bin: je Lib 3 DLLs + Tools, keine .lib.
    $script:ForwarderNames = @(
        'avcodec-62.dll', 'avcodec-62_arm64.dll', 'avcodec-62_arm64ec.dll',
        'avutil-60.dll',  'avutil-60_arm64.dll',  'avutil-60_arm64ec.dll',
        'ffmpeg.exe', 'ffprobe.exe'
    )

    # Header-Stub: Forwarder sind ARM64X, _arm64 ist ARM64, _arm64ec ist ARM64EC.
    $script:HeaderProvider = {
        param([string] $Path)
        $leaf = Split-Path -Path $Path -Leaf
        if ($leaf -match '_arm64ec\.dll$') { return "FILE HEADER VALUES`n    A641 machine (ARM64EC)`n" }
        if ($leaf -match '_arm64\.dll$')   { return "FILE HEADER VALUES`n    AA64 machine (ARM64)`n" }
        if ($leaf -match '\.dll$')         { return "FILE HEADER VALUES`n    AA64 machine (ARM64) (ARM64X)`n" }
        return "FILE HEADER VALUES`n    AA64 machine (ARM64)`n"
    }
}

Describe 'Get-Arm64xTargetFiles (Pure-Forwarder)' {
    It 'waehlt NUR die Forwarder-DLLs (ohne _arm64/_arm64ec-Suffix)' {
        $lister = { param($d) $script:ForwarderNames }
        $targets = Get-Arm64xTargetFiles -BinDir 'C:\bin' -FileLister $lister
        $leaves = $targets | ForEach-Object { Split-Path $_ -Leaf }
        $leaves | Should -Contain 'avcodec-62.dll'
        $leaves | Should -Contain 'avutil-60.dll'
        $leaves | Should -Not -Contain 'avcodec-62_arm64.dll'
        $leaves | Should -Not -Contain 'avcodec-62_arm64ec.dll'
        # Tools werden NICHT als ARM64X-Ziel gefuehrt (nur Praesenz geprueft).
        $leaves | Should -Not -Contain 'ffmpeg.exe'
        @($targets).Count | Should -Be 2
    }

    It 'bricht fail-fast ab, wenn ffprobe.exe fehlt' {
        $lister = { param($d) @('avcodec-62.dll', 'avcodec-62_arm64.dll', 'avcodec-62_arm64ec.dll', 'ffmpeg.exe') }
        { Get-Arm64xTargetFiles -BinDir 'C:\bin' -FileLister $lister } |
            Should -Throw -ExpectedMessage "*ffprobe.exe*fehlt*"
    }
}

Describe 'Invoke-Arm64xVerification (Pure-Forwarder)' {
    It 'besteht: Forwarder sind ARM64X, Ansichts-DLLs werden ignoriert, Paarung uebersprungen' {
        $lister = { param($d) $script:ForwarderNames }
        $r = Invoke-Arm64xVerification -BinDir 'C:\bin' `
            -HeaderProvider $script:HeaderProvider -FileLister $lister
        $r.Success | Should -BeTrue -Because $r.Message
        # Es wurden genau die 2 Forwarder geprueft.
        @($r.Checked).Count | Should -Be 2
        ($r.Checked | ForEach-Object Abi) | Should -Not -Contain 'ARM64EC'
        # Keine .lib im bin -> keine Paarungspruefung.
        $r.Pairing | Should -BeNullOrEmpty
    }

    It 'schlaegt fehl, wenn ein Forwarder nur ARM64 ist (kein Hybrid)' {
        $lister = { param($d) @('avcodec-62.dll', 'avcodec-62_arm64.dll', 'avcodec-62_arm64ec.dll', 'ffmpeg.exe', 'ffprobe.exe') }
        $provider = { param($p) "FILE HEADER VALUES`n    AA64 machine (ARM64)`n" }
        $r = Invoke-Arm64xVerification -BinDir 'C:\bin' -HeaderProvider $provider -FileLister $lister
        $r.Success | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match 'ARM64X'
    }
}