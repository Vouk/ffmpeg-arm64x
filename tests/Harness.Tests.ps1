<#
    Smoke-Tests für das Test-Grundgerüst selbst.

    Diese Tests stellen sicher, dass:
      - die Repo-Verzeichnisstruktur vorhanden ist,
      - die Reinlogik-Module unter scripts/lib importierbar bleiben (sobald vorhanden),
      - der FsCheck-Wrapper geladen werden kann und Invoke-Property funktioniert,
      - die Platzhalter-Lizenzdateien existieren.

    Sie enthalten noch keine Feature-Properties (1-8); diese kommen mit den
    jeweiligen Implementierungs-Tasks hinzu.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $PSScriptRoot 'FsCheckWrapper.psm1') -Force
}

Describe 'Repository-Gerüst' {
    It 'enthält die erwarteten Verzeichnisse' {
        $expected = @(
            '.github/workflows',
            'scripts',
            'scripts/lib',
            'installer',
            'installer/PathAction',
            'installer/license',
            'licenses',
            'tests'
        )
        foreach ($d in $expected) {
            (Test-Path (Join-Path $script:RepoRoot $d)) | Should -BeTrue -Because "$d sollte existieren"
        }
    }

    It 'enthält die Repo-Stammdateien' {
        foreach ($f in @('.gitignore', 'README.md', '.gitattributes')) {
            (Test-Path (Join-Path $script:RepoRoot $f)) | Should -BeTrue -Because "$f sollte existieren"
        }
    }

    It 'enthält keine Submodul-Definition (eigenständige Historie)' {
        (Test-Path (Join-Path $script:RepoRoot '.gitmodules')) | Should -BeFalse
    }

    It 'enthält die Platzhalter-Lizenzdateien' {
        $licenses = @(
            'licenses/LICENSE.GPL.txt',
            'licenses/LICENSE.LGPL.txt',
            'installer/license/gpl-3.0.rtf',
            'installer/license/lgpl-3.0.rtf'
        )
        foreach ($l in $licenses) {
            (Test-Path (Join-Path $script:RepoRoot $l)) | Should -BeTrue -Because "$l sollte existieren"
        }
    }
}

Describe 'FsCheck-Wrapper' {
    It 'erzwingt mindestens 100 Iterationen' {
        { Invoke-Property -Generator { 1 } -Property { param($x) $true } -Iterations 50 } |
            Should -Throw
    }

    It 'akzeptiert eine wahre Property über >= 100 zufällige Eingaben' {
        { Invoke-Property -Generator { Get-Random -Minimum 0 -Maximum 1000 } `
                          -Property { param($n) $n -ge 0 -and $n -lt 1000 } } |
            Should -Not -Throw
    }

    It 'meldet ein Gegenbeispiel, wenn die Property verletzt wird' {
        { Invoke-Property -Generator { 42 } -Property { param($n) $n -ne 42 } } |
            Should -Throw -ExpectedMessage '*Gegenbeispiel*'
    }
}
