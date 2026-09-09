# backend_cli — native CLI (merged wave-3 group P7, ex wip/P7).
#
# Layout discipline inherited from wip/P7/group.cmake:8-11: p7_cli_logic.cpp is
# pure logic and compiles into `sa_cli` (shared with sa_tests via the PUBLIC
# link below); p7_cli_main.cpp owns the executable's main() + embedded-server
# bootstrap and is enumerated ONLY for backend_cli. Do NOT glob *.cpp here —
# a glob would drag main() into sa_cli and collide with the Catch2-provided
# main() in sa_tests.
add_library(sa_cli STATIC p7_cli_logic.cpp)
target_include_directories(sa_cli PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
# <nlohmann/json.hpp> and <CLI11/CLI11.hpp> both arrive transitively through
# sa_core -> sa_third_party (root CMakeLists.txt:35-40). The vendored CLI11
# subdir needs NO extra include-path entry: third_party/ itself is an
# INTERFACE dir (root :37, the exact mechanism <nlohmann/json.hpp> uses).
target_link_libraries(sa_cli PUBLIC sa_core)
target_compile_features(sa_cli PUBLIC cxx_std_20)

add_executable(backend_cli p7_cli_main.cpp)
# shell32 = CommandLineToArgvW/LocalFree in utf8_args (p7_cli_main.cpp:60-72;
# same need as wip/P7/group.cmake:19). winhttp/advapi32 come PUBLIC from
# sa_core (core/CMakeLists.txt:22); ws2_32 from sa_server (server/CMakeLists.txt:36).
target_link_libraries(backend_cli PRIVATE sa_cli sa_server sa_core shell32)
set_target_properties(backend_cli PROPERTIES OUTPUT_NAME "backend_cli")
