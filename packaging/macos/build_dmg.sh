#!/usr/bin/env bash
# ==============================================================================
# 「学生时代模组编辑器」macOS DMG 镜像构建脚本
# ==============================================================================
# 用法：
#   bash packaging/macos/build_dmg.sh --app <path/to/学生时代模组编辑器.app> \
#   --version Alpha-v0.1 --output <输出目录>
#
# 输入 .app 由 build_release.py --target macos 的 assemble_macos 产出
# （dist/学生时代模组编辑器-<版本>-macos/学生时代模组编辑器.app，Flutter 产物
# 骨架 + Contents/MacOS 下的 native 三件套 backend/backend_cli/backend_tui、
# official_pack/）。
# 产出（文件名固定，供 CI 归档）：
#   student-age-editor-<版本>-macos.dmg
# 卷内布局为拖拽安装式：.app + /Applications 软链。
#
# 说明：
# - build_release.py 的 assemble_macos 在注入 native 三件套/official_pack 后
#   已对 .app 做过由内向外 ad-hoc 重签；本脚本在 staging 副本上再签一次，
#   确保 cp 后的副本封印仍然完整（同一由内向外策略，不用已废弃的 --deep）。
#   签名失败直接终止，不再产出封印损坏的「已损坏」包。
#   正式分发请在 CI 配置开发者签名与公证（见 build/release/使用说明-macos.txt）。
# - 脚本完全非交互，供 CI（GitHub Actions macos-14）自动调用；任何失败
#   均以非 0 退出码结束。
# - 须在 macOS 上运行（依赖 hdiutil/codesign）；本仓库 Windows 宿主仅可
#   做静态检查（bash -n、LF 行尾自检）。
# - 本文件必须保持 LF 行尾。
# ==============================================================================
set -euo pipefail

APP_NAME="学生时代模组编辑器"
# 发行文件名基名（ASCII）：GitHub Actions artifact 传输会剥离中文文件名前缀
FILE_BASE="student-age-editor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Release.entitlements 相对仓库根（脚本位于 packaging/macos/）
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/frontend/macos/Runner/Release.entitlements"

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

# 按魔数判断是否为 Mach-O（可执行/动态库）：codesign 对普通文本文件会报错，
# 故 Contents/MacOS 下仅签 Mach-O（backend 三件套等），跳过使用说明等附属文件。
is_macho() {
    local magic
    magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
    case "$magic" in
        feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca) return 0 ;;
        *) return 1 ;;
    esac
}

# 由内向外 ad-hoc 重签 .app 并校验封印。
# 不用 --deep：它对 Flutter 的嵌套 Frameworks 不可靠，且已被 Apple 废弃。
# 先签 Frameworks/Helpers 等嵌套代码，再签 Contents/MacOS 下除主程序外的
# Mach-O（注入的 backend 三件套），最后签 app 本体并附 entitlements。
resign_app() {
    local app="$1"
    local macos_dir="$app/Contents/MacOS"
    local frameworks="$app/Contents/Frameworks"
    local main_exe item sub entry f

    # PlistBuddy 为 macOS 自带；plutil 作兜底，避免取不到主程序名时把它当
    # 普通嵌套组件单独签一遍
    main_exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
                "$app/Contents/Info.plist" 2>/dev/null \
                || plutil -extract CFBundleExecutable raw \
                         "$app/Contents/Info.plist" 2>/dev/null || true)"

    if [ -d "$frameworks" ]; then
        for item in "$frameworks"/*.framework "$frameworks"/*.dylib; do
            [ -e "$item" ] || continue
            codesign --force --sign - "$item" || die "嵌套组件签名失败：$item"
        done
    fi
    for sub in Helpers XPCServices PlugIns; do
        [ -d "$app/Contents/$sub" ] || continue
        for entry in "$app/Contents/$sub"/*; do
            [ -e "$entry" ] || continue
            codesign --force --sign - "$entry" || die "嵌套组件签名失败：$entry"
        done
    done
    if [ -d "$macos_dir" ]; then
        for f in "$macos_dir"/*; do
            [ -f "$f" ] || continue
            [ -L "$f" ] && continue
            [ "$(basename "$f")" = "$main_exe" ] && continue
            is_macho "$f" || continue
            codesign --force --sign - "$f" || die "Contents/MacOS 组件签名失败：$f"
        done
    fi

    # 分开写而非数组拼接：macOS 自带 bash 3.2 在 set -u 下展开空数组会报错
    if [ -f "$ENTITLEMENTS" ]; then
        codesign --force --sign - --entitlements "$ENTITLEMENTS" "$app" \
            || die "app 本体签名失败：$app"
    else
        codesign --force --sign - "$app" || die "app 本体签名失败：$app"
    fi
    codesign --verify --strict "$app" || die "签名封印校验失败：$app"
    echo "[2/3] ad-hoc 重签完成，封印校验通过。"
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
        --meta-version)
            [ $# -ge 2 ] || die "--meta-version 缺少参数"
            META_VERSION="$2"; shift 2 ;;
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

# 显示版本（用于文件名）：允许 x.y.z 与 Alpha-v0.1 这类品牌串；
# --meta-version 提供工具元数据用的纯数字版本（省略时自动取显示版本的数字部分）
if [[ ! "$VERSION" =~ ^[0-9A-Za-z.-]+$ ]]; then
    die "版本号含非法字符（仅允许字母数字与 . -）：$VERSION"
fi
META_VERSION="${META_VERSION:-$(printf '%s' "$VERSION" | sed -E 's/^[^0-9]*//')}"
if [[ ! "$META_VERSION" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
    META_VERSION="0.0"
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
[ -f "$MACOS_DIR/backend_cli" ] || die ".app 内缺少内嵌 backend_cli（请先运行 build_release.py --target macos）：$MACOS_DIR/backend_cli"
[ -f "$MACOS_DIR/backend_tui" ] || die ".app 内缺少内嵌 backend_tui（请先运行 build_release.py --target macos）：$MACOS_DIR/backend_tui"

APP_BASENAME="$(basename "$APP_PATH")"
if [ "$APP_BASENAME" != "$APP_NAME.app" ]; then
    echo "[警告] 输入 .app 名称（${APP_BASENAME}）与标准名（$APP_NAME.app）不同，staging 中将按标准名重命名。" >&2
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(abs_path "$OUTPUT_DIR")"

DMG_OUT="$OUTPUT_DIR/$FILE_BASE-$VERSION-macos.dmg"

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

echo "[2/3] ad-hoc 重签 .app（由内向外，不用 --deep）..."
resign_app "$STAGED_APP"

# 拖拽安装布局：Finder 中常见「拖到 Applications」提示
ln -s /Applications "$STAGING/Applications"

# ----------------------------- [3/3] 生成 DMG -----------------------------
echo "[3/3] 生成 DMG（UDZO 压缩）..."
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_OUT"

SIZE="$(du -h "$DMG_OUT" | cut -f1)"
echo "完成：$DMG_OUT ($SIZE)"
echo "提示：DMG 内 .app 为 ad-hoc 签名（未做 Apple 公证）。"
echo "      首次打开若提示「无法验证开发者」或「已损坏，无法打开」，请在"
echo "      终端执行下面一行（先拖入「应用程序」），再双击打开："
echo "        xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\""
exit 0
