#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""组装「学生时代模组编辑器」Linux .deb 安装包（dpkg-deb --build）。

用法：
    python3 build_deb.py --source <zip发行目录> --version X.Y.Z --output <dist目录>

安装布局：全量组件（core + gui + tui/cli 命令 + 官方资源扩展包 + 桌面图标）
  /opt/student-age-editor/        便携 zip 内容（含 official_pack/）
  /usr/bin/editor-gui|tui|cli     启动命令
  /usr/share/applications/...     桌面入口
  /usr/share/icons/hicolor/...    应用图标
产物：<output>/student-age-editor_<version>_amd64.deb
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

APP_NAME = "学生时代模组编辑器"
PKG_ID = "student-age-editor"
HERE = os.path.dirname(os.path.abspath(__file__))
DESKTOP_TEMPLATE = os.path.join(HERE, "student-age-editor.desktop")
INSTALL_PREFIX = "/opt/" + PKG_ID


def parse_args():
    ap = argparse.ArgumentParser(description="组装 Linux .deb 安装包")
    ap.add_argument("--source", required=True, help="zip 发行目录（assemble_linux 输出）")
    ap.add_argument("--version", required=True, help="版本号 x.y.z")
    ap.add_argument("--output", required=True, help="产物输出目录")
    ap.add_argument("--maintainer", default="PakyiGame <pakyigame@users.noreply.github.com>")
    return ap.parse_args()


def ensure_exec(path):
    try:
        os.chmod(path, os.stat(path).st_mode | 0o111)
    except OSError:
        pass


def wrapper_script(target, mode):
    esc = target.replace("\\", "\\\\").replace('"', '\\"')
    mode = (" " + mode) if mode else ""
    return ('#!/bin/sh\n'
            '# 学生时代模组编辑器 启动命令（由 build_deb.py 生成）\n'
            'exec "%s"%s "$@"\n') % (esc, mode)


def dir_size_kb(path):
    total = 0
    for root, dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total // 1024 + 1


def main():
    args = parse_args()
    src = os.path.abspath(args.source)
    out_dir = os.path.abspath(args.output)
    if not os.path.isdir(src):
        raise SystemExit("错误：--source 目录不存在：%s" % src)
    for need in (APP_NAME, "backend", "_internal"):
        if not os.path.exists(os.path.join(src, need)):
            raise SystemExit("错误：--source 缺少 %s（zip 发行目录不完整？）" % need)
    os.makedirs(out_dir, exist_ok=True)

    work = tempfile.mkdtemp(prefix="sae_deb_")
    try:
        pkg = os.path.join(work, "pkg")
        app_dir = os.path.join(pkg, "opt", PKG_ID)
        shutil.copytree(src, app_dir, symlinks=True)
        # 安装向导脚本只随 zip/install.sh 分发，不进 /opt（有 /usr/bin 命令即可）
        shutil.rmtree(os.path.join(app_dir, "install.sh"), ignore_errors=True)
        ensure_exec(os.path.join(app_dir, APP_NAME))
        ensure_exec(os.path.join(app_dir, "backend"))

        # /usr/bin 启动命令
        usr_bin = os.path.join(pkg, "usr", "bin")
        os.makedirs(usr_bin)
        for name, rel, mode in (("editor-gui", APP_NAME, ""),
                                ("editor-tui", "backend", "tui"),
                                ("editor-cli", "backend", "cli")):
            cmd = os.path.join(usr_bin, name)
            with open(cmd, "w", encoding="utf-8") as f:
                f.write(wrapper_script(os.path.join(INSTALL_PREFIX, rel), mode))
            os.chmod(cmd, 0o755)

        # 桌面入口 + 图标
        apps_dir = os.path.join(pkg, "usr", "share", "applications")
        icons_dir = os.path.join(pkg, "usr", "share", "icons", "hicolor", "512x512", "apps")
        os.makedirs(apps_dir)
        os.makedirs(icons_dir)
        with open(DESKTOP_TEMPLATE, "r", encoding="utf-8") as f:
            desktop = f.read().replace("__INSTALL_DIR__", INSTALL_PREFIX)
        with open(os.path.join(apps_dir, PKG_ID + ".desktop"), "w", encoding="utf-8") as f:
            f.write(desktop)
        icon_src = os.path.join(src, "editor_icon.png")
        if os.path.isfile(icon_src):
            shutil.copy2(icon_src, os.path.join(icons_dir, PKG_ID + ".png"))

        # DEBIAN 元数据
        debian = os.path.join(pkg, "DEBIAN")
        os.makedirs(debian)
        control = (
            "Package: %s\n"
            "Version: %s\n"
            "Section: utils\n"
            "Priority: optional\n"
            "Architecture: amd64\n"
            "Installed-Size: %d\n"
            "Maintainer: %s\n"
            "Depends: libc6 (>= 2.39), libgtk-3-0, liblzma5, "
            "libgstreamer1.0-0, gstreamer1.0-plugins-base, gstreamer1.0-good\n"
            "Description: 《学生时代》游戏模组编辑器（GUI/TUI/CLI 三合一）\n"
            " 学生时代模组编辑器：用于《学生时代》(Steam AppID 1991040) 的"
            "模组编辑，含图形界面 (GUI)、终端界面 (TUI) 与命令行 (CLI)，"
            "内置官方资源扩展包，无需 Python/Flutter 运行环境。"
            "安装位置 /opt/student-age-editor。\n"
        ) % (PKG_ID, args.version, dir_size_kb(app_dir), args.maintainer)
        with open(os.path.join(debian, "control"), "w", encoding="utf-8") as f:
            f.write(control)
        postinst = (
            "#!/bin/sh\n"
            "set -e\n"
            "chmod +x /opt/%s/%s /opt/%s/backend 2>/dev/null || true\n"
            "if command -v update-desktop-database >/dev/null 2>&1; then "
            "update-desktop-database /usr/share/applications >/dev/null 2>&1 || true; fi\n"
            "if command -v gtk-update-icon-cache >/dev/null 2>&1; then "
            "gtk-update-icon-cache -q /usr/share/icons/hicolor >/dev/null 2>&1 || true; fi\n"
            "exit 0\n"
        ) % (PKG_ID, APP_NAME, PKG_ID)
        postinst_path = os.path.join(debian, "postinst")
        with open(postinst_path, "w", encoding="utf-8") as f:
            f.write(postinst)
        os.chmod(postinst_path, 0o755)

        out_path = os.path.join(out_dir, "%s_%s_amd64.deb" % (PKG_ID, args.version))
        if os.path.exists(out_path):
            os.remove(out_path)
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", pkg, out_path],
                       check=True)
        size_mb = os.path.getsize(out_path) / 1048576
        print("完成：%s (%.1f MB)" % (out_path, size_mb))
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()