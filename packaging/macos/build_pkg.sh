#!/usr/bin/env bash
# ==============================================================================
# 「学生时代模组编辑器」macOS PKG 组件安装器构建脚本
# ==============================================================================
# 用法：
#   bash packaging/macos/build_pkg.sh --app <path/to/学生时代模组编辑器.app> \
#                                     --version 1.4.0 --output <输出目录>
#
# 组件划分（对齐 Windows Inno setup.iss，见同目录 distribution.xml）：
#   core          核心运行时（.app 骨架 + 内嵌 backend/_internal），固定必选
#   gui           图形界面（GUI 主程序；postinstall 创建 editor-gui 命令）
#   tui / cli     终端/命令行界面（nopayload 脚本包；创建 editor-tui/editor-cli 命令）
#   officialpack  官方资源扩展包（.app/Contents/MacOS/official_pack）
#
# 实现：从 assemble_macos 产出的 .app 拆出三份 payload 根（gui / core /
# officialpack），分别 pkgbuild，再 productbuild 按 distribution.xml 的
# choice 定义合成带勾选页的安装包；拆包前对 .app 副本做 ad-hoc 重签
# （与 DMG 一致）。产物文件名固定，供 CI 归档：
#   <输出目录>/student-age-editor-<版本>-macos.pkg
#
# 注意：
# - 完全非交互，供 GitHub Actions macos-14 调用；除 codesign 警告外
#   任何失败均非 0 退出。
# - 本脚本须在 macOS 上运行（依赖 pkgbuild/productbuild/codesign/
#   PlistBuddy）；仓库 Windows 宿主仅做静态检查。
# - 本文件必须保持 LF 行尾。
# ==============================================================================
set -euo pipefail

APP_NAME="学生时代模组编辑器"
PKG_ID="student-age-editor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE_EOF'
用法：build_pkg.sh --app <path/to/学生时代模组编辑器.app> --version X.Y.Z --output <输出目录>

参数：
  --app      build_release.py 产出的 .app 路径（必填）
  --version  版本号，如 1.4.0（必填）
  --output   PKG 输出目录（必填）
USAGE_EOF
}

die() {
    echo "错误：$1" >&2
    exit 1
}

abs_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" ;;
    esac
}

# ----------------------------- [1/4] 参数解析与校验 -----------------------------
APP_PATH="" VERSION="" OUTPUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app)      [ $# -ge 2 ] || die "--app 缺少参数"; APP_PATH="$2"; shift 2 ;;
        --version)  [ $# -ge 2 ] || die "--version 缺少参数"; VERSION="$2"; shift 2 ;;
        --output)   [ $# -ge 2 ] || die "--output 缺少参数"; OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
done

[ -n "$APP_PATH" ]   || { usage >&2; die "缺少 --app 参数"; }
[ -n "$VERSION" ]    || { usage >&2; die "缺少 --version 参数"; }
[ -n "$OUTPUT_DIR" ] || { usage >&2; die "缺少 --output 参数"; }

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    die "版本号格式应为 x.y.z（如 1.4.0）：$VERSION"
fi

for tool in pkgbuild productbuild codesign; do
    command -v "$tool" >/dev/null 2>&1 || die "未找到 ${tool}，本脚本须在 macOS 上运行"
done
command -v PlistBuddy >/dev/null 2>&1 || command -v /usr/libexec/PlistBuddy >/dev/null 2>&1 \
    || die "未找到 PlistBuddy（macOS 自带）"

APP_PATH="${APP_PATH%/}"
[ -d "$APP_PATH" ] || die "未找到 .app：$APP_PATH"
APP_PATH="$(abs_path "$APP_PATH")"

PLIST="$APP_PATH/Contents/Info.plist"
MACOS_DIR="$APP_PATH/Contents/MacOS"
[ -f "$PLIST" ]             || die "无效的 .app（缺少 Contents/Info.plist）：$APP_PATH"
[ -f "$MACOS_DIR/backend" ] || die ".app 内缺少内嵌 backend（请先运行 build_release.py --target macos）"
[ -d "$MACOS_DIR/official_pack" ] || die ".app 内缺少 official_pack/（官方资源扩展包未内嵌，安装包前置条件不满足）"

GUIBIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null \
          || /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
[ -n "$GUIBIN" ] || die "无法读取 CFBundleExecutable"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(abs_path "$OUTPUT_DIR")"
PKG_OUT="$OUTPUT_DIR/$PKG_ID-$VERSION-macos.pkg"
echo "[1/4] 校验通过：${APP_PATH}（GUI 主程序 ${GUIBIN}）"

# ----------------------------- [2/4] staging 与 ad-hoc 重签 -----------------------------
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/studentage_pkg.XXXXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[2/4] 拷贝 .app 副本并 ad-hoc 重签 ..."
cp -R "$APP_PATH" "$WORK_DIR/app.app"
if ! codesign --force --deep --sign - "$WORK_DIR/app.app"; then
    echo "[警告] ad-hoc 重签失败，继续打包；安装后首次打开可能被拦（右键 -> 打开）。" >&2
fi

# 拆出三个 payload 根（dist 版 .app 的完整内容由 gui + core + officialpack 合并还原）
# gui：整个 .app 去掉 backend/_internal/official_pack
GUI_ROOT="$WORK_DIR/gui_root"
mkdir -p "$GUI_ROOT"
cp -R "$WORK_DIR/app.app" "$GUI_ROOT/$APP_NAME.app"
rm -rf "$GUI_ROOT/$APP_NAME.app/Contents/MacOS/backend" \
       "$GUI_ROOT/$APP_NAME.app/Contents/MacOS/_internal" \
       "$GUI_ROOT/$APP_NAME.app/Contents/MacOS/official_pack"
# core：.app 骨架 + backend/_internal（含随包说明文档）
CORE_ROOT="$WORK_DIR/core_root"
mkdir -p "$CORE_ROOT/Contents/MacOS"
cp -R "$WORK_DIR/app.app/Contents/Info.plist" "$WORK_DIR/app.app/Contents/PkgInfo" "$CORE_ROOT/Contents/" 2>/dev/null || true
for d in Frameworks Resources; do
    [ -d "$WORK_DIR/app.app/Contents/$d" ] && cp -R "$WORK_DIR/app.app/Contents/$d" "$CORE_ROOT/Contents/"
done
cp -R "$WORK_DIR/app.app/Contents/MacOS/backend" \
      "$WORK_DIR/app.app/Contents/MacOS/_internal" "$CORE_ROOT/Contents/MacOS/"
if [ -f "$(dirname "$APP_PATH")/使用说明.txt" ]; then
    cp "$(dirname "$APP_PATH")/使用说明.txt" "$CORE_ROOT/Contents/MacOS/使用说明.txt"
fi
# officialpack：仅官方资源扩展包
OP_ROOT="$WORK_DIR/op_root"
mkdir -p "$OP_ROOT/Contents/MacOS"
cp -R "$WORK_DIR/app.app/Contents/MacOS/official_pack" "$OP_ROOT/Contents/MacOS/"

# ----------------------------- [3/4] 子包（pkgbuild） -----------------------------
mkdir -p "$WORK_DIR/pkgs" "$WORK_DIR/scripts_gui" "$WORK_DIR/scripts_tui" "$WORK_DIR/scripts_cli"
BUNDLE="/Applications/$APP_NAME.app"
BIN="$BUNDLE/Contents/MacOS"

# gui / tui / cli 的 postinstall 创建 /usr/local/bin 启动命令（仅所选 choice 的包执行）
cat > "$WORK_DIR/scripts_gui/postinstall" <<EOF
#!/bin/sh
set -e
mkdir -p /usr/local/bin
printf '#!/bin/sh\\nexec "%s/%s" "\\$@"\\n' > /usr/local/bin/editor-gui
chmod 0755 /usr/local/bin/editor-gui
exit 0
EOF
cat > "$WORK_DIR/scripts_tui/postinstall" <<EOF
#!/bin/sh
set -e
mkdir -p /usr/local/bin
printf '#!/bin/sh\\nexec "%s/backend" tui "\\$@"\\n' > /usr/local/bin/editor-tui
chmod 0755 /usr/local/bin/editor-tui
exit 0
EOF
cat > "$WORK_DIR/scripts_cli/postinstall" <<EOF
#!/bin/sh
set -e
mkdir -p /usr/local/bin
printf '#!/bin/sh\\nexec "%s/backend" cli "\\$@"\\n' > /usr/local/bin/editor-cli
chmod 0755 /usr/local/bin/editor-cli
exit 0
EOF
chmod 0755 "$WORK_DIR"/scripts_*/postinstall

echo "[3/4] pkgbuild 子包 ..."
pkgbuild --root "$GUI_ROOT" --install-location "/Applications" \
    --identifier "com.pakyigame.${PKG_ID}.gui" --version "$VERSION" \
    --scripts "$WORK_DIR/scripts_gui" "$WORK_DIR/pkgs/gui.pkg"
pkgbuild --root "$CORE_ROOT" --install-location "$BUNDLE" \
    --identifier "com.pakyigame.${PKG_ID}.core" --version "$VERSION" \
    "$WORK_DIR/pkgs/core.pkg"
pkgbuild --root "$OP_ROOT" --install-location "$BUNDLE" \
    --identifier "com.pakyigame.${PKG_ID}.officialpack" --version "$VERSION" \
    "$WORK_DIR/pkgs/officialpack.pkg"
pkgbuild --nopayload \
    --identifier "com.pakyigame.${PKG_ID}.tui" --version "$VERSION" \
    --scripts "$WORK_DIR/scripts_tui" "$WORK_DIR/pkgs/tui.pkg"
pkgbuild --nopayload \
    --identifier "com.pakyigame.${PKG_ID}.cli" --version "$VERSION" \
    --scripts "$WORK_DIR/scripts_cli" "$WORK_DIR/pkgs/cli.pkg"

# ----------------------------- [4/4] productbuild 合成 -----------------------------
echo "[4/4] productbuild 合成 PKG ..."
DIST_FILE="$WORK_DIR/distribution.xml"
sed "s/@VERSION@/$VERSION/g" "$SCRIPT_DIR/distribution.xml" > "$DIST_FILE"
rm -f "$PKG_OUT"
productbuild --distribution "$DIST_FILE" --package-path "$WORK_DIR/pkgs" \
    --version "$VERSION" "$PKG_OUT"

SIZE="$(du -h "$PKG_OUT" | cut -f1)"
echo "完成：$PKG_OUT ($SIZE)"
echo "提示：PKG 未签名，首次打开请右键 -> 打开；"
echo "      或在\"系统设置 -> 隐私与安全性\"中允许。"
exit 0