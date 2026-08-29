# -*- coding: utf-8 -*-
"""update_check 单测：版本线内数值比较、跨版本线（1.4.x → Alpha-v0.x）按
「最新发行 ≠ 已装版本」判定、v 前缀归一，以及 check_update 的「按创建时间
取最新」在网络 mock 下的整体行为。

运行方式（在 backend 目录下）：
    python -m unittest editor.core.test_update_check -v
"""
import json
import unittest
from unittest import mock

from editor.core import update_check as uc


class _FakeResp(object):
    """可读且支持 with 的响应对象（模拟 urllib 返回值）。"""

    def __init__(self, payload):
        self._raw = json.dumps(payload).encode("utf-8")

    def read(self):
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _rel(tag, created, prerelease=False, draft=False):
    return {"tag_name": tag, "name": tag, "created_at": created,
            "prerelease": prerelease, "draft": draft, "assets": []}


class VersionKeyTest(unittest.TestCase):
    def test_alpha_and_semver(self):
        self.assertEqual(uc._version_key("Alpha-v0.1"), (0, 1))
        self.assertEqual(uc._version_key("v1.4.1"), (1, 4, 1))

    def test_no_version_returns_empty(self):
        self.assertEqual(uc._version_key("no-version"), ())
        self.assertEqual(uc._version_key(""), ())


class LinePrefixTest(unittest.TestCase):
    def test_prefixes(self):
        self.assertEqual(uc._line_prefix("Alpha-v0.1"), "Alpha-v")
        self.assertEqual(uc._line_prefix("Alpha-v0.10"), "Alpha-v")
        self.assertEqual(uc._line_prefix("v1.4.1"), "v")


class ShouldUpdateTest(unittest.TestCase):
    def test_same_line_numeric_compare(self):
        self.assertTrue(uc._should_update("Alpha-v0.10", "Alpha-v0.1"))
        self.assertFalse(uc._should_update("Alpha-v0.1", "Alpha-v0.2"))

    def test_cross_line_reset_counts_as_update(self):
        # 版本线重置：最新发行（创建时间最新）为 Alpha-v0.x，已装旧线 1.4.x
        self.assertTrue(uc._should_update("Alpha-v0.1", "1.4.1"))

    def test_same_release_with_v_prefix_not_an_update(self):
        self.assertFalse(uc._should_update("v1.4.1", "1.4.1"))
        self.assertFalse(uc._should_update("Alpha-v0.1", "alpha-v0.1"))

    def test_empty_latest_is_not_update(self):
        self.assertFalse(uc._should_update("", "Alpha-v0.1"))

    def test_undotted_latest_tag_is_not_update(self):
        # tag 提取不到点分版本号（如 "latest"/"no-version"）时无法判断新旧，
        # 不应误报「有更新」
        self.assertFalse(uc._should_update("latest", "Alpha-v0.1"))
        self.assertFalse(uc._should_update("no-version", "1.4.1"))


class CheckUpdateTest(unittest.TestCase):
    def test_picks_latest_by_created_at_and_cross_line(self):
        releases = [
            _rel("v1.4.1", "2026-01-01T00:00:00Z"),
            _rel("Alpha-v0.1", "2026-08-01T00:00:00Z"),
        ]
        with mock.patch("urllib.request.urlopen", return_value=_FakeResp(releases)):
            with mock.patch("editor.__version__", "1.4.1"):
                result = uc.check_update(timeout=3)
        self.assertTrue(result["ok"])
        self.assertEqual(result["latest_tag"], "Alpha-v0.1")
        # 旧线 1.4.1 用户必须被提示更新，而不是误报「已是最新」
        self.assertTrue(result["update_available"])

    def test_same_release_is_not_update(self):
        releases = [_rel("Alpha-v0.1", "2026-08-01T00:00:00Z")]
        with mock.patch("urllib.request.urlopen", return_value=_FakeResp(releases)):
            with mock.patch("editor.__version__", "Alpha-v0.1"):
                result = uc.check_update(timeout=3)
        self.assertTrue(result["ok"])
        self.assertFalse(result["update_available"])

    def test_network_failure_returns_error(self):
        with mock.patch("urllib.request.urlopen",
                        side_effect=OSError("network down")):
            result = uc.check_update(timeout=3)
        self.assertFalse(result["ok"])
        self.assertIn("network down", result.get("error", ""))

    def test_non_list_response_returns_friendly_error(self):
        # 限流/异常时 GitHub 可能返回 {"message": ...} 而非 release 列表：
        # 应返回友好错误而非 'str' object has no attribute 'get'
        with mock.patch("urllib.request.urlopen", return_value=_FakeResp(
                {"message": "API rate limit exceeded"})):
            result = uc.check_update(timeout=3)
        self.assertFalse(result["ok"])
        self.assertIn("非列表", result.get("error", ""))


if __name__ == "__main__":
    unittest.main()