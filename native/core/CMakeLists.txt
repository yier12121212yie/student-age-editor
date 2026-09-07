# sa_core: the shared static library (identity, string utils, wire formatter).
add_library(sa_core STATIC
    version.cpp
    strings.cpp
    json_wire.cpp
)

target_include_directories(sa_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")

# json_wire.h exposes nlohmann::ordered_json in its API, so the dependency must
# be PUBLIC to propagate the include path to server/ and tests/.
target_link_libraries(sa_core PUBLIC sa_third_party)

target_compile_features(sa_core PUBLIC cxx_std_20)

add_library(sa::core ALIAS sa_core)
