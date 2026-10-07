# ARM64X-FFmpeg-Build

Standalone-Repository, das **FFmpeg 8** (Standard: **8.1.3**) als **ARM64X-Hybrid-Binärdateien** (Windows on ARM: eine PE-Datei mit ARM64- *und* ARM64EC-Ansicht) baut, ausschließlich als **dynamische Bibliotheken** (Shared/DLL). Es werden **zwei Varianten** gebaut — **LGPL** (ohne GPL-Encoder) und **GPL** (zusätzlich x264/x265) — **ohne Hardware-Encoder**, und daraus **zwei MSI-Installer** erzeugt.

Der Build läuft vollautomatisch, aber **ausschließlich manuell ausgelöst** (`workflow_dispatch`) auf GitHub Actions.

> Dieses Repository besitzt eine eigenständige Git-Historie und ist unabhängig von anderen Projekten. Es enthält keine Submodule oder geteilten Git-Referenzen zu externen Repositories.

## Was gebaut wird

- **FFmpeg 8.1.3** als Shared Libraries (`avcodec`, `avformat`, `avutil`, `avfilter`, `avdevice`, `swscale`, `swresample`) — je DLL eine namensgleiche `.lib`-Import-Bibliothek. Es werden keine statischen FFmpeg-Bibliotheken erzeugt.
- **Echte Single-File-ARM64X-Hybride**: Je Kernbibliothek entsteht **eine** DLL, die ARM64- *und* ARM64EC-Code enthält (kein Forwarder-Trio). Der Forwarder-Pfad (`scripts/merge-arm64x.ps1` + `scripts/verify-arm64x.ps1`) bleibt als Fallback im Repo.
- **Zwei Lizenz-Varianten**, je ein eigenes MSI:
  - **LGPL**: ohne `--enable-gpl`, ohne libx264/libx265.
  - **GPL**: zusätzlich `--enable-gpl --enable-libx264 --enable-libx265`. x264 und x265 werden von `scripts/build-deps.ps1` **statisch** für ARM64 *und* ARM64EC gebaut und direkt in `avcodec` eingelinkt.
- **Keine Hardware-Encoder**: AMF und NVENC/NVDEC sind bewusst **nicht** enthalten. Auf Windows-on-ARM laden ihre Laufzeit-Probes die x64-GPU-Runtimes (nvcuda/nvEncodeAPI/amfrt) über die Emulation und blockieren in einem **ARM64EC**-Host (z. B. DaVinci Resolve) die Codec-/Device-Enumeration beim Plugin-Start minutenlang. WoA-Geräte haben zudem meist keine passende NVIDIA/AMD-GPU. Es bleiben die Software-Encoder (und im GPL-Build x264/x265).
- **Zwei MSI-Installer** (WiX): `ffmpeg-<version>-lgpl-arm64x.msi` und `ffmpeg-<version>-gpl-arm64x.msi`. Je MSI: Lizenzanzeige (variantenspezifische RTF, aktive Zustimmung erforderlich), anpassbarer Installationspfad (Standard `C:\Program Files\FFmpeg 8`; die DLLs und EXEs liegen direkt darin, kein `bin`-Unterordner), Eintrag dieses Verzeichnisses an den Anfang der System-`PATH`-Variable. GPL und LGPL haben verschiedene `UpgradeCode`s und sind nebeneinander installierbar.

## Verzeichnisstruktur

```
.github/workflows/    GitHub-Actions-Workflow (workflow_dispatch)
scripts/              Build-, Merge- und Verifikations-Skripte (PowerShell)
scripts/lib/          Testbare Reinlogik-Module (PowerShell)
installer/            WiX-Installer-Definitionen (Variant-Weiche GPL|LGPL)
installer/PathAction/ C++-Custom-Action für System-PATH-Manipulation
installer/license/    Lizenz-RTF (GPL + LGPL), die die Installer-UI anzeigt
licenses/             Volltext-Lizenzdateien (GPL + LGPL)
tests/                Pester-Tests (Unit + Property-Based mit FsCheck)
```

Zentrale Skripte:

- `scripts/build-variant.ps1` — orchestriert eine Variante End-to-End (beide Ansichten bauen → mergen → verifizieren → Fähigkeiten → MSI). Der Workflow ruft es zweimal auf (`lgpl`, `gpl`).
- `scripts/build-ffmpeg.ps1` — baut eine (Variante, Architektur); Parameter `-Variant lgpl|gpl` und `-DepsDir` (GPL: x264/x265-Wurzel).
- `scripts/build-deps.ps1` — baut x264 + x265 statisch für arm64 + arm64ec (nur GPL).
- `scripts/merge-arm64x-merged.ps1` / `scripts/verify-arm64x-merged.ps1` — True-Single-File-Merge und dessen Verifikation.
- `scripts/verify-capabilities.ps1` — statische Fähigkeitsprüfung aus FFmpegs `config.h` (`-Variant`: GPL verlangt x264/x265, LGPL verbietet sie; beide verbieten AMF/NVENC/NVDEC, die entfernt wurden).

## Build auslösen

Der Workflow wird ausschließlich manuell über GitHub Actions (`workflow_dispatch`) gestartet und akzeptiert die Eingaben `ffmpegVersion` und `productVersion`. Ein Lauf erzeugt beide MSI (LGPL + GPL). Es gibt keine automatischen Auslöser (`push`, `pull_request`, `schedule`, `release`).

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
- GPL-Variante (enthält x264/x265): siehe [`licenses/LICENSE.GPL.txt`](licenses/LICENSE.GPL.txt).

Der während der Installation angezeigte Lizenztext liegt als RTF unter `installer/license/lgpl-3.0.rtf` bzw. `installer/license/gpl-3.0.rtf`.
