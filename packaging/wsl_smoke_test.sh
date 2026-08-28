#!/usr/bin/env bash
set -euxo pipefail
# Linux 发行版冒烟测试（在 WSL 内运行，需 root）：
#   1) 便携目录 backend ping
#   2) install.sh 静默安装 → ping → 卸载
#   3) deb 安装 → ping → 卸载
#   4) AppImage 解包 → ping
# 版本号从 frontend/pubspec.yaml 读取，无需手工改。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VER="$(grep -m1 '^version:' frontend/pubspec.yaml \
  | sed -E 's/^version:[[:space:]]*([0-9]+(\.[0-9]+){1,3})(\+[0-9]+)?[[:space:]]*$/\1/')"
OUT_DIR="dist/学生时代模组编辑器-v$VER-linux"
DEB="dist/student-age-editor_${VER}_amd64.deb"
APPIMAGE="dist/学生时代模组编辑器-v${VER}-linux-amd64.AppImage"

ping_backend() {  # $1=backend 路径 $2=端口
  "$1" --port "$2" &
  local pid=$!
  local ok=0
  for _ in $(seq 1 40); do
    if python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:$2/api/ping',timeout=2)" 2>/dev/null; then
      ok=1
      break
    fi
    sleep 0.5
  done
  curl -s -X POST "http://127.0.0.1:$2/api/shutdown" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  if [ "$ok" != "1" ]; then
    echo "BACKEND_PING_FAILED: $1" >&2
    exit 1
  fi
  echo "PING_OK $1"
}

if [ ! -x "$OUT_DIR/backend" ]; then
  echo "跳过：便携目录不存在 $OUT_DIR（先运行 wsl_build_linux.sh）" >&2
  exit 1
fi

# 1) 便携 zip 目录
ping_backend "$OUT_DIR/backend" 8799

# 2) install.sh 静默安装 → 卸载
"$OUT_DIR/install.sh" --yes --dir /tmp/sae-smoke \
  --components gui,officialpack --commands cli --no-desktop-icon
ping_backend /tmp/sae-smoke/backend 8798
"$OUT_DIR/install.sh" --uninstall --yes --dir /tmp/sae-smoke
if [ -d /tmp/sae-smoke ]; then
  echo "UNINSTALL_FAILED: /tmp/sae-smoke 仍存在" >&2
  exit 1
fi
echo "INSTALL_UNINSTALL_OK"

# 3) deb 安装 → 卸载
dpkg -i "$DEB"
ping_backend /opt/student-age-editor/backend 8797
dpkg -r student-age-editor
echo "DEB_OK"

# 4) AppImage 解包 → 后端 ping（GUI 无显示环境不启动）
"$APPIMAGE" --appimage-extract >/dev/null
ping_backend squashfs-root/usr/share/student-age-editor/backend 8796
rm -rf squashfs-root
echo "APPIMAGE_OK"

# 拷贝产物回 Windows（仅当宿主盘可写时）
WIN_DST="/mnt/d/Program Files/Steam/steamapps/common/StudentAge/editor/dist"
if [ -d "$WIN_DST" ]; then
  cp -f "$OUT_DIR.zip" "$DEB" "$APPIMAGE" "$WIN_DST/" 2>/dev/null || true
  echo "已拷贝产物到 $WIN_DST"
fi
echo "=== ALL SMOKE TESTS PASSED ==="