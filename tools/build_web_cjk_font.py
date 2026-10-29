#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成网页版内置中文字体（frontend/assets/fonts/EditorCJK.ttf）。

为什么需要：CanvasKit 没有系统字体，中文要靠引擎的 fallback 字体服务从
fonts.gstatic.com（或构建期镜像）按 unicode 切片下载。Flutter 3.47 的这套
服务在首屏只登记/下载极少数切片（实测 OOBE 页面只取到 2 片，随后不再重试），
结果是大量汉字显示成豆腐块（□）。把一份完整覆盖简体中文的字体内置进应用、
并作为主题字体，可以彻底绕开这条运行时链路；镜像切片保留给生僻字兜底。

覆盖面：
  * GB2312 全部字符（6763 汉字 + 682 符号，日常简体中文几乎全覆盖）；
  * ASCII / Latin-1 / 常用标点 / 全角字符；
  * 仓库前端源码里出现的全部非 ASCII 字符（防止文案用了 GB2312 外的字）。

用法：
    pip install fonttools brotli
    python tools/build_web_cjk_font.py                 # 生成到默认路径
    python tools/build_web_cjk_font.py --refresh       # 重新下载源字体
    python tools/build_web_cjk_font.py --check         # 只校验现有产物覆盖

源字体：优先 google/fonts 的可变字体 NotoSansSC[wght].ttf（实例化到 400），
下载失败时回退 notofonts 的 NotoSansSC-Regular.otf。两者都是 SIL OFL 1.1。
生成结果约 2.1 MB（gzip 1.36 MB / brotli 1.16 MB），由构建期预压缩为
.gz/.br 旁文件后随网页版一起下发。
"""
import argparse
import glob
import gzip
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRONTEND = os.path.join(ROOT, "frontend")
DEFAULT_OUT = os.path.join(FRONTEND, "assets", "fonts", "EditorCJK.ttf")
DEFAULT_CACHE = os.path.join(ROOT, "_cache", "cjk_font")

SOURCES = (
    # (文件名, URL, 是否可变字体)
    ("NotoSansSC-VF.ttf",
     "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/"
     "NotoSansSC%5Bwght%5D.ttf", True),
    ("NotoSansSC-Regular.otf",
     "https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/"
     "SubsetOTF/SC/NotoSansSC-Regular.otf", False),
)

# 除 GB2312 外固定纳入的码位区间。
EXTRA_RANGES = (
    (0x0020, 0x007E),  # ASCII
    (0x00A0, 0x00FF),  # Latin-1
    (0x2010, 0x2027),  # 连字符/破折号/引号/省略号
    (0x2030, 0x205E),  # 其它通用标点
    (0x3000, 0x303F),  # CJK 标点（、。「」等）
    (0xFF00, 0xFFEF),  # 全角 ASCII / 半角片假名
)

# 生成器版本：改动字符集逻辑时递增，用于缓存失效。
GENERATOR_VERSION = 3


def gb2312_codepoints():
    """GB2312 全码表（含符号区与两级汉字）。"""
    cps = set()
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                cps.add(ord(bytes([hi, lo]).decode("gb2312")))
            except UnicodeDecodeError:
                continue
    return cps


def source_literals():
    """前端源码里出现的所有非 ASCII 字符（含注释，宁多勿少）。"""
    cps = set()
    for path in glob.glob(os.path.join(FRONTEND, "lib", "**", "*.dart"),
                          recursive=True):
        try:
            with io.open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError:
            continue
        cps.update(ord(ch) for ch in text if ord(ch) > 0x7F)
    return cps


def wanted_codepoints():
    cps = gb2312_codepoints() | source_literals()
    for lo, hi in EXTRA_RANGES:
        cps.update(range(lo, hi + 1))
    return cps


def download(name, url, cache_dir, refresh=False):
    os.makedirs(cache_dir, exist_ok=True)
    path = os.path.join(cache_dir, name)
    if os.path.isfile(path) and os.path.getsize(path) > 1048576 and not refresh:
        return path
    import urllib.request

    tmp = path + ".part"
    req = urllib.request.Request(url, headers={"User-Agent": "student-age-editor-build/1.0"})
    with urllib.request.urlopen(req, timeout=180) as resp, open(tmp, "wb") as f:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    if os.path.getsize(tmp) < 1048576:
        os.remove(tmp)
        raise IOError("下载内容过小：%s" % url)
    os.replace(tmp, path)
    return path


def pick_source(cache_dir, refresh):
    errors = []
    for name, url, is_var in SOURCES:
        try:
            return download(name, url, cache_dir, refresh), is_var
        except Exception as exc:  # noqa: BLE001 - 逐个源尝试
            errors.append("%s: %s" % (name, exc))
    raise SystemExit("错误：源字体下载失败（检查网络后重试，或用 --source 指定本地文件）\n  "
                     + "\n  ".join(errors))


def build(src, is_variable, out_path, codepoints):
    from fontTools import subset
    from fontTools.ttLib import TTFont

    font = TTFont(src)
    if is_variable and "fvar" in font:
        from fontTools.varLib import instancer

        instancer.instantiateVariableFont(font, {"wght": 400}, inplace=True)
    cmap = font.getBestCmap() or {}
    present = sorted(cp for cp in codepoints if cp in cmap)
    missing = sorted(cp for cp in codepoints if cp not in cmap)
    if not present:
        raise SystemExit("错误：源字体不含任何目标字符")

    options = subset.Options()
    options.no_hinting = True
    options.glyph_names = False
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.layout_features = []  # CJK 无需 OpenType 排版特性
    options.drop_tables += ["GSUB", "GPOS", "GDEF", "BASE", "vhea", "vmtx",
                            "DSIG", "MVAR", "STAT", "fvar", "avar", "gvar",
                            "HVAR", "VVAR"]
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=present)
    subsetter.subset(font)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    tmp = out_path + ".part"
    # 结果可复现：不写入保存时间，重复生成得到逐字节相同的文件。
    font.recalcTimestamp = False
    font.save(tmp)
    font.close()
    os.replace(tmp, out_path)
    return len(present), missing


def verify(out_path, codepoints, known_unavailable=()):
    """返回成品字体里仍然缺失、且不是源字体本身就缺的码位。"""
    from fontTools.ttLib import TTFont

    font = TTFont(out_path, lazy=True)
    cmap = font.getBestCmap() or {}
    font.close()
    known = set(known_unavailable)
    return sorted(cp for cp in codepoints if cp not in cmap and cp not in known)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--cache-dir", default=DEFAULT_CACHE)
    parser.add_argument("--source", default=None, help="本地源字体（.ttf/.otf）")
    parser.add_argument("--refresh", action="store_true", help="忽略缓存重新下载")
    parser.add_argument("--check", action="store_true",
                        help="只校验现有产物，不重新生成")
    args = parser.parse_args(argv)

    codepoints = wanted_codepoints()
    manifest_path = args.out + ".json"
    fingerprint = {
        "generator": GENERATOR_VERSION,
        "chars": len(codepoints),
        "codepoints_sha1": __import__("hashlib").sha1(
            ",".join(str(c) for c in sorted(codepoints)).encode()).hexdigest(),
    }

    if args.check or (os.path.isfile(args.out) and os.path.isfile(manifest_path)):
        old = None
        try:
            with io.open(manifest_path, "r", encoding="utf-8") as f:
                old = json.load(f)
        except (OSError, ValueError):
            pass
        if os.path.isfile(args.out):
            stale = not old or old.get("fingerprint") != fingerprint
            if not stale or args.check:
                missing = verify(args.out, codepoints,
                                 (old or {}).get("unavailable", ()))
                if missing:
                    print("[cjk-font] 警告：现有字体缺少 %d 个目标字符（示例：%s）"
                          % (len(missing),
                             ", ".join("U+%04X" % c for c in missing[:5])))
                    if args.check:
                        return 2
                if stale:
                    print("[cjk-font] 字符集或生成器有变化，重新生成 ...")
                else:
                    print("[cjk-font] 覆盖校验通过：%d 个字符，%.2f MB -> %s"
                          % (fingerprint["chars"],
                             os.path.getsize(args.out) / 1048576.0, args.out))
                    return 0

    if args.source:
        src, is_var = args.source, args.source.lower().endswith(".ttf")
    else:
        src, is_var = pick_source(args.cache_dir, args.refresh)

    print("[cjk-font] 源字体 %s（%.1f MB）"
          % (os.path.basename(src), os.path.getsize(src) / 1048576.0))
    count, missing = build(src, is_var, args.out, codepoints)
    remaining = verify(args.out, codepoints, missing)
    size = os.path.getsize(args.out)
    with open(args.out, "rb") as f:
        data = f.read()
    gz = len(gzip.compress(data, 9))
    br = gz
    try:
        import brotli

        br = len(brotli.compress(data, quality=11))
    except ImportError:
        pass
    manifest = {
        "fingerprint": fingerprint,
        "source": os.path.basename(src),
        "glyphs": count,
        "bytes": size,
        "gzip_bytes": gz,
        "brotli_bytes": br,
        # 源字体本身没有的码位（生僻标点等），运行时交给引擎 fallback。
        "unavailable": missing,
    }
    with io.open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    print("[cjk-font] %d 个字符（源字体缺 %d 个）-> %.2f MB"
          % (count, len(missing), size / 1048576.0))
    print("[cjk-font] 传输体积 gzip %.2f MB / brotli %.2f MB"
          % (gz / 1048576.0, br / 1048576.0))
    if remaining:
        print("[cjk-font] 警告：成品仍缺 %d 个字符：%s"
              % (len(remaining),
                 ", ".join("U+%04X" % c for c in remaining[:8])), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
