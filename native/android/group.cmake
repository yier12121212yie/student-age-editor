# Android JNI channel target (W4-4, made permanent in W5-4).
#
# Defines the `backend_shared` shared library (libbackend_shared.so), the native
# C++ distribution backend loaded by MainActivity.kt via jni_bridge.cpp.
#
# Wiring: native/CMakeLists.txt includes this file explicitly under `if(ANDROID)`
# at the end of the top-level tree:
#     if(ANDROID)
#         include("${CMAKE_CURRENT_SOURCE_DIR}/android/group.cmake")
#     endif()
# so official Windows/POSIX builds (build.cmd / build.sh / native-ci.yml), where
# ANDROID is undefined, never see it. Configure the NDK cross build via
# native/android/android_build.sh (or the equivalent
# `cmake -S native -B <dir> <NDK toolchain> && cmake --build <dir> --target backend_shared`).
# cli/tui/tests are only CONFIGURED here (their objects are never built for Android).
#
# Historical note: this file used to live at native/wip/android/group.cmake and
# was pulled in by the generic -DSA_GROUP_WIP=android hook. That migration-period
# hook is gone; the include is now explicit and ANDROID-gated (the former
# `if(NOT ANDROID) FATAL_ERROR` host-build guard is therefore redundant — a host
# build cannot reach this file at all). The root SA_GROUP_WIP hook itself stays
# for future parallel waves.
# Paths use CMAKE_CURRENT_LIST_DIR, so the file is self-contained and does not
# depend on the include site.

# http_client.cpp's __ANDROID__ stub yields when this is defined; sa_core must
# see it (its own compilation gets PUBLIC definitions).
target_compile_definitions(sa_core PUBLIC SA_ANDROID_HTTP_BRIDGE)

# bionic has no <iconv.h> (p3b_fs_tools.cpp is a W4-3 don't-touch TU): the
# shim dir supplies the declarations and the shim TU makes iconv_open fail,
# driving p3b's own utf8-replace degrade branch. Android-only path additions.
target_include_directories(sa_server PUBLIC "${CMAKE_CURRENT_LIST_DIR}/shim")

add_library(backend_shared SHARED
    "${CMAKE_CURRENT_LIST_DIR}/jni_bridge.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/http_jni_bridge.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/shim/iconv_shim.cpp")
target_include_directories(backend_shared PRIVATE "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(backend_shared PRIVATE sa_server)
target_compile_features(backend_shared PRIVATE cxx_std_20)

# __android_log_print for logcat observability (tag StudentAgeBackend).
find_library(ANDROID_LOG_LIB log)
target_link_libraries(backend_shared PRIVATE ${ANDROID_LOG_LIB})
