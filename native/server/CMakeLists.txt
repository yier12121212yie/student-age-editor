# backend: the native HTTP server executable (cpp-httplib + sa_core).
add_executable(backend
    main.cpp
)

target_link_libraries(backend PRIVATE sa_core)

# cpp-httplib HTTP-only build requires these Windows sockets libraries.
if(WIN32)
    target_link_libraries(backend PRIVATE ws2_32)
endif()

# HTTP-only: do NOT define CPPHTTPLIB_OPENSSL_SUPPORT. Reserved for a later wave.
set_target_properties(backend PROPERTIES OUTPUT_NAME "backend")
