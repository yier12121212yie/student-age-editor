# -*- coding: utf-8 -*-
"""一键构建「学生时代模组编辑器」发行版（多平台）。

流程：PyInstaller 打包后端 → Flutter 构建前端 → 组装发行版目录 → 打 zip
      → 用平台安装器构建安装包（Windows Inno / Linux deb+AppImage / macOS DMG+PKG）。
用法：
    python build_release.py [--target windows|macos|linux] [--version Alpha-v0.1]
                            [--skip-backend] [--skip-frontend]
                            [--installer] [--no-installer]

说明：
- 必须在目标平台上运行本脚本（PyInstaller 不支持交叉编译）：
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

依赖：Python 3.12 + PyInstaller + UnityPy；Flutter SDK（需在 PATH）；
      Windows 安装包另需 Inno Setup 6；Linux 安装包另需 dpkg-deb 与
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

APP_NAME = "学生时代模组编辑器"
# 发行文件名统一用 ASCII 基名：GitHub Actions 的 artifact 上传/下载链路会把
# 文件名开头的非 ASCII（中文）前缀整体剥离；中文名仅保留在 zip 内部目录、
# 安装器显示名、DMG 卷名等非文件名处。
APP_FILE_BASE = "student-age-editor"
TARGETS = ("windows", "macos", "linux")

# ----------------------------- Windows 安装包 -----------------------------
SETUP_ISS = os.path.join(ROOT, "packaging", "installer", "setup.iss")
BUNDLED_ZIP = os.path.join(ROOT, "build", "release", "bundled_resources.zip")
OFFICIAL_PACK_DIR = os.path.join(ROOT, "build", "release", "installer_official_pack")
ISCC_FALLBACKS = (
    r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    r"C:\Program Files\Inno Setup 6\ISCC.exe",
    os.path.expandvars(r"%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"),
)

# --------------------------- Linux/macOS 安装包 ---------------------------
# 官方资源扩展包在 Linux/macOS 产物中的只读系统根布局：
#   <程序目录>/official_pack/official-bundled/（resource_pack.system_packs_root 自动发现）
OFFICIAL_PACK_ID = "official-bundled"
ICON_SOURCE = os.path.join(FRONTEND, "macos", "Runner", "Assets.xcassets",
                           "AppIcon.appiconset", "app_icon_512.png")
LINUX_INSTALL_SH = os.path.join(ROOT, "packaging", "linux", "install.sh")
LINUX_BUILD_DEB = os.path.join(ROOT, "packaging", "linux", "build_deb.py")
LINUX_MAKE_APPIMAGE = os.path.join(ROOT, "packaging", "linux", "make_appimage.sh")
MACOS_BUILD_DMG = os.path.join(ROOT, "packaging", "macos", "build_dmg.sh")
MACOS_BUILD_PKG = os.path.join(ROOT, "packaging", "macos", "build_pkg.sh")
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
        "机器上生成。请先在本机启动一次编辑器（学生时代模组编辑器.exe 或\n"
        "python run_dev.py），待其生成 _cache 缓存后重新构建；\n"
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


def build_installer(version, source_dir):
    """第 5 步：调 ISCC 编译中文安装包到 dist。"""
    iscc = _locate_iscc()
    if iscc is None:
        raise SystemExit(
            "错误：未找到 Inno Setup 6（ISCC.exe），无法构建 Windows 安装包。\n"
            "请先安装：\n"
            "    winget install JRSoftware.InnoSetup\n"
            "    （失败时下载官方安装包静默安装：\n"
            "      https://jrsoftware.org/isdl.php  →  innosetup-*.exe /VERYSILENT）\n"
            "或使用 --no-installer 跳过本步骤。")
    err = _installer_prereq_error()
    if err:
        raise SystemExit(err)

    cmd_path = os.path.join(BACKEND_DIST, "editor_cmd.exe")
    assert os.path.isfile(cmd_path), \
        "后端打包失败：%s 未生成（backend.spec 应产出双 exe）" % cmd_path
    internal_dir = os.path.join(BACKEND_DIST, "_internal")
    assert os.path.isdir(internal_dir), \
        "后端打包失败：%s 未生成（onedir 共享依赖目录）" % internal_dir
    pack_name, _pack_ver = _ensure_official_pack_dir()

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
        "/DOutputDir=%s" % DIST_ROOT,
        SETUP_ISS,
    ]
    subprocess.run(cmd, cwd=ROOT, check=True)
    out = os.path.join(DIST_ROOT, "%s-setup-%s.exe" % (APP_FILE_BASE, version))
    assert os.path.isfile(out), "安装包未生成：%s" % out
    print("完成：%s (%.1f MB)" % (out, os.path.getsize(out) / 1048576))


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
                        "--version", version, "--output", DIST_ROOT],
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


def _copy_backend_bundle(dst_dir, bin_subdir=""):
    """复制 onedir 后端产物：可执行文件 + 整个 _internal/ 到目标目录。

    PyInstaller 6 onedir 的 bootloader 相对 exe 查找 _internal/，二者必须
    保持同目录；bin_subdir 非空时作为 dst_dir 下的相对子目录（exe 与
    _internal 一起放入）。只带 backend 可执行文件，不带 editor_cmd.exe
    （便携 zip 行为与 onefile 时期保持一致）。
    """
    target = os.path.join(dst_dir, bin_subdir) if bin_subdir else dst_dir
    shutil.copy2(backend_dist_path(), os.path.join(target, backend_exe_name()))
    shutil.copytree(os.path.join(BACKEND_DIST, "_internal"),
                    os.path.join(target, "_internal"))


def _embed_official_pack(base_dir, rel=""):
    """把官方资源包以 official_pack/official-bundled 布局放入发行目录。

    base_dir/rel 即 backend 可执行文件所在目录（后端 resource_pack 的
    system_packs_root 会自动发现并只读注册，无需拷贝到用户数据目录）。
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


# ---------------------------------------------------------------- 后端 ----

def build_backend():
    _step(1, "打包后端 %s ..." % backend_exe_name())
    # onedir：distpath 指向 build/release，spec 的 COLLECT(name='backend_dist')
    # 把 exe 与共享 _internal/ 写到 build/release/backend_dist/ 下。
    subprocess.run([
        sys.executable, "-m", "PyInstaller",
        os.path.join(ROOT, "packaging", "pyinstaller", "backend.spec"),
        "--distpath", os.path.join(ROOT, "build", "release"),
        "--workpath", os.path.join(ROOT, "build", "release", "pyinstaller_work"),
        "--noconfirm",
    ], cwd=ROOT, check=True)
    assert os.path.exists(backend_dist_path()), "后端打包失败：%s 未生成" \
        % backend_exe_name()


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
    _copy_backend_bundle(out_dir)
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
    _copy_backend_bundle(out_dir)
    _make_executable(os.path.join(out_dir, APP_NAME))
    _make_executable(os.path.join(out_dir, backend_exe_name()))
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
    # 后端可执行文件与 _internal/ 放进 .app/Contents/MacOS/（_internal 须与
    # exe 同目录，onedir bootloader 相对 exe 查找依赖），与前端主程序同目录
    # （launcher 查找逻辑）
    _copy_backend_bundle(dst_app, os.path.join("Contents", "MacOS"))
    _make_executable(os.path.join(dst_app, "Contents", "MacOS", backend_exe_name()))
    _embed_official_pack(dst_app, os.path.join("Contents", "MacOS"))
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
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, dirs, files in os.walk(out_dir):
            # macOS .app 内含符号链接（Frameworks），保留链接本身而非内容
            for d in dirs:
                p = os.path.join(root, d)
                if os.path.islink(p):
                    _zip_symlink(z, out_dir, p)
            for f in files:
                p = os.path.join(root, f)
                if os.path.islink(p):
                    _zip_symlink(z, out_dir, p)
                else:
                    z.write(p, os.path.relpath(p, DIST_ROOT))
    size_mb = os.path.getsize(zip_path) / 1048576
    print("完成：%s (%.1f MB)" % (zip_path, size_mb))


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


def main():
    global _TOTAL_STEPS
    ap = argparse.ArgumentParser(description="构建学生时代模组编辑器发行版")
    ap.add_argument("--target", default="windows", choices=TARGETS,
                    help="构建目标平台（须与当前系统一致）")
    ap.add_argument("--version", default=None,
                    help="发行版本号（默认取 frontend/pubspec.yaml）")
    ap.add_argument("--skip-backend", action="store_true", help="跳过后端打包（复用上次产物）")
    ap.add_argument("--skip-frontend", action="store_true", help="跳过 Flutter 构建（复用上次产物）")
    ap.add_argument("--installer", action="store_true",
                    help="构建安装包（各目标默认已开启，保留参数以兼容旧脚本）")
    ap.add_argument("--no-installer", action="store_true",
                    help="跳过安装包构建（Windows Inno / Linux deb+AppImage / macOS DMG+PKG）")
    args = ap.parse_args()

    if args.target == "windows" and not _is_windows():
        raise SystemExit("错误：Windows 包必须在 Windows 上构建。")
    if args.target == "linux" and _is_windows() and not os.environ.get("WSL_DISTRO_NAME"):
        pass  # 由调用方保证环境（如 WSL 内 sys.platform 也可能是 linux）
    if args.target == "macos" and sys.platform != "darwin":
        raise SystemExit("错误：macOS 包必须在 Mac 上构建。")

    version = args.version or read_frontend_version()
    if not version:
        raise SystemExit("错误：未能从 frontend/pubspec.yaml 解析版本号，"
                         "请用 --version x.y.z 显式指定。")

    # 各目标默认构建安装包（--no-installer 跳过）：
    # windows → Inno Setup；linux → deb + AppImage；macos → DMG + PKG
    build_inst = not args.no_installer
    _TOTAL_STEPS = 5 if build_inst else 4

    if not args.skip_backend:
        build_backend()
    else:
        assert os.path.exists(backend_dist_path()), \
            "--skip-backend 但找不到 %s" % backend_dist_path()

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



