// PathLogicTests.cpp
//
// Test-Grundgerüst für die reine PATH-Logik mit RapidCheck.
//
// Dieses Gerüst prüft aktuell nur die vorhandene Normalize-Funktion, um zu
// belegen, dass die RapidCheck-Einbindung (Generatoren, >= 100 Iterationen)
// funktioniert. Die Feature-Properties 6-8 werden in den Tasks 6.2-6.4 mit
// dem Tag "Feature: arm64x-ffmpeg-build, Property N" ergänzt.

#include <rapidcheck.h>

#include <string>

#include "PathLogic.h"

int main() {
    bool ok = true;

    // Sanity-Property: Normalize ist idempotent (normalize(normalize(x)) == normalize(x)).
    ok &= rc::check(
        "Grundgeruest: Normalize ist idempotent",
        [](const std::string& s) {
            const std::string once = pathaction::Normalize(s);
            const std::string twice = pathaction::Normalize(once);
            RC_ASSERT(once == twice);
        });

    // Sanity-Property: Normalize erzeugt keine abschliessenden Backslashes.
    ok &= rc::check(
        "Grundgeruest: Normalize entfernt abschliessende Backslashes",
        [](const std::string& s) {
            const std::string n = pathaction::Normalize(s);
            if (!n.empty()) {
                RC_ASSERT(n.back() != '\\');
                RC_ASSERT(n.back() != '/');
            }
        });

    return ok ? 0 : 1;
}
