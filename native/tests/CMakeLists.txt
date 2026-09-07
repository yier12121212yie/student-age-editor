# sa_tests: Catch2 unit tests linking sa_core.
#
# Uses the vendored amalgamated Catch2 (third_party/catch2/catch_amalgamated.*).
# catch_amalgamated.cpp provides the default Catch `main()` entry point (guarded
# by CATCH_AMALGAMATED_CUSTOM_MAIN, which we intentionally leave undefined), so
# the test .cpp files below contain only TEST_CASE(...) blocks and add no main.
add_executable(sa_tests
    "${CMAKE_SOURCE_DIR}/third_party/catch2/catch_amalgamated.cpp"
    test_strings.cpp
    test_json_wire.cpp
)

target_link_libraries(sa_tests PRIVATE sa_core)

# <catch_amalgamated.hpp> include dir is already on sa_third_party (via sa_core);
# restate it here for clarity since this TU includes it directly.
target_include_directories(sa_tests PRIVATE "${CMAKE_SOURCE_DIR}/third_party/catch2")

add_test(NAME sa_tests COMMAND sa_tests)
