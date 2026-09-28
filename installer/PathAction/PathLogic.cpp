// PathLogic.cpp
//
// Reine PATH-Manipulationslogik gemäß design.md ("PATH-Datenmodell (R10)").
// Diese Übersetzungseinheit ist bewusst frei von Registry- und Win32-
// Aufrufen, damit sie mit RapidCheck property-basiert getestet werden kann.
#include "PathLogic.h"

#include <algorithm>
#include <cctype>

namespace pathaction {

std::string Normalize(const std::string& entry) {
    std::string result = entry;
    // Abschließende Backslashes entfernen.
    while (!result.empty() && (result.back() == '\\' || result.back() == '/')) {
        result.pop_back();
    }
    // Case-insensitiver Vergleich: auf Kleinschreibung normalisieren.
    std::transform(result.begin(), result.end(), result.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return result;
}

std::vector<std::string> Split(const std::string& path) {
    std::vector<std::string> entries;
    std::string current;
    for (const char c : path) {
        if (c == ';') {
            if (!current.empty()) {
                entries.push_back(current);
            }
            current.clear();
        } else {
            current.push_back(c);
        }
    }
    if (!current.empty()) {
        entries.push_back(current);
    }
    return entries;
}

std::string Join(const std::vector<std::string>& entries) {
    std::string result;
    for (const std::string& entry : entries) {
        if (entry.empty()) {
            continue;
        }
        if (!result.empty()) {
            result.push_back(';');
        }
        result += entry;
    }
    return result;
}

namespace {

// Liefert alle Einträge aus system_path, deren Normalisierung nicht mit der
// von bin_path übereinstimmt; die relative Reihenfolge bleibt erhalten.
std::vector<std::string> RemoveMatching(const std::string& system_path,
                                         const std::string& bin_path) {
    const std::string bin_norm = Normalize(bin_path);
    std::vector<std::string> kept;
    for (std::string& entry : Split(system_path)) {
        if (Normalize(entry) != bin_norm) {
            kept.push_back(std::move(entry));
        }
    }
    return kept;
}

} // namespace

std::string Prepend(const std::string& system_path, const std::string& bin_path) {
    // Vorhandene (normalisierungsgleiche) Einträge entfernen, damit bin_path
    // danach genau einmal vorkommt (R10.3).
    std::vector<std::string> entries = RemoveMatching(system_path, bin_path);
    // bin_path an Position 0 einfügen (R10.1).
    entries.insert(entries.begin(), bin_path);
    return Join(entries);
}

std::string Remove(const std::string& system_path, const std::string& bin_path) {
    // Nur die eigenen Einträge entfernen; übrige Reihenfolge erhalten (R10.2).
    return Join(RemoveMatching(system_path, bin_path));
}

bool WouldExceedLimit(const std::string& system_path, const std::string& bin_path) {
    // Länge des Ergebnisses prüfen, ohne den PATH tatsächlich zu ändern (R10.5).
    return Prepend(system_path, bin_path).size() > kMaxPathLength;
}

} // namespace pathaction
