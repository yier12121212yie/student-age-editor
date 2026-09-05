# -*- coding: utf-8 -*-
"""realtime_sync 修复回归：

- 同秒等长改动检出：mtime 为秒级时尺寸不变、同秒编辑的内容改动
  须由 sha1 歧义比对检出（曾要等下一次无关变更才被捎带同步）
- rt_stop→rt_start 竞态：旧线程排空期间 start 不得早退假装已启动
  （曾致 watcher 静默死亡：配置 enabled、实际同步停摆）

运行方式（在 backend 目录下）：
    python -m pytest editor/server/test_realtime_sync.py -q
"""
import os
import tempfile
import threading
import time
import unittest
from unittest import mock

from editor.server import cloud_sync as cs
from editor.server import realtime_sync as rs


class AmbigContentChangedTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        cfgs = os.path.join(self._tmp.name, "mod", "Cfgs")
        os.makedirs(cfgs)
        self.path = os.path.join(cfgs, "TalkCfg.json")
        self.mod_root = os.path.dirname(cfgs)
        with rs._RT_AMBIG_SHA_LOCK:
            rs._RT_AMBIG_SHA.clear()
        self.addCleanup(lambda: rs._RT_AMBIG_SHA.clear())

    def _patch_mod_dir(self):
        return mock.patch.object(cs, "_get_mod_dir", return_value=self.mod_root)

    def test_same_second_equal_size_edit_detected(self):
        with open(self.path, "w", encoding="utf-8") as f:
            f.write("ABCDEFGHIJ")
        # 同一秒：第一次见 → 记基线按未变处理（与旧行为一致）
        with self._patch_mod_dir():
            self.assertFalse(rs._ambig_content_changed("m1", "Cfgs/TalkCfg.json"))
        with open(self.path, "w", encoding="utf-8") as f:
            f.write("abcdefghij")  # 等长替换
        with self._patch_mod_dir():
            self.assertTrue(rs._ambig_content_changed("m1", "Cfgs/TalkCfg.json"))
        # 内容再变回去 → 又能检出
        with open(self.path, "w", encoding="utf-8") as f:
            f.write("ABCDEFGHIJ")
        with self._patch_mod_dir():
            self.assertTrue(rs._ambig_content_changed("m1", "Cfgs/TalkCfg.json"))

    def test_detect_changes_reports_modified_on_ambig_change(self):
        with open(self.path, "w", encoding="utf-8") as f:
            f.write("ABCDEFGHIJ")
        prev = {"Cfgs/TalkCfg.json": (10, 1000)}
        cur = {"Cfgs/TalkCfg.json": (10, 1000)}
        with self._patch_mod_dir():
            self.assertEqual(rs._detect_changes(prev, cur, "m1")["changed"], set())
            with open(self.path, "w", encoding="utf-8") as f:
                f.write("xyzabcdxyz")  # 等长
            self.assertEqual(rs._detect_changes(prev, cur, "m1")["changed"],
                             {"Cfgs/TalkCfg.json"})


class RtStartStopRaceTest(unittest.TestCase):
    def setUp(self):
        with rs._rt_state_lock:
            rs._rt_state.update({"running": False, "enabled": False, "error": ""})
        rs._rt_stop.clear()
        rs._rt_thread = None
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        rs._rt_stop.set()
        t = rs._rt_thread
        if t and t.is_alive():
            t.join(timeout=2.0)
        rs._rt_thread = None
        with rs._rt_state_lock:
            rs._rt_state.update({"running": False, "enabled": False})

    def _patch_env(self):
        def stub_loop():
            while not rs._rt_stop.wait(0.05):
                pass
            with rs._rt_state_lock:
                rs._rt_state["running"] = False
        return mock.patch.multiple(
            "editor.server.realtime_sync",
            rt_get_config=lambda: {"provider_id": "p1"},
            _resolve_watch_mods=lambda cfg: ["m1"],
            rt_update_config=lambda cfg: None,
            _watcher_loop=stub_loop,
            rt_get_status=lambda: dict(rs._rt_state))

    def test_start_waits_for_draining_old_thread(self):
        # 旧线程卡在一次网络同步上（rt_stop join 超时的现场）：running=True、
        # stop 已置位、线程仍活着。旧实现此处早退 → 旧线程退出后同步停摆。
        started = threading.Event()

        def stuck_old():
            time.sleep(0.4)
            with rs._rt_state_lock:
                rs._rt_state["running"] = False
            started.set()

        with rs._rt_state_lock:
            rs._rt_state["running"] = True
        rs._rt_stop.set()
        old = threading.Thread(target=stuck_old, daemon=True)
        old.start()
        rs._rt_thread = old

        with self._patch_env():
            status = rs.rt_start()
        self.assertTrue(started.wait(2.0), "旧线程应已退出")
        new = rs._rt_thread
        self.assertIsNot(new, old)
        self.assertTrue(new.is_alive(), "新 watcher 线程必须已在运行")
        self.assertTrue(status.get("running"))

    def test_start_is_noop_when_already_running(self):
        def healthy_loop():
            while not rs._rt_stop.wait(0.05):
                pass
            with rs._rt_state_lock:
                rs._rt_state["running"] = False

        with rs._rt_state_lock:
            rs._rt_state["running"] = True
        rs._rt_stop.clear()
        t = threading.Thread(target=healthy_loop, daemon=True)
        t.start()
        rs._rt_thread = t
        with self._patch_env():
            rs.rt_start()
        self.assertIs(rs._rt_thread, t, "正常运行时不得重启线程")


if __name__ == "__main__":
    unittest.main()
