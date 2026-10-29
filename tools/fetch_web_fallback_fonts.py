#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Flutter Web 引擎的 fallback 字体（Roboto / 中日韩 Noto 切片）镜像到
本地 web 产物目录，避免运行时访问 fonts.gstatic.com。

背景：CanvasKit 不能使用系统字体，遇到正文字体没覆盖的字符（中文、emoji、
符号）时会从 https://fonts.gstatic.com/s/ 按切片下载 Noto 字体。该域名在
中国大陆不可达；下载失败还会触发引擎的无限重试（flutter#184449）。网页版
因此需要把这些切片放到同源目录，并在 flutter_bootstrap.js 里用
`fontFallbackBaseUrl: "fallback_fonts/"` 指过来。

用法：
    python tools/fetch_web_fallback_fonts.py --web-root frontend/build/web
    python tools/fetch_web_fallback_fonts.py --web-root frontend/build/web \
        --all-cjk --refresh

实现要点：
- 字体清单不在源码里，而是被编译进 `main.dart.js`（形如
  "notosanssc/v37/xxx.116.woff2"）。这里用正则从构建产物里提取，天然与
  当前 Flutter 引擎版本同步，不用手抄 URL。
- 只镜像显式允许的 family；默认覆盖简体中文 UI（Noto Sans SC）+ 引擎无论
  如何都会拉取的 Roboto + emoji/符号。
- 下载结果缓存到 `_cache/web_fallback_fonts/`，重复构建不重复下载。
- 目录结构保持 `<family>/<version>/<file>`，与引擎拼接 URL 的方式一致。

退出码：0 = 至少写入一个字体；2 = 一个都没拿到（调用方应告警并回退到
Google CDN，而不是产出指向空目录的包）。
"""
import argparse
import concurrent.futures
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_WEB_ROOT = os.path.join(ROOT, "frontend", "build", "web")
DEFAULT_CACHE_DIR = os.path.join(ROOT, "_cache", "web_fallback_fonts")
SOURCE_BASE = "https://fonts.gstatic.com/s/"

# 简体中文 + 引擎必然请求的 Roboto + emoji/符号。繁体/日韩按需 --all-cjk。
DEFAULT_FAMILIES = ("roboto", "notosanssc", "notocoloremoji", "notosanssymbols2")
ALL_CJK_FAMILIES = DEFAULT_FAMILIES + (
    "notosanstc",
    "notosanshk",
    "notosansjp",
    "notosanskr",
)

# main.dart.js 里的字体 URL：<family>/v<digits>/<name>[.<slice>].woff2
FONT_URL_RE = re.compile(
    r"""["']([a-z0-9_]+/v\d+/[A-Za-z0-9_.\-]+\.(?:woff2|ttf))["']"""
)


def read_font_manifest(web_root):
    js_path = os.path.join(web_root, "main.dart.js")
    if not os.path.isfile(js_path):
        raise SystemExit(
            "错误：找不到 %s（先执行 flutter build web）" % js_path
        )
    with open(js_path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    urls = set(FONT_URL_RE.findall(text))
    if not urls:
        raise SystemExit(
            "错误：没能从 main.dart.js 解析出 fallback 字体清单；"
            "Flutter 引擎的字体数据格式可能变了，请检查 FONT_URL_RE"
        )
    return urls


def select_urls(urls, families):
    picked = sorted(u for u in urls if u.split("/", 1)[0] in families)
    return picked


def download_one(rel, cache_dir, timeout, force):
    """返回 (rel, bytes_written, source)；失败抛异常。"""
    cache_path = os.path.join(cache_dir, *rel.split("/"))
    if os.path.isfile(cache_path) and os.path.getsize(cache_path) > 0 and not force:
        return rel, os.path.getsize(cache_path), "cache"
    url = SOURCE_BASE + rel
    last_err = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": "student-age-editor-build/1.0",
                    "Accept-Encoding": "identity",
                },
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = resp.read()
                expected = resp.headers.get("Content-Length")
                if not data:
                    raise IOError("empty body")
                if expected is not None and int(expected) != len(data):
                    raise IOError(
                        "short read (%d/%s)" % (len(data), expected)
                    )
            os.makedirs(os.path.dirname(cache_path), exist_ok=True)
            tmp = cache_path + ".part"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, cache_path)
            return rel, len(data), "network"
        except Exception as exc:  # noqa: BLE001 - 汇总后统一报错
            last_err = exc
            if attempt < 2:
                time.sleep(0.4 * (attempt + 1))
    raise IOError("%s: %s" % (url, last_err))


def mirror(web_root, families, cache_dir, timeout, force, jobs, all_cjk):
    urls = read_font_manifest(web_root)
    wanted = select_urls(urls, set(families))
    if not wanted:
        raise SystemExit(
            "错误：main.dart.js 里没有匹配的字体（families=%s）"
            % ",".join(sorted(families))
        )
    os.makedirs(cache_dir, exist_ok=True)

    results = []
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {
            pool.submit(download_one, rel, cache_dir, timeout, force): rel
            for rel in wanted
        }
        for fut in concurrent.futures.as_completed(futures):
            rel = futures[fut]
            try:
                results.append(fut.result())
            except Exception as exc:  # noqa: BLE001
                failures.append((rel, str(exc)))

    if not results:
        return 0, 0, wanted, failures

    out_root = os.path.join(web_root, "fallback_fonts")
    if os.path.isdir(out_root):
        shutil.rmtree(out_root)
    per_family = {}
    total = 0
    for rel, size, _source in results:
        dst = os.path.join(out_root, *rel.split("/"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        src = os.path.join(cache_dir, *rel.split("/"))
        if os.path.abspath(src) != os.path.abspath(dst):
            shutil.copy2(src, dst)
        fam = rel.split("/", 1)[0]
        per_family[fam] = per_family.get(fam, 0) + size
        total += size

    manifest = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": SOURCE_BASE,
        "families": per_family,
        "file_count": len(results),
        "bytes": total,
        "all_cjk": bool(all_cjk),
    }
    with open(os.path.join(out_root, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    return len(results), total, wanted, failures


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-root", default=DEFAULT_WEB_ROOT)
    parser.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--refresh", action="store_true", help="忽略缓存重新下载")
    parser.add_argument(
        "--all-cjk",
        action="store_true",
        help="同时镜像繁体/日韩（约 +8 MB，按需下载，不增加首屏传输）",
    )
    parser.add_argument(
        "--families",
        default=None,
        help="逗号分隔的 family 目录名（默认 roboto,notosanssc,notocoloremoji,notosanssymbols2）",
    )
    args = parser.parse_args(argv)

    families = (
        tuple(x.strip() for x in args.families.split(",") if x.strip())
        if args.families
        else (ALL_CJK_FAMILIES if args.all_cjk else DEFAULT_FAMILIES)
    )
    ok, total, wanted, failures = mirror(
        args.web_root,
        families,
        args.cache_dir,
        args.timeout,
        args.refresh,
        max(1, args.jobs),
        args.all_cjk,
    )

    print(
        "[fallback-fonts] 目标 %d 个切片，写入 %d 个，共 %.2f MB -> %s"
        % (len(wanted), ok, total / 1048576.0,
           os.path.join(args.web_root, "fallback_fonts"))
    )
    if failures:
        print("[fallback-fonts] 警告：%d 个切片下载失败，浏览器会在用到时回退到 Google CDN"
              % len(failures), file=sys.stderr)
        for rel, err in failures[:5]:
            print("  - %s: %s" % (rel, err), file=sys.stderr)
    if ok == 0:
        print("[fallback-fonts] 错误：一个字体都没拿到；网页版将回退 fonts.gstatic.com",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
