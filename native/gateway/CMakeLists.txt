# backend_gateway: the online hosting gateway (网页版计划 M2). POSIX-only —
# the whole subdirectory is gated by `if(UNIX)` in native/CMakeLists.txt, and
# the instance pool uses fork/exec/killpg. It reuses the frozen M1 transport
# and services by linking sa_server (which PUBLIC-ly carries sa_core, the
# vendored headers and the native/ include root); it does NOT touch server/.
#
# Split like server/: everything but main.cpp is a static library (sa_gateway)
# so the Catch2 suite can drive the exact same routes/ban-table/sessions code
# in-process without duplicating it. main.cpp holds only the CLI + boot wiring.
add_library(sa_gateway STATIC
    gw_config.cpp
    gw_sessions.cpp
    gw_usage.cpp
    gw_proxy.cpp
    gw_pool.cpp
)
target_include_directories(sa_gateway PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_link_libraries(sa_gateway PUBLIC sa_server sa_core)
target_compile_features(sa_gateway PUBLIC cxx_std_20)
add_library(sa::gateway ALIAS sa_gateway)

find_package(Threads REQUIRED)
target_link_libraries(sa_gateway PUBLIC Threads::Threads)

add_executable(backend_gateway main.cpp)
target_link_libraries(backend_gateway PRIVATE sa_gateway)
set_target_properties(backend_gateway PROPERTIES OUTPUT_NAME "backend_gateway")

# The gateway unit + integration suite lives in the shared sa_tests binary
# (tests/CMakeLists.txt globs test_*.cpp). sa_gateway is only declared on
# UNIX, so the link is guarded — Windows builds the same sa_tests without it,
# and tests/test_gateway.cpp is a `#ifndef _WIN32` TU that compiles to nothing
# there, so the Windows gate is byte-for-byte unaffected.
if(TARGET sa_tests)
    target_link_libraries(sa_tests PRIVATE sa_gateway)
endif()
