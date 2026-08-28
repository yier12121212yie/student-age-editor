#!/usr/bin/env bash
# 将 Linux 便携发行目录打包为 AppImage（AppDir + appimagetool）。
#
# 用法：make_appimage.sh --source <zip发行目录> --version X.Y.Z --output <dist目录>
# 由 build_release.py 调用；调用前会设置 APPIMAGETOOL 环境变量指向工具路径。
#
# 说明：AppImage 以只读 squashfs 挂载，后端（core/paths.py）会自动
# 将缓存/日志回退到 ~/.local/share/student-age-editor，无需额外处理。
set -euo pipefail

APP_NAME="学生时代模组编辑器"
PKG_ID="student-age-editor"
SRC=""; VER=""; OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SRC="$2"; shift 2 ;;
    --version) VER="$2"; shift 2 ;;
    --output) OUT="$2"; shift 2 ;;
    *) echo "错误：未知参数 $1" >&2; exit 1 ;;
  esac
done
[[ -n "$SRC" && -n "$VER" && -n "$OUT" ]] || { echo "用法：$0 --source <目录> --version <版本> --output <目录>" >&2; exit 1; }
[[ -d "$SRC" ]] || { echo "错误：--source 目录不存在：$SRC" >&2; exit 1; }
[[ -f "$SRC/$APP_NAME" ]] || { echo "错误：--source 缺少主程序 $APP_NAME" >&2; exit 1; }
case "$(uname -m)" in
  x86_64|amd64) ;;
  *) echo "警告：当前架构 $(uname -m) 与产物命名 amd64 不符" >&2 ;;
esac
mkdir -p "$OUT"

# 定位 appimagetool：环境变量 → 常见本地路径 → PATH
TOOL="${APPIMAGETOOL:-}"
if [[ -z "$TOOL" || ! -f "$TOOL" ]]; then
  for c in "$PWD/appimagetool-x86_64.AppImage" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/appimagetool-x86_64.AppImage"; do
    if [[ -f "$c" ]]; then TOOL="$c"; break; fi
  done
fi
if [[ -z "$TOOL" || ! -f "$TOOL" ]]; then
  TOOL="$(command -v appimagetool || true)"
fi
if [[ -z "$TOOL" || ! -f "$TOOL" ]]; then
  echo "错误：未找到 appimagetool。请下载并设置环境变量 APPIMAGETOOL：" >&2
  echo "  mkdir -p build/tools && curl -L -o build/tools/appimagetool-x86_64.AppImage \\" >&2
  echo "    https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/$PKG_ID.AppDir"
mkdir -p "$APPDIR/usr/share/$PKG_ID" \
         "$APPDIR/usr/share/icons/hicolor/512x512/apps"
cp -R "$SRC/." "$APPDIR/usr/share/$PKG_ID/"
chmod 0755 "$APPDIR/usr/share/$PKG_ID/$APP_NAME" \
          "$APPDIR/usr/share/$PKG_ID/backend" 2>/dev/null || true

# AppRun：GUI 主程序从真实位置启动（后端为其兄弟目录，启动逻辑不变）
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/share/student-age-editor/学生时代模组编辑器" "$@"
EOF
chmod 0755 "$APPDIR/AppRun"

# desktop 入口（Exec 用 AppRun 约定）与图标
DESKTOP_TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/student-age-editor.desktop"
sed "s|__INSTALL_DIR__|/usr/share/$PKG_ID|" "$DESKTOP_TEMPLATE" \
  | sed 's|^Exec=.*|Exec=AppRun|' > "$APPDIR/$PKG_ID.desktop"
chmod 0644 "$APPDIR/$PKG_ID.desktop" 2>/dev/null || true
if [[ -f "$SRC/editor_icon.png" ]]; then
  cp "$SRC/editor_icon.png" "$APPDIR/.DirIcon"
  cp "$SRC/editor_icon.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/$PKG_ID.png"
  # appimagetool 校验 desktop 的 Icon 时只查 AppDir 根目录
  cp "$SRC/editor_icon.png" "$APPDIR/$PKG_ID.png"
else
  echo "警告：未找到 editor_icon.png，AppImage 无图标" >&2
fi

OUT_FILE="$OUT/$APP_NAME-v$VER-linux-amd64.AppImage"
rm -f "$OUT_FILE"
if [[ "$TOOL" == *.AppImage ]]; then
  "$TOOL" --appimage-extract-and-run "$APPDIR" "$OUT_FILE"
else
  "$TOOL" "$APPDIR" "$OUT_FILE"
fi
echo "完成：$OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"