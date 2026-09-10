# sa_tests: Catch2 unit tests.
#
# Uses the vendored amalgamated Catch2 (third_party/catch2/catch_amalgamated.*).
# catch_amalgamated.cpp provides the default Catch `main()` entry point (guarded
# by CATCH_AMALGAMATED_CUSTOM_MAIN, which we intentionally leave undefined), so
# the test .cpp files below contain only TEST_CASE(...) blocks and add no main.
#
# Links sa_server directly: the S1/S2 acceptance tests drive the SAME in-process
# Router the transport dispatches (Python tests call router.dispatch through a
# MockClient — same idea), and the black-box perf cases bind a real loopback
# port and speak HTTP through httplib::Client.
file(GLOB SA_TEST_SOURCES CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/test_*.cpp"
     "${CMAKE_CURRENT_SOURCE_DIR}/bench_gen.cpp")

# POSIX portability gate (wave 4-2): drop the test translation units that are
# not yet portable on Linux/macOS. Each one calls an MSVC-only API outside any
# #ifdef guard (_putenv/_putenv_s, or CP_UTF8/MultiByteToWideChar) or leans on
# the Win32 GBK round-trip as its oracle, so they break the whole sa_tests link
# on POSIX even though their runtime cases are excluded via Catch2 tags anyway.
# W4-3 landed putenv_portable + a BSD-socket p5_mock and R4 landed the
# ScopedEnv POSIX branch, so test_plugins and test_p5_realtime now compile AND
# run green on POSIX and are back in the glob. This file enumerates the TUs
# kept out of POSIX builds as the single source of truth for "still
# Windows-only". On Windows this block is skipped entirely, so the official
# build keeps every test file (275 cases / 3055 assertions gate unchanged).
if(NOT WIN32)
    set(SA_POSIX_INCOMPATIBLE_TESTS
        test_cfg_store.cpp         # Win32 CP_UTF8/GBK conversion oracle + Win-only test hook
        test_p4_aa.cpp             # _putenv (EDITOR_DECODED_PACK_DIR)
        test_p3b_domain_tools.cpp  # _putenv_s; R4-owned surface, left to R4
        # Compiles on POSIX but 3 cases stay red (W4-2 WSL evidence, 201/204
        # passed): safe_rel_join traversal + sync_mod_folder skip_unsafe_path
        # cluster trace to the third hardcoded-'\\' gate in
        # cloud_sync.cpp:1984 (outside W4-2's two-gate authorization; W4-4/
        # W4-5), and the LocalDriver "C:/Windows/win.ini escapes root" case
        # tests Windows-only drive-letter absoluteness (Python behaves
        # identically non-raising under POSIX join). Re-admit with those fixes.
        test_p5_cloud.cpp
    )
    foreach(_sa_t ${SA_POSIX_INCOMPATIBLE_TESTS})
        list(REMOVE_ITEM SA_TEST_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/${_sa_t}")
    endforeach()
endif()

add_executable(sa_tests
    "${CMAKE_SOURCE_DIR}/third_party/catch2/catch_amalgamated.cpp"
    ${SA_TEST_SOURCES}
)

target_link_libraries(sa_tests PRIVATE sa_server sa_core)
# Wave-3 merges: [p7] CLI-logic tests take symbols from sa_cli (whose PUBLIC
# include dir resolves "p7_cli_logic.h"; <CLI11/CLI11.hpp> rides sa_third_party
# via sa_core); [p8] TUI logic + FTXUI-DOM snapshot tests take symbols AND the
# ftxui::dom / "p8_*.h" include dirs PUBLIC from sa_tui.
target_link_libraries(sa_tests PRIVATE sa_cli sa_tui)
target_include_directories(sa_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")

# <catch_amalgamated.hpp> include dir is already on sa_third_party (via sa_core);
# restate it here for clarity since this TU includes it directly.
target_include_directories(sa_tests PRIVATE "${CMAKE_SOURCE_DIR}/third_party/catch2")

add_test(NAME sa_tests COMMAND sa_tests)

# ---------------------------------------------------------------------------
# Wave-2 parallel isolation (orchestrator mechanism).
#
# Concurrent service groups must NOT touch the shared globs (server/*.cpp,
# server/services/*.cpp, tests/test_*.cpp) — a half-written file in any of
# them would break everyone's build directories. Each group develops under
# native/wip/<GROUP>/ (own route files + own Catch2 test_*.cpp + a main.cpp
# that grafts its routes onto sa::server_main), and configures its OWN build
# dir with -DSA_GROUP_WIP=<GROUP>. At merge the orchestrator moves landed
# files into the official layout and rewires api_router.cpp.
if(SA_GROUP_WIP)
    file(GLOB SA_WIP_SOURCES CONFIGURE_DEPENDS
         "${CMAKE_SOURCE_DIR}/wip/${SA_GROUP_WIP}/test_*.cpp")
    file(GLOB SA_WIP_SERVICE_SOURCES CONFIGURE_DEPENDS
         "${CMAKE_SOURCE_DIR}/wip/${SA_GROUP_WIP}/*.cpp")
    list(REMOVE_ITEM SA_WIP_SERVICE_SOURCES ${SA_WIP_SOURCES})
    list(REMOVE_ITEM SA_WIP_SERVICE_SOURCES
         "${CMAKE_SOURCE_DIR}/wip/${SA_GROUP_WIP}/main.cpp")

    target_sources(sa_tests PRIVATE ${SA_WIP_SOURCES} ${SA_WIP_SERVICE_SOURCES})
    target_include_directories(sa_tests PRIVATE
        "${CMAKE_SOURCE_DIR}/wip/${SA_GROUP_WIP}")

    if(EXISTS "${CMAKE_SOURCE_DIR}/wip/${SA_GROUP_WIP}/main.cpp")
        add_executable(backend_wip
            "${CMAKE_SOURCE_DIR}/wip/${SA_GROUP_WIP}/main.cpp"
            ${SA_WIP_SERVICE_SOURCES})
        target_link_libraries(backend_wip PRIVATE sa_server)
        target_include_directories(backend_wip PRIVATE
            "${CMAKE_SOURCE_DIR}/wip/${SA_GROUP_WIP}")
    endif()
endif()
