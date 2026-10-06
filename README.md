# ARM64X-FFmpeg-Build

Standalone-Repository, das **FFmpeg 8** (Standard: **8.1.3**) als **ARM64X-Hybrid-Binärdateien** (Windows on ARM: eine PE-Datei mit ARM64- *und* ARM64EC-Ansicht) baut, ausschließlich als **dynamische Bibliotheken** (Shared/DLL), in der **LGPL-Variante mit den Hardware-Encodern AMF und NVENC/NVDEC**, und daraus **einen MSI-Installer** erzeugt.

Der Build läuft vollautomatisch, aber **ausschließlich manuell ausgelöst** (`workflow_dispatch`) auf GitHub Actions.

> Dieses Repository besitzt eine eigenständige Git-Historie und ist unabhängig von anderen Projekten. Es enthält keine Submodule oder geteilten Git-Referenzen zu externen Repositories.

## Was gebaut wird

- **FFmpeg 8.1.3** als Shared Libraries (`avcodec`, `avformat`, `avutil`, `avfilter`, `avdevice`, `swscale`, `swresample`) — je DLL eine namensgleiche `.lib`-Import-Bibliothek. Es werden keine statischen Bibliotheken erzeugt.
- **Nur LGPL**: ohne `--enable-gpl`, ohne libx264/libx265.
- **Hardware-Encoder**: AMD **AMF** (`--enable-amf`) und NVIDIA **NVENC/NVDEC** (`--enable-nvenc --enable-nvdec`). Das sind header-only SDK-Integrationen (AMF-Header + nv-codec-headers), die zur Laufzeit die Treiber-DLLs laden und LGPL-verträglich sind. GPL-Codecs (x264/x265) bleiben ausgeschlossen.
- **Ein MSI-Installer** (WiX): Lizenzanzeige, anpassbarer Installationspfad (Standard `C:\Program Files\FFmpeg 8`), Eintrag des `bin`-Pfads an den Anfang der System-`PATH`-Variable.

## Verzeichnisstruktur

```
.github/workflows/    GitHub-Actions-Workflow (workflow_dispatch)
scripts/              Build-, Merge- und Verifikations-Skripte (PowerShell)
scripts/lib/          Testbare Reinlogik-Module (PowerShell)
installer/            WiX-Installer-Definitionen
installer/PathAction/ C++-Custom-Action für System-PATH-Manipulation
installer/license/    Lizenz-RTF, die die Installer-UI anzeigt
licenses/             Volltext-Lizenzdatei (LGPL)
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

## Lizenz

- LGPL-Variante: siehe [`licenses/LICENSE.LGPL.txt`](licenses/LICENSE.LGPL.txt).

Der während der Installation angezeigte Lizenztext liegt als RTF unter `installer/license/lgpl-3.0.rtf`.
