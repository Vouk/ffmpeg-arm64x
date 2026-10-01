# ARM64X-FFmpeg-Build

Standalone-Repository, das **FFmpeg 8** als **ARM64X-Hybrid-Binärdateien** (Windows on ARM: eine PE-Datei mit ARM64- *und* ARM64EC-Ansicht) baut, als **dynamische Bibliotheken** (Shared/DLL), in **zwei Lizenz-Varianten** (GPL und LGPL), und daraus **zwei MSI-Installer** erzeugt.

Der Build läuft vollautomatisch, aber **ausschließlich manuell ausgelöst** (`workflow_dispatch`) auf GitHub Actions.

> Dieses Repository besitzt eine eigenständige Git-Historie und ist unabhängig von anderen Projekten. Es enthält keine Submodule oder geteilten Git-Referenzen zu externen Repositories.

## Was gebaut wird

- **FFmpeg 8.x** als Shared Libraries (`avcodec`, `avformat`, `avutil`, `avfilter`, `avdevice`, `swscale`, `swresample`) — je DLL eine namensgleiche `.lib`-Import-Bibliothek.
- **GPL-Variante**: mit `--enable-gpl`, inklusive libx264, libx265.
- **LGPL-Variante**: ohne GPL-Komponenten (kein libx264/libx265).
- **Beide Varianten**: AMF- und NVIDIA-Header (Hardware-Encoding/Decoding) eingebunden.
- **Zwei MSI-Installer** (WiX): Lizenzanzeige, anpassbarer Installationspfad (Standard `C:\Program Files\FFmpeg 8`), Eintrag des `bin`-Pfads an den Anfang der System-`PATH`-Variable.

## Verzeichnisstruktur

```
.github/workflows/    GitHub-Actions-Workflow (workflow_dispatch)
scripts/              Build-, Merge- und Verifikations-Skripte (PowerShell)
scripts/lib/          Testbare Reinlogik-Module (PowerShell)
installer/            WiX-Installer-Definitionen
installer/PathAction/ C++-Custom-Action für System-PATH-Manipulation
installer/license/    Lizenz-RTFs, die die Installer-UI anzeigt
licenses/             Volltext-Lizenzdateien (GPL / LGPL)
tests/                Pester-Tests (Unit + Property-Based mit FsCheck)
```

## Build auslösen

Der Workflow wird ausschließlich manuell über GitHub Actions (`workflow_dispatch`) gestartet und akzeptiert die Eingaben `ffmpegVersion` und `productVersion`. Es gibt keine automatischen Auslöser (`push`, `pull_request`, `schedule`, `release`).

## Tests

Die reine, plattformunabhängige Logik ist gekapselt und lokal ohne CI testbar:

- **PowerShell-Reinlogik** (`scripts/lib/`): getestet mit [Pester](https://pester.dev/) + [FsCheck](https://fscheck.github.io/FsCheck/) (über einen dünnen Wrapper).
- **C++-PATH-Logik** (`installer/PathAction/`): getestet mit [RapidCheck](https://github.com/emil-e/rapidcheck) über ein CMake-Projekt.

```powershell
# PowerShell-Tests (Pester + FsCheck)
Invoke-Pester -Configuration (New-PesterConfiguration @{ Run = @{ Path = 'tests' } })

# C++-PATH-Logik (CMake + RapidCheck)
cmake -S installer/PathAction -B build_pathaction
cmake --build build_pathaction
ctest --test-dir build_pathaction --output-on-failure
```

Property-Tests laufen mit mindestens 100 Iterationen und referenzieren ihre Design-Property über das Tag-Format `Feature: arm64x-ffmpeg-build, Property N`.

## Lizenzen

- GPL-Variante: siehe [`licenses/LICENSE.GPL.txt`](licenses/LICENSE.GPL.txt).
- LGPL-Variante: siehe [`licenses/LICENSE.LGPL.txt`](licenses/LICENSE.LGPL.txt).

Die während der Installation angezeigten Lizenztexte liegen als RTF unter `installer/license/`.
