# W4-4 Android JNI channel target (via the root SA_GROUP_WIP hook, the
# orchestrator's sanctioned mechanism for adding a target without editing any
# shared build file): configure with
#   cmake -S native -B <dir> -DSA_GROUP_WIP=android <NDK toolchain>
# and `cmake --build <dir> --target backend_shared`. cli/tui/tests are only
# CONFIGURED (their objects are never built for Android).
#
# Deviation note vs the wave brief ("standalone native/android/CMakeLists.txt
# add_subdirectory-ing the native root"): measured impossible — CMAKE_SOURCE_DIR
# re-computes to the outermost CMakeLists (native/android) and cannot be
# overridden by set(), while native/tests/CMakeLists.txt resolves the vendored
# catch2 through it. The hook keeps native/ on top so the whole official tree
# configures UNCHANGED.
# Inside this hook, ${CMAKE_CURRENT_SOURCE_DIR} is native/ (root CMakeLists).

if(NOT ANDROID)
    # Only meaningful in an NDK cross build; configuring the hook in a host
    # build (someone forgetting the toolchain file) must not half-build JNI
    # sources with MSVC (jni.h absent / dlfcn semantics).
    message(FATAL_ERROR "SA_GROUP_WIP=android requires the NDK toolchain (-DANDROID... via android.toolchain.cmake)")
endif()

# http_client.cpp's __ANDROID__ stub yields when this is defined; sa_core must
# see it (its own compilation gets PUBLIC definitions).
target_compile_definitions(sa_core PUBLIC SA_ANDROID_HTTP_BRIDGE)

# bionic has no <iconv.h> (p3b_fs_tools.cpp is a W4-3 don't-touch TU): the
# shim dir supplies the declarations and the shim TU makes iconv_open fail,
# driving p3b's own utf8-replace degrade branch. Android-only path additions.
target_include_directories(sa_server PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/android/shim")

add_library(backend_shared SHARED
    "${CMAKE_CURRENT_SOURCE_DIR}/android/jni_bridge.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/android/http_jni_bridge.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/android/shim/iconv_shim.cpp")
target_include_directories(backend_shared PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/android")
target_link_libraries(backend_shared PRIVATE sa_server)
target_compile_features(backend_shared PRIVATE cxx_std_20)

# __android_log_print for logcat observability (tag StudentAgeBackend).
find_library(ANDROID_LOG_LIB log)
target_link_libraries(backend_shared PRIVATE ${ANDROID_LOG_LIB})
