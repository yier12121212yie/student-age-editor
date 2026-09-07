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
