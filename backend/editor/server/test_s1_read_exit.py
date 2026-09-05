# -*- coding: utf-8 -*-
"""S1 读路径准出测试（still-stone-stickleback.md S1 准出清单）：

- 热 GET（缓存命中）cfg.parses == 0、cfg.dumps == 0、cfg.read_bytes == 0
- 缓存命中响应字节 == 现场解析后序列化（legacy 逐字复刻）——专杀
  indent/ensure_ascii 两套参数用错
- 失效语义用 os.utime 强制推进 mtime（Windows 15.6ms 粒度，不靠 sleep）
- 一次写后只重解析写入那张表（A 重建、B 零解析）；写路径顺手播种缓存
  （_seed_table_cache）后写后首次 GET 也零解析

夹具用字符串 join 造（~480KB，越过 256KB 缓存门槛），不用 json.dumps。

运行方式（在 backend 目录下）：
    python -m pytest editor/server/test_s1_read_exit.py -q
"""
import json
import os
import tempfile
import unittest

from editor.server import cfg_store
from editor.server.api import build_router, STATE, _invalidate_table_cache
from editor.server.perf import COUNTERS


def _big_table(n=1200, marker="x"):
    """~480KB 合成表：1200 行 × ~400B，越过 _TABLE_CACHE_MIN_BODY=256KB。"""
    rows = ",".join(
        '"%d": {"id": %d, "content": "%s%d%s"}' % (i, i, marker * 190, i, marker * 190)
        for i in range(n))
    return "{" + rows + "}"


def _legacy_cfg_read(path, cfg_name):
    """今天 cfg_read 免缓存路径的逐字复刻（倍数参照 + 行为等价硬证据）。"""
    with open(path, "rb") as f:
        raw = f.read()
    try:
        content = raw.decode("utf-8-sig")
        lossy = False
    except UnicodeDecodeError:
        content = raw.decode("utf-8-sig", errors="replace")
        lossy = True
    data = json.loads(content.strip() or "{}")
    if not isinstance(data, dict):
        data = {}
    payload = {"cfg": cfg_name, "data": data, "exists": True,
               "mtime_ns": os.stat(path).st_mtime_ns}
    if lossy:
        payload["lossy"] = True
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


class S1ExitTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.mod_root = os.path.join(self._tmp.name, "mod")
        self.cfg_dir = os.path.join(self.mod_root, "Cfgs", "zh-cn")
        os.makedirs(self.cfg_dir)
        self._saved = (STATE.workspace_root, STATE.mod_root, STATE.mod_name)
        STATE.workspace_root = self._tmp.name
        STATE.mod_root = self.mod_root
        STATE.mod_name = "mod"
        self.router = build_router()
        self.addCleanup(cfg_store.debug_reset_stacks)
        # _TABLE_CACHE 是进程级单例：清掉其他用例残留，保证计数隔离；
        # 结束后同样清空，不给后续用例留跨 tmpdir 的陈旧键
        _invalidate_table_cache()
        self.addCleanup(_invalidate_table_cache)
        COUNTERS.reset()
        self.addCleanup(COUNTERS.reset)

    def tearDown(self):
        STATE.workspace_root, STATE.mod_root, STATE.mod_name = self._saved

    def _path(self, name):
        return os.path.join(self.cfg_dir, name + ".json")

    def _put_big(self, name, marker="x"):
        with open(self._path(name), "w", encoding="utf-8", newline="") as f:
            f.write(_big_table(marker=marker))

    def _get(self, name, query=None):
        return self.router.dispatch("GET", "/api/cfg/" + name, query or {}, None)

    def test_hot_get_counters_all_zero(self):
        self._put_big("TalkCfg")
        self._get("TalkCfg")  # warm
        before = {k: COUNTERS.get(k) for k in
                  ("cfg.parses", "cfg.dumps", "cfg.read_bytes", "cfg.reads")}
        status, payload = self._get("TalkCfg")
        self.assertEqual(status, 200)
        self.assertIsInstance(payload, bytes)  # 免序列化原始字节出口
        self.assertEqual(COUNTERS.get("cfg.parses") - before["cfg.parses"], 0)
        self.assertEqual(COUNTERS.get("cfg.dumps") - before["cfg.dumps"], 0)
        self.assertEqual(COUNTERS.get("cfg.read_bytes") - before["cfg.read_bytes"], 0)
        self.assertEqual(COUNTERS.get("cfg.reads") - before["cfg.reads"], 1)

    def test_cache_hit_bytes_equal_fresh_serialization(self):
        self._put_big("TalkCfg")
        _s, warm = self._get("TalkCfg")
        _s2, warm2 = self._get("TalkCfg")
        legacy = _legacy_cfg_read(self._path("TalkCfg"), "TalkCfg")
        # 字节级等价（json.dumps 同一套参数才可能做到）
        self.assertEqual(warm2, legacy)
        self.assertEqual(warm, warm2)
        # 行为等价硬证据
        self.assertEqual(json.loads(warm), json.loads(legacy))

    def test_invalidation_via_utime_not_sleep(self):
        self._put_big("TalkCfg")
        _s, first = self._get("TalkCfg")
        self._put_big("TalkCfg", marker="y")  # 外部改写（体积相同）
        st = os.stat(self._path("TalkCfg"))
        forced = (st.st_mtime_ns + 10 ** 9, st.st_mtime_ns + 10 ** 9)
        os.utime(self._path("TalkCfg"), ns=forced)  # 强制推进，不靠 sleep
        before = COUNTERS.get("cfg.parses")
        _s2, second = self._get("TalkCfg")
        self.assertEqual(COUNTERS.get("cfg.parses") - before, 1)  # 重解析一次
        self.assertIn(b'y190', second)  # 新内容
        self.assertNotEqual(json.loads(second)["data"],
                            json.loads(first)["data"])

    def test_write_reparses_only_written_table(self):
        self._put_big("TalkCfg")
        self._put_big("OptionCfg")
        self._get("TalkCfg")
        self._get("OptionCfg")
        before = COUNTERS.get("cfg.parses")
        # 全量写 TalkCfg（写大表：body 越过缓存门槛，写后播种才生效）
        new_data = json.loads(_big_table(marker="z"))
        status, payload = self.router.dispatch(
            "PUT", "/api/cfg/TalkCfg", {}, {"data": new_data})
        self.assertEqual(status, 200)
        after_write = COUNTERS.get("cfg.parses")
        # 写前 lossy 探测命中暖缓存（0 解析）；写后播种 → 后续 GET 零解析
        _s, talk = self._get("TalkCfg")
        self.assertEqual(COUNTERS.get("cfg.parses") - after_write, 0)
        self.assertEqual(json.loads(talk)["data"], new_data)
        # OptionCfg 全程零解析（写入只影响被写那张表）
        _s2, _opt = self._get("OptionCfg")
        self.assertEqual(COUNTERS.get("cfg.parses") - before, 0)

    def test_patch_write_then_get_is_zero_parse(self):
        self._put_big("TalkCfg")
        self._get("TalkCfg")
        before = COUNTERS.get("cfg.parses")
        status, payload = self.router.dispatch(
            "PUT", "/api/cfg/TalkCfg", {},
            {"patch": {"set": {"7": {"id": 7, "content": "补丁行"}}}})
        self.assertEqual(status, 200)
        self.assertEqual(payload["applied_set"], 1)
        _s, body = self._get("TalkCfg")
        data = json.loads(body)["data"]
        self.assertEqual(data["7"], {"id": 7, "content": "补丁行"})
        self.assertIn("1000", data)  # 其余行原样保留
        # patch 分支没有写前 lossy 探测的全表重解析（apply_patch 走缓存提供者），
        # 写后 GET 零解析
        self.assertEqual(COUNTERS.get("cfg.parses") - before, 0)


if __name__ == "__main__":
    unittest.main()
