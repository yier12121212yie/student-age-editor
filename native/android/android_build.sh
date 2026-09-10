#!/usr/bin/env bash
# W4-4: cross-build libbackend_shared.so (the native C++ distribution backend
# for the Android APK) and drop it into the Flutter app's jniLibs tree.
#
# Replaces the Chaquopy python-embedding channel: MainActivity.kt loads this
# .so and calls nativeStart/nativeStop (see jni_bridge.cpp).
#
# Mechanism: official root tree (`-S native`) + the orchestrator's parallel-
# wave hook `-DSA_GROUP_WIP=android` (native/wip/android/group.cmake defines
# the backend_shared target). No shared CMake file is edited; cli/tui/tests
# are configured but never built (only the target is requested).
#
# Usage (Git Bash on the Windows build host; CI runs the same on ubuntu):
#   native/android/android_build.sh                  # arm64-v8a + x86_64
#   native/android/android_build.sh arm64-v8a        # single ABI
# Env overrides: ANDROID_HOME, NDK_DIR, CMAKE_BIN, NINJA_BIN, ANDROID_API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # native/android
NATIVE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$NATIVE_DIR")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-D:/android-sdk}}"
# NDK: explicit override > pinned version under the SDK > newest installed one.
# (GitHub's ubuntu-latest ships a preinstalled NDK, so the fallback covers CI.)
NDK="${NDK_DIR:-}"
if [ -z "$NDK" ]; then
    if [ -d "$SDK/ndk/28.2.13676358" ]; then
        NDK="$SDK/ndk/28.2.13676358"
    elif [ -d "$SDK/ndk" ]; then
        NDK="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)"
    fi
fi

# cmake/ninja: CI (ubuntu) has them on PATH; the Windows build host keeps them
# under the VS Build Tools tree, which vcvars does NOT export. Explicit env
# override wins, then the Windows paths, then PATH.
first_existing() {  # args: candidate paths (may be empty); prints the first real one
    for c in "$@"; do
        if [ -n "$c" ] && { [ -x "$c" ] || [ -f "$c" ]; }; then printf '%s\n' "$c"; return 0; fi
    done
    return 1
}
CMAKE="${CMAKE_BIN:-$(first_existing \
    /d/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe \
    "$(command -v cmake 2>/dev/null || true)" || true)}"
NINJA="${NINJA_BIN:-$(first_existing \
    /d/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe \
    "$(command -v ninja 2>/dev/null || true)" || true)}"
API="${ANDROID_API:-24}"
ABIS="${*:-arm64-v8a x86_64}"

[ -d "$NDK" ] || { echo "[android_build] ERROR: NDK not found at '$NDK' (set NDK_DIR/ANDROID_HOME)" >&2; exit 2; }
[ -n "$CMAKE" ] || { echo "[android_build] ERROR: cmake not found (set CMAKE_BIN or put it on PATH)" >&2; exit 2; }
[ -n "$NINJA" ] || { echo "[android_build] ERROR: ninja not found (set NINJA_BIN or put it on PATH)" >&2; exit 2; }

for abi in $ABIS; do
    build="$SCRIPT_DIR/build-$abi"
    "$CMAKE" -G Ninja -S "$NATIVE_DIR" -B "$build" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM="android-$API" \
        -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_MAKE_PROGRAM="$NINJA" \
        -DSA_GROUP_WIP=android
    "$CMAKE" --build "$build" --target backend_shared

    so="$(find "$build" -name 'libbackend_shared.so' -type f | head -1)"
    [ -n "$so" ] || { echo "[android_build] ERROR: libbackend_shared.so missing after build" >&2; exit 1; }
    out="$REPO_DIR/frontend/android/app/src/main/jniLibs/$abi"
    mkdir -p "$out"
    cp "$so" "$out/libbackend_shared.so"
    ls -l "$out/libbackend_shared.so"
    echo "[android_build] $abi OK"
done
echo "[android_build] done: $ABIS"
