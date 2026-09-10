# sa_core: the shared static library (identity, string utils, wire formatter,
# UTF-8 codec, SHA-1, path/stat helpers, atomic writes, asset resolution).
add_library(sa_core STATIC
    version.cpp
    strings.cpp
    json_wire.cpp
    utf8.cpp
    sha1.cpp
    md5.cpp
    paths.cpp
    atomic_io.cpp
    util.cpp
    steam_paths.cpp
    env_store.cpp
    http_client.cpp
    assets.cpp
)

target_include_directories(sa_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")

if(WIN32)
    # steam_paths reads HKCU\Software\Valve\Steam via the registry;
    # http_client speaks WinHTTP (in-box, schannel TLS — no third-party dep).
    target_link_libraries(sa_core PUBLIC advapi32 winhttp)
endif()

# json_wire.h exposes nlohmann::ordered_json in its API, so the dependency must
# be PUBLIC to propagate the include path to server/ and tests/.
target_link_libraries(sa_core PUBLIC sa_third_party)

target_compile_features(sa_core PUBLIC cxx_std_20)

add_library(sa::core ALIAS sa_core)
