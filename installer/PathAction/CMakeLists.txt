cmake_minimum_required(VERSION 3.20)

project(PathAction LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# Reine PATH-Manipulationslogik (Registry-/Win32-frei, damit testbar).
# Die eigentliche Implementierung (Normalize/Prepend/Remove/WouldExceedLimit)
# folgt in Task 6.1. Hier wird bereits die Bibliothek als Ziel deklariert,
# damit das Test-Grundgerüst steht.
# ---------------------------------------------------------------------------
add_library(path_logic STATIC
    PathLogic.cpp
)
target_include_directories(path_logic PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# ---------------------------------------------------------------------------
# PATH-Custom-Action als DLL (Task 6.5).
# Verbindet die reine Kernlogik (path_logic) mit Registry, MSI und dem
# WM_SETTINGCHANGE-Broadcast. Wird von WiX als Typ-1-Custom-Action (Binary +
# DllEntry) eingebunden. Die Exporte sind in PathAction.def deklariert, damit
# die Einsprungnamen unverziert bleiben.
#
# Nur auf Windows/MSVC baubar (verwendet windows.h, msi.h, msiquery.h). Auf
# anderen Plattformen wird das Ziel uebersprungen, damit die reine Kernlogik
# und ihre Tests weiterhin plattformunabhaengig konfigurierbar bleiben.
# ---------------------------------------------------------------------------
if(WIN32)
    add_library(PathAction SHARED
        PathAction.cpp
        PathAction.def
    )
    target_link_libraries(PathAction PRIVATE
        path_logic
        msi
        advapi32
        user32
    )
    # Kein "lib"-Praefix; WiX erwartet PathAction.dll.
    set_target_properties(PathAction PROPERTIES
        PREFIX ""
        OUTPUT_NAME "PathAction"
    )
endif()

# ---------------------------------------------------------------------------
# Tests: RapidCheck (property-based) + einfache Assertions.
# RapidCheck wird per FetchContent eingebunden (dieselbe PBT-Bibliothek,
# die auch andernorts als _deps/rapidcheck verwendet wird).
# ---------------------------------------------------------------------------
option(PATHACTION_BUILD_TESTS "Build PathAction tests (RapidCheck)" ON)

if(PATHACTION_BUILD_TESTS)
    enable_testing()

    include(FetchContent)
    FetchContent_Declare(
        rapidcheck
        GIT_REPOSITORY https://github.com/emil-e/rapidcheck.git
        GIT_TAG        ff6af6fc683159deb51c543b065eba14dfcf329b
    )
    FetchContent_MakeAvailable(rapidcheck)

    add_executable(path_logic_tests
        tests/PathLogicTests.cpp
    )
    target_link_libraries(path_logic_tests PRIVATE path_logic rapidcheck)

    add_test(NAME path_logic_tests COMMAND path_logic_tests)
endif()
