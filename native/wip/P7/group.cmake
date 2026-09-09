# wip/P7/group.cmake — P7 (CLI) target definitions.
#
# Included by native/CMakeLists.txt when configured with -DSA_GROUP_WIP=P7.
# ${CMAKE_CURRENT_SOURCE_DIR} here is native/ (the hook runs at top scope).
#
# Layout ownership reminder: only wip/P7/* is ours. The SA_GROUP_WIP block in
# tests/CMakeLists.txt already globs wip/P7/test_*.cpp AND wip/P7/*.cpp into
# sa_tests (minus main.cpp), so every .cpp sitting directly in wip/P7/ must be
# pure logic that the test exe wants to link. The CLI *entry point* therefore
# lives in wip/P7/cli/ (never globbed) and the testable parsing/planning/
# formatting code lives in wip/P7/p7_cli_logic.{h,cpp} (globbed on purpose).

set(SA_P7_DIR "${CMAKE_CURRENT_SOURCE_DIR}/wip/P7")

add_executable(backend_cli
    "${SA_P7_DIR}/cli/p7_cli_main.cpp"   # main() + embedded-server bootstrap
    "${SA_P7_DIR}/p7_cli_logic.cpp"      # pure logic (also in sa_tests via glob)
)
target_link_libraries(backend_cli PRIVATE sa_server sa_core shell32)
target_include_directories(backend_cli PRIVATE
    "${SA_P7_DIR}"                      # p7_cli_logic.h
    "${SA_P7_DIR}/third_party"          # <CLI11/CLI11.hpp>
)

# sa_tests needs the vendored CLI11 dir too (p7_cli_logic.cpp includes it and
# is linked into the test exe by the SA_GROUP_WIP glob).
target_include_directories(sa_tests PRIVATE "${SA_P7_DIR}/third_party")
