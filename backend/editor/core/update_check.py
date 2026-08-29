# -*- coding: utf-8 -*-
"""检查应用更新：通过 GitHub Releases API 查询最新发行版。

供 CLI 的 /update 命令与 TUI 的「检查更新」入口手动触发调用
（只做单次查询，不做后台轮询）。用法::

    from editor.core.update_check import check_update
    result = check_update(timeout=6)
    # 成功: {"ok": True, "current": ..., "latest_tag": ..., ...}
    # 失败: {"ok": False, "error": "...", "current": ...}

目标仓库由模块常量 GITHUB_REPO 决定，默认
yier12121212yie/student-age-editor，可用环境变量
EDITOR_UPDATE_REPO 覆盖，便于 fork 或本地测试。

版本比较规则：_version_key() 从 tag 里提取点分数字串
（如 "Alpha-v0.1" → (0, 1)）转成整数元组后比较——是数值比较
而非字符串比较，因此 Alpha-v0.10 会正确地大于 Alpha-v0.9；
Alpha 阶段所有 tag 都含数字版本号，元组比较足够。

注意：网络失败（超时/断网/HTTP 错误/JSON 解析失败等）不抛异常，
统一返回 {"ok": False, "error": 原因, "current": 当前版本}，
由调用方负责展示。
"""
import json
import os
import re
import urllib.error
import urllib.request

# 目标仓库（应用发行版所在）；可用环境变量覆盖（便于 fork/测试）
GITHUB_REPO = os.environ.get("EDITOR_UPDATE_REPO") or "yier12121212yie/student-age-editor"

# 只取最近 5 个 release（足够覆盖当前迭代线），从中按创建时间挑最新
_RELEASES_URL = "https://api.github.com/repos/%s/releases?per_page=5"

_USER_AGENT = "student-age-editor-update-check"


def _version_key(tag):
    """从 tag 提取数字版本元组，用于比较新旧。

    "Alpha-v0.1" → (0, 1)；"v1.4.1" → (1, 4, 1)；"Alpha-v0.10" → (0, 10)。
    各段转成 int 后按元组比较（数值比较而非字符串比较，因此
    (0, 10) > (0, 9) 成立）；tag 中没有点分数字时返回空元组 ()，
    它永远小于任何带版本的 tag。
    """
    match = re.search(r"(\d+(?:\.\d+)+)", tag or "")
    if not match:
        return ()
    return tuple(int(part) for part in match.group(1).split("."))


def _line_prefix(tag):
    """版本线前缀：首个点分数字之前的文本（"Alpha-v0.1" → "Alpha-v"、
    "v1.4.1" → "v"）。版本线重置（如 1.4.x → Alpha-v0.x）后，不同前缀的
    数值元组之间没有可比较的语义，必须退回按「是否为同一发行」判断。
    """
    match = re.search(r"\d+(?:\.\d+)+", tag or "")
    if not match:
        return tag or ""
    return (tag or "")[:match.start()]


def _same_release(tag, current):
    """忽略大小写及首字符 v/V 后，两个版本字符串是否指代同一发行。"""
    norm = lambda s: re.sub(r"^[vV]", "", s or "").strip().lower()
    return bool(tag) and norm(tag) == norm(current)


def _should_update(latest_tag, current):
    """latest 与 current 是否应提示更新。

    同一版本线内用数值元组比较（Alpha-v0.10 > Alpha-v0.9 成立）；
    跨版本线（前缀不同，如当前 1.4.x、最新按创建时间取的 Alpha-v0.x）
    数值比较无意义，退化为「最新发行与已装版本不是同一发行」；
    latest 提取不到点分版本号（如 tag "latest"）时无法判断新旧，不提示。
    """
    if not (latest_tag or "").strip():
        return False
    v_latest = _version_key(latest_tag)
    if not v_latest:
        return False
    v_current = _version_key(current)
    if v_latest and v_current and _line_prefix(latest_tag) == _line_prefix(current):
        return v_latest > v_current
    return not _same_release(latest_tag, current)


def _empty_result(current):
    """仓库暂无可用发行版（列表为空或全是 draft）时的返回值。"""
    return {
        "ok": True,
        "current": current,
        "latest_tag": "",
        "latest_name": "",
        "prerelease": False,
        "published_at": "",
        "html_url": "",
        "notes": "",
        "update_available": False,
        "assets": [],
    }


def check_update(timeout=6):
    """查询 GitHub 最新 Release 并与当前版本比较，返回结果字典。

    返回结构见模块 docstring；网络/解析失败不抛异常，返回
    {"ok": False, "error": 原因, "current": 当前版本}。
    """
    # 在函数体内导入，避免模块顶层 import editor 造成循环导入
    try:
        from editor import __version__ as current
    except Exception:
        current = "Alpha-v0.1"

    try:
        req = urllib.request.Request(_RELEASES_URL % GITHUB_REPO, headers={
            "User-Agent": _USER_AGENT,
            "Accept": "application/vnd.github+json",
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            releases = json.loads(resp.read().decode("utf-8"))
        if not isinstance(releases, list):
            # 非列表响应（如限流/异常时的 {"message": ...}）不能按 release 遍历
            return {"ok": False,
                    "error": "GitHub 返回了意外的响应格式（非列表）",
                    "current": current}
        # 「最新发行版」按创建时间取：GitHub 列表顺序不保证按时间排列，
        # 也不能按版本号取最大（版本线重置为 Alpha-v0.1 后，旧线 1.4.x
        # 的数字版本永远更大，会误报更新）
        candidates = [r for r in releases if not r.get("draft")]
        rel = max(candidates, key=lambda r: r.get("created_at") or "") \
            if candidates else None
        if rel is None:
            return _empty_result(current)
        latest_tag = rel.get("tag_name") or ""
        return {
            "ok": True,
            "current": current,
            "latest_tag": latest_tag,
            "latest_name": rel.get("name") or "",
            "prerelease": bool(rel.get("prerelease")),
            "published_at": rel.get("published_at") or "",
            "html_url": rel.get("html_url") or rel.get("url") or "",
            # 完整返回发布说明，截断交给展示层
            "notes": rel.get("body") or "",
            "update_available": _should_update(latest_tag, current),
            "assets": [
                {
                    "name": a.get("name", ""),
                    "url": a.get("browser_download_url", ""),
                    "size": a.get("size", 0),
                }
                for a in rel.get("assets") or []
            ],
        }
    except Exception as exc:
        # HTTPError 时把状态码写进错误信息（如 "HTTP 404"），更可读
        if isinstance(exc, urllib.error.HTTPError):
            error = "HTTP %d" % exc.code
        else:
            error = str(exc) or type(exc).__name__
        return {"ok": False, "error": error, "current": current}


if __name__ == "__main__":  # 手工调试: python -m editor.core.update_check
    import sys

    # Windows 控制台默认非 UTF-8 编码，直接打印中文发布说明可能报错
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    print(json.dumps(check_update(), ensure_ascii=False, indent=2))
