// PathLogic.h
//
// Reine PATH-Manipulationslogik der PATH-Custom-Action, frei von Registry-
// und Win32-Aufrufen, damit sie mit RapidCheck property-basiert testbar ist.
//
// Die Funktionen bilden das PATH-Datenmodell aus design.md (Abschnitt
// "PATH-Datenmodell (R10)") ab und erfüllen die Requirements 10.1, 10.2,
// 10.3 und 10.5. Sie arbeiten ausschließlich auf ';'-getrennten
// Zeichenketten und Listen; das eigentliche Lesen/Schreiben der Registry
// und der WM_SETTINGCHANGE-Broadcast liegen bewusst außerhalb dieser
// Übersetzungseinheit (Task 6.5).
#pragma once

#include <string>
#include <vector>

namespace pathaction {

// Maximale Länge der System-PATH-Variable (REG_EXPAND_SZ-Grenze).
constexpr size_t kMaxPathLength = 2047;

// Normalisiert einen einzelnen PATH-Eintrag für den Duplikat-Vergleich:
// case-insensitiv und ohne abschließenden Backslash (R10.3).
std::string Normalize(const std::string& entry);

// Zerlegt einen ';'-getrennten PATH-String in seine Einträge. Leere
// Einträge (z. B. durch doppelte oder abschließende Semikola) werden
// verworfen, damit Vergleich und Zusammenbau deterministisch bleiben.
std::vector<std::string> Split(const std::string& path);

// Fügt die Einträge mit ';' zusammen (Umkehrung von Split, ohne leere
// Einträge zu erzeugen).
std::string Join(const std::vector<std::string>& entries);

// Stellt bin_path an den Anfang von system_path (R10.1). Bereits vorhandene,
// zu bin_path normalisierungsgleiche Einträge werden zuvor entfernt, sodass
// bin_path danach genau einmal an Position 0 vorkommt (R10.3). Die Operation
// ist idempotent: erneutes Voranstellen ändert das Ergebnis nicht.
std::string Prepend(const std::string& system_path, const std::string& bin_path);

// Entfernt ausschließlich die zu bin_path normalisierungsgleichen Einträge
// aus system_path und belässt alle übrigen Einträge unverändert in ihrer
// ursprünglichen Reihenfolge (R10.2).
std::string Remove(const std::string& system_path, const std::string& bin_path);

// Prüft, ob das Voranstellen von bin_path an system_path einen PATH-String
// von mehr als kMaxPathLength (2047) Zeichen erzeugen würde, ohne den PATH
// dabei zu verändern (R10.5). Gibt true zurück, wenn die Grenze
// überschritten würde.
bool WouldExceedLimit(const std::string& system_path, const std::string& bin_path);

} // namespace pathaction
