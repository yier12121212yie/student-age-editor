#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按源码实际引用裁剪 Flutter Web 产物的图标字体。

为什么需要：`flutter build --tree-shake-icons` 对 fluent_ui /
fluentui_system_icons 只做了 6%–18% 的表裁剪，字形数一个没少（实测
FluentSystemIcons-Regular 仍是 8373 个字形 / 2.04 MB）。而网页端启动时会把
FontManifest 里的每个字体都拉一遍，5 个图标字体合计 4.4 MB，是首屏第二大
开销（仅次于 main.dart.js）。

做法：
1. 从 pub 包源码解析每个图标类的 const 定义（名字 → 码点 + fontFamily）。
2. 扫描 app（frontend/lib）与 fluent_ui 包自身的 `FluentIcons.x` /
   `SegoeIcons.x` 引用，按 import 前缀判断属于哪个包，收集每个 family
   实际用到的码点（app 里没有任何动态 `IconData(...)` 构造）。
3. 用 fontTools 把 build/web 里的字体裁到「用到的码点 + 空格」，原地替换。

安全性：裁剪前校验每个码点在原字体 cmap 中存在；裁剪后再次校验子集包含
全部请求码点，任一失败就保留原字体（最多退回优化前的体积，不会缺图标）。
动态图标名（把字符串映射到 IconData）不在当前代码里；若以后引入，需要
在 `collect_dynamic_codepoints` 里补。

用法：
    pip install fonttools
    python tools/subset_web_icon_fonts.py --web-root frontend/build/web
"""
import argparse
import json
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRONTEND = os.path.join(ROOT, "frontend")
DEFAULT_WEB_ROOT = os.path.join(FRONTEND, "build", "web")

# Flutter 沙箱里保留的图标字体（Material/Cupertino 已由 flutter_tools 裁到
# 15 KB / 1.4 KB，不需要再处理）。
TARGET_FAMILIES = {
    "packages/fluentui_system_icons/FluentSystemIcons-Regular",
    "packages/fluentui_system_icons/FluentSystemIcons-Filled",
    "packages/fluent_ui/FluentIcons",
    "packages/fluent_ui/SegoeIcons",
}

# 图标类定义所在文件（相对各包根目录）。
DEF_FILES = {
    "fluentui_system_icons": [
        ("FluentIcons", "lib/src/fluent_icons.dart"),
    ],
    "fluent_ui": [
        ("FluentIcons", "lib/src/icons.dart"),
        ("SegoeIcons", "lib/src/windows_icons.dart"),
        ("WindowsIcons", "lib/src/windows_icons.dart"),
    ],
}

# WindowsIcon 在非 Windows（Web）平台上按名字把 Segoe 图标映射成 FluentIcons
# 图标再绘制（fluent_ui/src/controls/utils/windows_icon.dart）。因此每个
# `WindowsIcons.x` 引用还要把同名的 FluentIcons 码点一起保留，否则下拉框/
# 数字框的箭头会在 Web 上变成豆腐块。
WEB_FALLBACK_CLASS = "WindowsIcons"
WEB_FALLBACK_TARGET = ("fluent_ui", "FluentIcons")

ICON_DEF_RE = re.compile(
    r"static\s+const\s+IconData\s+(\w+)\s*=\s*IconData\(\s*"
    r"(0x[0-9a-fA-F]+|\d+)\s*,\s*fontFamily:\s*'([^']+)'",
    re.S,
)
IMPORT_RE = re.compile(
    r"""^\s*import\s+'package:(fluent_ui|fluentui_system_icons)/[^']+'\s*"""
    r"""(?:as\s+(\w+))?\s*;""",
    re.M,
)
USE_RE = re.compile(
    r"\b(?:(?P<alias>[A-Za-z_]\w*)\.)?"
    r"(FluentIcons|SegoeIcons|WindowsIcons)\.(?P<name>\w+)"
)

# 总是保留的码点：空格（Web 引擎用它测量行高）。
BASE_CODEPOINTS = {0x20}


def package_roots():
    """从 frontend/.dart_tool/package_config.json 解析包根目录。"""
    cfg = os.path.join(FRONTEND, ".dart_tool", "package_config.json")
    roots = {}
    try:
        with open(cfg, "r", encoding="utf-8") as f:
            data = json.load(f)
        for entry in data.get("packages", []):
            name = entry.get("name")
            if name not in DEF_FILES:
                continue
            uri = entry.get("rootUri", "")
            if uri.startswith("file:///"):
                path = uri[len("file:///"):]
                # Windows: file:///D:/x -> D:/x
                if re.match(r"^[A-Za-z]:", path):
                    path = path
                else:
                    path = "/" + path
            elif os.path.isabs(uri):
                path = uri
            else:
                path = os.path.normpath(os.path.join(FRONTEND, ".dart_tool", uri))
            roots[name] = path
    except (OSError, ValueError) as exc:
        raise SystemExit("错误：无法读取 %s（先 flutter pub get）：%s" % (cfg, exc))
    missing = [n for n in DEF_FILES if n not in roots]
    if missing:
        raise SystemExit("错误：包未解析：%s" % ", ".join(missing))
    return roots


def load_icon_defs(roots):
    """返回 {pkg: {class_name: {icon_name: (family, codepoint)}}}。"""
    defs = {}
    for pkg, files in DEF_FILES.items():
        pkg_defs = {}
        for class_name, rel in files:
            path = os.path.join(roots[pkg], *rel.split("/"))
            try:
                text = open(path, "r", encoding="utf-8", errors="replace").read()
            except OSError as exc:
                raise SystemExit("错误：找不到图标定义 %s: %s" % (path, exc))
            table = pkg_defs.setdefault(class_name, {})
            for name, cp, family in ICON_DEF_RE.findall(text):
                table[name] = (family, int(cp, 0))
        defs[pkg] = pkg_defs
    return defs


def resolve(icon_defs, pkg, class_name, icon_name):
    hit = icon_defs.get(pkg, {}).get(class_name, {}).get(icon_name)
    if hit is None:
        return None
    family, cp = hit
    # FontManifest 里包字体的 family 形如 packages/<pkg>/<family>。
    return "packages/%s/%s" % (pkg, family), cp


def scan_file_usage(path, icon_defs, used, stats):
    """扫描一个 Dart 文件里的图标引用，把码点累加进 used[family]。"""
    try:
        text = open(path, "r", encoding="utf-8", errors="replace").read()
    except OSError:
        return
    imports = list(IMPORT_RE.finditer(text))
    unprefixed = None
    aliases = {}
    for m in imports:
        pkg, alias = m.group(1), m.group(2)
        if alias:
            aliases[alias] = pkg
        else:
            unprefixed = pkg
    for m in USE_RE.finditer(text):
        alias = m.group("alias")
        class_name = m.group(2)
        name = m.group("name")
        if alias:
            pkg = aliases.get(alias)
            if not pkg:
                continue
            hit = resolve(icon_defs, pkg, class_name, name)
            if hit is None and alias == "fluent":
                hit = resolve(icon_defs, "fluent_ui", class_name, name)
        else:
            pkg = unprefixed
            hit = resolve(icon_defs, pkg, class_name, name) if pkg else None
            if hit is None:
                # 无（或无法判定）显式 import 时，按类名在两个包里都查一遍；
                # 取到的码点只会让子集略大，不会缺图标。
                for candidate in ("fluent_ui", "fluentui_system_icons"):
                    hit = resolve(icon_defs, candidate, class_name, name)
                    if hit is not None:
                        break
        if hit is None:
            stats["unresolved"].add("%s.%s" % (class_name, name))
            continue
        family, cp = hit
        used.setdefault(family, set()).add(cp)
        stats["refs"] += 1
        if class_name == WEB_FALLBACK_CLASS:
            fb = resolve(icon_defs, WEB_FALLBACK_TARGET[0],
                         WEB_FALLBACK_TARGET[1], name)
            if fb is not None:
                used.setdefault(fb[0], set()).add(fb[1])


def collect_used(roots, icon_defs):
    used = {}
    stats = {"refs": 0, "unresolved": set()}
    lib_dir = os.path.join(FRONTEND, "lib")
    for dirpath, _dirs, files in os.walk(lib_dir):
        for name in files:
            if name.endswith(".dart"):
                scan_file_usage(os.path.join(dirpath, name), icon_defs, used, stats)
    # fluent_ui 组件内部也会用图标（FluentIcons.* / SegoeIcons.*），这些
    # 引用不在 app 里，但会出现在屏幕上。
    pkg_lib = os.path.join(roots["fluent_ui"], "lib")
    for dirpath, _dirs, files in os.walk(pkg_lib):
        for name in files:
            if not name.endswith(".dart"):
                continue
            if os.path.abspath(os.path.join(dirpath, name)) == \
                    os.path.abspath(os.path.join(roots["fluent_ui"], "lib", "src", "icons.dart")):
                continue
            scan_file_usage(os.path.join(dirpath, name), icon_defs, used, stats)
    return used, stats


def subset_fonts(web_root, used):
    try:
        from fontTools import subset
        from fontTools.ttLib import TTFont
    except ImportError:
        print("    提示：未安装 fonttools，跳过图标字体子集化"
              "（pip install fonttools 可省约 2 MB）")
        return False

    manifest_path = os.path.join(web_root, "assets", "FontManifest.json")
    try:
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError) as exc:
        print("    警告：读取 %s 失败，跳过图标字体子集化：%s" % (manifest_path, exc))
        return False

    assets = {}
    for fam in manifest:
        family = fam.get("family", "")
        for font in fam.get("fonts", []):
            asset = font.get("asset", "")
            if family and asset:
                assets[family] = os.path.join(web_root, "assets", *asset.split("/"))

    changed = 0
    remove_families = set()
    for family in sorted(TARGET_FAMILIES):
        path = assets.get(family)
        if not path or not os.path.isfile(path):
            continue
        codepoints = set(used.get(family, set())) | BASE_CODEPOINTS
        if len(codepoints) <= len(BASE_CODEPOINTS):
            # 零引用的声明字体（如 fluent_ui 的 SegoeIcons）只是白白占首屏，
            # 连文件带 FontManifest 条目一起删掉。
            print("    图标字体 %-46s 无引用，移除（-%.0f KB）"
                  % (family.rsplit("/", 1)[-1], os.path.getsize(path) / 1024.0))
            remove_families.add(family)
            changed += 1
            continue
        try:
            font = TTFont(path, lazy=True)
            cmap = font.getBestCmap() or {}
            wanted = sorted(cp for cp in codepoints if cp in cmap)
            missing = sorted(cp for cp in codepoints if cp not in cmap)
            if missing:
                print("    提示：%s 缺少 %d 个码点（跳过这些）：%s"
                      % (family, len(missing),
                         ", ".join("U+%04X" % cp for cp in missing[:5])))
            if not wanted:
                font.close()
                continue
            options = subset.Options()
            options.no_hinting = True
            options.glyph_names = False
            options.drop_tables += ["DSIG"]
            options.recalc_bounds = False
            subsetter = subset.Subsetter(options=options)
            subsetter.populate(unicodes=wanted)
            subsetter.subset(font)
            fd, tmp = tempfile.mkstemp(suffix=".ttf",
                                      dir=os.path.dirname(path) or None)
            os.close(fd)
            font.save(tmp)
            font.close()

            # 校验子集：请求的码点必须全部还在，否则回退原字体。
            check = TTFont(tmp, lazy=True)
            got = check.getBestCmap() or {}
            check.close()
            absent = [cp for cp in wanted if cp not in got]
            if absent:
                os.remove(tmp)
                print("    警告：%s 子集校验失败（缺 %d 个码点），保留原字体"
                      % (family, len(absent)))
                continue
            before = os.path.getsize(path)
            after = os.path.getsize(tmp)
            if after >= before:
                os.remove(tmp)
                continue
            os.replace(tmp, path)
            changed += 1
            print("    图标字体 %-46s %6.0f KB -> %5.0f KB (-%.1f%%)"
                  % (family.rsplit("/", 1)[-1], before / 1024.0, after / 1024.0,
                     (1.0 - after / float(before)) * 100.0))
        except Exception as exc:  # noqa: BLE001 - 单个字体失败不影响构建
            print("    警告：%s 子集化失败，保留原字体：%s" % (family, exc))

    if remove_families:
        kept = []
        for fam in manifest:
            if fam.get("family") in remove_families:
                continue
            kept.append(fam)
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(kept, f, ensure_ascii=False, indent=2)
        for family in remove_families:
            try:
                os.remove(assets[family])
            except OSError:
                pass
    return changed > 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-root", default=DEFAULT_WEB_ROOT)
    args = parser.parse_args(argv)

    roots = package_roots()
    icon_defs = load_icon_defs(roots)
    used, stats = collect_used(roots, icon_defs)
    print("[icon-fonts] 解析到 %d 处图标引用，%d 个 family 命中"
          % (stats["refs"], len(used)))
    if stats["unresolved"]:
        print("[icon-fonts] 提示：%d 个引用无法映射（不影响构建）：%s"
              % (len(stats["unresolved"]),
                 ", ".join(sorted(stats["unresolved"])[:5])), file=sys.stderr)
    for family in sorted(used):
        print("  %-52s %d 个码点" % (family, len(used[family])))
    subset_fonts(args.web_root, used)
    return 0


if __name__ == "__main__":
    sys.exit(main())
