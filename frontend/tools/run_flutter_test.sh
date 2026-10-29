#!/usr/bin/env bash
# 在本环境里跑 flutter test 的替代路径。
#
# 背景：`flutter test` / `dart test` 在本机不可用（Dart VM 无法 spawn 子进程；
# frontend_server 对 `--sdk-root` 传 URI 会在 Windows 上抛
# "Illegal character in path"）。下面这套调用实测可用：
#   1. 复制 .dart_tool/package_config.json，把 rootUri 全部改成绝对 file:// URI；
#   2. 用 frontend_server_aot 编译测试为 kernel（--sdk-root 用纯路径 + 结尾斜杠，
#      --platform 用 file:// URI）；
#   3. 用 flutter_tester.exe 直接跑这个 dill。
#
# 用法： tools/run_flutter_test.sh test/xxx_test.dart [more...]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FLUTTER_SDK="${FLUTTER_SDK:-/d/flutter/flutter}"
DART_SDK="$FLUTTER_SDK/bin/cache/dart-sdk"
DARTAOT="$DART_SDK/bin/dartaotruntime.exe"
FS="$FLUTTER_SDK/bin/cache/artifacts/engine/windows-x64/frontend_server_aot.dart.snapshot"
FT="$FLUTTER_SDK/bin/cache/artifacts/engine/windows-x64/flutter_tester.exe"
SDK_COMMON="$FLUTTER_SDK/bin/cache/artifacts/engine/common/flutter_patched_sdk"
# 纯路径（frontend_server 只接受这种形式作为 --sdk-root）
SDK_ROOT_PATH="$(cygpath -m "$SDK_COMMON")/"
PLATFORM_URI="file:///$(cygpath -m "$SDK_COMMON")/platform_strong.dill"

PY="${PY:-python}"
VENV_DIR="$DART_SDK/../../.venv_fluttertest"

WORK=".tmp_build"
mkdir -p "$WORK"

# --- 1. 绝对化 package_config ---
PKG_ABS="$WORK/pkg_abs.json"
"$PY" - "$ROOT" "$PKG_ABS" <<'PYEOF'
import json, os, sys
root, dst = sys.argv[1], sys.argv[2]
src = os.path.join(root, ".dart_tool", "package_config.json")
d = json.load(open(src, encoding="utf-8"))
base = os.path.dirname(src)
for p in d["packages"]:
    ru = p["rootUri"]
    if not ru.startswith("file://"):
        ap = os.path.normpath(os.path.join(base, ru.replace("/", os.sep)))
        p["rootUri"] = "file:///" + ap.replace("\\", "/")
json.dump(d, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF

rc=0
for f in "$@"; do
  name="$(basename "$f" .dart)"
  dill="$WORK/$name.dill"
  echo "=== compile $f ==="
  "$DARTAOT" "$FS" \
    "--sdk-root=$SDK_ROOT_PATH" \
    "--platform=$PLATFORM_URI" \
    --target=flutter \
    --packages="$(cygpath -m "$ROOT/$PKG_ABS")" \
    --output-dill="$dill" \
    "$f" > "$WORK/$name.compile.log" 2>&1
  # frontend_server 成功时会打印结果行 + 一串 "+file://..." 依赖清单
  if ! grep -q '^+file://' "$WORK/$name.compile.log"; then
    echo "--- compile FAILED ---"
    head -40 "$WORK/$name.compile.log"
    rc=1
    continue
  fi
  echo "=== run $name ==="
  # 关键：FLUTTER_TEST=true（flutter_test binding 靠它识别「由 flutter test 启动」），
  # 以及 --non-interactive / --use-test-fonts / --packages=。缺任一都会挂起。
  # --flutter-assets-dir 指向 `flutter test` 预构建好的 unit_test_assets，
  # 否则部分测试会因找不到 shaders/ink_sparkle.frag 之类资源而失败。
  assets_arg=()
  if [ -d "$ROOT/build/unit_test_assets" ]; then
    assets_arg=("--flutter-assets-dir=$(cygpath -m "$ROOT/build/unit_test_assets")")
  fi
  FLUTTER_TEST=true "$FT" \
    --disable-vm-service \
    --enable-checked-mode \
    --verify-entry-points \
    --enable-software-rendering \
    --skia-deterministic-rendering \
    --non-interactive \
    --use-test-fonts \
    --disable-asset-fonts \
    "--icu-data-file-path=$FLUTTER_SDK/bin/cache/artifacts/engine/windows-x64/icudtl.dat" \
    "--packages=$(cygpath -m "$ROOT/.dart_tool/package_config.json")" \
    "${assets_arg[@]}" \
    "$dill" < /dev/null 2>&1 | grep -v 'ApiClient\]'
  status="${PIPESTATUS[0]}"
  if [ "$status" -ne 0 ]; then rc=1; fi
done
exit $rc
