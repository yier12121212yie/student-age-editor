#!/usr/bin/env bash
# ==============================================================================
# 「学生时代模组编辑器」macOS PKG 组件安装器构建脚本
# ==============================================================================
# 用法：
#   bash packaging/macos/build_pkg.sh --app <path/to/学生时代模组编辑器.app> \
#                                     --version 1.4.0 --output <输出目录>
#
# 组件划分（对齐 Windows Inno setup.iss，见同目录 distribution.xml）：
#   core          核心运行时（.app 骨架 + 内嵌 native 三件套
#                 backend/backend_cli/backend_tui），固定必选
#   gui           图形界面（GUI 主程序；postinstall 创建 editor-gui 命令）
#   tui / cli     终端/命令行界面（nopayload 脚本包；创建 editor-tui/editor-cli 命令）
#   officialpack  官方资源扩展包（.app/Contents/Resources/official_pack；
#                 codesign 会把 Contents/MacOS 下子目录当嵌套代码，数据只能放 Resources）
#
# 实现：从 assemble_macos 产出的 .app 拆出三份 payload 根（gui / core /
# officialpack），分别 pkgbuild，再 productbuild 按 distribution.xml 的
# choice 定义合成带勾选页的安装包；拆包前对 .app 副本做由内向外 ad-hoc 重签
# （与 DMG 一致，不用 --deep）。产物文件名固定，供 CI 归档：
#   <输出目录>/student-age-editor-<版本>-macos.pkg
#
# 注意：
# - PKG 把 .app 拆成 core/gui/officialpack 三份 payload 分别安装再合并。默认
#   全选安装时，合并出的文件集合与构建期签名时一致，封印有效；但用户若取消
#   勾选 officialpack，合并结果会缺少官方资源包、封印随之失效——这属于用户
#   自选裁剪的已知边界，届时按末尾提示用 xattr 去隔离即可（不做安装后重签：
#   那需要在用户机上以 root 调用 codesign，未装 Xcode 命令行工具时会弹出
#   系统安装提示，对普通用户是更差的体验）。
# - 完全非交互，供 GitHub Actions macos-14 调用；任何失败均非 0 退出。
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

# Release.entitlements 相对仓库根（脚本位于 packaging/macos/）
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/frontend/macos/Runner/Release.entitlements"

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

# 由内向外 ad-hoc 重签 .app 并校验封印（不用已废弃且对 Flutter 嵌套
# Frameworks 不可靠的 --deep）。失败即终止构建。
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
}

# ----------------------------- [1/4] 参数解析与校验 -----------------------------
APP_PATH="" VERSION="" OUTPUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app)      [ $# -ge 2 ] || die "--app 缺少参数"; APP_PATH="$2"; shift 2 ;;
        --version)  [ $# -ge 2 ] || die "--version 缺少参数"; VERSION="$2"; shift 2 ;;
        --meta-version)
            [ $# -ge 2 ] || die "--meta-version 缺少参数"
            META_VERSION="$2"; shift 2 ;;
        --output)   [ $# -ge 2 ] || die "--output 缺少参数"; OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) usage >&2; die "未知参数：$1" ;;
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
[ -f "$MACOS_DIR/backend_cli" ] || die ".app 内缺少内嵌 backend_cli（请先运行 build_release.py --target macos）"
[ -f "$MACOS_DIR/backend_tui" ] || die ".app 内缺少内嵌 backend_tui（请先运行 build_release.py --target macos）"
[ -d "$APP_PATH/Contents/Resources/official_pack" ] || die ".app 内缺少 Contents/Resources/official_pack/（官方资源扩展包未内嵌，安装包前置条件不满足）"

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

echo "[2/4] 拷贝 .app 副本并 ad-hoc 重签（由内向外，不用 --deep）..."
cp -R "$APP_PATH" "$WORK_DIR/app.app"
# 使用说明内嵌进 Contents/Resources。必须在重签之前放入：签名封印覆盖 bundle
# 全部内容，重签后新增文件会使封印失效、Gatekeeper 报「已损坏」。不能放
# Contents/MacOS——codesign 把 MacOS 下的非 Mach-O 文件也当代码，会直接签失败。
if [ -f "$(dirname "$APP_PATH")/使用说明.txt" ]; then
    cp "$(dirname "$APP_PATH")/使用说明.txt" \
       "$WORK_DIR/app.app/Contents/Resources/使用说明.txt"
fi
resign_app "$WORK_DIR/app.app"

# 拆出三个 payload 根（dist 版 .app 的完整内容由 gui + core + officialpack 合并还原）
# gui：整个 .app 去掉 native 三件套/official_pack（aa_scan 可选）
GUI_ROOT="$WORK_DIR/gui_root"
mkdir -p "$GUI_ROOT"
cp -R "$WORK_DIR/app.app" "$GUI_ROOT/$APP_NAME.app"
rm -rf "$GUI_ROOT/$APP_NAME.app/Contents/MacOS/backend" \
       "$GUI_ROOT/$APP_NAME.app/Contents/MacOS/backend_cli" \
       "$GUI_ROOT/$APP_NAME.app/Contents/MacOS/backend_tui" \
       "$GUI_ROOT/$APP_NAME.app/Contents/MacOS/aa_scan" \
       "$GUI_ROOT/$APP_NAME.app/Contents/Resources/official_pack"
# core：.app 骨架 + native 三件套（含随包说明文档）
CORE_ROOT="$WORK_DIR/core_root"
mkdir -p "$CORE_ROOT/Contents/MacOS"
cp -R "$WORK_DIR/app.app/Contents/Info.plist" "$WORK_DIR/app.app/Contents/PkgInfo" "$CORE_ROOT/Contents/" 2>/dev/null || true
for d in Frameworks Resources; do
    [ -d "$WORK_DIR/app.app/Contents/$d" ] && cp -R "$WORK_DIR/app.app/Contents/$d" "$CORE_ROOT/Contents/"
done
# official_pack 属于可选 officialpack choice，不随 core 必选包分发
rm -rf "$CORE_ROOT/Contents/Resources/official_pack"
cp -R "$WORK_DIR/app.app/Contents/MacOS/backend" \
      "$WORK_DIR/app.app/Contents/MacOS/backend_cli" \
      "$WORK_DIR/app.app/Contents/MacOS/backend_tui" "$CORE_ROOT/Contents/MacOS/"
[ -f "$WORK_DIR/app.app/Contents/MacOS/aa_scan" ] && \
    cp "$WORK_DIR/app.app/Contents/MacOS/aa_scan" "$CORE_ROOT/Contents/MacOS/"
# 使用说明已在上方重签前放入 Contents/Resources，随 core payload 整拷落盘
# officialpack：仅官方资源扩展包
OP_ROOT="$WORK_DIR/op_root"
mkdir -p "$OP_ROOT/Contents/Resources"
cp -R "$WORK_DIR/app.app/Contents/Resources/official_pack" "$OP_ROOT/Contents/Resources/"

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
printf '#!/bin/sh\\nexec "%s/backend_tui" "\\$@"\\n' > /usr/local/bin/editor-tui
chmod 0755 /usr/local/bin/editor-tui
exit 0
EOF
cat > "$WORK_DIR/scripts_cli/postinstall" <<EOF
#!/bin/sh
set -e
mkdir -p /usr/local/bin
printf '#!/bin/sh\\nexec "%s/backend_cli" "\\$@"\\n' > /usr/local/bin/editor-cli
chmod 0755 /usr/local/bin/editor-cli
exit 0
EOF
chmod 0755 "$WORK_DIR"/scripts_*/postinstall

echo "[3/4] pkgbuild 子包 ..."
pkgbuild --root "$GUI_ROOT" --install-location "/Applications" \
    --identifier "com.pakyigame.${PKG_ID}.gui" --version "$META_VERSION" \
    --scripts "$WORK_DIR/scripts_gui" "$WORK_DIR/pkgs/gui.pkg"
pkgbuild --root "$CORE_ROOT" --install-location "$BUNDLE" \
    --identifier "com.pakyigame.${PKG_ID}.core" --version "$META_VERSION" \
    "$WORK_DIR/pkgs/core.pkg"
pkgbuild --root "$OP_ROOT" --install-location "$BUNDLE" \
    --identifier "com.pakyigame.${PKG_ID}.officialpack" --version "$META_VERSION" \
    "$WORK_DIR/pkgs/officialpack.pkg"
pkgbuild --nopayload \
    --identifier "com.pakyigame.${PKG_ID}.tui" --version "$META_VERSION" \
    --scripts "$WORK_DIR/scripts_tui" "$WORK_DIR/pkgs/tui.pkg"
pkgbuild --nopayload \
    --identifier "com.pakyigame.${PKG_ID}.cli" --version "$META_VERSION" \
    --scripts "$WORK_DIR/scripts_cli" "$WORK_DIR/pkgs/cli.pkg"

# ----------------------------- [4/4] productbuild 合成 -----------------------------
echo "[4/4] productbuild 合成 PKG ..."
DIST_FILE="$WORK_DIR/distribution.xml"
sed "s/@VERSION@/$VERSION/g" "$SCRIPT_DIR/distribution.xml" > "$DIST_FILE"
rm -f "$PKG_OUT"
productbuild --distribution "$DIST_FILE" --package-path "$WORK_DIR/pkgs" \
    --version "$META_VERSION" "$PKG_OUT"

SIZE="$(du -h "$PKG_OUT" | cut -f1)"
echo "完成：$PKG_OUT ($SIZE)"
echo "提示：PKG 未签名（含内部 .app 为 ad-hoc 签名，未做 Apple 公证）。"
echo "      首次打开若提示「无法验证开发者」或「已损坏，无法打开」，请在"
echo "      终端执行下面一行，再双击打开："
echo "        xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\""
exit 0
