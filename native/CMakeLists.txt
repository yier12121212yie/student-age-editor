# Top-level build for the native (C++) StudentAge editor backend.
#
# Toolchain assumption (see build.cmd): MSVC (vcvars64) + CMake + Ninja. It also
# configures with the "Visual Studio 17 2022" multi-config generator; only
# single-config Ninja is exercised by build.cmd.
cmake_minimum_required(VERSION 3.21)

project(StudentAgeNative
        VERSION 0.1.0
        DESCRIPTION "Native C++ backend for the StudentAge editor"
        LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Build type (single-config)" FORCE)
endif()

# Keep build artifacts out of the source tree and predictable for build.cmd.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
endif()

# Vendored single-header / amalgamated dependencies (see third_party/README.md).
# Exposed as an INTERFACE target so includes are propagated, not repeated.
add_library(sa_third_party INTERFACE)
target_include_directories(sa_third_party INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party"          # -> <nlohmann/json.hpp>
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/httplib"  # -> <httplib.h>
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/catch2"   # -> <catch_amalgamated.hpp>
)
# cpp-httplib needs Winsock on Windows; wired here because the server target
# includes <httplib.h> transitively through nothing (server links it directly),
# but core pulls nlohmann only. Linking is finalized in server/CMakeLists.txt.

if(MSVC)
    # /utf-8 so the vendored UTF-8 sources and our string literals are read as
    # UTF-8 regardless of the host ANSI codepage.
    add_compile_options(/utf-8 /W3 /permissive-)
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS NOMINMAX WIN32_LEAN_AND_MEAN)
else()
    add_compile_options(-Wall -Wextra)
    add_compile_definitions(NOMINMAX)
endif()

enable_testing()

add_subdirectory(core)
add_subdirectory(server)
add_subdirectory(tests)

# Parallel-wave hook: a group working under -DSA_GROUP_WIP=<G> may ship extra
# target definitions (own executables, vendored third-party subdirs) in
# wip/<G>/group.cmake. This keeps every shared build file orchestrator-owned.
# Inside the hook, ${CMAKE_CURRENT_SOURCE_DIR} still refers to native/.
if(SA_GROUP_WIP AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/wip/${SA_GROUP_WIP}/group.cmake")
    include("${CMAKE_CURRENT_SOURCE_DIR}/wip/${SA_GROUP_WIP}/group.cmake")
endif()
