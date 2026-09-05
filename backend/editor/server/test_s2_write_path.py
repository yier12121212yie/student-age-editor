# -*- coding: utf-8 -*-
"""S2 写路径准出测试（still-stone-stickleback.md S2 准出清单）：

- 内容未变重存 → 不快照不写盘（cfg.snapshot_bytes 增量为 0、list_history 为空）
- 变 12 次 → 磁盘恰好保留 HISTORY_KEEP=10 份且删的是最旧，不越界修剪其他表
- 三次带快照的大表写入后 debug_stack_bytes() == 0（A8）；snapshot=False 反向配对 > 0
- undo() 后文件字节与最初全等（含 BOM 表）
- monkeypatch _restore 抛 PermissionError → undo 返回 ok=False 且栈长度不变（B3）
- test_save_preserves_bom_and_lf（B4/B5）
- expect_digest 冲突检测（B6：mtime 同刻度漏检补口）
- apply_patch：set/remove 应用、if_match 逐行深比对、行级冲突不回全表、
  表级冲突回磁盘 data、走 S1 解析缓存提供者、补丁值深拷贝
- read_lossy：GBK → lossy、UTF-8 → 干净、缺失文件三 None

运行方式（在 backend 目录下）：
    python -m pytest editor/server/test_s2_write_path.py -q
"""
import hashlib
import json
import os
import tempfile
import unittest
from unittest import mock

from editor.server import cfg_store as s
from editor.server import perf


class S2TestBase(unittest.TestCase):
    """每个用例一个临时 Mod 目录：<mod>/Cfgs/zh-cn/<name>.json 布局。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.mod_root = os.path.join(self._tmp.name, "mod")
        self.cfg_dir = os.path.join(self.mod_root, "Cfgs", "zh-cn")
        os.makedirs(self.cfg_dir)
        self.path = os.path.join(self.cfg_dir, "EvtCfg.json")
        self.history_dir = os.path.join(self.mod_root, s.HISTORY_DIR)
        s.debug_reset_stacks()
        self.addCleanup(s.debug_reset_stacks)
        # 计数器读数按增量断言，起始先清零防串扰
        perf.COUNTERS.reset()
        self.addCleanup(perf.COUNTERS.reset)
        # 清理解析缓存提供者，用例各自注册
        s.set_parse_provider(None)

    def _write_direct(self, data, path=None):
        # newline=""：禁用 Windows 文本模式 \n → CRLF 翻译（B4 修的正是这个坑）
        path = path or self.path
        with open(path, "w", encoding="utf-8", newline="") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def _read_direct(self, path=None):
        path = path or self.path
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)

    def _stack_len(self, path=None):
        entry = s._STACKS.get(s._path_key(path or self.path))
        return (len(entry["undo"]), len(entry["redo"])) if entry else (0, 0)

    def _big_payload(self, rows=400):
        # ~200KB 量级：足以让「栈存整表文本」在 debug_stack_bytes 上显著非零
        return {str(i): {"id": i, "content": "对白" + "x" * 200}
                for i in range(rows)}


class UnchangedWriteTest(S2TestBase):
    def test_unchanged_content_no_snapshot_no_write(self):
        self._write_direct({"1": {"id": 1, "name": "same"}})
        before_bytes = perf.COUNTERS.get("cfg.snapshot_bytes")
        before_mtime = os.stat(self.path).st_mtime_ns
        r = s.write_cfg(self.path, {"1": {"id": 1, "name": "same"}})
        self.assertTrue(r["ok"], r)
        self.assertTrue(r["unchanged"])
        self.assertIsNone(r["snapshot"])
        self.assertEqual(perf.COUNTERS.get("cfg.snapshot_bytes"), before_bytes)
        self.assertEqual(perf.COUNTERS.get("cfg.snapshots_written"), 0)
        self.assertEqual(perf.COUNTERS.get("cfg.writes"), 0)
        self.assertFalse(os.path.isdir(self.history_dir))
        # mtime 未被触碰（没有真实写盘）
        self.assertEqual(os.stat(self.path).st_mtime_ns, before_mtime)

    def test_unchanged_write_does_not_disturb_undo_stack(self):
        self._write_direct({"1": {"id": 1}})
        s.write_cfg(self.path, {"1": {"id": 1}})  # unchanged
        s.write_cfg(self.path, {"2": {"id": 2}})  # changed
        self.assertEqual(self._stack_len(), (1, 0))  # 只登记真实变更那一次


class HistoryPruneTest(S2TestBase):
    def test_prune_keeps_newest_10_and_spares_other_tables(self):
        self._write_direct({"v": 0})
        r1 = s.write_cfg(self.path, {"v": 1})
        first_snap = r1["snapshot"]
        self.assertIsNotNone(first_snap)
        for i in range(2, 13):  # 变 12 次
            s.write_cfg(self.path, {"v": i})
        entries = s.list_history(self.path)
        self.assertEqual(len(entries), s.HISTORY_KEEP)
        names = {e["file"] for e in entries}
        self.assertNotIn(first_snap, names)  # 删的是最旧
        # 并排：另一张表的快照不被越界修剪
        other = os.path.join(self.cfg_dir, "TalkCfg.json")
        self._write_direct({"1": {"id": 1}}, path=other)
        ro = s.write_cfg(other, {"2": {"id": 2}})
        self.assertEqual(len(s.list_history(other)), 1)
        self.assertEqual(len(s.list_history(self.path)), s.HISTORY_KEEP)


class UndoStackBytesTest(S2TestBase):
    def test_snapshot_writes_leave_zero_stack_bytes(self):
        payload = self._big_payload()
        self._write_direct(dict(payload))  # 预建文件：后续三次均为「覆盖 + 快照」
        for i in range(3):
            payload2 = dict(payload)
            payload2[str(i)] = {"id": i, "marker": i}
            r = s.write_cfg(self.path, payload2)
            self.assertTrue(r["ok"])
            self.assertIsNotNone(r["snapshot"])
        self.assertEqual(s.debug_stack_bytes(), 0)

    def test_no_snapshot_writes_fall_back_to_text(self):
        self._write_direct(self._big_payload())
        for i in range(3):
            r = s.write_cfg(self.path, {"i": i}, snapshot=False)
            self.assertTrue(r["ok"])
            self.assertIsNone(r["snapshot"])
        self.assertGreater(s.debug_stack_bytes(), 0)
        s.debug_reset_stacks()
        self.assertEqual(s.debug_stack_bytes(), 0)


class ByteEquivalenceTest(S2TestBase):
    def test_undo_restores_original_bytes_exactly(self):
        original = b'\xef\xbb\xbf{\n  "1": {\n    "id": 1,\n    "name": "\xe6\x97\xa7"\n  }\n}'
        with open(self.path, "wb") as f:
            f.write(original)
        r = s.write_cfg(self.path, {"1": {"id": 1, "name": "新"}})
        self.assertTrue(r["ok"])
        self.assertTrue(s.undo(self.path)["ok"])
        with open(self.path, "rb") as f:
            self.assertEqual(f.read(), original)

    def test_save_preserves_bom_and_lf(self):
        with open(self.path, "wb") as f:
            f.write('﻿{"1": {"id": 1}}\n'.encode("utf-8"))
        r = s.write_cfg(self.path, {"1": {"id": 1, "name": "新"}, "2": {"id": 2}})
        self.assertTrue(r["ok"])
        with open(self.path, "rb") as f:
            raw = f.read()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"))  # B5：源 BOM 原样保留
        self.assertNotIn(b"\r\n", raw)                    # B4：不引入 CRLF


class UndoRestoreFailureTest(S2TestBase):
    def test_undo_restore_failure_keeps_stack_intact(self):
        self._write_direct({"1": {"name": "v1"}})
        s.write_cfg(self.path, {"1": {"name": "v2"}})
        s.write_cfg(self.path, {"1": {"name": "v3"}})
        before = self._stack_len()
        self.assertEqual(before, (2, 0))
        with mock.patch.object(s, "_restore",
                               side_effect=PermissionError("[WinError 5]")):
            r = s.undo(self.path)
        self.assertFalse(r["ok"])
        self.assertIn("撤销失败", r["error"])
        self.assertEqual(self._stack_len(), before)  # B3：栈未消费
        # 解除故障后 undo 正常恢复
        r = s.undo(self.path)
        self.assertTrue(r["ok"], r)
        self.assertEqual(self._read_direct(), {"1": {"name": "v2"}})


class DigestConflictTest(S2TestBase):
    """B6：Windows mtime 粒度 ~15.6ms，同刻度外部改动 mtime 比较漏过 → sha1 摘要补口。"""

    def test_digest_conflict_detected_within_same_mtime_tick(self):
        self._write_direct({"1": {"name": "v1"}})
        with open(self.path, "rb") as f:
            stale_digest = hashlib.sha1(f.read()).hexdigest()
        stale_mtime = os.stat(self.path).st_mtime_ns
        self._write_direct({"1": {"name": "changed-externally"}})
        os.utime(self.path, ns=(stale_mtime, stale_mtime))  # 抹掉 mtime 证据
        r = s.write_cfg(self.path, {"1": {"name": "local"}},
                        expect_mtime_ns=stale_mtime, expect_digest=stale_digest)
        self.assertFalse(r["ok"])
        self.assertTrue(r["conflict"])
        self.assertEqual(r["reason"], "digest")
        self.assertEqual(self._read_direct(), {"1": {"name": "changed-externally"}})

    def test_matching_digest_passes(self):
        self._write_direct({"1": {"name": "v1"}})
        with open(self.path, "rb") as f:
            digest = hashlib.sha1(f.read()).hexdigest()
        r = s.write_cfg(self.path, {"1": {"name": "local"}}, expect_digest=digest)
        self.assertTrue(r["ok"], r)
        self.assertEqual(self._read_direct(), {"1": {"name": "local"}})


class ApplyPatchTest(S2TestBase):
    def setUp(self):
        super().setUp()
        self._write_direct({"1000": {"id": 1000, "content": "旧"},
                            "1001": {"id": 1001, "content": "待删"}})

    def test_set_and_remove_applied(self):
        r = s.apply_patch(self.path, set={"1000": {"id": 1000, "content": "新"}},
                          remove=["1001"])
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["applied"], {"set": 1, "remove": 1})
        self.assertEqual(self._read_direct(),
                         {"1000": {"id": 1000, "content": "新"}})
        self.assertEqual(len(s.list_history(self.path)), 1)

    def test_if_match_conflict_reports_keys_without_data(self):
        r = s.apply_patch(self.path, set={"1000": {"id": 1000, "content": "改"}},
                          if_match={"1000": {"id": 1000, "content": "过期基线"}})
        self.assertFalse(r["ok"])
        self.assertTrue(r["conflict"])
        self.assertEqual(r["reason"], "rows")
        self.assertEqual(r["conflicting_keys"], ["1000"])
        self.assertNotIn("data", r)  # 行级冲突不回全表
        self.assertEqual(self._read_direct()["1000"]["content"], "旧")

    def test_if_match_deep_compare_passes(self):
        r = s.apply_patch(self.path, set={"1000": {"id": 1000, "content": "新"}},
                          if_match={"1000": {"id": 1000, "content": "旧"},
                                    "1001": {"id": 1001, "content": "待删"}})
        self.assertTrue(r["ok"], r)
        self.assertEqual(self._read_direct()["1000"]["content"], "新")

    def test_mtime_conflict_returns_disk_data(self):
        stale = os.stat(self.path).st_mtime_ns
        self._write_direct({"1": {"name": "external"}})
        forced = stale + 10 ** 9  # 抹平同刻度：保证 mtime 确实不同
        os.utime(self.path, ns=(forced, forced))
        r = s.apply_patch(self.path, set={"2": {"id": 2}},
                          expect_mtime_ns=stale)
        self.assertFalse(r["ok"])
        self.assertTrue(r["conflict"])
        self.assertIn("data", r)  # 表级冲突回磁盘内容供 409 三选 UI
        self.assertEqual(r["data"], {"1": {"name": "external"}})

    def test_patch_value_deep_copied(self):
        value = {"id": 1002, "tags": ["a"]}
        r = s.apply_patch(self.path, set={"1002": value})
        self.assertTrue(r["ok"])
        value["tags"].append("b")  # 调用方事后改引用不得影响已写盘/返回内容
        self.assertEqual(r["data"]["1002"]["tags"], ["a"])
        self.assertEqual(self._read_direct()["1002"]["tags"], ["a"])

    def test_uses_parse_cache_provider(self):
        # 磁盘文件删掉也能补丁成功：证明当前数据来自 S1 解析缓存提供者而非读盘
        cached = {"1000": {"id": 1000, "content": "缓存态"}}
        s.set_parse_provider(lambda p: (cached, False, 12345) if p == self.path else None)
        os.unlink(self.path)
        r = s.apply_patch(self.path, set={"1001": {"id": 1001}})
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["data"]["1000"], cached["1000"])
        self.assertEqual(r["data"]["1001"], {"id": 1001})
        self.assertEqual(self._read_direct()["1000"], cached["1000"])


class PatchCacheHitCommitSemanticsTest(S2TestBase):
    """缓存命中只免除解析，不免除读盘：_commit 的 raw 必须来自磁盘字节。

    回归背景：曾把缓存命中时的 raw 留成 None（_commit 的「文件不存在」哨兵），
    导致大表（≥256KB 进 _TABLE_CACHE）表级乐观锁静默失效、undo 按
    existed=False 登记并在撤销时 os.unlink 删掉整张表。
    """

    def _register_cache(self, cached):
        s.set_parse_provider(
            lambda p: (cached, False, 12345) if p == self.path else None)

    def test_cache_hit_still_detects_mtime_conflict(self):
        self._write_direct({"1": {"name": "external"}})
        stale = os.stat(self.path).st_mtime_ns
        self._register_cache({"1": {"name": "缓存态"}})
        # 外部（云同步/另一设备）在缓存注册后改写文件，并抹平同刻度
        forced = stale + 10 ** 9
        self._write_direct({"2": {"name": "外部改动"}})
        os.utime(self.path, ns=(forced, forced))
        r = s.apply_patch(self.path, set={"3": {"id": 3}}, expect_mtime_ns=stale)
        self.assertFalse(r["ok"])
        self.assertTrue(r["conflict"])
        self.assertEqual(r["reason"], "mtime")
        self.assertEqual(r["data"], {"2": {"name": "外部改动"}})

    def test_cache_hit_patch_then_undo_restores_previous_content(self):
        self._write_direct({"1000": {"id": 1000, "content": "旧"}})
        self._register_cache({"1000": {"id": 1000, "content": "旧"}})
        r = s.apply_patch(self.path, set={"1001": {"id": 1001}})
        self.assertTrue(r["ok"], r)
        u = s.undo(self.path)
        self.assertTrue(u["ok"], u)
        # 曾因 existed=False 被判「创建型写入」而整个 unlink
        self.assertEqual(self._read_direct(),
                         {"1000": {"id": 1000, "content": "旧"}})


class UndoTextFallbackTest(S2TestBase):
    """快照缺失时 undo/redo 走内存文本兜底：BOM 必须按原样补回，
    lossy 源必须安全失败（不能把 U+FFFD 占位符永久写盘）。"""

    def _write_bom_direct(self, data, path=None):
        path = path or self.path
        with open(path, "wb") as f:
            f.write(b"\xef\xbb\xbf" +
                    json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8"))

    def test_undo_text_fallback_restores_bom(self):
        self._write_bom_direct({"1": {"name": "旧"}})
        r = s.write_cfg(self.path, {"1": {"name": "新"}}, snapshot=False)
        self.assertTrue(r["ok"])
        self.assertIsNone(r["snapshot"])
        u = s.undo(self.path)
        self.assertTrue(u["ok"], u)
        with open(self.path, "rb") as f:
            raw = f.read()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"))
        self.assertEqual(json.loads(raw.decode("utf-8-sig")), {"1": {"name": "旧"}})

    def test_redo_text_fallback_restores_bom(self):
        self._write_bom_direct({"1": {"name": "旧"}})
        s.write_cfg(self.path, {"1": {"name": "新"}}, snapshot=False)
        self.assertTrue(s.undo(self.path)["ok"])
        rd = s.redo(self.path)
        self.assertTrue(rd["ok"], rd)
        with open(self.path, "rb") as f:
            self.assertTrue(f.read().startswith(b"\xef\xbb\xbf"))

    def test_undo_lossy_without_snapshot_safely_fails(self):
        with open(self.path, "wb") as f:
            f.write('{"1": {"name": "旧"}}'.encode("gbk"))
        r = s.write_cfg(self.path, {"1": {"name": "新"}}, snapshot=False)
        self.assertTrue(r["ok"])
        u = s.undo(self.path)
        self.assertFalse(u["ok"])
        self.assertIn("有损", u.get("error", ""))
        # 文件保持新写入内容，绝没有把 U+FFFD 占位符写回盘
        with open(self.path, "r", encoding="utf-8") as f:
            self.assertEqual(json.load(f), {"1": {"name": "新"}})


class ReadLossyTest(S2TestBase):
    def test_gbk_source_flagged_lossy(self):
        with open(self.path, "wb") as f:
            f.write('{"1": {"name": "旧"}}'.encode("gbk"))
        raw, text, lossy = s.read_lossy(self.path)
        self.assertTrue(lossy)
        self.assertIn("\ufffd", text)
        with open(self.path, "rb") as f:
            self.assertEqual(raw, f.read())

    def test_utf8_source_clean_and_missing_is_triple_none(self):
        self._write_direct({"1": {"name": "旧"}})
        _raw, text, lossy = s.read_lossy(self.path)
        self.assertFalse(lossy)
        self.assertEqual(json.loads(text), {"1": {"name": "旧"}})
        self.assertEqual(s.read_lossy(os.path.join(self.cfg_dir, "缺.json")),
                         (None, None, False))


if __name__ == "__main__":
    unittest.main()
