# backend: the native HTTP server (CONVENTIONS 1 layout).
#
# sa_server is everything but main.cpp — the transport, the caches, the write
# pipeline, the state and the route services. The `backend` executable is just
# main.cpp + link, so Catch2 tests can drive the exact same router/transport
# in-process (test_s1's `build_router()` equivalent) without duplicating code.
#
# Sources are glob-collected: adding a service file never touches this script.
file(GLOB SA_SERVER_SOURCES CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")
list(REMOVE_ITEM SA_SERVER_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
file(GLOB SA_SERVER_SERVICE_SOURCES CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/services/*.cpp")

add_library(sa_server STATIC
    ${SA_SERVER_SOURCES}
    ${SA_SERVER_SERVICE_SOURCES}
)

# Services include each other and the transport as "server/..." from native/.
# Wave-2 merge: the services directory is itself on the include path so the
# merged files keep their bare-name cross-includes ("p3b_miniz_config.h" etc.).
target_include_directories(sa_server PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/.."
    "${CMAKE_CURRENT_SOURCE_DIR}/services")
target_link_libraries(sa_server PUBLIC sa_core)
target_compile_features(sa_server PUBLIC cxx_std_20)
add_library(sa::server ALIAS sa_server)

add_executable(backend main.cpp)
target_link_libraries(backend PRIVATE sa_server)

# Raw Winsock transport (server/httpd.cpp) — mirrors the ws2_32 wiring the
# vendored cpp-httplib needs (kept for the test client, see tests/).
if(WIN32)
    target_link_libraries(sa_server PUBLIC ws2_32)
    target_link_libraries(backend PRIVATE ws2_32)
endif()

# p3b_fs_tools.cpp 的 POSIX 分支包含 <iconv.h>（glibc 把 iconv 收进 libc，无
# 链接依赖），但 macOS 的 iconv 在独立 libiconv.dylib，需显式链接；Android 走
# android/group.cmake 的 shim（bionic 无 iconv），不经过这里。
if(APPLE)
    find_library(SA_LIBICONV iconv)
    if(SA_LIBICONV)
        target_link_libraries(sa_server PUBLIC "${SA_LIBICONV}")
    endif()
endif()

# No OpenSSL: SHA-256 (revision_manager) goes through sa_core's self-contained
# implementation, so the Android NDK cross-build configures without it too.
# HTTP-only: do NOT define CPPHTTPLIB_OPENSSL_SUPPORT. Reserved for a later wave.
set_target_properties(backend PROPERTIES OUTPUT_NAME "backend")
