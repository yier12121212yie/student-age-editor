# -*- coding: utf-8 -*-
"""一键构建「学生时代模组编辑器」发行版（多平台）。

流程：构建后端 → Flutter 构建前端 → 组装发行版目录 → 打 zip
      → 用平台安装器构建安装包（Windows Inno / Linux deb+AppImage / macOS DMG+PKG）。
用法：
    python build_release.py [--target windows|macos|linux|web|server-linux]
                            [--version Alpha-v0.1]
                            [--skip-backend] [--skip-frontend]
                            [--prebuilt-backend DIR]
                            [--installer] [--no-installer]
                            [--check-only]

说明：
- web / server-linux 为「网页版」独立发行目标（M3.1）：
  web → flutter build web，产物打 dist/web-app-<版本>.zip（根级含
    README-网页版.txt）；server-linux（仅 Linux）→ native CMake 构建
    backend + backend_gateway 两目标，连同 packaging/gateway/ 示例资产
    与 README-服务器版.txt 打 dist/editor-server-linux-<版本>.zip。
    两者均为独立发行物，绝不进任何桌面安装包/APK；桌面 zip 打包后置
    断言清单不得含 Web 特征文件（flutter_service_worker/main.dart.js/
    index.html）。backend_gateway 目标缺失（native/gateway 未落地）时
    报错退出码 2。--check-only 跑纯逻辑自测（不触碰工具链）。
- 后端构建通道全平台 native（波次 4/5）：
  windows → C++ native 后端：调用 CMake（优先 PATH，其次 vswhere 探测
    Visual Studio 自带 cmake/ninja 与 vcvars64）构建 native/，产物三件套
    backend.exe / backend_cli.exe / backend_tui.exe 拷入 backend_dist/；
    另尽力用 PyInstaller 冻结 tools/resource_scan 为独立工具 aa_scan.exe
    （失败仅警告降级为「本次不随包」，不阻塞主链路）。CI 可先用
    --prebuilt-backend <dir> 传入预构建产物目录，跳过本地 CMake 构建。
  macos/linux → C++ native 后端：调用 CMake+Ninja 构建 native/，产物
    backend / backend_cli / backend_tui（POSIX 无 .exe 后缀）拷入
    backend_dist/；aa_scan 同样尽力冻结为 aa_scan（无 .exe）。PyInstaller
    backend.spec 冻结 Python 的通道整体退役（删 backend/editor 后不再有
    依赖）。--prebuilt-backend <dir> 同样适用。
- 必须在目标平台上运行本脚本（不支持交叉编译）：
  Windows 包在 Windows 上构建，Linux 包在 Linux/WSL 上构建，macOS 包在
  Mac 上构建。跨平台出包请配合 CI（见 .github/workflows/release.yml）。
- Android 为 APK，由 frontend/android 的 Gradle(Chaquopy) 直接构建，
  不走本脚本；CI 中执行 flutter build apk。
- 版本号默认取 frontend/pubspec.yaml 的 version: x.y.z[-预发布后缀]+n
  （取 x.y.z[-预发布后缀]，如 0.1.0-alpha.1），可用 --version 覆盖。
- 各目标默认追加第 5 步构建安装包（--no-installer 跳过）：
  windows → Inno Setup setup.exe；linux → .deb + AppImage；
  macos → .dmg + .pkg。安装包内嵌官方资源扩展包，需本机已有游戏资源
  缓存（_cache/base_data.pkl 与 aa_index/aa_index.json，在装过游戏的
  机器上生成）；便携 zip 在缓存缺失时仅跳过内嵌、其余不受影响。

依赖：Windows 后端需 MSVC 工具链（Visual Studio / BuildTools，含 CMake；
      Ninja 优先 PATH，缺失时回落 VS 生成器）；Linux/macOS 后端需
      CMake+Ninja（Ninja 缺失时回落系统默认生成器）+ C++20 编译器；
      aa_scan 冻结另需 PyInstaller + UnityPy；Flutter SDK（需在 PATH）；
      Windows 安装包另需 Inno Setup 6（缺失时 Windows 通道打印警告后跳过
      安装包步骤，仅出便携 zip）；Linux 安装包另需 dpkg-deb 与
      appimagetool；macOS 安装包使用系统自带 hdiutil/pkgbuild/productbuild。
"""
import argparse
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
FRONTEND = os.path.join(ROOT, "frontend")
BACKEND_DIST = os.path.join(ROOT, "build", "release", "backend_dist")
DIST_ROOT = os.path.join(ROOT, "dist")

# Windows native（C++）后端通道
NATIVE_DIR = os.path.join(ROOT, "native")
NATIVE_ASSETS_DIR = os.path.join(NATIVE_DIR, "assets")
NATIVE_BUILD_DIR = os.path.join(ROOT, "build", "release", "native_build")
NATIVE_BUILD_DIR_POSIX = os.path.join(ROOT, "build", "release", "native_build_posix")
NATIVE_BINS = ("backend.exe", "backend_cli.exe", "backend_tui.exe")
# POSIX native 产物名无 .exe（native/build.sh 同样如此）
NATIVE_BINS_POSIX = ("backend", "backend_cli", "backend_tui")
# AA 资源扫描独立工具（tools/resource_scan 的 PyInstaller onefile 冻结）
AA_SCAN_SPEC = os.path.join(ROOT, "packaging", "pyinstaller", "aa_scan.spec")
AA_SCAN_EXE = "aa_scan.exe"
AA_SCAN_POSIX = "aa_scan"

APP_NAME = "学生时代模组编辑器"
# 发行文件名统一用 ASCII 基名：GitHub Actions 的 artifact 上传/下载链路会把
# 文件名开头的非 ASCII（中文）前缀整体剥离；中文名仅保留在 zip 内部目录、
# 安装器显示名、DMG 卷名等非文件名处。
APP_FILE_BASE = "student-age-editor"
# web / server-linux 为网页版独立发行目标（M3.1）：产物是独立发行物，绝不
# 进任何桌面安装包/APK（用户硬约束），桌面通道由 _assert_no_desktop_web_pollution
# 在 zip 后做特征文件断言兜底。
TARGETS = ("windows", "macos", "linux", "web", "server-linux")

# ------------------------- 网页版独立发行目标（M3.1） -------------------------
WEB_DIST = os.path.join(FRONTEND, "build", "web")
WEB_STAGING = os.path.join(ROOT, "build", "release", "web_staging")
SERVER_STAGING = os.path.join(ROOT, "build", "release", "server_staging")
# 在线托管发行物源目录名（zip 内部根）与 README 文件名（zip 内部，非外部
# 文件名，不受 artifact 上传链路剥离非 ASCII 文件名的限制）
SERVER_ROOT_NAME = "editor-server-linux"
WEB_README_NAME = "README-网页版.txt"
SERVER_README_NAME = "README-服务器版.txt"
WEB_README_SOURCE = os.path.join(ROOT, "packaging", "web", "README.txt")
# gateway 在线部署示例资产（systemd unit / Caddyfile 等，由 native/gateway
# 子项目提供）；缺失时跳过并在包内 README 清单注明，不报错
GATEWAY_PACKAGING_DIR = os.path.join(ROOT, "packaging", "gateway")
# server-linux 独立构建目录（与桌面 POSIX 构建互不干扰）
NATIVE_SERVER_BUILD_DIR = os.path.join(NATIVE_DIR, "build-server")
NATIVE_SERVER_BINS = ("backend", "backend_gateway")
# Web 特征文件（构建产物级）：桌面 zip/APK 与服务器包清单断言用
WEB_FINGERPRINT_TOKENS = ("flutter_service_worker", "main.dart.js",
                          "index.html")

# ----------------------------- Windows 安装包 -----------------------------
SETUP_ISS = os.path.join(ROOT, "packaging", "installer", "setup.iss")
BUNDLED_ZIP = os.path.join(ROOT, "build", "release", "bundled_resources.zip")
OFFICIAL_PACK_DIR = os.path.join(ROOT, "build", "release", "installer_official_pack")
# 人物图片资源扩展包（可选组件 / 服务器端两种分发方式的数据源）
PORTRAIT_PACK_ZIP = os.path.join(ROOT, "build", "release", "portrait_pack.zip")
PORTRAIT_PACK_DIR = os.path.join(ROOT, "build", "release", "installer_portrait_pack")
PORTRAIT_PACK_ID = "portraits"
PORTRAIT_PACK_EXPORT = os.path.join(ROOT, "packaging", "export_portrait_pack.py")
# 背景图片资源扩展包（可选组件 / 服务器端两种分发方式的数据源）
BACKGROUND_PACK_ZIP = os.path.join(ROOT, "build", "release", "background_pack.zip")
BACKGROUND_PACK_DIR = os.path.join(ROOT, "build", "release", "installer_background_pack")
BACKGROUND_PACK_ID = "backgrounds"
BACKGROUND_PACK_EXPORT = os.path.join(ROOT, "packaging", "export_background_pack.py")
ISCC_FALLBACKS = (
    r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    r"C:\Program Files\Inno Setup 6\ISCC.exe",
    os.path.expandvars(r"%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"),
)

# --------------------------- Linux/macOS 安装包 ---------------------------
# 官方资源扩展包在 Linux/macOS 产物中的只读系统根布局：
#   <程序目录>/official_pack/official-bundled/
# macOS 例外：数据目录放 Contents/Resources/official_pack/——codesign 会把
# Contents/MacOS 下的子目录当嵌套代码，非 Mach-O 内容会导致签名失败。
OFFICIAL_PACK_ID = "official-bundled"
ICON_SOURCE = os.path.join(FRONTEND, "macos", "Runner", "Assets.xcassets",
                           "AppIcon.appiconset", "app_icon_512.png")
LINUX_INSTALL_SH = os.path.join(ROOT, "packaging", "linux", "install.sh")
LINUX_BUILD_DEB = os.path.join(ROOT, "packaging", "linux", "build_deb.py")
LINUX_MAKE_APPIMAGE = os.path.join(ROOT, "packaging", "linux", "make_appimage.sh")
MACOS_BUILD_DMG = os.path.join(ROOT, "packaging", "macos", "build_dmg.sh")
MACOS_BUILD_PKG = os.path.join(ROOT, "packaging", "macos", "build_pkg.sh")
# 签名 entitlements：.app 内含自行注入的 native 可执行文件，需放开库校验
# （前端 DebugProfile.entitlements 另有 allow-jit/network.server，仅调试用）。
MACOS_ENTITLEMENTS = os.path.join(FRONTEND, "macos", "Runner",
                                  "Release.entitlements")
APPIMAGETOOL_LOCAL = os.path.join(ROOT, "build", "tools", "appimagetool-x86_64.AppImage")

_TOTAL_STEPS = 4


def _step(n, msg):
    print("[%d/%d] %s" % (n, _TOTAL_STEPS, msg))


def read_frontend_version():
    """从 frontend/pubspec.yaml 解析版本号（version: x.y.z[-pre]+n → 'x.y.z[-pre]'）。"""
    path = os.path.join(FRONTEND, "pubspec.yaml")
    try:
        with io.open(path, "r", encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^version:\s*(\d+(?:\.\d+){1,3}(?:-[0-9A-Za-z.-]+)?)"
                             r"(?:\+\d+)?\s*$", line.strip())
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def _locate_iscc():
    exe = shutil.which("ISCC")
    if exe:
        return exe
    for p in ISCC_FALLBACKS:
        if os.path.isfile(p):
            return p
    return None


def _official_pack_available():
    """游戏资源缓存是否可用（内嵌官方资源包的前置条件）。"""
    candidates = [
        (os.path.join(ROOT, "_cache", "base_data.pkl"),
         os.path.join(ROOT, "_cache", "aa_index", "aa_index.json")),
        (os.path.join(ROOT, "backend", "_cache", "base_data.pkl"),
         os.path.join(ROOT, "backend", "_cache", "aa_index", "aa_index.json")),
    ]
    return any(os.path.isfile(pkl) and os.path.isfile(aa) for pkl, aa in candidates)


def _installer_prereq_error():
    """官方资源包前置条件（游戏资源缓存）不满足时返回中文错误，否则 None。"""
    if _official_pack_available():
        return None
    return (
        "错误：未找到游戏资源缓存（base_data.pkl 与 aa_index/aa_index.json）。\n"
        "安装包需要内嵌完整官方资源包，而缓存只能在装有《学生时代》的\n"
        "机器上生成。请先在本机启动一次编辑器（学生时代模组编辑器，或\n"
        "native 的 backend / backend_tui），待其生成 _cache 缓存后重新构建；\n"
        "或用仓库内 tools/resource_scan（native aa_scan 工具）扫描游戏资源；\n"
        "或使用 --no-installer 跳过安装包构建（仅出便携 zip）。"
    )


def _ensure_official_pack_dir():
    """导出官方资源包 zip 并解包出安装目录（已就绪则复用），返回 (name, version)。

    Inno 无法解压 zip，故同时传 /DOfficialPackZip（源档）与
    /DOfficialPackDir（已解包目录）给 setup.iss；Linux/macOS 安装器只用
    解包目录（以 official_pack/official-bundled 布局内嵌进发行目录）。
    """
    if (os.path.isdir(OFFICIAL_PACK_DIR)
            and os.path.isfile(os.path.join(OFFICIAL_PACK_DIR, "manifest.json"))
            and os.path.isfile(BUNDLED_ZIP)):
        try:
            with io.open(os.path.join(OFFICIAL_PACK_DIR, "manifest.json"),
                         "r", encoding="utf-8-sig") as f:
                manifest = json.load(f)
            return (manifest.get("name") or "官方资源扩展包",
                    manifest.get("version") or "")
        except Exception:
            pass
    return _export_official_pack(BUNDLED_ZIP)


def _export_official_pack(zip_path):
    """调 export_bundled.py 导出官方资源包 zip，解包出安装目录。

    返回 manifest 的 (name, version)。Inno 无法解压 zip，故同时传
    /DOfficialPackZip（源档）与 /DOfficialPackDir（已解包目录）给 setup.iss。
    """
    print("    导出官方资源扩展包 %s ..." % zip_path)
    if os.path.exists(zip_path):
        os.remove(zip_path)
    subprocess.run([sys.executable,
                    os.path.join(ROOT, "packaging", "export_bundled.py"),
                    "--out", zip_path], cwd=ROOT, check=True)
    if os.path.isdir(OFFICIAL_PACK_DIR):
        shutil.rmtree(OFFICIAL_PACK_DIR)
    os.makedirs(OFFICIAL_PACK_DIR)
    with zipfile.ZipFile(zip_path) as z:
        manifest = json.loads(z.read("manifest.json").decode("utf-8-sig"))
        z.extractall(OFFICIAL_PACK_DIR)
    return manifest.get("name") or "官方资源扩展包", manifest.get("version") or ""


def _image_pack_ready(pack_dir):
    return (os.path.isdir(pack_dir)
            and os.path.isfile(os.path.join(pack_dir, "manifest.json")))


def _ensure_image_pack_dir(zip_path, pack_dir, export_script, label, hint):
    """导出一个图片资源扩展包（可选）并解包出安装目录；不可用时返回 False。

    人物图片包要从游戏 bundle 解码真实立绘，依赖装有《学生时代》的 Windows
    机器 + UnityPy/Pillow（见 packaging/export_portrait_pack.py）；背景包可
    直接吃 `参考资料/背景` 已解码图片（见 export_background_pack.py）。任何
    前置缺失都只提示并返回 False，不阻塞安装包构建——安装器侧据此隐藏对应的
    可选组件。
    """
    if _image_pack_ready(pack_dir):
        return True
    print("    导出%s %s ..." % (label, zip_path))
    try:
        if os.path.exists(zip_path):
            os.remove(zip_path)
        subprocess.run([sys.executable, export_script, "--out", zip_path],
                       cwd=ROOT, check=True)
    except (subprocess.CalledProcessError, OSError) as e:
        print("    提示：%s导出失败（%s），本次产物不含该可选组件。" % (label, e))
        return False
    if not os.path.isfile(zip_path):
        print("    提示：未生成%s，跳过该可选组件（%s）。" % (label, hint))
        return False
    if os.path.isdir(pack_dir):
        shutil.rmtree(pack_dir)
    os.makedirs(pack_dir)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(pack_dir)
    print("    %s就绪：%s" % (label, pack_dir))
    return True


def _portrait_pack_ready():
    return _image_pack_ready(PORTRAIT_PACK_DIR)


def _ensure_portrait_pack_dir():
    """导出「人物图片资源扩展包」（可选组件）。"""
    return _ensure_image_pack_dir(
        PORTRAIT_PACK_ZIP, PORTRAIT_PACK_DIR, PORTRAIT_PACK_EXPORT,
        "人物图片资源扩展包", "需装有游戏的机器")


def _background_pack_ready():
    return _image_pack_ready(BACKGROUND_PACK_DIR)


def _ensure_background_pack_dir():
    """导出「背景图片资源扩展包」（可选组件）。"""
    return _ensure_image_pack_dir(
        BACKGROUND_PACK_ZIP, BACKGROUND_PACK_DIR, BACKGROUND_PACK_EXPORT,
        "背景图片资源扩展包", "需 参考资料/背景 或装有游戏的机器")


def build_installer(version, source_dir):
    """第 5 步：调 ISCC 编译中文安装包到 dist（仅 Windows 通道）。

    ISCC 缺失时打印警告并返回 False（跳过安装包，保留便携 zip）；
    需要硬失败的场景（CI）请在流水线里显式校验 setup exe 产物。
    """
    iscc = _locate_iscc()
    if iscc is None:
        print("    警告：未找到 Inno Setup 6（ISCC.exe），跳过 Windows 安装包"
              "构建（本次仅出便携 zip）。\n"
              "    需要安装包请安装：winget install JRSoftware.InnoSetup\n"
              "    （或 https://jrsoftware.org/isdl.php → innosetup-*.exe "
              "/VERYSILENT）")
        return False
    err = _installer_prereq_error()
    if err:
        raise SystemExit(err)

    for name in NATIVE_BINS:
        p = os.path.join(BACKEND_DIST, name)
        assert os.path.isfile(p), \
            "后端产物缺失：%s 未生成（native 三件套应为 backend/backend_cli/" \
            "backend_tui）" % p
    pack_name, _pack_ver = _ensure_official_pack_dir()
    has_portraits = _ensure_portrait_pack_dir()
    has_backgrounds = _ensure_background_pack_dir()

    _step(5, "构建 Windows 安装包（Inno Setup）...")
    cmd = [
        iscc,
        "/DAppVersion=%s" % version,
        "/DAppFileBase=%s" % APP_FILE_BASE,
        "/DSourceDir=%s" % source_dir,
        "/DBackendDist=%s" % BACKEND_DIST,
        "/DOfficialPackZip=%s" % BUNDLED_ZIP,
        "/DOfficialPackDir=%s" % OFFICIAL_PACK_DIR,
        "/DOfficialPackId=official-bundled",
        "/DOfficialPackName=%s" % pack_name,
        "/DPortraitPackDir=%s" % PORTRAIT_PACK_DIR,
        "/DBackgroundPackDir=%s" % BACKGROUND_PACK_DIR,
        "/DOutputDir=%s" % DIST_ROOT,
    ]
    # 人物图片包可用时才定义 HasPortraitPack（setup.iss 以 #ifdef 判断）。ISPP 的
    # 命令行 /Dname=0 会把值当字符串，符号仍算“已定义”，不能用来表达“关闭”；
    # 因此不可用时直接不传该开关，而不是传 =0（那会让安装器保留空目录源而
    # 编译失败：No files found matching ...installer_portrait_pack\*）。
    if has_portraits:
        cmd.append("/DHasPortraitPack")
    # 背景包同理：可用时才定义 HasBackgroundPack。
    if has_backgrounds:
        cmd.append("/DHasBackgroundPack")
    cmd.append(SETUP_ISS)
    subprocess.run(cmd, cwd=ROOT, check=True)
    out = os.path.join(DIST_ROOT, "%s-setup-%s.exe" % (APP_FILE_BASE, version))
    assert os.path.isfile(out), "安装包未生成：%s" % out
    print("完成：%s (%.1f MB)" % (out, os.path.getsize(out) / 1048576))
    return True


# ----------------------------- Linux 安装包 -----------------------------

def _locate_appimagetool():
    exe = os.environ.get("APPIMAGETOOL")
    if exe and os.path.isfile(exe):
        return exe
    which = shutil.which("appimagetool")
    if which:
        return which
    if os.path.isfile(APPIMAGETOOL_LOCAL):
        return APPIMAGETOOL_LOCAL
    return None


def _numeric_version(version):
    """安装器工具元数据用的纯数字版本（dpkg/pkgbuild 要求以数字开头）。

    显示版本可携带品牌前缀（如 Alpha-v0.1）或预发布后缀（0.1.0-alpha.1），
    取其中的数字段；无数字段时回退 0.0。
    """
    m = re.search(r"(\d+(?:\.\d+)+)", version)
    return m.group(1) if m else "0.0"


def build_linux_installers(version, out_dir):
    """第 5 步：构建 .deb（dpkg-deb）与 AppImage（appimagetool），须在 Linux 上。"""
    _step(5, "构建 Linux 安装包（deb + AppImage）...")
    err = _installer_prereq_error()
    if err:
        raise SystemExit(err)
    # zip 组装阶段缓存缺失时会跳过内嵌，这里兜底补齐（安装包必须内嵌）
    if not os.path.isdir(os.path.join(out_dir, "official_pack", OFFICIAL_PACK_ID)):
        _ensure_official_pack_dir()
        shutil.copytree(OFFICIAL_PACK_DIR,
                        os.path.join(out_dir, "official_pack", OFFICIAL_PACK_ID))

    deb = os.path.join(DIST_ROOT, "student-age-editor_%s_amd64.deb" % version)
    subprocess.run([sys.executable, LINUX_BUILD_DEB,
                    "--source", out_dir, "--version", version,
                    "--deb-version", _numeric_version(version),
                    "--output", DIST_ROOT], cwd=ROOT, check=True)
    assert os.path.isfile(deb), "deb 未生成：%s" % deb
    print("完成：%s (%.1f MB)" % (deb, os.path.getsize(deb) / 1048576))

    tool = _locate_appimagetool()
    if tool is None:
        raise SystemExit(
            "错误：未找到 appimagetool，无法构建 AppImage。\n"
            "请先下载（CI 已自动下载到 build/tools/）：\n"
            "    mkdir -p build/tools && curl -L -o "
            "build/tools/appimagetool-x86_64.AppImage \\\n"
            "      https://github.com/AppImage/AppImageKit/releases/download/"
            "continuous/appimagetool-x86_64.AppImage\n"
            "    chmod +x build/tools/appimagetool-x86_64.AppImage\n"
            "或使用 --no-installer 跳过安装包构建。")
    env = os.environ.copy()
    env["APPIMAGETOOL"] = tool
    subprocess.run(["bash", LINUX_MAKE_APPIMAGE,
                    "--source", out_dir, "--version", version,
                    "--output", DIST_ROOT], cwd=ROOT, check=True, env=env)
    appimage = os.path.join(DIST_ROOT,
                            "%s-%s-linux-amd64.AppImage" % (APP_FILE_BASE, version))
    assert os.path.isfile(appimage), "AppImage 未生成：%s" % appimage
    print("完成：%s (%.1f MB)" % (appimage, os.path.getsize(appimage) / 1048576))


# ----------------------------- macOS 安装包 -----------------------------

def build_macos_installers(version, out_dir):
    """第 5 步：构建 DMG（拖拽安装）与 PKG（组件勾选向导），须在 Mac 上。"""
    _step(5, "构建 macOS 安装包（DMG + PKG）...")
    err = _installer_prereq_error()
    if err:
        raise SystemExit(err)
    app_bundle = os.path.join(out_dir, "%s.app" % APP_NAME)
    assert os.path.isdir(app_bundle), "未找到 %s" % app_bundle
    for script in (MACOS_BUILD_DMG, MACOS_BUILD_PKG):
        subprocess.run(["bash", script, "--app", app_bundle,
                        "--version", version,
                        "--meta-version", _numeric_version(version),
                        "--output", DIST_ROOT],
                       cwd=ROOT, check=True)
    dmg = os.path.join(DIST_ROOT, "%s-%s-macos.dmg" % (APP_FILE_BASE, version))
    pkg = os.path.join(DIST_ROOT, "%s-%s-macos.pkg" % (APP_FILE_BASE, version))
    for out in (dmg, pkg):
        assert os.path.isfile(out), "安装包未生成：%s" % out
        print("完成：%s (%.1f MB)" % (out, os.path.getsize(out) / 1048576))


def _is_windows():
    return sys.platform == "win32"


def backend_exe_name():
    return "backend.exe" if _is_windows() else "backend"


def backend_dist_path():
    return os.path.join(BACKEND_DIST, backend_exe_name())


def _native_bins():
    """native 三件套产物名（Windows 带 .exe，POSIX 无后缀）。"""
    return NATIVE_BINS if _is_windows() else NATIVE_BINS_POSIX


def _aa_scan_name():
    """AA 扫描工具产物名（Windows aa_scan.exe，POSIX aa_scan）。"""
    return AA_SCAN_EXE if _is_windows() else AA_SCAN_POSIX


def _copy_native_backend_bundle(dst_dir, bin_subdir=""):
    """复制 native 后端产物到发行根：三件套 + 可选 aa_scan + assets 词典。

    native 可执行文件自带全部依赖（静态/单体），不再有 PyInstaller 的
    _internal/ 共享目录；backend_launcher.dart 探测「与主程序同目录的
    backend」，故三件套必须与前端主程序平铺同目录。bin_subdir 非空时作为
    dst_dir 下的相对子目录（macOS .app 的 Contents/MacOS）。POSIX 上复制后
    补执行位（copy2 一般已保留，显式 chmod 兜底）。

    assets/（dicts.json、schema.json）必须随包：后端按「exe 目录上溯找
    assets/」解析（native/core/assets.cpp），发行目录里没有 dicts.json 时
    /api/dicts 返回空字典——说话人候选全空、剧本导入的角色名识别全部退化。
    """
    target = os.path.join(dst_dir, bin_subdir) if bin_subdir else dst_dir
    for name in _native_bins():
        shutil.copy2(os.path.join(BACKEND_DIST, name),
                     os.path.join(target, name))
        if not _is_windows():
            _make_executable(os.path.join(target, name))
    aa_name = _aa_scan_name()
    aa = os.path.join(BACKEND_DIST, aa_name)
    if os.path.isfile(aa):
        shutil.copy2(aa, os.path.join(target, aa_name))
        if not _is_windows():
            _make_executable(os.path.join(target, aa_name))
    else:
        print("    提示：本次未随包 %s（AA 资源扫描工具缺失，"
              "不影响编辑器运行；重扫资源请用仓库内 python 工具）。" % aa_name)
    # macOS .app：数据目录必须放 Contents/Resources（codesign 把 Contents/MacOS
    # 下的子目录当嵌套代码，assets/ 目录会导致签名失败）。后端 assets.cpp 的
    # 逐级上探含 <dir>/Resources/assets 候选，能自动发现。
    assets_target = (os.path.join(dst_dir, "Contents", "Resources", "assets")
                     if bin_subdir else os.path.join(target, "assets"))
    if os.path.isdir(NATIVE_ASSETS_DIR):
        shutil.copytree(NATIVE_ASSETS_DIR, assets_target, dirs_exist_ok=True)
    if not os.path.isfile(os.path.join(assets_target, "dicts.json")):
        raise FileNotFoundError(
            "发行目录缺少 assets/dicts.json（native/assets 不完整？）："
            "词典缺失会让说话人候选与剧本导入的角色识别全部失效")


def _embed_official_pack(base_dir, rel=""):
    """把官方资源包以 official_pack/official-bundled 布局放入发行目录。

    base_dir/rel 即期望的系统包根（Windows/Linux 为可执行文件目录；macOS 为
    Contents/Resources，因 codesign 会把 Contents/MacOS 下子目录当嵌套代码）。
    缓存缺失时跳过并提示（便携 zip 不受影响）；安装包构建另有硬性校验。
    """
    target = os.path.join(base_dir, rel) if rel else base_dir
    if not _official_pack_available():
        print("    提示：未找到游戏资源缓存，本次产物不内嵌官方资源扩展包"
              "（不影响已安装游戏的用户）。")
        return
    _ensure_official_pack_dir()
    shutil.copytree(OFFICIAL_PACK_DIR,
                    os.path.join(target, "official_pack", OFFICIAL_PACK_ID))


# ---------------------------------------------------- 网页版独立发行目标 ----

def _path_has_web_fingerprint(name):
    """路径任一层级为 Web 产物特征（flutter build web 特有，桌面/服务器
    发行物出现即视为污染）。flutter_service_worker 用前缀匹配
    （flutter_service_worker.js 等变体），其余按文件名精确匹配。"""
    for part in name.replace("\\", "/").split("/"):
        if part.startswith("flutter_service_worker") or part in ("main.dart.js",
                                                                 "index.html"):
            return True
    return False


def _web_fingerprint_hits(names):
    return [n for n in names if _path_has_web_fingerprint(n)]


def _zip_entry_names(zip_path):
    """zip 清单条目名。"""
    with zipfile.ZipFile(zip_path) as z:
        return z.namelist()


def _zip_flat(src_dir, zip_path):
    """把 src_dir 打包为 zip，条目名相对 src_dir（暂存目录已备好所需的
    内部层级与 README；zipfile 通道与 make_zip 一致，不用 ditto——Web/
    服务器产物无签名与扩展属性诉求）。"""
    os.makedirs(DIST_ROOT, exist_ok=True)
    if os.path.exists(zip_path):
        os.remove(zip_path)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED,
                         compresslevel=6) as z:
        for root, dirs, files in os.walk(src_dir):
            for name in sorted(dirs) + sorted(files):
                p = os.path.join(root, name)
                if os.path.isdir(p):
                    continue
                z.write(p, os.path.relpath(p, src_dir))
    return zip_path


def _assert_no_desktop_web_pollution(zip_path):
    """桌面打包后置断言：便携 zip 不得混入 Web 产物。

    桌面组装（assemble_*）只拷各平台 Flutter 桌面 bundle 目录
    （build/windows|linux|macos 下），从不拷 build/web/，本断言仅作
    防回归护栏，不改变打包行为。"""
    hits = _web_fingerprint_hits(_zip_entry_names(zip_path))
    assert not hits, (
        "硬约束违反：桌面发行包 %s 混入 Web 产物特征文件（%s）。"
        "网页版只能以独立发行物发布（dist/web-app-*.zip），"
        "绝不进任何桌面安装包/APK。"
        % (os.path.basename(zip_path), ", ".join(hits[:5])))


def _copy_web_root_flat(src, dst):
    """把 Web 产物目录的「内容」拷入暂存目录（zip 根级为 index.html、
    main.dart.js、flutter_service_worker.js、assets/ 等 + README）。"""
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(src):
        s = os.path.join(src, name)
        d = os.path.join(dst, name)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copy2(s, d)


def _stage_web_readme(dst_dir):
    """网页包根级 README-网页版.txt：首选入库的 packaging/web/README.txt，
    缺失时兜底生成精简文案（README 位于 zip 内部，中文名不受文件名限制）。"""
    dst = os.path.join(dst_dir, WEB_README_NAME)
    if os.path.isfile(WEB_README_SOURCE):
        shutil.copy2(WEB_README_SOURCE, dst)
        return
    print("    提示：未找到 %s，已兜底生成精简版说明。" % WEB_README_SOURCE)
    with io.open(dst, "w", encoding="utf-8") as f:
        f.write("网页版使用说明（精简版，完整版见仓库 WEB_GUIDE.md）\n\n"
                "1. 解压本 zip 得到网页资源目录（含 index.html）。\n"
                "2. 下载对应平台的桌面发行包，在其目录下执行：\n"
                "       backend --web-root <本目录>\n"
                "   随后浏览器打开后端提示的本地地址即可使用。\n")


def build_web_release(version, skip_frontend=False):
    """web 目标：flutter build web → dist/web-app-<版本>.zip（独立发行物）。

    版本注入沿用 build_frontend 的惯例（现有通道不传 --dart-define，构建
    版本号由 pubspec 承担）；跨平台可构建，产物不进任何桌面包。"""
    global _TOTAL_STEPS
    _TOTAL_STEPS = 2
    _step(1, "构建 Flutter Web 前端 ...")
    if not skip_frontend:
        cmd = _flutter_cmd()
        if cmd is None:
            raise SystemExit("错误：未找到 flutter 命令。"
                             "请安装 Flutter SDK 并将其加入 PATH。")
        subprocess.run(cmd + ["build", "web", "--release"],
                       cwd=FRONTEND, check=True)
    else:
        assert os.path.isfile(os.path.join(WEB_DIST, "index.html")), \
            "--skip-frontend 但找不到 Web 构建产物 %s" % WEB_DIST

    _step(2, "组装并打包 Web 发行版 ...")
    if not os.path.isdir(WEB_DIST):
        raise SystemExit("错误：未找到 flutter build web 产物目录 %s"
                         "（先不带 --skip-frontend 构建一次）。" % WEB_DIST)
    if os.path.isdir(WEB_STAGING):
        shutil.rmtree(WEB_STAGING)
    _copy_web_root_flat(WEB_DIST, WEB_STAGING)
    _stage_web_readme(WEB_STAGING)
    zip_path = os.path.join(DIST_ROOT, "web-app-%s.zip" % version)
    _zip_flat(WEB_STAGING, zip_path)
    names = _zip_entry_names(zip_path)
    assert WEB_README_NAME in names, \
        "Web 发行包缺少根级 %s" % WEB_README_NAME
    print("完成：%s (%.1f MB)" % (zip_path, os.path.getsize(zip_path) / 1048576))


def _find_cmake_target_in_source(token):
    """在 native/ 源码树的 CMakeLists.txt 中寻找 target token（跳过构建
    子树）。backend_gateway 的 add_executable 可能出现在 native/CMakeLists
    或 native/gateway/CMakeLists，仅扫顶层会漏报。"""
    for dirpath, dirs, files in os.walk(NATIVE_DIR):
        dirs[:] = [d for d in dirs if not d.startswith("build")]
        if "CMakeLists.txt" in files:
            try:
                with io.open(os.path.join(dirpath, "CMakeLists.txt"), "r",
                             encoding="utf-8", errors="replace") as f:
                    if re.search(r"\b%s\b" % token, f.read()):
                        return True
            except OSError:
                pass
    return False


def _write_server_readme(dst_dir, version, gateway_assets, has_assets):
    """生成包内 README-服务器版.txt，兼作发行物清单：缺目录只提示不报错。"""
    notes = []
    if not gateway_assets:
        notes.append("- 提示：未找到 packaging/gateway/（systemd/Caddy 示例资产），"
                     "本次未随包——需 native/gateway 子项目落地后补齐。")
    if not has_assets:
        notes.append("- 提示：未找到 native/assets/（词典/模式资源），"
                     "backend 的 /api/dicts 将退化为空字典。")
    lines = [
        "%s 在线托管发行物（Linux x86_64）  版本 %s" % (APP_NAME, version),
        "",
        "包内容：",
        "  backend              后端主程序（提供 API 与网页资源托管）",
        "  backend_gateway      在线托管网关（POSIX-only）",
        "  assets/              词典与模式资源（backend 按可执行文件目录上溯查找）",
    ]
    if gateway_assets:
        lines.append("  gateway/             systemd / Caddy 部署示例资产")
    lines += [
        "",
        "一、在线托管形态：",
        "  1. 将本包解压到服务器（如 /opt/student-age-editor-server）。",
        "  2. 用 systemd 分别拉起 backend 与 backend_gateway"
        "（示例 service 见 gateway/ 目录）。",
        "  3. Caddy 反向代理到 backend 并启用 TLS（示例 Caddyfile 见 gateway/"
        "；缺 gateway/ 时参考仓库 WEB_GUIDE.md 的在线托管章节）。",
        "  4. 前端网页产物（web-app-<版本>.zip 解压内容）由 backend --web-root"
        " 托管或由 Caddy 直接服务。",
        "",
        "二、本机浏览器形态（无需本包之外的服务器）：",
        "  下载 web-app-<版本>.zip 与对应平台桌面发行包，在桌面包目录执行"
        "「backend --web-root <web-app 解压目录>」。",
        "",
        "完整指南见仓库 WEB_GUIDE.md。",
    ]
    if notes:
        lines += ["", "打包清单备注："] + notes
    with io.open(os.path.join(dst_dir, SERVER_README_NAME), "w",
                 encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def build_server_linux_release(version):
    """server-linux 目标：在线托管发行物（backend + backend_gateway +
    gateway 示例资产 + README），仅 Linux 上构建，产物独立于桌面通道。"""
    global _TOTAL_STEPS
    _TOTAL_STEPS = 2
    if not sys.platform.startswith("linux"):
        raise SystemExit("错误：server-linux 发行物必须在 Linux 上构建"
                         "（backend_gateway 为 POSIX-only 二进制）。")
    cmake = shutil.which("cmake")
    if not cmake:
        raise SystemExit("错误：未找到 cmake。\n解决：apt install cmake "
                         "ninja-build（CI 已自动安装）。")
    ninja = shutil.which("ninja")
    if not ninja:
        raise SystemExit("错误：未找到 Ninja（本通道按 CMake+Ninja 约定构建）。\n"
                         "解决：apt install ninja-build 或安装到 PATH。")
    # configure 前置校验：旧树（native/gateway 未落地）无该 target 时给出
    # 清晰报错并以退出码 2 终止（与一般构建失败退出码 1 区分，CI 可据此
    # 判定「通道尚未启用」而非「构建坏了」）
    if not _find_cmake_target_in_source("backend_gateway"):
        sys.stderr.write(
            "错误：native/ 源码树未发现 backend_gateway 构建目标，"
            "需 native/gateway 落地后启用 server-linux 通道。\n")
        raise SystemExit(2)

    _step(1, "构建在线托管后端（backend + backend_gateway）...")
    os.makedirs(NATIVE_SERVER_BUILD_DIR, exist_ok=True)
    subprocess.run([cmake, "-S", NATIVE_DIR, "-B", NATIVE_SERVER_BUILD_DIR,
                    "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
                    "-DSA_APP_VERSION=%s" % (version or "dev")],
                   cwd=ROOT, check=True)
    subprocess.run([cmake, "--build", NATIVE_SERVER_BUILD_DIR,
                    "--target", "backend", "backend_gateway"],
                   cwd=ROOT, check=True)

    _step(2, "组装并打包在线托管发行版 ...")
    if os.path.isdir(SERVER_STAGING):
        shutil.rmtree(SERVER_STAGING)
    os.makedirs(SERVER_STAGING)
    stage_root = os.path.join(SERVER_STAGING, SERVER_ROOT_NAME)
    os.makedirs(stage_root)
    missing = []
    for name in NATIVE_SERVER_BINS:
        p = _find_native_bin(NATIVE_SERVER_BUILD_DIR, name)
        if not p:
            missing.append(name)
            continue
        dst = os.path.join(stage_root, name)
        shutil.copy2(p, dst)
        _make_executable(dst)
        print("    %s ← %s" % (name, os.path.relpath(p, ROOT)))
    if missing:
        raise SystemExit(
            "错误：构建产物缺少 %s（构建目录 %s）。若为 backend_gateway，"
            "需 native/gateway 落地后启用。" % (", ".join(missing),
                                               NATIVE_SERVER_BUILD_DIR))
    # assets 必须随包：后端按可执行文件目录上溯查找 assets/（native/core/
    # assets.cpp），缺失时 /api/dicts 返回空字典（同 _copy_native_backend_bundle）
    has_assets = os.path.isdir(NATIVE_ASSETS_DIR)
    if has_assets:
        shutil.copytree(NATIVE_ASSETS_DIR, os.path.join(stage_root, "assets"))
    # gateway 示例资产（systemd/Caddy，packaging/gateway/ 子项目）：缺目录
    # 时跳过并在 README 清单注明，不因缺文件报错
    gateway_assets = os.path.isdir(GATEWAY_PACKAGING_DIR)
    if gateway_assets:
        shutil.copytree(GATEWAY_PACKAGING_DIR,
                        os.path.join(stage_root, "gateway"))
    else:
        print("    提示：未找到 %s，示例部署资产本次不随包。"
              % GATEWAY_PACKAGING_DIR)
    _write_server_readme(stage_root, version, gateway_assets, has_assets)
    zip_path = os.path.join(DIST_ROOT, "editor-server-linux-%s.zip" % version)
    print("    打包 zip %s ..." % os.path.basename(zip_path))
    _zip_flat(SERVER_STAGING, zip_path)
    server_hits = _web_fingerprint_hits(_zip_entry_names(zip_path))
    assert not server_hits, \
        "服务器发行包混入 Web 产物（应仅含二进制/资产/README）：%s" % ", ".join(
            server_hits[:3])
    print("完成：%s (%.1f MB)" % (zip_path, os.path.getsize(zip_path) / 1048576))


# ---------------------------------------------------------------- 后端 ----

# POSIX（linux/macos）native 构建见下方 build_backend_native_posix。
# 旧的 PyInstaller backend.spec 通道已随 W4-5a 整体退役（删 backend/editor
# 后不再存在 Python 后端可冻结）。

# ------------------------------------------------------- native (Windows) ----

_VSWHERE_CANDIDATES = (
    os.path.expandvars(
        r"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"),
    r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe",
)


def _vs_install_dir():
    """用 vswhere 探测带 VC 工具的 VS/BuildTools 安装目录；找不到返回 None。

    不硬编码任何安装路径（如 D:\\BuildTools）：vswhere 是官方发现机制，
    VS2017+（含 BuildTools）通吃。"""
    for w in _VSWHERE_CANDIDATES:
        if not os.path.isfile(w):
            continue
        for extra in (["-requires",
                       "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"], []):
            try:
                r = subprocess.run(
                    [w, "-utf8", "-latest", "-products", "*"] + extra
                    + ["-property", "installationPath"],
                    capture_output=True, text=True, timeout=30)
                line = r.stdout.strip().splitlines()
                if r.returncode == 0 and line and os.path.isdir(line[0]):
                    return line[0]
            except Exception:
                pass
    return None


def _probe_native_toolchain():
    """探测 native 构建所需工具，返回 (cmake, ninja, vcvars) 三元组。

    - cmake：PATH 优先；缺失时取 VS 自带（Common7/IDE/.../CMake/bin）。
    - ninja：PATH 优先；缺失时取 VS 自带；再缺失 → None，构建函数回落
      「Visual Studio 17 2022」多配置生成器（与 native-ci.yml 同法）。
    - vcvars：PATH 上已有 cl.exe 则为 None（环境就绪）；否则给出
      vcvars64.bat 路径；连 VS 都探测不到时返回错误信息供上层报错。
    """
    cmake = shutil.which("cmake")
    ninja = shutil.which("ninja")
    vcvars = None if shutil.which("cl") else ""
    if cmake and ninja and vcvars is None:
        return cmake, ninja, None
    vs = _vs_install_dir()
    if not cmake and vs:
        p = os.path.join(vs, "Common7", "IDE", "CommonExtensions", "Microsoft",
                         "CMake", "CMake", "bin", "cmake.exe")
        cmake = p if os.path.isfile(p) else None
    if not ninja and vs:
        p = os.path.join(vs, "Common7", "IDE", "CommonExtensions", "Microsoft",
                         "CMake", "Ninja", "ninja.exe")
        if os.path.isfile(p):
            ninja = p
    if vcvars == "":
        p = os.path.join(vs, "VC", "Auxiliary", "Build", "vcvars64.bat") if vs \
            else None
        vcvars = p if p and os.path.isfile(p) else None
    return cmake, ninja, vcvars if vcvars else None


def _msvc_env(vcvars):
    """返回带 MSVC x64 环境的 os.environ 副本；vcvars 为 None 时原样返回。"""
    env = os.environ.copy()
    if not vcvars:
        return env
    # shell=True → cmd.exe /c ""<vcvars64.bat>" && set"（Windows 惯用法，
    # 避开 list 形式下 cmd 引号解析的坑）。显式 utf-8 + errors=replace：
    # 中文系统上 text=True 默认按 cp936 解码，vcvars 输出含非 ASCII（路径/
    # 横幅）时会 UnicodeDecodeError 或乱码。
    r = subprocess.run('"%s" && set' % vcvars, shell=True, cwd=ROOT,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=300)
    if r.returncode != 0:
        raise SystemExit(
            "错误：初始化 MSVC 环境失败（%s）。\n%s" % (vcvars, r.stderr[-800:]))
    for line in r.stdout.splitlines():
        k, sep, v = line.partition("=")
        if sep and k:
            env[k] = v
    return env


def _find_native_bin(root, name):
    """在构建目录内定位可执行文件（Ninja 平铺 bin/，VS 生成器嵌套 bin/Release/）。"""
    direct = os.path.join(root, "bin", name)
    if os.path.isfile(direct):
        return direct
    for sub in (os.path.join("bin", "Release"), os.path.join("bin", "Debug")):
        p = os.path.join(root, sub, name)
        if os.path.isfile(p):
            return p
    for dirpath, _dirs, files in os.walk(os.path.join(root, "bin")
                                         if os.path.isdir(os.path.join(root, "bin"))
                                         else root):
        if name in files:
            return os.path.join(dirpath, name)
    return None


def _reset_backend_dist():
    """清空重建 backend_dist/（避免残留上一通道产物，如旧 _internal/）。"""
    if os.path.isdir(BACKEND_DIST):
        shutil.rmtree(BACKEND_DIST)
    os.makedirs(BACKEND_DIST)


def build_backend_native(prebuilt_dir=None, version=""):
    """Windows 后端：native C++ 三件套（backend/backend_cli/backend_tui）。

    prebuilt_dir 非空 → 从该目录拷三件套（CI 用，跳过自建，工具链缺失无所谓）；
    否则调用 CMake 构建 native/（复用/新建 NATIVE_BUILD_DIR，Release+Ninja，
    无 Ninja 回落 VS 生成器；vcvars 环境缺失时给出清晰报错）。

    version → -DSA_APP_VERSION（GET /api/version 与更新检查用的发行版本号，
    与产物命名同源；空则 "dev"）。走 --prebuilt-backend 时本函数不配置
    CMake，注入由产生产物的那一步负责（release.yml 的 native 构建步骤）。
    """
    _step(1, "构建 native C++ 后端（backend/backend_cli/backend_tui）...")
    _reset_backend_dist()
    src = None
    if prebuilt_dir:
        prebuilt_dir = os.path.abspath(prebuilt_dir)
        if not os.path.isdir(prebuilt_dir):
            raise SystemExit("错误：--prebuilt-backend 目录不存在：%s" % prebuilt_dir)
        src = prebuilt_dir
    else:
        cmake, ninja, vcvars = _probe_native_toolchain()
        if not cmake:
            raise SystemExit(
                "错误：未找到 cmake（PATH 与 Visual Studio 自带位置均无）。\n"
                "解决：安装 Visual Studio BuildTools 2022（勾选 C++ CMake 工具），\n"
                "      或把 cmake 加入 PATH；也可先自行构建 native/ 后用\n"
                "      --prebuilt-backend <bin目录> 传入现成产物。")
        if not shutil.which("cl") and not vcvars:
            raise SystemExit(
                "错误：MSVC 编译器环境缺失（PATH 无 cl.exe，且经 vswhere 未"
                "探测到 vcvars64.bat）。\n解决：安装/修复 Visual Studio "
                "BuildTools 2022（含 C++ 生成工具），或从「x64 Native Tools"
                " 命令提示符」运行本脚本；也可先自行构建 native/ 后用 "
                "--prebuilt-backend <bin目录> 传入现成产物。")
        env = _msvc_env(vcvars)
        os.makedirs(NATIVE_BUILD_DIR, exist_ok=True)
        gen_args = (["-G", "Ninja"] if ninja
                    else ["-G", "Visual Studio 17 2022", "-A", "x64"])
        if not ninja:
            print("    提示：未找到 Ninja，回落「Visual Studio 17 2022」生成器。")
        print("    cmake configure: native → %s (%s)" % (
            os.path.relpath(NATIVE_BUILD_DIR, ROOT),
            "Ninja" if ninja else "VS17"))
        subprocess.run([cmake, "-S", NATIVE_DIR, "-B", NATIVE_BUILD_DIR]
                       + gen_args + ["-DCMAKE_BUILD_TYPE=Release",
                                     "-DSA_APP_VERSION=%s" % (version or "dev")],
                       cwd=ROOT, env=env, check=True)
        build_cmd = [cmake, "--build", NATIVE_BUILD_DIR]
        if not ninja:
            build_cmd += ["--config", "Release"]
        subprocess.run(build_cmd, cwd=ROOT, env=env, check=True)
        src = NATIVE_BUILD_DIR

    missing = []
    for name in NATIVE_BINS:
        cand = os.path.join(src, name)
        p = cand if os.path.isfile(cand) else _find_native_bin(src, name)
        if not p or not os.path.isfile(p):
            missing.append(name)
            continue
        shutil.copy2(p, os.path.join(BACKEND_DIST, name))
        print("    %s ← %s" % (name, os.path.relpath(p, ROOT)))
    if missing:
        raise SystemExit(
            "错误：native 构建产物缺少 %s（来源 %s）。\n"
            "首次构建请确认 native/build.cmd 全绿，或用 --prebuilt-backend "
            "指向已含三件套的目录。" % (", ".join(missing), src))


def build_backend_native_posix(prebuilt_dir=None, version=""):
    """Linux/macOS 后端：native C++ 三件套（backend/backend_cli/backend_tui）。

    镜像 Windows 的 build_backend_native，但工具链探测走 POSIX：cmake 必须
    在 PATH；ninja 优先，缺失时用 CMake 默认生成器（Unix Makefiles）。
    prebuilt_dir 非空 → 从该目录拷三件套（CI 预构建注入，跳过自建）。
    version → -DSA_APP_VERSION（含义同 build_backend_native；空则 "dev"）。
    """
    _step(1, "构建 native C++ 后端（backend/backend_cli/backend_tui）...")
    _reset_backend_dist()
    src = None
    if prebuilt_dir:
        prebuilt_dir = os.path.abspath(prebuilt_dir)
        if not os.path.isdir(prebuilt_dir):
            raise SystemExit("错误：--prebuilt-backend 目录不存在：%s" % prebuilt_dir)
        src = prebuilt_dir
    else:
        cmake = shutil.which("cmake")
        if not cmake:
            raise SystemExit(
                "错误：未找到 cmake。\n解决：安装 cmake（如 apt install "
                "cmake ninja-build，或 brew install cmake ninja）；也可先自行"
                "构建 native/ 后用 --prebuilt-backend <bin目录> 传入现成产物。")
        ninja = shutil.which("ninja")
        os.makedirs(NATIVE_BUILD_DIR_POSIX, exist_ok=True)
        gen_args = ["-G", "Ninja"] if ninja else []
        if not ninja:
            print("    提示：未找到 Ninja，回落 CMake 默认生成器（Unix Makefiles）。")
        print("    cmake configure: native → %s (%s)" % (
            os.path.relpath(NATIVE_BUILD_DIR_POSIX, ROOT),
            "Ninja" if ninja else "default"))
        subprocess.run([cmake, "-S", NATIVE_DIR, "-B", NATIVE_BUILD_DIR_POSIX]
                       + gen_args + ["-DCMAKE_BUILD_TYPE=Release",
                                     "-DSA_APP_VERSION=%s" % (version or "dev")],
                       cwd=ROOT, check=True)
        subprocess.run([cmake, "--build", NATIVE_BUILD_DIR_POSIX],
                       cwd=ROOT, check=True)
        src = NATIVE_BUILD_DIR_POSIX

    missing = []
    for name in NATIVE_BINS_POSIX:
        cand = os.path.join(src, name)
        p = cand if os.path.isfile(cand) else _find_native_bin(src, name)
        if not p or not os.path.isfile(p):
            missing.append(name)
            continue
        dst = os.path.join(BACKEND_DIST, name)
        shutil.copy2(p, dst)
        _make_executable(dst)
        print("    %s ← %s" % (name, os.path.relpath(p, ROOT)))
    if missing:
        raise SystemExit(
            "错误：native 构建产物缺少 %s（来源 %s）。\n"
            "首次构建请确认 native/build.sh 全绿，或用 --prebuilt-backend "
            "指向已含三件套的目录。" % (", ".join(missing), src))


def build_aa_scan():
    """尽力把 tools/resource_scan 冻结成单文件 aa_scan（+ .exe）放入 backend_dist/。

    可选产物：构建失败或本机无 PyInstaller 时打印警告并返回 False
    （发行不随 aa_scan，不阻塞主链路）。"""
    aa_name = _aa_scan_name()
    try:
        import PyInstaller  # noqa: F401
    except ImportError:
        print("    警告：未安装 PyInstaller，跳过 %s 冻结；"
              "本次发行不随资源扫描工具（pip install pyinstaller 后可带上）。"
              % aa_name)
        return False
    print("    冻结 AA 资源扫描工具 %s（tools/resource_scan）..." % aa_name)
    try:
        subprocess.run([
            sys.executable, "-m", "PyInstaller", AA_SCAN_SPEC,
            "--distpath", os.path.join(ROOT, "build", "release", "aa_scan_dist"),
            "--workpath", os.path.join(ROOT, "build", "release", "aa_scan_work"),
            "--noconfirm",
        ], cwd=ROOT, check=True,
           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except Exception as e:
        print("    警告：%s 构建失败（%s），本次发行不随资源扫描工具。"
              % (aa_name, e))
        return False
    exe = os.path.join(ROOT, "build", "release", "aa_scan_dist", aa_name)
    if not os.path.isfile(exe):
        print("    警告：%s 未生成，本次发行不随资源扫描工具。" % aa_name)
        return False
    shutil.copy2(exe, os.path.join(BACKEND_DIST, aa_name))
    _make_executable(os.path.join(BACKEND_DIST, aa_name))
    print("    %s (%.1f MB)" % (aa_name, os.path.getsize(exe) / 1048576))
    return True


# ---------------------------------------------------------------- 前端 ----

def _flutter_cmd():
    """返回可被 subprocess 直接执行的 flutter 命令列表。

    Windows 上 flutter 是 flutter.bat，CreateProcess 无法直接执行，
    需要经 cmd.exe /c 包装；同时优先解析完整路径避免 PATH 差异。
    """
    exe = shutil.which("flutter")
    if not exe:
        return None
    if _is_windows():
        return ["cmd", "/c", exe]
    return [exe]


def build_frontend(target):
    _step(2, "构建 Flutter 前端 (%s) ..." % target)
    cmd = _flutter_cmd()
    if cmd is None:
        raise SystemExit("错误：未找到 flutter 命令。请安装 Flutter SDK 并将其加入 PATH。")
    subcmd = {"windows": "windows", "linux": "linux", "macos": "macos"}[target]
    subprocess.run(cmd + ["build", subcmd, "--release"],
                   cwd=FRONTEND, check=True)


def _frontend_release_dir(target):
    """返回各平台 Flutter 构建产物目录 / 主程序路径。"""
    if target == "windows":
        d = os.path.join(FRONTEND, "build", "windows", "x64", "runner", "Release")
        return d, os.path.join(d, "student_age_editor.exe")
    if target == "linux":
        d = os.path.join(FRONTEND, "build", "linux", "x64", "release", "bundle")
        return d, os.path.join(d, "student_age_editor")
    if target == "macos":
        d = os.path.join(FRONTEND, "build", "macos", "Build", "Products", "Release")
        return d, os.path.join(d, "%s.app" % APP_NAME)
    raise ValueError(target)


# ------------------------------------------------------------- 组装 ----

def _copytree(src, dst):
    shutil.copytree(src, dst)


def assemble_windows(version):
    _TARGET_LABEL = 'windows'
    out_dir = os.path.join(DIST_ROOT, "%s-%s" % (APP_NAME, version))
    release_dir, main_exe = _frontend_release_dir("windows")
    _step(3, "组装发行版目录 %s ..." % out_dir)
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)
    # 主程序重命名为中文名，dll/data/native_assets 原样拷贝
    shutil.copy2(main_exe, os.path.join(out_dir, "%s.exe" % APP_NAME))
    for name in os.listdir(release_dir):
        if name == "student_age_editor.exe":
            continue
        src = os.path.join(release_dir, name)
        _copytree(src, os.path.join(out_dir, name)) if os.path.isdir(src) \
            else shutil.copy2(src, os.path.join(out_dir, name))
    _copy_native_backend_bundle(out_dir)
    _copy_readme(out_dir, _TARGET_LABEL)
    return out_dir


def assemble_linux(version):
    _TARGET_LABEL = 'linux'
    out_dir = os.path.join(DIST_ROOT, "%s-%s-linux" % (APP_NAME, version))
    bundle_dir, main_bin = _frontend_release_dir("linux")
    _step(3, "组装发行版目录 %s ..." % out_dir)
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)
    shutil.copy2(main_bin, os.path.join(out_dir, APP_NAME))
    for name in os.listdir(bundle_dir):
        if name == "student_age_editor":
            continue
        src = os.path.join(bundle_dir, name)
        _copytree(src, os.path.join(out_dir, name)) if os.path.isdir(src) \
            else shutil.copy2(src, os.path.join(out_dir, name))
    _copy_native_backend_bundle(out_dir)
    _make_executable(os.path.join(out_dir, APP_NAME))
    _embed_official_pack(out_dir)
    if os.path.isfile(ICON_SOURCE):
        shutil.copy2(ICON_SOURCE, os.path.join(out_dir, "editor_icon.png"))
    else:
        print("    警告：未找到应用图标 %s，桌面图标将不可用。" % ICON_SOURCE)
    if os.path.isfile(LINUX_INSTALL_SH):
        shutil.copy2(LINUX_INSTALL_SH, os.path.join(out_dir, "install.sh"))
        _make_executable(os.path.join(out_dir, "install.sh"))
    else:
        print("    警告：未找到 packaging/linux/install.sh，本次 zip 不含安装向导。")
    _copy_readme(out_dir, _TARGET_LABEL)
    return out_dir


# ------------------------------------------------------- macOS 代码签名 ----
# 已知 Mach-O 魔数（含 little/big endian 与 fat 头），用于判断某文件是否可签。
_MACHO_MAGICS = (0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe,
                 0xcafebabe, 0xbebafeca)


def _is_macho(path):
    """按魔数判断是否为 Mach-O（可执行/动态库），非 Mach-O 跳过签名。"""
    try:
        with open(path, "rb") as f:
            head = f.read(4)
    except OSError:
        return False
    if len(head) < 4:
        return False
    return int.from_bytes(head, "big") in _MACHO_MAGICS


def _macos_main_executable(app_path):
    """从 Info.plist 读取 CFBundleExecutable（读不到返回 None）。"""
    plist = os.path.join(app_path, "Contents", "Info.plist")
    try:
        with io.open(plist, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None
    m = re.search(r"<key>CFBundleExecutable</key>\s*<string>([^<]+)</string>",
                  text)
    return m.group(1).strip() if m else None


def _macos_nested_code(app_path):
    """收集需在 app 本体之前单独签名的嵌套代码（由内向外顺序）。

    含 Frameworks/ 下的 .framework 与 .dylib、Helpers/XPCServices/PlugIns/，
    以及 Contents/MacOS 下除主程序外的 Mach-O（注入的 backend 三件套等）。
    """
    items = []
    frameworks = os.path.join(app_path, "Contents", "Frameworks")
    if os.path.isdir(frameworks):
        for name in sorted(os.listdir(frameworks)):
            p = os.path.join(frameworks, name)
            if name.endswith(".framework") or name.endswith(".dylib"):
                items.append(p)
    for sub in ("Helpers", "XPCServices", "PlugIns"):
        d = os.path.join(app_path, "Contents", sub)
        if os.path.isdir(d):
            for name in sorted(os.listdir(d)):
                items.append(os.path.join(d, name))
    macos_dir = os.path.join(app_path, "Contents", "MacOS")
    main_exe = _macos_main_executable(app_path)
    if os.path.isdir(macos_dir):
        for name in sorted(os.listdir(macos_dir)):
            p = os.path.join(macos_dir, name)
            if name == main_exe or not os.path.isfile(p) or os.path.islink(p):
                continue
            if _is_macho(p):
                items.append(p)
    return items


def _run_checked(cmd, what):
    """执行外部命令，失败时以清晰的中文错误终止（而非抛裸 traceback）。"""
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as e:
        raise SystemExit("错误：%s 失败（退出码 %d）：%s"
                         % (what, e.returncode, " ".join(cmd)))


def sign_macos_app(app_path):
    """对 .app 做由内向外 ad-hoc 重签并校验封印。

    assemble_macos 在 Flutter 产物 .app 内注入了 native 三件套与 official_pack，
    原有内嵌签名封印随之失效——这正是 Gatekeeper 报「已损坏」的直接原因，必须
    在注入之后重新签名。此处不使用已废弃的 --deep（对 Flutter 的嵌套
    Frameworks 不可靠），而是先签 Frameworks/Helpers 等嵌套代码，最后签 app
    本体并附 entitlements；失败即中断，不产出签名损坏的坏包。
    """
    if sys.platform != "darwin":
        raise SystemExit("错误：macOS 签名只能在 Mac 上执行。")
    codesign = shutil.which("codesign")
    if codesign is None:
        raise SystemExit("错误：未找到 codesign，请安装 Xcode 命令行工具"
                         "（xcode-select --install）。")
    nested = _macos_nested_code(app_path)
    for item in nested:
        _run_checked([codesign, "--force", "--sign", "-", item],
                     "嵌套组件签名（%s）" % os.path.basename(item))
    sign_cmd = [codesign, "--force", "--sign", "-"]
    if os.path.isfile(MACOS_ENTITLEMENTS):
        sign_cmd += ["--entitlements", MACOS_ENTITLEMENTS]
    sign_cmd.append(app_path)
    _run_checked(sign_cmd, "app 本体签名")
    _run_checked([codesign, "--verify", "--strict", app_path], "签名封印校验")
    print("    ad-hoc 重签完成：%d 个嵌套组件 + app 本体，封印校验通过。"
          % len(nested))


def assemble_macos(version):
    _TARGET_LABEL = 'macos'
    out_dir = os.path.join(DIST_ROOT, "%s-%s-macos" % (APP_NAME, version))
    _, app_bundle = _frontend_release_dir("macos")
    assert os.path.isdir(app_bundle), "未找到 %s" % app_bundle
    _step(3, "组装发行版目录 %s ..." % out_dir)
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)
    dst_app = os.path.join(out_dir, "%s.app" % APP_NAME)
    shutil.copytree(app_bundle, dst_app, symlinks=True)
    # native 三件套放进 .app/Contents/MacOS/，与前端主程序同目录（launcher
    # 探测同目录 backend）；不再有 PyInstaller 的 _internal/。
    _copy_native_backend_bundle(dst_app, os.path.join("Contents", "MacOS"))
    _embed_official_pack(dst_app, os.path.join("Contents", "Resources"))
    # 注入发生在 Flutter 内嵌签名之后，原封印已失效；必须在打包前重签，
    # 否则 zip/dmg/pkg 内的 .app 会被 Gatekeeper 判定为「已损坏」。
    sign_macos_app(dst_app)
    _copy_readme(out_dir, _TARGET_LABEL)
    return out_dir


def _copy_readme(out_dir, target):
    name = {"windows": "使用说明.txt",
            "linux": "使用说明-linux.txt",
            "macos": "使用说明-macos.txt"}[target]
    # 首选入库的 packaging/notes/；build/release/ 保留为本地覆盖位置
    candidates = [
        os.path.join(ROOT, "packaging", "notes", name),
        os.path.join(ROOT, "build", "release", name),
    ]
    for src in candidates:
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(out_dir, "使用说明.txt"))
            return
    print("    警告：未找到 %s（%s），发行目录不含使用说明。" % (name, candidates[0]))


def _make_executable(path):
    st = os.stat(path)
    os.chmod(path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


# --------------------------------------------------------------- zip ----

def make_zip(out_dir, zip_name):
    _step(4, "打包 zip %s ..." % zip_name)
    zip_path = os.path.join(DIST_ROOT, zip_name)
    if os.path.exists(zip_path):
        os.remove(zip_path)
    # macOS 用 ditto：Apple 自带、正确保留符号链接与扩展属性，是打包已签名
    # .app 的推荐方式（zipfile 会丢 xattr，可能影响签名校验）。其余平台沿用
    # zipfile（Windows/Linux 产物无签名，无需 xattr）。
    if sys.platform == "darwin":
        _make_zip_ditto(out_dir, zip_path)
        _assert_no_desktop_web_pollution(zip_path)
        size_mb = os.path.getsize(zip_path) / 1048576
        print("完成：%s (%.1f MB)" % (zip_path, size_mb))
        return
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, dirs, files in os.walk(out_dir):
            # macOS .app 内含符号链接（Frameworks），保留链接本身而非内容。
            # 目录链接写完条目后必须从 dirs 剔除：否则 os.walk 深入链接目标，
            # 把链接指向的内容再以真实文件打包一遍（体积翻倍、结构混乱）。
            skip = set()
            for d in dirs:
                p = os.path.join(root, d)
                if os.path.islink(p):
                    _zip_symlink(z, out_dir, p)
                    skip.add(d)
            dirs[:] = [d for d in dirs if d not in skip]
            for f in files:
                p = os.path.join(root, f)
                if os.path.islink(p):
                    _zip_symlink(z, out_dir, p)
                else:
                    z.write(p, os.path.relpath(p, DIST_ROOT))
    # 桌面便携 zip 后置断言：防 Web 产物混入（网页版只能独立发行）
    _assert_no_desktop_web_pollution(zip_path)
    size_mb = os.path.getsize(zip_path) / 1048576
    print("完成：%s (%.1f MB)" % (zip_path, size_mb))


def _make_zip_ditto(out_dir, zip_path):
    """用 ditto 打包（--keepParent 保留 out_dir 顶层目录为 zip 根）。

    ditto 保留符号链接、权限与扩展属性，是打包已签名 macOS 应用的标准做法；
    刻意不用 --sequesterRsrc（会写入 __MACOSX 冗余目录）。
    """
    ditto = shutil.which("ditto")
    if ditto is None:
        raise SystemExit("错误：未找到 ditto（macOS 自带，不应缺失）。")
    _run_checked([ditto, "-c", "-k", "--keepParent", out_dir, zip_path],
                 "ditto 打包 zip")


def _zip_symlink(z, dist_root, link_path):
    target = os.readlink(link_path)
    info = zipfile.ZipInfo(os.path.relpath(link_path, dist_root))
    mode = 0o755 if os.path.isdir(link_path) else 0o644
    info.external_attr = ((stat.S_IFLNK | mode) & 0xFFFF) << 16
    z.writestr(info, target.encode("utf-8"))


ASSEMBLERS = {
    "windows": assemble_windows,
    "linux": assemble_linux,
    "macos": assemble_macos,
}


def run_self_check():
    """--check-only：纯逻辑级自测（不触碰 flutter/cmake，不跑真实 release）。

    验证：① 目标注册表完整；② 桌面打包的反 Web 污染断言用临时假清单
    验证正/反例；③ 桌面 zip/APK 与 Web/服务器发行物命名规则符合约定。
    全部通过打印 PASS 并返回 0，否则打印 FAIL 返回 1。"""
    failures = []

    # ① 目标注册表：桌面三目标有组装器，web/server-linux 有独立入口函数
    for t in ("windows", "macos", "linux"):
        if t not in ASSEMBLERS:
            failures.append("ASSEMBLERS 缺少桌面目标 %s" % t)
    for fn, name in ((build_web_release, "build_web_release"),
                     (build_server_linux_release,
                      "build_server_linux_release")):
        if not callable(fn):
            failures.append("%s 不可调用" % name)

    # ② 反 Web 污染断言（纯清单级，不读 zip）：正例放行、反例拦截
    clean_manifest = ["%s-9.9.9/%s.exe" % (APP_NAME, APP_NAME),
                      "%s-9.9.9/data/flutter_assets/APP" % APP_NAME,
                      "%s-9.9.9/assets/dicts.json" % APP_NAME]
    polluted_manifest = ["student-age-editor-9.9.9/main.dart.js",
                         "web/flutter_service_worker.js",
                         "nested/dir/index.html"]
    hits = _web_fingerprint_hits(clean_manifest)
    if hits:
        failures.append("断言误伤桌面正常清单：%s" % ", ".join(hits))
    hits = _web_fingerprint_hits(polluted_manifest)
    if len(hits) != len(polluted_manifest):
        failures.append("断言未完全拦截污染清单（期望 %d 项，实际 %d 项：%s）"
                        % (len(polluted_manifest), len(hits), ", ".join(hits)))

    # ③ 命名规则：web/server 有独立发行名（不与桌面 zip 同名冲突）
    version = "9.9.9"
    version = "9.9.9"
    expects = {
        "windows": "%s-%s.zip" % (APP_FILE_BASE, version),
        "linux": "%s-%s-linux.zip" % (APP_FILE_BASE, version),
        "macos": "%s-%s-macos.zip" % (APP_FILE_BASE, version),
        "web": "web-app-%s.zip" % version,
        "server-linux": "editor-server-linux-%s.zip" % version,
    }
    print("目标注册表：")
    for t in TARGETS:
        print("  %-12s → dist/%s" % (t, expects[t]))
        if t not in expects:
            failures.append("目标 %s 缺少发行物命名约定" % t)
    for name in (WEB_README_NAME, SERVER_README_NAME):
        print("  发行物内说明：%s" % name)

    if failures:
        for msg in failures:
            print("FAIL: %s" % msg)
        print("自测未通过（%d 项）" % len(failures))
        return 1
    print("PASS")
    return 0


def main():
    global _TOTAL_STEPS
    ap = argparse.ArgumentParser(description="构建学生时代模组编辑器发行版")
    ap.add_argument("--target", default="windows", choices=TARGETS,
                    help="构建目标平台（桌面目标须与当前系统一致；"
                         "web/server-linux 为网页版独立发行物，"
                         "server-linux 仅 Linux）")
    ap.add_argument("--version", default=None,
                    help="发行版本号（默认取 frontend/pubspec.yaml）")
    ap.add_argument("--skip-backend", action="store_true", help="跳过后端打包（复用上次产物）")
    ap.add_argument("--skip-frontend", action="store_true", help="跳过 Flutter 构建（复用上次产物）")
    ap.add_argument("--prebuilt-backend", metavar="DIR", default=None,
                    help="全平台通道：从 DIR 拷 native 三件套，跳过本地 CMake "
                         "构建（CI 预构建场景；DIR 含或嵌套 bin/ 均可；"
                         "Windows 为 .exe，Linux/macOS 无后缀）")
    ap.add_argument("--installer", action="store_true",
                    help="构建安装包（各目标默认已开启，保留参数以兼容旧脚本）")
    ap.add_argument("--no-installer", action="store_true",
                    help="跳过安装包构建（Windows Inno / Linux deb+AppImage / macOS DMG+PKG）")
    ap.add_argument("--check-only", action="store_true",
                    help="只做纯逻辑级自测（目标注册表、桌面打包反 Web 污染"
                         "断言正/反例、发行物命名），不触碰构建工具链；"
                         "全部通过打印 PASS 并以 0 退出")
    args = ap.parse_args()

    if args.check_only:
        sys.exit(run_self_check())

    if args.target == "windows" and not _is_windows():
        raise SystemExit("错误：Windows 包必须在 Windows 上构建。")
    if args.target == "macos" and sys.platform != "darwin":
        raise SystemExit("错误：macOS 包必须在 Mac 上构建。")

    version = args.version or read_frontend_version()
    if not version:
        raise SystemExit("错误：未能从 frontend/pubspec.yaml 解析版本号，"
                         "请用 --version x.y.z 显式指定。")

    # 网页版独立发行目标：不走桌面管线（无安装包步骤，产物不进桌面包）
    if args.target == "web":
        build_web_release(version, skip_frontend=args.skip_frontend)
        return
    if args.target == "server-linux":
        build_server_linux_release(version)
        return

    # 各目标默认构建安装包（--no-installer 跳过）：
    # windows → Inno Setup；linux → deb + AppImage；macos → DMG + PKG
    build_inst = not args.no_installer
    _TOTAL_STEPS = 5 if build_inst else 4

    if not args.skip_backend:
        if args.target == "windows":
            # Windows 后端通道（波次 4）：native C++ 三件套 + 可选 aa_scan.exe
            build_backend_native(args.prebuilt_backend, version)
            build_aa_scan()
        else:
            # Linux/macOS 后端通道（波次 5）：native C++ 三件套 + 可选 aa_scan
            build_backend_native_posix(args.prebuilt_backend, version)
            build_aa_scan()
    else:
        missing = [n for n in _native_bins()
                   if not os.path.exists(os.path.join(BACKEND_DIST, n))]
        if missing:
            raise SystemExit("--skip-backend 但找不到 %s"
                             % ", ".join(os.path.join(BACKEND_DIST, n)
                                         for n in missing))

    _, main_prog = _frontend_release_dir(args.target)
    if not args.skip_frontend:
        build_frontend(args.target)
    else:
        assert os.path.exists(main_prog), \
            "--skip-frontend 但找不到 Flutter 构建产物 %s" % main_prog

    out_dir = ASSEMBLERS[args.target](version)
    # zip 外部文件名用 ASCII 基名；dist 目录（zip 内部根目录）保持中文显示名
    zip_name = "%s-%s%s.zip" % (
        APP_FILE_BASE, version,
        {"windows": "", "linux": "-linux", "macos": "-macos"}[args.target])
    make_zip(out_dir, zip_name)
    if build_inst:
        if args.target == "windows":
            build_installer(version, out_dir)
        elif args.target == "linux":
            build_linux_installers(version, out_dir)
        else:
            build_macos_installers(version, out_dir)


if __name__ == "__main__":
    main()



