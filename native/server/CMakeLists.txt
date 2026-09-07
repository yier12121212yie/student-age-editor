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
target_include_directories(sa_server PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/..")
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

# HTTP-only: do NOT define CPPHTTPLIB_OPENSSL_SUPPORT. Reserved for a later wave.
set_target_properties(backend PROPERTIES OUTPUT_NAME "backend")
