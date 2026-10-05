// PathAction.cpp
//
// Win32-/MSI-Anbindung der PATH-Custom-Action (Task 6.5).
//
// Diese Ubersetzungseinheit verbindet die reine, testbare Kernlogik aus
// PathLogic.{h,cpp} (Normalize/Prepend/Remove/WouldExceedLimit) mit der
// Windows-Registry, dem MSI-Installer und dem WM_SETTINGCHANGE-Broadcast.
//
// Die Custom Actions werden als DLL-Exporte bereitgestellt, damit WiX sie
// als Typ-1-Custom-Actions (Binary + DllEntry) einbinden kann. Sie sind als
// transaktionale, geplante Aktionen ausgelegt (Deferred + Rollback), gemaess
// design.md ("Error Handling -> PATH-Custom-Action"):
//
//   * PathPrependDeferred  - liest den bestehenden System-PATH, sichert ihn
//                            fuer das Rollback, berechnet den neuen Wert ueber
//                            die Kernlogik (Prepend), prueft die 2047-Grenze
//                            VOR dem Schreiben (WouldExceedLimit) und schreibt
//                            nur bei Erfolg. Danach WM_SETTINGCHANGE.       R10.1/R10.5/R10.6
//   * PathRemoveDeferred   - entfernt den eigenen Bin_Path-Eintrag und laesst
//                            die uebrigen Eintraege in ihrer Reihenfolge
//                            unveraendert (Remove). Danach WM_SETTINGCHANGE.  R10.2/R10.6
//   * PathRollback         - stellt bei Abbruch den zuvor gesicherten PATH
//                            wieder her.                                     R10.4
//
// Da die Aktionen "deferred" laufen (kein Zugriff auf Session-Properties),
// werden BINPATH und der gesicherte Vorwert ueber die CustomActionData-
// Property (Name der deferred Action) uebergeben. Fuer das Rollback wird die
// CustomActionData der Rollback-Action mit dem Vorwert befuellt.
//
// Bei jedem Registry-Schreibfehler bleibt der PATH unveraendert und die
// Aktion meldet einen Fehler an den Installer (R10.4); die MSI-Transaktion
// rollt die Sitzung anschliessend zurueck.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <msi.h>
#include <msiquery.h>

#include <string>
#include <vector>

#include "PathLogic.h"

namespace {

// Registry-Schluessel und -Wert der systemweiten PATH-Variable.
constexpr wchar_t kEnvKeyPath[] =
    L"SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment";
constexpr wchar_t kPathValueName[] = L"Path";

// Trennzeichen fuer die CustomActionData-Nutzlast der Prepend-Aktion.
// Layout:  <BinPath> "|" <gesicherter alter PATH>
// Das Zeichen '|' ist in Windows-Pfaden unzulaessig und daher als Trenner
// eindeutig. Fuer Remove und Rollback wird die Nutzlast direkt interpretiert.
constexpr wchar_t kFieldSeparator = L'|';

// --- UTF-8 <-> UTF-16 Konvertierung -------------------------------------
// Die Kernlogik arbeitet auf std::string (UTF-8/ANSI), die Win32-Registry
// auf std::wstring. Wir konvertieren an der Grenze.

std::wstring Widen(const std::string& utf8) {
    if (utf8.empty()) {
        return std::wstring();
    }
    const int len = ::MultiByteToWideChar(
        CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), nullptr, 0);
    if (len <= 0) {
        return std::wstring();
    }
    std::wstring result(static_cast<size_t>(len), L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                          static_cast<int>(utf8.size()), &result[0], len);
    return result;
}

std::string Narrow(const std::wstring& utf16) {
    if (utf16.empty()) {
        return std::string();
    }
    const int len = ::WideCharToMultiByte(
        CP_UTF8, 0, utf16.c_str(), static_cast<int>(utf16.size()), nullptr, 0,
        nullptr, nullptr);
    if (len <= 0) {
        return std::string();
    }
    std::string result(static_cast<size_t>(len), '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, utf16.c_str(),
                          static_cast<int>(utf16.size()), &result[0], len,
                          nullptr, nullptr);
    return result;
}

// --- MSI-Logging ---------------------------------------------------------
// Schreibt eine Zeile in das MSI-Log (via MsiProcessMessage / INSTALLMESSAGE_INFO).
void LogMessage(MSIHANDLE install, const std::wstring& text) {
    PMSIHANDLE record = ::MsiCreateRecord(1);
    if (record == 0) {
        return;
    }
    // Feld 0 traegt das Format, Feld 1 den Text.
    ::MsiRecordSetStringW(record, 0, L"PathAction: [1]");
    ::MsiRecordSetStringW(record, 1, text.c_str());
    ::MsiProcessMessage(install, INSTALLMESSAGE_INFO, record);
}

// Zeigt dem Nutzer eine Fehlermeldung (INSTALLMESSAGE_ERROR).
void LogError(MSIHANDLE install, const std::wstring& text) {
    PMSIHANDLE record = ::MsiCreateRecord(1);
    if (record == 0) {
        return;
    }
    ::MsiRecordSetStringW(record, 0, L"PathAction-Fehler: [1]");
    ::MsiRecordSetStringW(record, 1, text.c_str());
    ::MsiProcessMessage(install, INSTALLMESSAGE_ERROR, record);
}

// --- Registry-Zugriff ----------------------------------------------------

// Liest den systemweiten PATH aus der Registry. Gibt bei Erfolg true zurueck
// und legt den Rohwert in out_value ab; out_is_expand gibt an, ob der Wert
// als REG_EXPAND_SZ (statt REG_SZ) gespeichert war, damit wir den Typ beim
// Zurueckschreiben erhalten. Fehlt der Wert, wird ein leerer PATH und true
// zurueckgegeben (der Schluessel existiert immer auf Windows).
bool ReadSystemPath(std::wstring& out_value, bool& out_is_expand) {
    out_value.clear();
    out_is_expand = true;  // System-PATH ist konventionell REG_EXPAND_SZ.

    HKEY key = nullptr;
    LSTATUS status = ::RegOpenKeyExW(HKEY_LOCAL_MACHINE, kEnvKeyPath, 0,
                                     KEY_QUERY_VALUE, &key);
    if (status != ERROR_SUCCESS) {
        return false;
    }

    DWORD type = 0;
    DWORD bytes = 0;
    status = ::RegQueryValueExW(key, kPathValueName, nullptr, &type, nullptr,
                                &bytes);
    if (status == ERROR_FILE_NOT_FOUND) {
        // Kein PATH-Wert vorhanden -> leerer PATH.
        ::RegCloseKey(key);
        out_value.clear();
        out_is_expand = true;
        return true;
    }
    if (status != ERROR_SUCCESS) {
        ::RegCloseKey(key);
        return false;
    }

    std::vector<BYTE> buffer(bytes + sizeof(wchar_t), 0);
    status = ::RegQueryValueExW(key, kPathValueName, nullptr, &type,
                                buffer.data(), &bytes);
    ::RegCloseKey(key);
    if (status != ERROR_SUCCESS) {
        return false;
    }

    out_is_expand = (type == REG_EXPAND_SZ);
    const wchar_t* chars = reinterpret_cast<const wchar_t*>(buffer.data());
    // Anzahl Zeichen (ohne moegliches abschliessendes NUL).
    size_t char_count = bytes / sizeof(wchar_t);
    while (char_count > 0 && chars[char_count - 1] == L'\0') {
        --char_count;
    }
    out_value.assign(chars, char_count);
    return true;
}

// Schreibt den systemweiten PATH zurueck. Gibt bei Erfolg true zurueck.
bool WriteSystemPath(const std::wstring& value, bool is_expand) {
    HKEY key = nullptr;
    LSTATUS status = ::RegOpenKeyExW(HKEY_LOCAL_MACHINE, kEnvKeyPath, 0,
                                     KEY_SET_VALUE, &key);
    if (status != ERROR_SUCCESS) {
        return false;
    }

    const DWORD type = is_expand ? REG_EXPAND_SZ : REG_SZ;
    // Groesse inklusive abschliessendem NUL-Zeichen.
    const DWORD bytes =
        static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
    status = ::RegSetValueExW(key, kPathValueName, 0, type,
                              reinterpret_cast<const BYTE*>(value.c_str()),
                              bytes);
    ::RegCloseKey(key);
    return status == ERROR_SUCCESS;
}

// Sendet WM_SETTINGCHANGE, damit laufende Prozesse den aktualisierten PATH
// uebernehmen koennen (R10.6). Verwendet SendMessageTimeout mit kurzem
// Timeout, damit haengende Top-Level-Fenster die Installation nicht
// blockieren.
void BroadcastEnvironmentChange() {
    DWORD_PTR result = 0;
    ::SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0,
                          reinterpret_cast<LPARAM>(L"Environment"),
                          SMTO_ABORTIFHUNG, 5000, &result);
}

// --- CustomActionData-Zugriff -------------------------------------------

// Liest die CustomActionData-Property der laufenden (deferred) Custom Action.
std::wstring GetCustomActionData(MSIHANDLE install) {
    DWORD size = 0;
    // Erst die benoetigte Groesse ermitteln.
    UINT rc = ::MsiGetPropertyW(install, L"CustomActionData", L"", &size);
    if (rc != ERROR_MORE_DATA && rc != ERROR_SUCCESS) {
        return std::wstring();
    }
    std::wstring buffer(size + 1, L'\0');
    DWORD cap = size + 1;
    rc = ::MsiGetPropertyW(install, L"CustomActionData", &buffer[0], &cap);
    if (rc != ERROR_SUCCESS) {
        return std::wstring();
    }
    buffer.resize(cap);
    return buffer;
}

} // namespace

extern "C" {

// -------------------------------------------------------------------------
// Deferred: Bin_Path an den Anfang des System-PATH stellen.
//
// CustomActionData-Layout:  <BinPath> '|' <alter PATH-Rohwert>
// Der alte PATH-Rohwert wird typischerweise von der Immediate-Action gesetzt,
// die auch die Rollback-CustomActionData mit dem Vorwert fuellt. Fehlt der
// Vorwert im CustomActionData, wird der PATH hier frisch aus der Registry
// gelesen (defensiv).
// -------------------------------------------------------------------------
__declspec(dllexport) UINT __stdcall PathPrependDeferred(MSIHANDLE hInstall) {
    const std::wstring data = GetCustomActionData(hInstall);

    // BinPath vom (optionalen) Vorwert trennen.
    std::wstring bin_path_w;
    const size_t sep = data.find(kFieldSeparator);
    if (sep == std::wstring::npos) {
        bin_path_w = data;
    } else {
        bin_path_w = data.substr(0, sep);
    }

    if (bin_path_w.empty()) {
        LogError(hInstall, L"BINPATH ist leer; PATH bleibt unveraendert.");
        return ERROR_INSTALL_FAILURE;
    }

    // Aktuellen System-PATH lesen.
    std::wstring current_w;
    bool is_expand = true;
    if (!ReadSystemPath(current_w, is_expand)) {
        LogError(hInstall,
                 L"System-PATH konnte nicht gelesen werden; PATH unveraendert.");
        return ERROR_INSTALL_FAILURE;
    }

    // Neuen Wert ueber die reine Kernlogik berechnen.
    const std::string current = Narrow(current_w);
    const std::string bin_path = Narrow(bin_path_w);

    // 2047-Grenze VOR dem Schreiben pruefen (R10.5).
    if (pathaction::WouldExceedLimit(current, bin_path)) {
        LogError(hInstall,
                 L"Der System-PATH wuerde die maximale Laenge von 2047 Zeichen "
                 L"ueberschreiten; BINPATH wird nicht eingetragen, PATH bleibt "
                 L"unveraendert.");
        return ERROR_INSTALL_FAILURE;
    }

    const std::string updated = pathaction::Prepend(current, bin_path);
    const std::wstring updated_w = Widen(updated);

    // Nur bei Erfolg schreiben; bei Schreibfehler bleibt PATH unveraendert (R10.4).
    if (!WriteSystemPath(updated_w, is_expand)) {
        LogError(hInstall,
                 L"Schreiben des System-PATH in die Registry fehlgeschlagen; "
                 L"PATH bleibt unveraendert.");
        return ERROR_INSTALL_FAILURE;
    }

    // Erfolgreiche Aenderung dem System bekanntgeben (R10.6).
    BroadcastEnvironmentChange();
    LogMessage(hInstall, L"BINPATH wurde an den Anfang des System-PATH gestellt.");
    return ERROR_SUCCESS;
}

// -------------------------------------------------------------------------
// Immediate: den AKTUELLEN System-PATH lesen und als CustomActionData der
// Rollback-Action (Property-Name "PathRollback") hinterlegen (R10.4).
//
// Diese Aktion laeuft VOR PathPrependDeferred und erfasst damit den PATH-
// Vorwert, BEVOR er geaendert wird. Nur so hat die Rollback-Action bei einem
// Abbruch ueberhaupt einen Wert zum Wiederherstellen. (Zuvor setzte eine
// statische WiX-CustomAction die Rollback-Daten hart auf "" -> Rollback war
// wirkungslos und ein fehlgeschlagener Install/Upgrade liess die PATH-
// Aenderung stehen bzw. verlor den Eintrag.)
//
// Als IMMEDIATE-Aktion hat sie Zugriff auf Session-Properties und darf
// MsiSetProperty aufrufen; das Setzen der Property "PathRollback" liefert den
// Wert als CustomActionData an die gleichnamige rollback-Action.
// -------------------------------------------------------------------------
__declspec(dllexport) UINT __stdcall PathCaptureRollback(MSIHANDLE hInstall) {
    std::wstring current_w;
    bool is_expand = true;
    if (!ReadSystemPath(current_w, is_expand)) {
        // PATH nicht lesbar: Rollback-Daten leer lassen (Rollback wird dann zu
        // einem No-op). Install nicht hieran scheitern lassen -- die eigentliche
        // Aenderung in PathPrependDeferred prueft den Zugriff ohnehin erneut.
        LogMessage(hInstall,
                   L"PATH-Vorwert konnte nicht gelesen werden; Rollback-Daten leer.");
        ::MsiSetPropertyW(hInstall, L"PathRollback", L"");
        return ERROR_SUCCESS;
    }

    // Den vollstaendigen Vorwert als Rollback-CustomActionData hinterlegen.
    const UINT rc = ::MsiSetPropertyW(hInstall, L"PathRollback", current_w.c_str());
    if (rc != ERROR_SUCCESS) {
        LogError(hInstall,
                 L"Rollback-Daten (PATH-Vorwert) konnten nicht gesetzt werden.");
        return ERROR_INSTALL_FAILURE;
    }
    LogMessage(hInstall, L"PATH-Vorwert fuer Rollback gesichert.");
    return ERROR_SUCCESS;
}

// -------------------------------------------------------------------------
// Deferred: Bin_Path bei Deinstallation aus dem System-PATH entfernen.
//
// CustomActionData-Layout:  <BinPath>
// -------------------------------------------------------------------------
__declspec(dllexport) UINT __stdcall PathRemoveDeferred(MSIHANDLE hInstall) {
    const std::wstring data = GetCustomActionData(hInstall);

    std::wstring bin_path_w = data;
    const size_t sep = data.find(kFieldSeparator);
    if (sep != std::wstring::npos) {
        bin_path_w = data.substr(0, sep);
    }

    if (bin_path_w.empty()) {
        LogError(hInstall, L"BINPATH ist leer; PATH bleibt unveraendert.");
        return ERROR_INSTALL_FAILURE;
    }

    std::wstring current_w;
    bool is_expand = true;
    if (!ReadSystemPath(current_w, is_expand)) {
        LogError(hInstall,
                 L"System-PATH konnte nicht gelesen werden; PATH unveraendert.");
        return ERROR_INSTALL_FAILURE;
    }

    const std::string current = Narrow(current_w);
    const std::string bin_path = Narrow(bin_path_w);

    // Nur den eigenen Eintrag entfernen, uebrige Reihenfolge erhalten (R10.2).
    const std::string updated = pathaction::Remove(current, bin_path);
    const std::wstring updated_w = Widen(updated);

    if (!WriteSystemPath(updated_w, is_expand)) {
        LogError(hInstall,
                 L"Schreiben des System-PATH in die Registry fehlgeschlagen; "
                 L"PATH bleibt unveraendert.");
        return ERROR_INSTALL_FAILURE;
    }

    BroadcastEnvironmentChange();
    LogMessage(hInstall, L"BINPATH wurde aus dem System-PATH entfernt.");
    return ERROR_SUCCESS;
}

// -------------------------------------------------------------------------
// Rollback: den zuvor gesicherten System-PATH wiederherstellen (R10.4).
//
// CustomActionData-Layout:  <gesicherter PATH-Rohwert>
// Die Rollback-CustomActionData muss den kompletten Vorwert des PATH tragen,
// damit die Aktion ihn beim Abbruch der Transaktion zurueckschreibt. Ein
// leerer Vorwert wuerde den PATH loeschen; deshalb wird ein Fehlen als
// "nichts wiederherzustellen" behandelt und der PATH unveraendert gelassen.
// -------------------------------------------------------------------------
__declspec(dllexport) UINT __stdcall PathRollback(MSIHANDLE hInstall) {
    const std::wstring data = GetCustomActionData(hInstall);
    if (data.empty()) {
        LogMessage(hInstall,
                   L"Kein gesicherter PATH-Vorwert; nichts wiederherzustellen.");
        return ERROR_SUCCESS;
    }

    // Der Vorwert wird als kompletter PATH-Rohwert erwartet. Ein optionaler
    // Feldtrenner wird ignoriert (nur der Teil vor dem ersten '|' zaehlt),
    // damit dasselbe Datenformat wie bei der Prepend-Aktion nutzbar ist.
    std::wstring restore_w = data;
    const size_t sep = data.find(kFieldSeparator);
    if (sep != std::wstring::npos) {
        restore_w = data.substr(sep + 1);
    }

    if (!WriteSystemPath(restore_w, /*is_expand=*/true)) {
        LogError(hInstall,
                 L"Wiederherstellen des System-PATH beim Rollback fehlgeschlagen.");
        return ERROR_INSTALL_FAILURE;
    }

    BroadcastEnvironmentChange();
    LogMessage(hInstall, L"System-PATH wurde beim Rollback wiederhergestellt.");
    return ERROR_SUCCESS;
}

} // extern "C"

// Minimaler DllMain, damit die DLL ohne CRT-Startup-Annahmen ladbar bleibt.
BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) {
    return TRUE;
}
