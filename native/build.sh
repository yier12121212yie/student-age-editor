#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot native backend build for POSIX hosts (Linux / macOS). This is the
# counterpart of build.cmd, which stays Windows-only (vcvars64 + MSVC). Here we
# assume the toolchain is already on PATH: cmake, ninja and a C++20 compiler
# (g++ or clang++). Run from anywhere:
#
#     ./native/build.sh                 # default build dir (build-linux on WSL)
#     BUILD_DIR=build ./native/build.sh # explicit build dir
#     BUILD_TYPE=Debug ./native/build.sh
#
# Exit code 0 == configure + build + tests all green.
#
# NOTE: on Windows/WSL the NTFS repo also carries the MSVC build/ tree. NEVER
# point this at it. When running under WSL the default is build-linux so the
# two configure caches never collide (see the WSL_DISTRO_NAME branch below).
# ---------------------------------------------------------------------------
set -euo pipefail

# Directory this script lives in (native/), absolute.
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build dir selection. Precedence: explicit BUILD_DIR, else build-linux under
# WSL (to avoid the Windows-owned build/ on the shared NTFS mount), else build.
if [[ -z "${BUILD_DIR:-}" ]]; then
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        BUILD_DIR="$NATIVE_DIR/build-linux"
    else
        BUILD_DIR="$NATIVE_DIR/build"
    fi
fi
BUILD_TYPE="${BUILD_TYPE:-Release}"

echo "[build.sh] native dir: $NATIVE_DIR"
echo "[build.sh] build dir:  $BUILD_DIR"
echo "[build.sh] build type: $BUILD_TYPE"

# --- preflight: required tools ----------------------------------------------
missing=0
for tool in cmake ninja; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[build.sh] ERROR: '$tool' not found on PATH" >&2
        missing=1
    fi
done
# A C++20 compiler must be reachable: honor $CXX if set, else need g++/clang++.
if [[ -n "${CXX:-}" ]]; then
    if ! command -v "$CXX" >/dev/null 2>&1; then
        echo "[build.sh] ERROR: \$CXX='$CXX' not found on PATH" >&2
        missing=1
    fi
elif ! command -v g++ >/dev/null 2>&1 && ! command -v clang++ >/dev/null 2>&1; then
    echo "[build.sh] ERROR: no C++ compiler (g++/clang++) found on PATH" >&2
    missing=1
fi
[ "$missing" -eq 0 ] || exit 2

echo "[build.sh] cmake: $(cmake --version | head -1)"
echo "[build.sh] ninja: $(ninja --version)"

# --- configure --------------------------------------------------------------
# Release is the gate build (parity with build.cmd): the 40MB [perf][slow]
# cases need an optimized JSON path. Override with BUILD_TYPE=Debug.
echo
echo "[build.sh] === configure (Ninja, $BUILD_TYPE) -> $BUILD_DIR ==="
cmake -G Ninja -S "$NATIVE_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="$BUILD_TYPE"

# --- build ------------------------------------------------------------------
# Default "all" target, mirroring build.cmd: sa_tests + sa_core/sa_server/
# sa_cli/sa_tui + the backend / backend_cli / backend_tui executables all
# compile on POSIX since W4-2/W4-3 (shell32 link is WIN32-guarded,
# http_client dlopens libcurl, p5_mock has a BSD-socket branch).
echo
echo "[build.sh] === build (all) ==="
cmake --build "$BUILD_DIR" --config "$BUILD_TYPE"

# --- test -------------------------------------------------------------------
# The Catch2 binary is 'sa_tests' on POSIX (no .exe suffix, unlike build.cmd).
# Default exclusions cover the cases that are not yet POSIX-runnable:
#   [httpd]  wire-level cases that bind a real port and drive httplib::Client
#            hang on POSIX (W4-2 WSL evidence; tracked for W4-4/W4-5)
#   [slow]   the 40MB [perf][s1][s2][bench][slow] acceptance cases (already
#            covered by the Windows gate; IO-heavy over the WSL NTFS mount)
#   [network]  the one real-HTTPS case in test_http_client_posix.cpp
# Vendored Catch2 reports v3.7.1 but without the --exclude-tags option:
# exclusions go through the positional '~[tag]' test-spec list (verified the
# 3 specs drop exactly the tagged cases). Intentional word-split below.
# Override e.g. TEST_ARGS='' to run everything.
TEST_ARGS="${TEST_ARGS:-~[httpd] ~[slow] ~[network]}"
echo
echo "[build.sh] === test (sa_tests $TEST_ARGS) ==="
# shellcheck disable=SC2086  # intentional word-split of TEST_ARGS
"$BUILD_DIR/bin/sa_tests" $TEST_ARGS

echo
echo "[build.sh] ALL GREEN (configure + build + tests)"
echo "[build.sh] server binary: $BUILD_DIR/bin/backend"
