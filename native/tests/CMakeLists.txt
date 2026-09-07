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

add_executable(sa_tests
    "${CMAKE_SOURCE_DIR}/third_party/catch2/catch_amalgamated.cpp"
    ${SA_TEST_SOURCES}
)

target_link_libraries(sa_tests PRIVATE sa_server sa_core)
target_include_directories(sa_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")

# <catch_amalgamated.hpp> include dir is already on sa_third_party (via sa_core);
# restate it here for clarity since this TU includes it directly.
target_include_directories(sa_tests PRIVATE "${CMAKE_SOURCE_DIR}/third_party/catch2")

add_test(NAME sa_tests COMMAND sa_tests)
