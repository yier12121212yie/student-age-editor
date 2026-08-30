# -*- coding: utf-8 -*-
"""cfg_store 单测：统一写入口的原子写、冲突检测（expect_mtime_ns / force）、
历史快照生成、撤销/重做往返与栈上限裁剪、list_history 排序。

运行方式（在 backend 目录下）：
    python -m pytest editor/server/test_cfg_store.py -q
    python -m unittest editor.server.test_cfg_store -v
"""
import json
import os
import tempfile
import unittest

from editor.server import cfg_store as s


class CfgStoreTestBase(unittest.TestCase):
    """每个用例一个临时 Mod 目录：<mod>/Cfgs/zh-cn/<name>.json 布局。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.mod_root = os.path.join(self._tmp.name, "mod")
        self.cfg_dir = os.path.join(self.mod_root, "Cfgs", "zh-cn")
        os.makedirs(self.cfg_dir)
        self.path = os.path.join(self.cfg_dir, "EvtCfg.json")
        self.history_dir = os.path.join(self.mod_root, s.HISTORY_DIR)

    def _write_direct(self, data, path=None):
        """绕过 cfg_store 直接落盘（模拟外部工具/游戏写入）。"""
        path = path or self.path
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def _read_direct(self, path=None):
        path = path or self.path
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)

    def _mtime(self, path=None):
        return os.stat(path or self.path).st_mtime_ns


class WriteSnapshotTest(CfgStoreTestBase):
    def test_overwrite_creates_snapshot_with_old_content(self):
        self._write_direct({"1": {"id": 1, "name": "old"}})
        old_mtime = self._mtime()
        # Windows 文件时间戳以系统时钟刻度（约 15.6ms）为粒度，连续两次写入
        # 可能落在同一刻度内得到相同 mtime_ns；等待一个刻度再写保证时间推进。
        import time
        time.sleep(0.02)
        r = s.write_cfg(self.path, {"1": {"id": 1, "name": "new"}})
        self.assertTrue(r["ok"])
        self.assertIsNotNone(r["snapshot"])
        self.assertEqual(r["mtime_ns"], self._mtime())
        self.assertNotEqual(r["mtime_ns"], old_mtime)
        snaps = os.listdir(self.history_dir)
        self.assertEqual(len(snaps), 1)
        with open(os.path.join(self.history_dir, snaps[0]), "r",
                  encoding="utf-8-sig") as f:
            self.assertEqual(json.load(f), {"1": {"id": 1, "name": "old"}})
        # 快照文件名前缀为表名
        self.assertTrue(snaps[0].startswith("EvtCfg_"))

    def test_create_file_has_no_snapshot(self):
        r = s.write_cfg(self.path, {"1": {"id": 1}})
        self.assertTrue(r["ok"])
        self.assertIsNone(r["snapshot"])
        self.assertFalse(os.path.isdir(self.history_dir))
        self.assertEqual(self._read_direct(), {"1": {"id": 1}})

    def test_snapshot_false_skips_history(self):
        self._write_direct({"1": {"id": 1}})
        r = s.write_cfg(self.path, {"2": {"id": 2}}, snapshot=False)
        self.assertTrue(r["ok"])
        self.assertIsNone(r["snapshot"])
        self.assertFalse(os.path.isdir(self.history_dir))

    def test_flat_layout_mod_root(self):
        # <mod>/Cfgs/<name>.json 布局：快照同样落在 <mod>/.editor_history
        flat_dir = os.path.join(self.mod_root, "Cfgs")
        flat_path = os.path.join(flat_dir, "ItemCfg.json")
        self._write_direct({"1": {"id": 1}}, path=flat_path)
        r = s.write_cfg(flat_path, {"1": {"id": 1, "name": "x"}})
        self.assertTrue(r["ok"])
        self.assertTrue(os.path.isdir(self.history_dir))


class ConflictDetectionTest(CfgStoreTestBase):
    def test_conflict_rejected_when_mtime_differs(self):
        self._write_direct({"1": {"id": 1, "name": "disk"}})
        stale = self._mtime()
        self._write_direct({"1": {"id": 1, "name": "changed-externally"}})
        # 同一文件系统时间戳粒度内连续写盘 mtime 可能不变，强制错开
        forced = stale + 10 ** 9
        os.utime(self.path, ns=(forced, forced))
        r = s.write_cfg(self.path, {"1": {"id": 1, "name": "local"}},
                        expect_mtime_ns=stale)
        self.assertFalse(r["ok"])
        self.assertTrue(r["conflict"])
        self.assertEqual(r["mtime_ns"], self._mtime())
        # 返回磁盘当前内容
        self.assertEqual(r["data"], {"1": {"id": 1, "name": "changed-externally"}})
        # 磁盘未被覆盖
        self.assertEqual(self._read_direct(),
                         {"1": {"id": 1, "name": "changed-externally"}})

    def test_matching_mtime_passes(self):
        self._write_direct({"1": {"id": 1}})
        r = s.write_cfg(self.path, {"1": {"id": 1, "name": "ok"}},
                        expect_mtime_ns=self._mtime())
        self.assertTrue(r["ok"])
        self.assertEqual(self._read_direct(), {"1": {"id": 1, "name": "ok"}})

    def test_expect_none_skips_check(self):
        self._write_direct({"1": {"id": 1}})
        r = s.write_cfg(self.path, {"1": {"id": 1, "name": "no-check"}})
        self.assertTrue(r["ok"])

    def test_force_overrides_conflict(self):
        self._write_direct({"1": {"id": 1, "name": "disk"}})
        stale = self._mtime()
        self._write_direct({"1": {"id": 1, "name": "changed-externally"}})
        forced = stale + 10 ** 9
        os.utime(self.path, ns=(forced, forced))
        r = s.write_cfg(self.path, {"1": {"id": 1, "name": "local"}},
                        expect_mtime_ns=stale, force=True)
        self.assertTrue(r["ok"])
        self.assertEqual(self._read_direct(), {"1": {"id": 1, "name": "local"}})

    def test_expect_mtime_on_missing_file_writes(self):
        # 目标不存在（expect 与 exists 条件不满足）→ 直接创建
        r = s.write_cfg(self.path, {"1": {"id": 1}}, expect_mtime_ns=12345)
        self.assertTrue(r["ok"])
        self.assertEqual(self._read_direct(), {"1": {"id": 1}})


class UndoRedoTest(CfgStoreTestBase):
    def test_undo_redo_round_trip(self):
        self._write_direct({"1": {"id": 1, "name": "v1"}})
        s.write_cfg(self.path, {"1": {"id": 1, "name": "v2"}})
        s.write_cfg(self.path, {"1": {"id": 1, "name": "v3"}})
        r = s.undo(self.path)
        self.assertTrue(r["ok"])
        self.assertEqual(r["data"], {"1": {"id": 1, "name": "v2"}})
        self.assertEqual(self._read_direct(), {"1": {"id": 1, "name": "v2"}})
        r = s.undo(self.path)
        self.assertEqual(self._read_direct(), {"1": {"id": 1, "name": "v1"}})
        r = s.undo(self.path)
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"], "nothing to undo")
        # redo 回到 v3
        r = s.redo(self.path)
        self.assertTrue(r["ok"])
        self.assertEqual(r["data"], {"1": {"id": 1, "name": "v2"}})
        r = s.redo(self.path)
        self.assertEqual(self._read_direct(), {"1": {"id": 1, "name": "v3"}})
        r = s.redo(self.path)
        self.assertFalse(r["ok"])

    def test_new_write_clears_redo(self):
        self._write_direct({"1": {"id": 1, "name": "v1"}})
        s.write_cfg(self.path, {"1": {"id": 1, "name": "v2"}})
        s.undo(self.path)
        s.write_cfg(self.path, {"1": {"id": 1, "name": "v3"}})
        r = s.redo(self.path)
        self.assertFalse(r["ok"])
        self.assertEqual(self._read_direct(), {"1": {"id": 1, "name": "v3"}})

    def test_undo_of_create_removes_file(self):
        # 文件原本不存在：undo 创建型写入应回到「不存在」
        s.write_cfg(self.path, {"1": {"id": 1}})
        r = s.undo(self.path)
        self.assertTrue(r["ok"])
        self.assertFalse(os.path.isfile(self.path))
        self.assertIsNone(r["data"])
        # redo 恢复创建
        r = s.redo(self.path)
        self.assertTrue(r["ok"])
        self.assertEqual(self._read_direct(), {"1": {"id": 1}})

    def test_undo_stack_limit_prunes_oldest(self):
        self._write_direct({"0": {"id": 0}})
        for i in range(1, s.HISTORY_LIMIT + 6):  # 写 55 次
            s.write_cfg(self.path, {"i": i})
        # undo 上限 50：第 51 次 undo 应失败（最早的写入已丢弃）
        for _ in range(s.HISTORY_LIMIT):
            r = s.undo(self.path)
            self.assertTrue(r["ok"])
        r = s.undo(self.path)
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"], "nothing to undo")


class ListHistoryTest(CfgStoreTestBase):
    def test_list_history_newest_first_and_filtered_by_cfg(self):
        self._write_direct({"1": {"id": 1}})
        for i in range(3):
            s.write_cfg(self.path, {"i": i})
        # 其他表的快照不应混入
        other = os.path.join(self.cfg_dir, "TalkCfg.json")
        self._write_direct({"1": {"id": 1}}, path=other)
        s.write_cfg(other, {"i": 1})
        entries = s.list_history(self.path)
        self.assertEqual(len(entries), 3)
        self.assertTrue(all(e["file"].startswith("EvtCfg_") for e in entries))
        # 新 → 旧（ts 降序）
        ts_list = [e["ts"] for e in entries]
        self.assertEqual(ts_list, sorted(ts_list, reverse=True))
        for e in entries:
            self.assertIn("size", e)
            self.assertGreater(e["size"], 0)

    def test_list_history_empty_when_no_dir(self):
        self.assertEqual(s.list_history(self.path), [])


if __name__ == "__main__":
    unittest.main()
