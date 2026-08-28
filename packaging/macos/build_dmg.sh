#!/usr/bin/env bash
# ==============================================================================
# 「学生时代模组编辑器」macOS DMG 镜像构建脚本
# ==============================================================================
# 用法：
#   bash packaging/macos/build_dmg.sh --app <path/to/学生时代模组编辑器.app> \
#                                     --version 1.4.0 --output <输出目录>
#
# 输入 .app 由 build_release.py --target macos 的 assemble_macos 产出
# （dist/学生时代模组编辑器-vX.Y.Z-macos/学生时代模组编辑器.app，Flutter 产物
# 骨架 + Contents/MacOS 下的 backend、_internal/、official_pack/）。
# 产出（文件名固定，供 CI 归档）：
#   <输出目录>/学生时代模组编辑器-vX.Y.Z-macos.dmg
# 卷内布局为拖拽安装式：.app + /Applications 软链。
#
# 说明：
# - assemble_macos 在 Flutter 产物 .app 内新增了 backend/_internal，原内嵌
#   签名已失效；本脚本在 staging 副本上做 ad-hoc 重签
#   （codesign --force --deep --sign -，失败仅警告、继续打包）。
#   正式分发请在 CI 配置开发者签名与公证（见 build/release/使用说明-macos.txt）。
# - 脚本完全非交互，供 CI（GitHub Actions macos-14）自动调用；任何失败
#   （除上述 codesign 警告外）均以非 0 退出码结束。
# - 须在 macOS 上运行（依赖 hdiutil/codesign）；本仓库 Windows 宿主仅可
#   做静态检查（bash -n、LF 行尾自检）。
# - 本文件必须保持 LF 行尾。
# ==============================================================================
set -euo pipefail

APP_NAME="学生时代模组编辑器"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE_EOF'
用法：build_dmg.sh --app <path/to/学生时代模组编辑器.app> --version X.Y.Z --output <输出目录>

参数：
  --app      build_release.py 产出的 .app 路径（必填）
  --version  版本号，如 1.4.0（必填）
  --output   DMG 输出目录（必填）
USAGE_EOF
}

die() {
    echo "错误：$1" >&2
    exit 1
}

# 相对路径转绝对路径（不依赖 realpath，兼容 macOS 自带 bash 3.2）
abs_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" ;;
    esac
}

# ----------------------------- [1/3] 参数解析与校验 -----------------------------
APP_PATH="" VERSION="" OUTPUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app)
            [ $# -ge 2 ] || die "--app 缺少参数"
            APP_PATH="$2"; shift 2 ;;
        --version)
            [ $# -ge 2 ] || die "--version 缺少参数"
            VERSION="$2"; shift 2 ;;
        --output)
            [ $# -ge 2 ] || die "--output 缺少参数"
            OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            usage >&2; die "未知参数：$1" ;;
    esac
done

[ -n "$APP_PATH" ]   || { usage >&2; die "缺少 --app 参数"; }
[ -n "$VERSION" ]    || { usage >&2; die "缺少 --version 参数"; }
[ -n "$OUTPUT_DIR" ] || { usage >&2; die "缺少 --output 参数"; }

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    die "版本号格式应为 x.y.z（如 1.4.0）：$VERSION"
fi

command -v hdiutil  >/dev/null 2>&1 || die "未找到 hdiutil，本脚本须在 macOS 上运行"
command -v codesign >/dev/null 2>&1 || die "未找到 codesign，本脚本须在 macOS 上运行（需安装 Xcode 命令行工具）"

APP_PATH="${APP_PATH%/}"
[ -d "$APP_PATH" ] || die "未找到 .app：$APP_PATH"
APP_PATH="$(abs_path "$APP_PATH")"

PLIST="$APP_PATH/Contents/Info.plist"
MACOS_DIR="$APP_PATH/Contents/MacOS"
[ -f "$PLIST" ]              || die "无效的 .app（缺少 Contents/Info.plist）：$APP_PATH"
[ -f "$MACOS_DIR/backend" ]  || die ".app 内缺少内嵌 backend（请先运行 build_release.py --target macos）：$MACOS_DIR/backend"

APP_BASENAME="$(basename "$APP_PATH")"
if [ "$APP_BASENAME" != "$APP_NAME.app" ]; then
    echo "[警告] 输入 .app 名称（$APP_BASENAME）与标准名（$APP_NAME.app）不同，staging 中将按标准名重命名。" >&2
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(abs_path "$OUTPUT_DIR")"

DMG_OUT="$OUTPUT_DIR/$APP_NAME-v$VERSION-macos.dmg"

echo "[1/3] 校验通过：$APP_PATH"

# ----------------------------- [2/3] staging 组装 -----------------------------
# 临时 staging 目录：.app 副本 + /Applications 软链；EXIT 时统一清理
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/studentage_dmg.XXXXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGING="$WORK_DIR/dmg_staging"
mkdir -p "$STAGING"
STAGED_APP="$STAGING/$APP_NAME.app"

echo "[2/3] 拷贝 .app 到 staging ..."
# cp -R 保留符号链接（Contents/Frameworks 内含链接，不可解引用）
cp -R "$APP_PATH" "$STAGED_APP"

echo "[2/3] ad-hoc 重签（codesign --force --deep --sign -）..."
# 失败仅警告：产物仍可用，只是 Gatekeeper 可能拦截（用户可 xattr 去隔离）
if ! codesign --force --deep --sign - "$STAGED_APP"; then
    echo "[警告] ad-hoc 重签失败，继续打包；安装后首次打开可能被拦（右键 -> 打开，或 xattr -dr com.apple.quarantine 去隔离）。" >&2
fi

# 拖拽安装布局：Finder 中常见「拖到 Applications」提示
ln -s /Applications "$STAGING/Applications"

# ----------------------------- [3/3] 生成 DMG -----------------------------
echo "[3/3] 生成 DMG（UDZO 压缩）..."
hdiutil create \
    -volname "$APP_NAME v$VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_OUT"

SIZE="$(du -h "$DMG_OUT" | cut -f1)"
echo "完成：$DMG_OUT ($SIZE)"
echo "提示：DMG 内 .app 为 ad-hoc 签名，首次打开请右键 -> 打开；"
echo "      或先执行：xattr -dr com.apple.quarantine 学生时代模组编辑器.app"
exit 0
