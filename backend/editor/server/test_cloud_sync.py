# -*- coding: utf-8 -*-
"""cloud_sync 安全与正确性测试：

- _safe_rel_join：远端 rel 含 ``..``/盘符/绝对路径时拒绝（路径穿越防护）
- OpenListDriver.stat：解析 /api/fs/get 的 modified 字段（曾恒返回 mtime=0，
  使"远端较新则跳过上传"守卫失效，双向同步退化为本地单向覆盖）

运行方式（在 backend 目录下）：
    python -m pytest editor/server/test_cloud_sync.py -q
"""
import os
import tempfile
import unittest
from unittest import mock

from editor.server import cloud_sync as cs


class SafeRelJoinTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.mod_dir = os.path.join(self._tmp.name, "mod")

    def test_normal_rel_resolves_under_mod_dir(self):
        full = cs._safe_rel_join(self.mod_dir, "Cfgs/zh-cn/TalkCfg.json")
        self.assertTrue(full.startswith(os.path.abspath(self.mod_dir) + os.sep))
        self.assertEqual(os.path.normpath(full),
                         os.path.normpath(os.path.join(self.mod_dir, "Cfgs", "zh-cn", "TalkCfg.json")))

    def test_parent_traversal_rejected(self):
        for rel in ("../evil.json", "../../evil.json", "a/../../evil.json",
                    "..\\evil.json", "Cfgs/../../outside.json"):
            self.assertIsNone(cs._safe_rel_join(self.mod_dir, rel), rel)

    def test_drive_letter_rejected(self):
        self.assertIsNone(cs._safe_rel_join(self.mod_dir, "C:/Windows/evil.json"))

    def test_rooted_path_contained(self):
        # "/etc/passwd" 经 strip 后应被收纳进 mod_dir 内（不逃逸即可，无需拒绝）
        full = cs._safe_rel_join(self.mod_dir, "/Cfgs/a.json")
        self.assertIsNotNone(full)
        self.assertTrue(full.startswith(os.path.abspath(self.mod_dir) + os.sep))

    def test_dot_and_empty_segments_normalized(self):
        full = cs._safe_rel_join(self.mod_dir, "./Cfgs//zh-cn/./TalkCfg.json")
        self.assertIsNotNone(full)
        self.assertEqual(os.path.normpath(full),
                         os.path.normpath(os.path.join(self.mod_dir, "Cfgs", "zh-cn", "TalkCfg.json")))


class OpenListStatTest(unittest.TestCase):
    def _driver(self):
        d = cs.OpenListDriver({"url": "http://127.0.0.1:5244"})
        return d

    def test_stat_parses_modified_iso_string(self):
        d = self._driver()
        with mock.patch.object(d, "_api", return_value={
            "name": "TalkCfg.json", "is_dir": False, "size": 123,
            "modified": "2026-09-01T08:30:00Z",
        }):
            obj = d.stat("mods/demo/Cfgs/TalkCfg.json")
        self.assertIsNotNone(obj)
        self.assertEqual(obj.size, 123)
        # 2026-09-01T08:30:00Z 的 epoch 秒；非 0 即修复（曾恒 0）
        self.assertEqual(obj.mtime, 1788251400)

    def test_stat_parses_numeric_modified(self):
        d = self._driver()
        with mock.patch.object(d, "_api", return_value={
            "name": "a.json", "is_dir": False, "size": 1, "modified": 1788328200,
        }):
            obj = d.stat("mods/demo/a.json")
        self.assertEqual(obj.mtime, 1788328200)

    def test_stat_bad_modified_falls_back_to_zero(self):
        d = self._driver()
        with mock.patch.object(d, "_api", return_value={
            "name": "a.json", "is_dir": False, "size": 1, "modified": "not-a-date",
        }):
            obj = d.stat("mods/demo/a.json")
        self.assertEqual(obj.mtime, 0)


if __name__ == "__main__":
    unittest.main()
