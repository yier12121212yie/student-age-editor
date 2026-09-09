# backend_tui — TUI + lightweight agent (merged wave-3 group P8, ex wip/P8).
#
# Layering preserved from the group layout: this directory root holds the
# headless sources (view-model state machine, backend API client, cfg diff,
# agent codec, FTXUI-DOM renderer + string renderer) and they compile into the
# `sa_tui` static library. sa_tui is linked into BOTH backend_tui and sa_tests
# (the [p8] snapshot tests need RenderPageToString + ftxui::dom headers, which
# propagate PUBLIC). The interactive layer (tui/app.{h,cpp}, tui/main.cpp with
# the executable's main()) is enumerated ONLY for backend_tui, so sa_tests —
# which already carries the Catch2-provided main() — never sees it. Do not
# glob tui/ into sa_tui; that was the wip/P8/group.cmake:8-11 invariant.

# Vendored FTXUI v5.0.0 as embedded static libs (first project-style vendor;
# see third_party/README.md). All OFF/ON vars are load-bearing: TESTS=OFF keeps
# FetchContent(googletest) out (offline configure), INSTALL=OFF skips CPack.
set(FTXUI_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(FTXUI_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(FTXUI_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(FTXUI_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(FTXUI_QUIET ON CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ftxui"
                 "${CMAKE_BINARY_DIR}/third_party/ftxui")

# sa_tui: pure logic + headless DOM rendering. PUBLIC include dir keeps the
# merged bare-name includes ("p8_agent.h" in tests AND in tui/*) working with
# zero edits — same trick as server/services in server/CMakeLists.txt:20-25.
file(GLOB SA_TUI_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")
add_library(sa_tui STATIC ${SA_TUI_SOURCES})
target_include_directories(sa_tui PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(sa_tui PUBLIC sa_core ftxui::dom)
target_compile_features(sa_tui PUBLIC cxx_std_20)
add_library(sa::tui ALIAS sa_tui)

# backend_tui: interactive shell + entry point only; sa_tui carries the rest.
add_executable(backend_tui tui/app.cpp tui/main.cpp)
target_link_libraries(backend_tui PRIVATE sa_tui ftxui::component)
set_target_properties(backend_tui PROPERTIES OUTPUT_NAME "backend_tui")
