#!/usr/bin/env bash
set -euxo pipefail
cd /root/editorbuild/editor/frontend/build/linux/x64/release
grep -E "CMAKE_INSTALL_PREFIX|BINARY_NAME" CMakeCache.txt || true
echo "=== install manifest ==="
cat install_manifest.txt || true
echo "=== find binaries ==="
find /root/editorbuild/editor/frontend/build -name "student_age_editor*" 2>/dev/null
find /root/editorbuild/editor/frontend/build -name "libflutter_linux_gtk.so" 2>/dev/null | head -5
