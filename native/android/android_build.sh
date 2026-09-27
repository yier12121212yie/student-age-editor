#!/usr/bin/env bash
# W4-4: cross-build libbackend_shared.so (the native C++ distribution backend
# for the Android APK) and drop it into the Flutter app's jniLibs tree.
#
# Replaces the Chaquopy python-embedding channel: MainActivity.kt loads this
# .so and calls nativeStart/nativeStop (see jni_bridge.cpp).
#
# Mechanism: official root tree (`-S native`) + the NDK toolchain. The toolchain
# sets ANDROID, which makes native/CMakeLists.txt explicitly include
# native/android/group.cmake (the backend_shared target definition, permanent
# since W5-4). cli/tui/tests are configured but never built (only the target is
# requested).
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
# override wins, then a vswhere-probed VS installation, then the legacy
# hardcoded paths as a last-resort fallback, then PATH.
first_existing() {  # args: candidate paths (may be empty); prints the first real one
    for c in "$@"; do
        if [ -n "$c" ] && { [ -x "$c" ] || [ -f "$c" ]; }; then printf '%s\n' "$c"; return 0; fi
    done
    return 1
}
# vswhere 是官方的 VS/BuildTools 发现机制：不依赖任何写死的安装盘符。
VS_DIR=""
VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
if [ -f "$VSWHERE" ]; then
    VS_DIR="$("$VSWHERE" -utf8 -latest -products '*' \
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
        -property installationPath 2>/dev/null | head -1 || true)"
fi
CMAKE="${CMAKE_BIN:-$(first_existing \
    "$VS_DIR/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe" \
    /d/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe \
    "$(command -v cmake 2>/dev/null || true)" || true)}"
NINJA="${NINJA_BIN:-$(first_existing \
    "$VS_DIR/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe" \
    /d/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe \
    "$(command -v ninja 2>/dev/null || true)" || true)}"
API="${ANDROID_API:-24}"
ABIS="${*:-arm64-v8a x86_64}"

[ -d "$NDK" ] || { echo "[android_build] ERROR: NDK not found at '$NDK' (set NDK_DIR/ANDROID_HOME)" >&2; exit 2; }
[ -n "$CMAKE" ] || { echo "[android_build] ERROR: cmake not found (set CMAKE_BIN or put it on PATH)" >&2; exit 2; }
[ -n "$NINJA" ] || { echo "[android_build] ERROR: ninja not found (set NINJA_BIN or put it on PATH)" >&2; exit 2; }

# NDK-bundled llvm-strip (multi-target: one binary handles arm64-v8a and x86_64).
# The Release build type only turns on -O; it does NOT strip — the produced .so
# still carries ~76MB of .debug_*/.symtab (see strip step in the loop below).
case "$(uname -s 2>/dev/null || echo UNKNOWN)" in
    Linux*)  NDK_HOST="linux-x86_64";  STRIP_BIN="llvm-strip" ;;
    Darwin*) NDK_HOST="darwin-x86_64"; STRIP_BIN="llvm-strip" ;;
    *)       NDK_HOST="windows-x86_64"; STRIP_BIN="llvm-strip.exe" ;;  # Git Bash/MSYS on the Win host
esac
STRIP="$(first_existing \
    "$NDK/toolchains/llvm/prebuilt/$NDK_HOST/bin/$STRIP_BIN" \
    "$(ls "$NDK"/toolchains/llvm/prebuilt/*/bin/"$STRIP_BIN" 2>/dev/null | head -1 || true)" || true)"

# NDK ships llvm-strip (multi-target: one binary handles both ABIs). Resolve it
# the same way as cmake/ninja: known host tag first, then any prebuilt dir.
case "$(uname -s 2>/dev/null || echo)" in
    Linux*)  NDK_HOST="linux-x86_64";  EXE="" ;;
    Darwin*) NDK_HOST="darwin-x86_64"; EXE="" ;;
    *)       NDK_HOST="windows-x86_64"; EXE=".exe" ;;
esac
STRIP="$(first_existing \
    "$NDK/toolchains/llvm/prebuilt/$NDK_HOST/bin/llvm-strip$EXE" \
    "$(ls "$NDK"/toolchains/llvm/prebuilt/*/bin/llvm-strip"$EXE" 2>/dev/null | head -1 || true)" || true)"

for abi in $ABIS; do
    build="$SCRIPT_DIR/build-$abi"
    "$CMAKE" -G Ninja -S "$NATIVE_DIR" -B "$build" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM="android-$API" \
        -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_MAKE_PROGRAM="$NINJA"
    "$CMAKE" --build "$build" --target backend_shared

    so="$(find "$build" -name 'libbackend_shared.so' -type f | head -1)"
    [ -n "$so" ] || { echo "[android_build] ERROR: libbackend_shared.so missing after build" >&2; exit 1; }
    out="$REPO_DIR/frontend/android/app/src/main/jniLibs/$abi"
    mkdir -p "$out"
    cp "$so" "$out/libbackend_shared.so"
    # Strip the jniLibs copy that gets packaged into the APK (AGP strips again at
    # packaging as a safety net; doing it here shrinks the ~76MB of .debug_*/.symtab
    # out of the working artifact and speeds up the gradle merge step).
    # --strip-unneeded keeps .dynsym intact, so the JNI exports (nativeStart/
    # nativeStop/http*) are unaffected. The UNSTRIPPED original stays in the CMake
    # build dir ($build) — use it as the symbol file for ndk-stack/addr2line when
    # symbolising crashes.
    if [ -n "$STRIP" ]; then
        "$STRIP" --strip-unneeded "$out/libbackend_shared.so"
    else
        echo "[android_build] WARN: llvm-strip not found under NDK ('$NDK'), jniLibs copy stays unstripped" >&2
    fi
    ls -l "$out/libbackend_shared.so"
    echo "[android_build] $abi OK (unstripped symbol copy: $so)"
done
echo "[android_build] done: $ABIS"
