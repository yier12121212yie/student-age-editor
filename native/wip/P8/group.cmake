# wip/P8/group.cmake — P8 (TUI + lightweight agent chat) private build wiring.
#
# Included from native/CMakeLists.txt only when -DSA_GROUP_WIP=P8. Inside this
# file ${CMAKE_CURRENT_SOURCE_DIR} still refers to native/. Nothing here touches
# the shared tree; the orchestrator's build never sees these targets.
#
# Vendored FTXUI (v5.0.0) is added as static library targets and linked into a
# single `backend_tui` executable. Pure-logic translation units live in
# wip/P8/*.cpp (also globbed into sa_tests by tests/CMakeLists.txt); the
# interactive rendering + entry point live in wip/P8/tui/ so their main()/event
# loop symbols never pollute the Catch2 test executable.

if(TARGET backend_tui)
  return()
endif()

# Build FTXUI purely as embedded static libs: no install, no examples/docs/tests.
set(FTXUI_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(FTXUI_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(FTXUI_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(FTXUI_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(FTXUI_QUIET ON CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/wip/P8/third_party/ftxui")

# sa_tests already globbed wip/P8/*.cpp (including render_dom.cpp, which uses the
# ftxui DOM) — give it the DOM/screen headers+lib so those snapshot tests link.
if(TARGET sa_tests)
  target_link_libraries(sa_tests PRIVATE ftxui::dom)
endif()

# backend_tui: pure logic (wip/P8/*.cpp minus tests/main) + interactive layer
# (wip/P8/tui/*.cpp). Reuse sa_core for outbound HTTP (WinHTTP) + json + paths.
file(GLOB P8_LOGIC_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/wip/P8/*.cpp")
list(FILTER P8_LOGIC_SOURCES EXCLUDE REGEX "test_.*\\.cpp$")
file(GLOB P8_TUI_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/wip/P8/tui/*.cpp")

add_executable(backend_tui ${P8_LOGIC_SOURCES} ${P8_TUI_SOURCES})
target_include_directories(backend_tui PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/wip/P8")
target_link_libraries(backend_tui PRIVATE sa_core ftxui::component)
set_target_properties(backend_tui PROPERTIES OUTPUT_NAME "backend_tui")
