# -*- coding: utf-8 -*-
"""API/服务层健壮性回归：
- cfg_read 遇非法 UTF-8 表给 400 而不是 500；
- /api/tts/save 绑定未发生时如实回 boundTalkId=None + warning；
- /api/mods/select 的 root 越界判断在大小写不同的 Windows 路径下不误杀；
- extract_event 按 ID 编码（事件+3 位对白 / +2 位选项）精确匹配，不连带他事件；
- BaseDataService.load 全量重载时不残留上一环境/目录的行；
- cloud_sync 下载覆盖配置表后丢弃 cfg_store 内存 undo 栈。

运行方式（在 backend 目录下）：
    python -m pytest editor/server/test_api_robustness.py -q
"""
import base64
import json
import os
import tempfile
import unittest

from editor.server import cfg_store
from editor.server import cloud_sync
from editor.server.api import build_router, STATE
from editor.server.base_service import BaseDataService


def _put_cfg(cfg_dir, name, data):
    with open(os.path.join(cfg_dir, name), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)


class ApiRobustnessTest(unittest.TestCase):
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

    def tearDown(self):
        STATE.workspace_root, STATE.mod_root, STATE.mod_name = self._saved

    def test_cfg_read_gbk_file_no_crash(self):
        # GBK 转存只损坏非 ASCII 内容值，JSON 结构仍在：容错解码返回 200
        # （修复前是 UnicodeDecodeError → 500）。用户在编辑器里改回后保存
        # 即恢复为合法 UTF-8，这是比拒绝打开更可用的修复路径。
        with open(os.path.join(self.cfg_dir, "EvtCfg.json"), "wb") as f:
            f.write('{"1": {"title": "乱码"}}'.encode("gbk"))
        status, payload = self.router.dispatch("GET", "/api/cfg/EvtCfg", {}, None)
        self.assertEqual(status, 200)
        self.assertIn("1", payload["data"])

    def test_cfg_read_binary_garbage_returns_400(self):
        with open(os.path.join(self.cfg_dir, "EvtCfg.json"), "wb") as f:
            f.write(b"\xff\xfe\x01\x02not json at all")
        status, payload = self.router.dispatch("GET", "/api/cfg/EvtCfg", {}, None)
        self.assertEqual(status, 400)
        self.assertIn("JSON", payload.get("error", ""))

    def test_tts_save_bind_without_writecfg_reports_unbound(self):
        b64 = base64.b64encode(b"RIFFfake-audio-bytes").decode()
        status, payload = self.router.dispatch(
            "POST", "/api/tts/save", {},
            {"audio": b64, "ext": "wav", "key": "vo1",
             "bindTalkId": "1000001001"})
        self.assertEqual(status, 200)
        self.assertIsNone(payload.get("audioCfgId"))
        # 曾经的坑：绑定分支被短路不执行，响应却回填 bindTalkId 骗过前端
        self.assertIsNone(payload.get("boundTalkId"))
        self.assertIn("未绑定", payload.get("warning", ""))

    @unittest.skipUnless(os.name == "nt", "Windows 路径大小写不敏感")
    def test_mod_select_case_insensitive_root(self):
        abs_root = os.path.abspath(self.mod_root)
        flipped = abs_root[0].lower() + abs_root[1:]  # 盘符大小写差异
        status, payload = self.router.dispatch(
            "POST", "/api/mods/select", {}, {"root": flipped})
        self.assertEqual(status, 200, payload)
        self.assertEqual(os.path.normcase(payload["mod"]["root"]),
                         os.path.normcase(abs_root))


class ExtractEventEncodingTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.svc = BaseDataService(editor_root=self._tmp.name,
                                   cache_root=self._tmp.name)

    def test_exact_suffix_length_no_overmatch(self):
        self.svc.data = {
            "EvtCfg": {"1000001": {"id": 1000001}},
            "TalkCfg": {"1000001001": {"id": 1000001001},   # 7+3 ✔
                        "100000100": {"id": 100000100},     # 短一位 ✘
                        "10000010001": {"id": 10000010001}},  # 长一位 ✘
            "OptionCfg": {"100000101": {"id": 100000101},   # 7+2 ✔
                          "1000001001": {"id": 1000001001}},  # 像对白 ✘
        }
        d = self.svc.extract_event("1000001")
        self.assertEqual(sorted(d["TalkCfg"].keys()), ["1000001001"])
        self.assertEqual(sorted(d["OptionCfg"].keys()), ["100000101"])


class BaseReloadReplaceTest(unittest.TestCase):
    """全量重载（缓存未命中）必须整体替换而非合并：切环境后不残留旧行。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def _make_env_dir(self, name, rows):
        d = os.path.join(self._tmp.name, name)
        cfg = os.path.join(d, "Cfgs", "zh-cn")
        os.makedirs(cfg)
        _put_cfg(cfg, "EvtCfg.json", rows)
        return d

    def test_second_load_drops_old_rows(self):
        svc = BaseDataService(editor_root=self._tmp.name,
                              cache_root=os.path.join(self._tmp.name, "cache"))
        a = self._make_env_dir("a", {"9999001": {"id": 9999001}})
        b = self._make_env_dir("b", {"9999002": {"id": 9999002}})
        loaded, _missing, errors = svc.load(
            env={"mode": "studio", "base_game_dir": a}, force=True)
        self.assertIn("EvtCfg", loaded, errors)
        self.assertIn("9999001", svc.data.get("EvtCfg", {}))
        loaded, _m2, _e2 = svc.load(
            env={"mode": "studio", "base_game_dir": b}, force=True)
        self.assertIn("EvtCfg", loaded)
        self.assertIn("9999002", svc.data["EvtCfg"])
        self.assertNotIn("9999001", svc.data["EvtCfg"])


class CloudSyncForgetTest(unittest.TestCase):
    def test_download_over_cfg_forgets_undo_stack(self):
        with tempfile.TemporaryDirectory() as t:
            cfg_dir = os.path.join(t, "Cfgs", "zh-cn")
            os.makedirs(cfg_dir)
            path = os.path.join(cfg_dir, "EvtCfg.json")
            cfg_store.write_cfg(path, {"1": {"id": 1}})  # 建立内存 undo 栈
            new_rows = {"2": {"id": 2}}

            class _Drv(object):
                def get(self, remote, local):
                    _put_cfg(os.path.dirname(local), os.path.basename(local),
                             new_rows)

            cloud_sync._drv_get(_Drv(), "remote/EvtCfg.json", path)
            # 下载覆盖后撤销栈必须作废，否则 undo 会把刚同步的整表回滚掉
            r = cfg_store.undo(path)
            self.assertFalse(r["ok"])
            self.assertEqual(r["error"], "nothing to undo")
            with open(path, encoding="utf-8") as f:
                self.assertEqual(json.load(f), new_rows)

    def test_download_non_cfg_path_is_noop(self):
        with tempfile.TemporaryDirectory() as t:
            audio_dir = os.path.join(t, "audio")
            os.makedirs(audio_dir)
            path = os.path.join(audio_dir, "a.wav")

            class _Drv(object):
                def get(self, remote, local):
                    with open(local, "wb") as f:
                        f.write(b"RIFF")

            cloud_sync._drv_get(_Drv(), "r/a.wav", path)
            self.assertTrue(os.path.isfile(path))


class CfgPatchApiTest(unittest.TestCase):
    """S2 契约：PUT /api/cfg/<name> body 以 patch 字段判别增量补丁（不新增路由），
    /api/ping 以 cfg_patch: true 做能力门（旧后端 → 前端退回 GET+PUT 全表）。"""

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
        _put_cfg(self.cfg_dir, "EvtCfg.json",
                 {"1000": {"id": 1000, "content": "旧"},
                  "1001": {"id": 1001, "content": "待删"}})

    def tearDown(self):
        STATE.workspace_root, STATE.mod_root, STATE.mod_name = self._saved

    def _path(self):
        return os.path.join(self.cfg_dir, "EvtCfg.json")

    def _disk(self):
        with open(self._path(), encoding="utf-8-sig") as f:
            return json.load(f)

    def test_ping_advertises_cfg_patch_capability(self):
        status, payload = self.router.dispatch("GET", "/api/ping", {}, None)
        self.assertEqual(status, 200)
        self.assertIs(payload.get("cfg_patch"), True)

    def test_patch_branch_applies_set_and_remove(self):
        status, payload = self.router.dispatch(
            "PUT", "/api/cfg/EvtCfg", {},
            {"patch": {"set": {"1000": {"id": 1000, "content": "新"}},
                       "remove": ["1001"]}})
        self.assertEqual(status, 200)
        self.assertEqual(payload["applied_set"], 1)
        self.assertEqual(payload["applied_remove"], 1)
        self.assertIsNotNone(payload["mtime_ns"])
        self.assertEqual(self._disk(),
                         {"1000": {"id": 1000, "content": "新"}})
        # 写后 GET 反映新内容（表缓存已失效重建）
        status, payload = self.router.dispatch("GET", "/api/cfg/EvtCfg", {}, None)
        self.assertEqual(payload["data"], {"1000": {"id": 1000, "content": "新"}})

    def test_patch_if_match_conflict_returns_keys_not_data(self):
        status, payload = self.router.dispatch(
            "PUT", "/api/cfg/EvtCfg", {},
            {"patch": {"set": {"1000": {"id": 1000, "content": "改"}}},
             "if_match": {"1000": {"id": 1000, "content": "过期基线"}}})
        self.assertEqual(status, 409)
        self.assertEqual(payload["conflicting_keys"], ["1000"])
        self.assertNotIn("data", payload)
        self.assertEqual(self._disk()["1000"]["content"], "旧")

    def test_patch_mtime_conflict_returns_disk_data(self):
        stale = os.stat(self._path()).st_mtime_ns
        _put_cfg(self.cfg_dir, "EvtCfg.json", {"1": {"name": "external"}})
        forced = stale + 10 ** 9
        os.utime(self._path(), ns=(forced, forced))
        status, payload = self.router.dispatch(
            "PUT", "/api/cfg/EvtCfg", {},
            {"patch": {"set": {"2": {"id": 2}}}, "expect_mtime_ns": stale})
        self.assertEqual(status, 409)
        self.assertEqual(payload["data"], {"1": {"name": "external"}})

    def test_full_table_write_still_works_without_patch(self):
        status, payload = self.router.dispatch(
            "PUT", "/api/cfg/EvtCfg", {},
            {"data": {"9": {"id": 9}}})
        self.assertEqual(status, 200)
        self.assertEqual(self._disk(), {"9": {"id": 9}})

    def test_patch_invalid_shapes_rejected(self):
        status, _p = self.router.dispatch(
            "PUT", "/api/cfg/EvtCfg", {}, {"patch": "not-a-dict"})
        self.assertEqual(status, 400)
        status, _p = self.router.dispatch(
            "PUT", "/api/cfg/EvtCfg", {},
            {"patch": {"set": {}}, "if_match": [1, 2]})
        self.assertEqual(status, 400)


class ModCfgsCacheBoundaryTest(unittest.TestCase):
    """G3：_load_mod_cfgs 只读视图 + B16 坏表不再伪装空表。"""

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

    def tearDown(self):
        STATE.workspace_root, STATE.mod_root, STATE.mod_name = self._saved

    def test_load_mod_cfgs_returns_readonly_views(self):
        from editor.server.api import _load_mod_cfgs, _invalidate_mod_cfgs_cache
        _put_cfg(self.cfg_dir, "EvtCfg.json", {"1": {"id": 1}})
        _invalidate_mod_cfgs_cache()
        mod_cfgs = _load_mod_cfgs()
        tbl = mod_cfgs["EvtCfg"]
        from types import MappingProxyType
        self.assertIsInstance(tbl, MappingProxyType)
        # 表级写入必须被拒（旧浅拷贝契约下会静默污染缓存）
        with self.assertRaises(TypeError):
            tbl["9999"] = {"id": 9999}
        # 顶层 dict 也是每次新建的，调用方 setdefault 不再影响缓存
        mod_cfgs.setdefault("TalkCfg", {})
        mod_cfgs2 = _load_mod_cfgs()
        self.assertNotIn("TalkCfg", mod_cfgs2)

    def test_broken_table_reported_not_faked_as_empty(self):
        from editor.server.api import _load_mod_cfgs, _invalidate_mod_cfgs_cache
        with open(os.path.join(self.cfg_dir, "EvtCfg.json"), "wb") as f:
            f.write(b"{not valid json at all")
        _put_cfg(self.cfg_dir, "ItemCfg.json", {"1": {"id": 1}})
        _invalidate_mod_cfgs_cache()
        status, payload = self.router.dispatch("POST", "/api/bugfix/scan", {}, {})
        self.assertEqual(status, 200)
        broken = [b for b in payload["bugs"]
                  if b.get("flag") == "ERROR" and b.get("cfg") == "EvtCfg"]
        self.assertTrue(broken)  # 坏表显式报 ERROR，而非「无问题」
        self.assertIn("解析失败", broken[0]["desc"])
        # 修复坏文件后 broken 状态随指纹更新消散
        _put_cfg(self.cfg_dir, "EvtCfg.json", {"1": {"id": 1}})
        st = os.stat(os.path.join(self.cfg_dir, "EvtCfg.json"))
        os.utime(os.path.join(self.cfg_dir, "EvtCfg.json"),
                 ns=(st.st_mtime_ns + 10 ** 9,) * 2)
        from editor.server.api import _broken_mod_cfgs
        _load_mod_cfgs()
        self.assertNotIn("EvtCfg", _broken_mod_cfgs())


if __name__ == "__main__":
    unittest.main()
