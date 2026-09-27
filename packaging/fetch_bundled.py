# -*- coding: utf-8 -*-
"""从 GitHub Release 下载官方预解码资源包（构建机无游戏时用）。

用法:
  python packaging/fetch_bundled.py --out <保存路径>
          [--asset bundled_preview.zip] [--repo owner/repo] [--tag latest]
          [--expect-sha256 <hex>]

- --repo 默认取环境变量 GITHUB_REPOSITORY（CI 自动注入）；缺省时报错退出。
- --tag latest 自动解析最新 release（releases/latest），也可指定版本标签。
- 用 urllib（零第三方依赖），可选 GITHUB_TOKEN 增加 Authorization 头。
- --expect-sha256: 供应链强校验（安全批次 A）。给定 64 位十六进制摘要时，
  下载完成后立即重算 SHA-256，不一致则删除落盘文件并退出码 1 —— CI 中
  应把官方资产的哈希 pin 在 packaging/ci_assets.lock.json 并把该值传进来，
  防止 Release asset 被替换后静默进入发行物。
- 404 / 缺少对应 asset 视为「无包可注入」，打印明确原因并退出码 0，
  便于 CI 中可选注入而不让 job 失败；其余网络/IO 错误退出码 1。
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request

# Windows CI 的管道 stdout 默认是 cp1252 等区域编码，打印中文会直接
# UnicodeEncodeError；这里强制 UTF-8 并容忍不可编码字符。
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

_USER_AGENT = "StudentAge-editor-release-bot/1.0"

# 退出码约定：0 成功/无包跳过；1 网络/IO 错误（CI 可降级为不带资源继续）；
# 3 SHA-256 强校验失败（供应链告警，CI 必须中止）。
EXIT_HASH_MISMATCH = 3


class HashMismatch(RuntimeError):
    pass


def _request(url, token=None, timeout=30):
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": _USER_AGENT,
    })
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


def resolve_asset(repo, tag, asset_name, token):
    """返回 (下载 url, asset id 或 None, 是否命中)；404/缺 asset 时返回 (None, None, False)。

    私有仓库的 browser_download_url 对 Bearer token 也会 404，须走
    资产 API（Accept: application/octet-stream）下载，因此同时返回 id。
    """
    if tag == "latest":
        api = "https://api.github.com/repos/%s/releases/latest" % repo
    else:
        api = "https://api.github.com/repos/%s/releases/tags/%s" % (
            repo, urllib.parse.quote(tag, safe=""))
    try:
        status, body = _request(api, token)
    except urllib.error.HTTPError as e:
        if e.code in (404, 410):
            print("没有找到 %s 的 Release（tag=%s），跳过资源包注入"
                  % (repo, tag))
            return None, None, False
        raise
    if status != 200:
        print("GitHub API 返回 %d，无法解析 release，跳过" % status)
        return None, None, False
    data = json.loads(body.decode("utf-8"))
    for a in data.get("assets") or []:
        if a.get("name") == asset_name:
            return a.get("browser_download_url"), a.get("id"), True
    print("Release %s 中未找到 asset '%s'，跳过资源包注入"
          % (data.get("tag_name") or tag, asset_name))
    return None, None, False


def download(url, out_path, token, repo=None, asset_id=None):
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    if token and asset_id and repo:
        # 私有仓库必须走资产 API（octet-stream 直出文件字节流）。
        url = "https://api.github.com/repos/%s/releases/assets/%s" % (
            repo, asset_id)
        req = urllib.request.Request(url, headers={
            "Accept": "application/octet-stream",
            "User-Agent": _USER_AGENT,
        })
        req.add_header("Authorization", "Bearer " + token)
    else:
        req = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
        if token:
            req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=600) as r, \
            open(out_path, "wb") as f:
        shutil.copyfileobj(r, f)
    print("已下载 %s -> %s (%.1f MB)"
          % (os.path.basename(out_path), out_path,
             os.path.getsize(out_path) / 1048576))
    return out_path


def sha256_of(path):
    """流式计算文件 SHA-256（资源包可达数百 MB，不能整读进内存）。"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def verify_sha256(out_path, expect):
    """供应链强校验：摘要不匹配删除落盘文件并抛 HashMismatch（退出码 3）。"""
    actual = sha256_of(out_path)
    if actual.lower() != expect.strip().lower():
        try:
            os.remove(out_path)
        except OSError:
            pass
        raise HashMismatch(
            "SHA-256 校验失败：期望 %s，实际 %s（文件已删除）。"
            "若上游资产为官方更新，请同步更新 packaging/ci_assets.lock.json"
            % (expect.strip().lower(), actual))
    print("SHA-256 校验通过：%s" % actual)


def main():
    ap = argparse.ArgumentParser(
        description="从 GitHub Release 下载官方预解码资源包（无游戏构建机用）")
    ap.add_argument("--asset", default="bundled_preview.zip",
                    help="Release asset 文件名（默认 bundled_preview.zip）")
    ap.add_argument("--out", required=True, help="保存路径")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""),
                    help="owner/repo（默认取环境变量 GITHUB_REPOSITORY）")
    ap.add_argument("--tag", default="latest",
                    help="Release 标签；latest 自动解析最新 Release")
    ap.add_argument("--expect-sha256", default="",
                    help="期望的 SHA-256（64 位十六进制）；给定后下载完成即强校验，"
                         "不一致删除文件并退出 1。CI 从 packaging/ci_assets.lock.json 取值")
    args = ap.parse_args()

    if not args.repo:
        print("错误：未指定 --repo，且环境变量 GITHUB_REPOSITORY 为空。\n"
              "GitHub Actions 中会自动注入；本地请用 --repo owner/repo。",
              file=sys.stderr)
        return 1

    token = os.environ.get("GITHUB_TOKEN", "")
    try:
        url, asset_id, found = resolve_asset(args.repo, args.tag,
                                             args.asset, token)
        if not found or not url:
            return 0  # 无包 → 跳过，不视为失败
        download(url, args.out, token, repo=args.repo, asset_id=asset_id)
        if args.expect_sha256:
            verify_sha256(args.out, args.expect_sha256)
    except HashMismatch:
        raise
    except Exception as e:
        print("获取资源包失败：%s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HashMismatch as e:
        print("供应链校验失败：%s" % e, file=sys.stderr)
        sys.exit(EXIT_HASH_MISMATCH)