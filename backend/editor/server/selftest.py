# -*- coding: utf-8 -*-
"""后端 API 自测（unittest）：全程使用临时模组 _smoke_test_mod，不触碰真实模组。

运行方式（在 backend 目录下）：
    python -m unittest editor.server.selftest -v
"""
import json
import os
import sys
import time
import unittest
import urllib.error
import urllib.request

TEST_MOD = "_smoke_test_mod"


def _call(port, method, path, body=None, headers=None):
    url = "http://127.0.0.1:%d%s" % (port, path)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8"))


class BackendApiTest(unittest.TestCase):
    port = None

    @classmethod
    def setUpClass(cls):
        from editor.server import start_server
        _, cls.port = start_server()

    # ---------- 基础端点 ----------
    def test_basic_endpoints(self):
        for path in ("/api/ping", "/api/state", "/api/mods", "/api/schema",
                     "/api/dicts", "/api/aa/status", "/api/cfg",
                     "/api/tools/list?scope=workspace&path="):
            status, _ = _call(self.port, "GET", path)
            self.assertEqual(status, 200, path)

    def test_schema_content(self):
        _, payload = _call(self.port, "GET", "/api/schema")
        self.assertIn("EvtCfg", payload.get("game_schema", {}))
        self.assertIn("PersonCfg", payload.get("game_schema", {}))

    def test_sandbox_escape_blocked(self):
        status, payload = _call(self.port, "GET",
                                "/api/tools/read?scope=mod&path=../../etc/passwd")
        self.assertEqual(status, 400)
        self.assertIn("escapes", payload.get("error", ""))

    def test_url_encoded_escape_blocked(self):
        # URL 编码的 .. 同样被拦截
        status, payload = _call(self.port, "GET",
                                "/api/tools/read?scope=mod&path=..%2F..%2Fetc%2Fpasswd")
        self.assertEqual(status, 400)
        self.assertIn("escapes", payload.get("error", ""))

    def test_forbidden_host_rejected(self):
        status, _ = _call(self.port, "GET", "/api/ping",
                          headers={"Host": "evil.example.com"})
        self.assertEqual(status, 403)

    def test_forbidden_origin_rejected(self):
        status, _ = _call(self.port, "GET", "/api/ping",
                          headers={"Origin": "https://evil.example.com"})
        self.assertEqual(status, 403)

    def test_local_origin_allowed(self):
        status, _ = _call(self.port, "GET", "/api/ping",
                          headers={"Origin": "http://127.0.0.1"})
        self.assertEqual(status, 200)

    # ---------- 模组生命周期 ----------
    def test_mod_create_title_injection_blocked(self):
        status, payload = _call(self.port, "POST", "/api/mods/create",
                                {"title": "../../evil", "desc": ""})
        self.assertEqual(status, 400)
        self.assertIn("非法字符", payload.get("error", ""))

    def test_mod_select_root_outside_workspace_blocked(self):
        status, _ = _call(self.port, "POST", "/api/mods/select",
                          {"root": os.environ.get("WINDIR", r"C:\Windows")})
        self.assertEqual(status, 400)

    def test_mod_lifecycle(self):
        status, payload = _call(self.port, "POST", "/api/mods/create",
                                {"title": TEST_MOD, "desc": "smoke"})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload.get("mod", {}).get("name"), TEST_MOD)

        status, payload = _call(self.port, "POST", "/api/mods/select",
                                {"name": TEST_MOD})
        self.assertEqual(status, 200)
        self.assertEqual(payload.get("mod", {}).get("name"), TEST_MOD)

        status, payload = _call(self.port, "PUT", "/api/cfg/EvtCfg",
                                {"data": {"101": {"id": 101, "title": "t"}}})
        self.assertEqual(status, 200, payload)

        status, payload = _call(self.port, "GET", "/api/cfg/EvtCfg")
        self.assertEqual(status, 200)
        self.assertIn("101", payload.get("data", {}))

        status, _ = _call(self.port, "POST", "/api/mods/delete",
                          {"name": TEST_MOD})
        self.assertEqual(status, 200)

    def test_guide_validate_and_effect_modes(self):
        """指南校验端点与 effect suggest/validate 新 mode（自建独立模组，不依赖执行顺序）。"""
        name = "_smoke_guide_mod"
        status, _ = _call(self.port, "POST", "/api/mods/create",
                          {"title": name, "desc": "guide"})
        self.assertEqual(status, 200)
        try:
            status, _ = _call(self.port, "POST", "/api/mods/select",
                              {"name": name})
            self.assertEqual(status, 200)
            evt = {"1314170": {"id": 1314170, "title": "t", "type": 4,
                               "rate": 1, "talkId": [1314170001]}}
            talk = {"1314170001": {"id": 1314170001, "content": "第一句"}}
            status, _ = _call(self.port, "PUT", "/api/cfg/EvtCfg", {"data": evt})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/TalkCfg", {"data": talk})
            self.assertEqual(status, 200)

            # 合规数据：0 error；跨表引用（TalkCfg 磁盘表）满足
            status, payload = _call(self.port, "POST", "/api/validate",
                                    {"cfg": "EvtCfg", "data": evt})
            self.assertEqual(status, 200)
            self.assertEqual(payload.get("counts", {}).get("error"), 0, payload)

            # 首句对话缺失 → error（指南：无法预览）
            bad_evt = {"1314170": {"id": 1314170, "talkId": [9999999999]}}
            status, payload = _call(self.port, "POST", "/api/validate",
                                    {"cfg": "EvtCfg", "data": bad_evt})
            self.assertEqual(status, 200)
            self.assertGreaterEqual(payload.get("counts", {}).get("error", 0), 1)

            # 非法事件ID → error
            status, payload = _call(self.port, "POST", "/api/validate",
                                    {"cfg": "EvtCfg",
                                     "data": {"7123456": {"id": 7123456}}})
            self.assertEqual(status, 200)
            self.assertGreaterEqual(payload.get("counts", {}).get("error", 0), 1)

            # cfg_ids：引用字段下拉数据源
            status, payload = _call(self.port, "GET", "/api/cfg_ids?name=TalkCfg")
            self.assertEqual(status, 200)
            self.assertTrue(any(i.get("id") == "1314170001"
                                for i in payload.get("items", [])), payload)

            # effect_validate 新 mode：screen（单行扁平）/ action（2D 指令行）
            status, payload = _call(self.port, "POST", "/api/effect_validate",
                                    {"mode": "screen", "text": "4001,0.5"})
            self.assertEqual(status, 200)
            self.assertTrue(payload.get("valid"), payload)
            self.assertIn("屏幕抖动", " ".join(payload.get("translations", [])))
            status, payload = _call(self.port, "POST", "/api/effect_validate",
                                    {"mode": "screen", "text": "[[4001],[9999]]"})
            self.assertFalse(payload.get("valid"))
            status, payload = _call(self.port, "POST", "/api/effect_validate",
                                    {"mode": "action", "text": "[[0,3000,1]]"})
            self.assertTrue(payload.get("valid"), payload)
            self.assertIn("设置表情", " ".join(payload.get("translations", [])))
            status, payload = _call(self.port, "POST", "/api/effect_validate",
                                    {"mode": "action", "text": "[[0,1001,1,2]]"})
            self.assertFalse(payload.get("valid"))

            # effect_suggest 新 mode：模板库已就绪，返回非空候选
            status, payload = _call(self.port, "GET",
                                    "/api/effect_suggest?mode=screen&q=4001")
            self.assertEqual(status, 200)
            self.assertTrue(payload.get("items"), payload)
            status, payload = _call(self.port, "GET",
                                    "/api/effect_suggest?mode=action&q=3000")
            self.assertEqual(status, 200)
            self.assertTrue(payload.get("items"), payload)
        finally:
            _call(self.port, "POST", "/api/mods/delete", {"name": name})


class BaseServiceLogicTest(unittest.TestCase):
    """BaseDataService 纯逻辑测试（无需 HTTP）。"""

    def _make_service(self):
        import tempfile
        from editor.server.base_service import BaseDataService
        return BaseDataService(tempfile.mkdtemp(), tempfile.mkdtemp())

    def test_extract_event_delta(self):
        svc = self._make_service()
        svc.data = {
            "EvtCfg": {"101": {"id": 101, "title": "A"}},
            "TalkCfg": {"101001": {"id": 101001}, "201001": {"id": 201001}},
            "OptionCfg": {"101001": {"id": 101001}},
        }
        delta = svc.extract_event("101")
        self.assertIn("EvtCfg", delta)
        self.assertIn("TalkCfg", delta)
        self.assertNotIn("201001", delta["TalkCfg"])

    def test_parse_script_ids_and_content(self):
        from editor.server.story_service import parse_script
        parsed = parse_script("101", "【小明】你好世界", {"小明": 1})
        self.assertTrue(parsed)
        first = sorted(parsed.items())[0]
        self.assertIn("content", first[1])

    def test_search_events_filters(self):
        svc = self._make_service()
        svc.data = {"EvtCfg": {
            "101": {"id": 101, "title": "开学典礼", "npc": [1], "type": 1},
            "102": {"id": 102, "title": "未命名", "npc": [], "type": 2},
        }}
        out = svc.search_events(keyword="开学")
        self.assertEqual(out["total"], 1)
        self.assertEqual(out["events"][0]["id"], "101")

    def test_export_pure_mode(self):
        from editor.server.story_service import export_story
        evt = {"5": {"id": 5, "title": "小事件", "talkId": [5001]}}
        talk = {"5001": {"id": 5001, "content": "台词甲", "roleIds": [1],
                         "nextTalk": [5002]},
                "5002": {"id": 5002, "content": "台词乙", "roleIds": [2]}}
        text = export_story(evt, talk, {}, {"1": "角色一", "2": "角色二"},
                            ["5"], opts={"pure": True})
        self.assertIn("角色一：台词甲", text)
        self.assertIn("角色二：台词乙", text)
        self.assertNotIn("背景", text)


class CloudSyncLogicTest(unittest.TestCase):
    """云同步纯逻辑回归测试（无需网络）。"""

    # ---------- _parse_http_date ----------
    def test_parse_http_date_rfc1123(self):
        from editor.server.cloud_sync import _parse_http_date
        import email.utils
        s = "Wed, 18 Oct 2023 10:00:00 GMT"
        self.assertEqual(_parse_http_date(s),
                         int(email.utils.parsedate_to_datetime(s).timestamp()))

    def test_parse_http_date_rfc3339_and_garbage(self):
        from editor.server.cloud_sync import _parse_http_date
        from datetime import datetime, timezone
        expect = int(datetime(2023, 10, 18, 10, 0, 0, tzinfo=timezone.utc).timestamp())
        self.assertEqual(_parse_http_date("2023-10-18T10:00:00Z"), expect)
        self.assertEqual(_parse_http_date(""), 0)
        self.assertEqual(_parse_http_date("not a date"), 0)

    # ---------- WebDAV list/stat 解析 mtime ----------
    def test_webdav_list_parses_mtime(self):
        from editor.server import cloud_sync
        xml = ("<?xml version=\"1.0\" encoding=\"utf-8\"?>"
               "<D:multistatus xmlns:D=\"DAV:\">"
               "<D:response><D:href>/dav/mods/</D:href>"
               "<D:propstat><D:prop><D:resourcetype><D:collection/>"
               "</D:resourcetype></D:prop></D:propstat></D:response>"
               "<D:response><D:href>/dav/mods/a.txt</D:href>"
               "<D:propstat><D:prop><D:getcontentlength>123</D:getcontentlength>"
               "<D:getlastmodified>Wed, 18 Oct 2023 10:00:00 GMT</D:getlastmodified>"
               "</D:prop></D:propstat></D:response>"
               "</D:multistatus>").encode("utf-8")
        drv = cloud_sync.WebDAVDriver({"url": "http://example.com/dav"})
        orig = cloud_sync._http_request
        cloud_sync._http_request = lambda *a, **k: (207, xml, {})
        try:
            objs = drv.list("mods")
        finally:
            cloud_sync._http_request = orig
        self.assertEqual(len(objs), 1)
        self.assertEqual(objs[0].name, "a.txt")
        self.assertEqual(objs[0].size, 123)
        self.assertEqual(objs[0].mtime,
                         cloud_sync._parse_http_date("Wed, 18 Oct 2023 10:00:00 GMT"))

    def test_webdav_stat_parses_mtime(self):
        from editor.server import cloud_sync
        xml = ("<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\">"
               "<D:response><D:href>/dav/mods/a.txt</D:href><D:propstat><D:prop>"
               "<D:getcontentlength>7</D:getcontentlength>"
               "<D:getlastmodified>2023-10-18T10:00:00Z</D:getlastmodified>"
               "</D:prop></D:propstat></D:response></D:multistatus>").encode("utf-8")
        drv = cloud_sync.WebDAVDriver({"url": "http://example.com/dav"})
        orig = cloud_sync._http_request
        cloud_sync._http_request = lambda *a, **k: (207, xml, {})
        try:
            o = drv.stat("mods/a.txt")
        finally:
            cloud_sync._http_request = orig
        self.assertGreater(o.mtime, 0)
        self.assertEqual(o.size, 7)

    # ---------- _list_remote_recursive 失败传播 ----------
    def test_recursive_list_raises_when_all_failed(self):
        from editor.server import cloud_sync

        class _FlakyDriver:
            def __init__(self):
                self.calls = 0

            def list(self, remote):
                self.calls += 1
                if self.calls == 1:
                    return [cloud_sync.Obj("sub", "sub", True, 0, 0, "")]
                raise IOError("boom")

        with self.assertRaises(ValueError):
            cloud_sync._list_remote_recursive(_FlakyDriver(), "mods/x")

    def test_recursive_list_returns_files(self):
        from editor.server import cloud_sync

        class _OkDriver:
            def list(self, remote):
                if (remote or "").strip("/") == "mods/y":
                    return [cloud_sync.Obj("f.txt", "f.txt", False, 3, 0, "")]
                return []

        out = cloud_sync._list_remote_recursive(_OkDriver(), "mods/y")
        self.assertIn("f.txt", out)

    # ---------- 阿里云盘 _resolve 空路径 ----------
    def test_aliyun_resolve_empty_returns_tuple(self):
        from editor.server.cloud_sync import AliyunDriveDriver
        drv = AliyunDriveDriver({"refresh_token": "x" * 40})
        self.assertEqual(drv._resolve(""), ("root", ""))
        self.assertEqual(drv._resolve("/"), ("root", ""))

    # ---------- _need_sync 判定 ----------
    def test_need_sync_branches(self):
        from editor.server.cloud_sync import _need_sync
        # size 不同必须同步
        self.assertTrue(_need_sync(10, 100, "", 11, 100, ""))
        # 双方 sha 有效：相等跳过，不等同步
        self.assertFalse(_need_sync(10, 100, "aa", 10, 100, "aa"))
        self.assertTrue(_need_sync(10, 100, "aa", 10, 100, "bb"))
        # size 相等、远端有 sha：补算本地 sha 后比对
        import hashlib
        import os
        import tempfile
        fd, path = tempfile.mkstemp(suffix=".txt")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(b"hello")
            want = hashlib.sha1(b"hello").hexdigest()
            self.assertTrue(_need_sync(5, 100, "", 5, 100, "other", local_path=path))
            self.assertFalse(_need_sync(5, 100, "", 5, 100, want, local_path=path))
        finally:
            os.remove(path)
        # 双方 mtime 有效且差异大
        self.assertTrue(_need_sync(5, 1000, "", 5, 5000, ""))

    # ---------- 百度 list 携带 mtime ----------
    def test_baidu_list_uses_mtime_field(self):
        from editor.server import cloud_sync
        payload = json.dumps({"errno": 0, "list": [
            {"server_filename": "a.json", "isdir": 0, "size": 5,
             "local_mtime": 1697613600, "server_mtime": 1697613601},
        ]}).encode("utf-8")
        drv = cloud_sync.BaiduNetdiskDriver({"refresh_token": "x" * 40})
        orig_api = cloud_sync.BaiduNetdiskDriver._api
        cloud_sync.BaiduNetdiskDriver._api = lambda self, *a, **k: json.loads(payload.decode("utf-8"))
        try:
            objs = drv.list("mods/m1")
        finally:
            cloud_sync.BaiduNetdiskDriver._api = orig_api
        self.assertEqual(objs[0].mtime, 1697613600)


class StoryAndFixApiTest(unittest.TestCase):
    port = None

    @classmethod
    def setUpClass(cls):
        from editor.server import start_server
        _, cls.port = start_server()

    def test_base_status_endpoint(self):
        status, payload = _call(self.port, "GET", "/api/base/status")
        self.assertEqual(status, 200)
        self.assertIn("status", payload)

    def test_base_events_requires_ready(self):
        # 未加载本体数据时，事件检索应返回 409（而非崩溃）
        status, _ = _call(self.port, "GET", "/api/base/events")
        self.assertEqual(status, 409)

    def test_bugfix_scan_smoke(self):
        # 无 mod 时返回 400；有 mod 时返回 200 且带 bugs 列表（不因环境 mod 存在而失败）
        status, payload = _call(self.port, "POST", "/api/bugfix/scan")
        if status == 400:
            self.assertIn("no mod selected", payload.get("error", ""))
        else:
            self.assertEqual(status, 200, payload)
            self.assertIn("bugs", payload)

    def test_bugfix_scan_and_fix_option_1(self):
        # 构造恶性 bug：OptionCfg 存在 id=1，且 TalkCfg 引用 option=[1]
        mod = "_bugfix_fix_test_mod"
        try:
            status, payload = _call(self.port, "POST", "/api/mods/create",
                                    {"title": mod, "desc": "bugfix smoke"})
            self.assertEqual(status, 200, payload)
            status, _ = _call(self.port, "POST", "/api/mods/select", {"name": mod})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/OptionCfg",
                              {"data": {"1": {"id": 1, "content": "坏选项"}}})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/TalkCfg",
                              {"data": {"5001": {"id": 5001, "content": "你好",
                                                 "option": [1]}}})
            self.assertEqual(status, 200)

            status, payload = _call(self.port, "POST", "/api/bugfix/scan")
            self.assertEqual(status, 200)
            flags = {b.get("flag") for b in payload.get("bugs", [])}
            self.assertIn("FIX_OPTION_1", flags)
            self.assertIn("FIX_TALK_1", flags)

            status, payload = _call(self.port, "POST", "/api/bugfix/fix", {})
            self.assertEqual(status, 200)
            self.assertGreaterEqual(payload.get("fixed"), 1)

            status, payload = _call(self.port, "GET", "/api/cfg/OptionCfg")
            self.assertNotIn("1", payload.get("data", {}))
            status, payload = _call(self.port, "GET", "/api/cfg/TalkCfg")
            opts = payload.get("data", {}).get("5001", {}).get("option", [])
            self.assertTrue(all(str(x).strip("[]") != "1" for x in opts))
        finally:
            _call(self.port, "POST", "/api/mods/delete", {"name": mod})

    def test_bugfix_scan_requires_mod(self):
        # 删除当前选中的 mod 后，scan 应返回 400（no mod selected）
        mod = "_bugfix_nomod_test_mod"
        try:
            status, _ = _call(self.port, "POST", "/api/mods/create",
                              {"title": mod, "desc": "nomod"})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "POST", "/api/mods/select", {"name": mod})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "POST", "/api/mods/delete", {"name": mod})
            self.assertEqual(status, 200)
            status, payload = _call(self.port, "POST", "/api/bugfix/scan")
            self.assertEqual(status, 400)
            self.assertIn("no mod selected", payload.get("error", ""))
        finally:
            _call(self.port, "POST", "/api/mods/delete", {"name": mod})

    def test_story_import_requires_fields(self):
        status, _ = _call(self.port, "POST", "/api/story/import", {"start_id": "", "text": ""})
        self.assertEqual(status, 400)

    def test_story_import_then_export_roundtrip(self):
        mod = "_story_fix_test_mod"
        try:
            status, payload = _call(self.port, "POST", "/api/mods/create",
                                    {"title": mod, "desc": "story smoke"})
            self.assertEqual(status, 200, payload)
            status, _ = _call(self.port, "POST", "/api/mods/select", {"name": mod})
            self.assertEqual(status, 200)

            # 导入（仅预览不落盘）→ 导出（读回同一份数据）
            script = "【林小梅】今天天气真好。\n【林小梅】我们一起去操场吧。"
            status, payload = _call(self.port, "POST", "/api/story/import",
                                    {"start_id": "101", "text": script, "write": False})
            self.assertEqual(status, 200, payload)
            self.assertGreater(payload.get("count", 0), 0)

            status, payload = _call(self.port, "POST", "/api/story/export",
                                    {"evt_ids": ["101"]})
            self.assertEqual(status, 200, payload)
            self.assertIn("text", payload)
        finally:
            _call(self.port, "POST", "/api/mods/delete", {"name": mod})


class AaPreviewTest(unittest.TestCase):
    """AA 资源预览接口测试（依赖本地 aa_index 缓存，无缓存时跳过）。"""

    port = None

    @classmethod
    def setUpClass(cls):
        from editor.server import start_server
        _, cls.port = start_server()

    @classmethod
    def _cache_path(cls):
        from editor.server.api import _editor_root
        return os.path.join(_editor_root(), "_cache", "aa_index", "aa_index.json")

    def _ensure_ready(self):
        status, payload = _call(self.port, "POST", "/api/aa/scan", {})
        self.assertEqual(status, 200, payload)
        for _ in range(60):
            status, payload = _call(self.port, "GET", "/api/aa/status")
            if payload.get("status") == "ready":
                return
            time.sleep(0.5)
        self.fail("aa index not ready: %s" % payload)

    def test_preview_requires_ready_index(self):
        # 索引未就绪时预览应报 400；若同进程其它测试已就绪则跳过
        status, payload = _call(self.port, "GET", "/api/aa/status")
        if payload.get("status") == "ready":
            self.skipTest("aa index already ready in this session")
        status, payload = _call(self.port, "POST", "/api/aa/preview",
                                {"kind": "tex", "key": "x"})
        self.assertEqual(status, 400)
        self.assertIn("not ready", payload.get("error", ""))

    def test_preview_tex_aud_txt(self):
        import base64
        if not os.path.exists(self._cache_path()):
            self.skipTest("no aa_index cache available")
        self._ensure_ready()
        status, payload = _call(self.port, "GET", "/api/aa/keys?limit=1")
        self.assertEqual(status, 200)
        keys = {k: (payload.get(k) or []) for k in ("tex", "aud", "txt")}
        self.assertTrue(all(keys.values()), keys)

        # tex -> PNG base64
        status, payload = _call(self.port, "POST", "/api/aa/preview",
                                {"kind": "tex", "key": keys["tex"][0]})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload.get("mime"), "image/png")
        self.assertEqual(base64.b64decode(payload["data"])[:4], b"\x89PNG")

        # aud -> 音频 base64 + ext
        status, payload = _call(self.port, "POST", "/api/aa/preview",
                                {"kind": "aud", "key": keys["aud"][0]})
        self.assertEqual(status, 200, payload)
        self.assertTrue(payload.get("ext", "").startswith("."))
        self.assertTrue(base64.b64decode(payload["data"]))

        # txt -> 文本
        status, payload = _call(self.port, "POST", "/api/aa/preview",
                                {"kind": "txt", "key": keys["txt"][0]})
        self.assertEqual(status, 200, payload)
        self.assertIn("text", payload)

    def test_preview_missing_key_and_bad_kind(self):
        import base64
        if not os.path.exists(self._cache_path()):
            self.skipTest("no aa_index cache available")
        self._ensure_ready()
        status, payload = _call(self.port, "POST", "/api/aa/preview",
                                {"kind": "tex", "key": "__missing_key__"})
        self.assertEqual(status, 404)
        status, payload = _call(self.port, "POST", "/api/aa/preview",
                                {"kind": "bogus", "key": "x"})
        self.assertEqual(status, 400)

    def test_preview_cross_bundle_texture(self):
        """回归：本地化包 Sprite 依赖其它 bundle 的图集纹理（如 img_champ），应能正常预览。"""
        import base64
        if not os.path.exists(self._cache_path()):
            self.skipTest("no aa_index cache available")
        self._ensure_ready()
        status, payload = _call(self.port, "GET", "/api/aa/keys?q=img_champ")
        self.assertEqual(status, 200)
        tex = payload.get("tex") or []
        if "img_champ" not in tex:
            self.skipTest("img_champ not in tex index")
        status, payload = _call(self.port, "POST", "/api/aa/preview",
                                {"kind": "tex", "key": "img_champ"})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload.get("mime"), "image/png")
        self.assertEqual(base64.b64decode(payload["data"])[:4], b"\x89PNG")


# ---------- AI 侧栏附件上传 ----------

def _make_docx(paragraphs):
    """构造最小可解析 docx（仅 word/document.xml）。"""
    import io
    import zipfile
    ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    body = "".join(
        '<w:p><w:r><w:t>%s</w:t></w:r></w:p>' % p for p in paragraphs)
    xml = ('<?xml version="1.0" encoding="UTF-8"?>'
           '<w:document xmlns:w="%s"><w:body>%s</w:body></w:document>'
           % (ns, body))
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("word/document.xml", xml)
    return buf.getvalue()


def _make_xlsx():
    """构造最小可解析 xlsx（1 个工作表 + 共享字符串 + 数字）。"""
    import io
    import zipfile
    s_ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    r_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    p_ns = "http://schemas.openxmlformats.org/package/2006/relationships"
    wb = ('<?xml version="1.0" encoding="UTF-8"?>'
          '<workbook xmlns="%s" xmlns:r="%s">'
          '<sheets><sheet name="Sheet1" r:id="rId1"/></sheets></workbook>'
          % (s_ns, r_ns))
    rels = ('<?xml version="1.0" encoding="UTF-8"?>'
            '<Relationships xmlns="%s">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
            'officeDocument/2006/relationships/worksheet" '
            'Target="worksheets/sheet1.xml"/></Relationships>' % p_ns)
    sst = ('<?xml version="1.0" encoding="UTF-8"?>'
           '<sst xmlns="%s" count="2" uniqueCount="2">'
           '<si><t>姓名</t></si><si><t>张三</t></si></sst>' % s_ns)
    sheet = ('<?xml version="1.0" encoding="UTF-8"?>'
             '<worksheet xmlns="%s"><sheetData>'
             '<row r="1"><c r="A1" t="s"><v>0</v></c>'
             '<c r="B1"><v>95</v></c></row>'
             '<row r="2"><c r="A2" t="s"><v>1</v></c>'
             '<c r="B2"><v>88</v></c></row>'
             '</sheetData></worksheet>' % s_ns)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("xl/workbook.xml", wb)
        zf.writestr("xl/_rels/workbook.xml.rels", rels)
        zf.writestr("xl/sharedStrings.xml", sst)
        zf.writestr("xl/worksheets/sheet1.xml", sheet)
    return buf.getvalue()


def _make_png():
    return b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0dIHDR" + b"\x00" * 13 \
        + b"IEND\xaeB`\x82"


class AiUploadTest(unittest.TestCase):
    port = None

    @classmethod
    def setUpClass(cls):
        from editor.server import start_server
        _, cls.port = start_server()

    def _upload(self, name, raw):
        import base64
        return _call(self.port, "POST", "/api/ai/upload",
                     {"name": name,
                      "data": base64.b64encode(raw).decode("ascii")})

    def test_upload_txt(self):
        status, payload = self._upload("说明.txt", "你好，AI！\n第二行".encode("utf-8"))
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["kind"], "text")
        self.assertIn("你好", payload["text"])
        self.assertIn("第二行", payload["text"])
        self.assertFalse(payload["truncated"])

    def test_upload_md(self):
        status, payload = self._upload("readme.md", "# 标题\n正文内容".encode("utf-8"))
        self.assertEqual(status, 200, payload)
        self.assertIn("# 标题", payload["text"])
        self.assertIn("正文", payload["text"])

    def test_upload_docx(self):
        status, payload = self._upload("文档.docx", _make_docx(["第一段", "第二段"]))
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["kind"], "text")
        self.assertIn("第一段", payload["text"])
        self.assertIn("第二段", payload["text"])

    def test_upload_xlsx(self):
        status, payload = self._upload("表格.xlsx", _make_xlsx())
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["kind"], "text")
        self.assertIn("Sheet1", payload["text"])
        self.assertIn("姓名", payload["text"])
        self.assertIn("张三", payload["text"])
        self.assertIn("95", payload["text"])

    def test_upload_png(self):
        import base64
        raw = _make_png()
        status, payload = self._upload("截图.png", raw)
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["kind"], "image")
        self.assertEqual(payload["mime"], "image/png")
        self.assertEqual(payload["data"], base64.b64encode(raw).decode("ascii"))

    def test_upload_jpg(self):
        status, payload = self._upload("照片.jpg", b"\xff\xd8\xff\xe0" + b"\x00" * 16)
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["kind"], "image")
        self.assertEqual(payload["mime"], "image/jpeg")
        self.assertTrue(payload["data"])

    def test_upload_bad_type_rejected(self):
        status, payload = self._upload("恶意.exe", b"MZ....")
        self.assertEqual(status, 400)
        self.assertIn("不支持", payload.get("error", ""))

    def test_upload_bad_png_magic_rejected(self):
        status, payload = self._upload("伪图.png", b"not a png at all")
        self.assertEqual(status, 400)
        self.assertIn("PNG", payload.get("error", ""))

    def test_upload_empty_name_rejected(self):
        status, _ = self._upload("", b"abc")
        self.assertEqual(status, 400)


class AiDomainApiTest(unittest.TestCase):
    """AI 细分领域 API：领域清单、条目列表/读取/修改/新建/删除、字段校验、备份。"""
    port = None
    mod = "_ai_domain_test_mod"

    @classmethod
    def setUpClass(cls):
        from editor.server import start_server
        _, cls.port = start_server()

    def setUp(self):
        status, _ = _call(self.port, "POST", "/api/mods/create",
                          {"title": self.mod, "desc": "ai domain smoke"})
        self.assertEqual(status, 200)
        status, _ = _call(self.port, "POST", "/api/mods/select",
                          {"name": self.mod})
        self.assertEqual(status, 200)

    def tearDown(self):
        _call(self.port, "POST", "/api/mods/delete", {"name": self.mod})

    def test_domains_listing(self):
        status, payload = _call(self.port, "GET", "/api/ai/domains")
        self.assertEqual(status, 200)
        ids = [d["id"] for d in payload["domains"]]
        for expect in ("story", "character", "background", "social",
                       "love", "item", "achievement", "study", "club",
                       "minigame", "battle", "job", "world", "function", "table"):
            self.assertIn(expect, ids)
        by_id = {d["id"]: d for d in payload["domains"]}
        self.assertIn("EvtCfg", by_id["story"]["tables"])      # 剧情含事件
        self.assertIn("TalkCfg", by_id["story"]["tables"])     # 剧情含对话
        self.assertIn("BgCfg", by_id["background"]["tables"])  # 背景含背景图
        self.assertNotIn("PersonCfg", by_id["background"]["tables"])
        # 兜底领域包含其余表，且与已分类表无重叠
        assigned = set()
        for d in payload["domains"]:
            if d["id"] == "table":
                continue
            assigned.update(d["tables"])
        self.assertTrue(assigned)
        self.assertTrue(by_id["table"]["tables"])
        self.assertTrue(assigned.isdisjoint(by_id["table"]["tables"]))

    def test_domain_item_crud_roundtrip(self):
        # 准备 PersonCfg（人物领域）
        sample = {"1": {"id": 1, "name": "测试角色", "birthday": [1, 2]}}
        status, _ = _call(self.port, "PUT", "/api/cfg/PersonCfg",
                          {"data": sample})
        self.assertEqual(status, 200)

        # 列表 + 关键词搜索
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/items?domain=character")
        self.assertEqual(status, 200)
        self.assertTrue(any(i["cfg"] == "PersonCfg" and i["id"] == "1"
                            for i in payload["items"]))
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/items?domain=character&q=%E6%B5%8B%E8%AF%95")
        self.assertEqual(status, 200)
        self.assertTrue(payload["items"])
        self.assertEqual(payload["items"][0]["name"], "测试角色")

        # 读取单条
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/item?domain=character&cfg=PersonCfg&id=1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["name"], "测试角色")
        self.assertIn("cfg_cn", payload)

        # 领域归属错误拒绝
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/item?domain=background&cfg=PersonCfg&id=1")
        self.assertEqual(status, 400)
        self.assertIn("不属于领域", payload["error"])

        # 字段级修改（合并语义：id 保留、其他字段不动）
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "character", "cfg": "PersonCfg",
                                 "id": "1", "patch": {"name": "新名字"}})
        self.assertEqual(status, 200)
        self.assertTrue(payload["changed"])
        self.assertEqual(payload["patched_fields"], ["name"])
        self.assertEqual(payload["data"]["name"], "新名字")
        self.assertEqual(payload["data"]["id"], 1)
        self.assertEqual(payload["data"]["birthday"], [1, 2])

        # 类型规整：字符串数组 → 数组
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "character", "cfg": "PersonCfg",
                                 "id": "1", "patch": {"birthday": "[9, 9]"}})
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["birthday"], [9, 9])

        # 未知字段拒绝
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "character", "cfg": "PersonCfg",
                                 "id": "1", "patch": {"noSuchField": 1}})
        self.assertEqual(status, 400)
        self.assertIn("不在 schema 中", payload["error"])

        # 非法数值拒绝
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "character", "cfg": "PersonCfg",
                                 "id": "1", "patch": {"id": "abc"}})
        self.assertEqual(status, 400)
        self.assertIn("数值", payload["error"])

        # String 字段拒绝 bool（类型校验缺口回归）
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "character", "cfg": "PersonCfg",
                                 "id": "1", "patch": {"name": True}})
        self.assertEqual(status, 400)
        self.assertIn("字符串", payload["error"])

        # 空 schema 表拒绝写操作（元数据/空表，无法校验字段）
        status, _ = _call(self.port, "PUT", "/api/cfg/SportDefine",
                          {"data": {"1": {"id": 1}}})
        self.assertEqual(status, 200)
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "table", "cfg": "SportDefine",
                                 "id": "1", "patch": {"x": 1}})
        self.assertEqual(status, 400)
        self.assertIn("无字段定义", payload["error"])

        # 备份文件已生成（写操作自动备份原表）
        status, payload = _call(self.port, "GET",
                                "/api/tools/list?path=Cfgs/zh-cn&deep=0")
        self.assertEqual(status, 200)
        self.assertIn("PersonCfg.json.bak",
                      [e["name"] for e in payload.get("entries", [])])

        # 新建（自动分配 id）
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "character", "cfg": "PersonCfg",
                                 "data": {"id": 2, "name": "新角色"}})
        self.assertEqual(status, 200)
        self.assertEqual(payload["id"], "2")
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/item?domain=character&cfg=PersonCfg&id=2")
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["name"], "新角色")

        # 新建重复 id 拒绝
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "character", "cfg": "PersonCfg",
                                 "data": {"id": 1, "name": "重复"}})
        self.assertEqual(status, 400)
        self.assertIn("已存在", payload["error"])

        # 删除
        status, payload = _call(self.port, "DELETE",
                                "/api/ai/domain/item?domain=character&cfg=PersonCfg&id=2")
        self.assertEqual(status, 200)
        self.assertTrue(payload["deleted"])
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/item?domain=character&cfg=PersonCfg&id=2")
        self.assertEqual(status, 400)
        self.assertIn("不存在", payload["error"])

        # 未知领域拒绝
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/items?domain=no_such_domain")
        self.assertEqual(status, 400)

    def test_create_item_auto_creates_missing_table(self):
        """表不存在时新建条目应自动建表（而不是报「配置表不存在」）。"""
        # setUp 新建的模组没有任何配置表
        status, payload = _call(self.port, "GET",
                                "/api/tools/list?path=Cfgs/zh-cn&deep=0")
        self.assertEqual(status, 200)
        self.assertNotIn("TalkCfg.json",
                         [e["name"] for e in payload.get("entries", [])])
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "story", "cfg": "TalkCfg",
                                 "data": {"id": 8001, "content": "你好"}})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["id"], "8001")
        # 表已自动落盘，可正常读取
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/item?domain=story&cfg=TalkCfg&id=8001")
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["content"], "你好")

    def test_read_missing_table_gives_actionable_error(self):
        """读取不存在的配置表时给出可执行提示（而不是裸「配置表不存在」）。"""
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/item?domain=story&cfg=TalkCfg&id=1")
        self.assertEqual(status, 400)
        self.assertIn("create_domain_item", payload["error"])
        self.assertIn("TalkCfg", payload["error"])

    def test_story_domain_talk_update(self):
        """剧情领域：改对话内容（用户核心诉求场景）。"""
        sample = {"7001": {"id": 7001, "content": "原台词", "roleIds": [1]}}
        status, _ = _call(self.port, "PUT", "/api/cfg/TalkCfg", {"data": sample})
        self.assertEqual(status, 200)
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "story", "cfg": "TalkCfg",
                                 "id": "7001", "patch": {"content": "新台词"}})
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["content"], "新台词")
        self.assertEqual(payload["data"]["roleIds"], [1])
        # 中文摘要列表
        status, payload = _call(self.port, "GET",
                                "/api/ai/domain/items?domain=story&table=TalkCfg")
        self.assertEqual(status, 200)
        self.assertTrue(any(i["id"] == "7001" and i["name"] == "新台词"
                            for i in payload["items"]))

    def test_create_talk_only_role_name_auto_fills_role_ids(self):
        """AI 只填 roleName（自定义名字）时，后端按角色字典自动补必填的 roleIds。"""
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "story", "cfg": "TalkCfg",
                                 "data": {"id": 8101, "content": "你好呀",
                                          "roleName": "薛诗蕾"}})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["roleIds"], [102])
        self.assertEqual(payload["data"]["roleName"], "薛诗蕾")

    def test_create_talk_unknown_role_name_rejected(self):
        """AI 只填了字典外的 roleName（自定义名字）而没有 roleIds 时，后端应报错引导补 ID。"""
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "story", "cfg": "TalkCfg",
                                 "data": {"id": 8102, "content": "你好",
                                          "roleName": "神秘人"}})
        self.assertEqual(status, 400)
        self.assertIn("roleIds", payload["error"])
        self.assertIn("get_game_dicts", payload["error"])

    def test_create_talk_narration_without_speaker_allowed(self):
        """旁白（roleIds 与 roleName 皆空）应正常创建，不触发 roleIds 校验。"""
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "story", "cfg": "TalkCfg",
                                 "data": {"id": 8103, "content": "一天清晨……"}})
        self.assertEqual(status, 200, payload)
        self.assertNotIn("roleIds", payload["data"])
        self.assertNotIn("roleName", payload["data"])

    def test_update_talk_role_name_keeps_existing_role_ids(self):
        """已有 roleIds 的对白只改 roleName（自定义名字）应放行，roleIds 保持不变。"""
        sample = {"8104": {"id": 8104, "content": "原台词", "roleIds": [102]}}
        status, _ = _call(self.port, "PUT", "/api/cfg/TalkCfg", {"data": sample})
        self.assertEqual(status, 200)
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "story", "cfg": "TalkCfg",
                                 "id": "8104", "patch": {"roleName": "小蕾"}})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["roleIds"], [102])
        self.assertEqual(payload["data"]["roleName"], "小蕾")

    def test_update_talk_only_role_name_auto_fills_role_ids(self):
        """旁白对白（roleIds 为空）被补 roleName 时，自动按名字补 roleIds。"""
        sample = {"8105": {"id": 8105, "content": "原台词", "roleIds": []}}
        status, _ = _call(self.port, "PUT", "/api/cfg/TalkCfg", {"data": sample})
        self.assertEqual(status, 200)
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "story", "cfg": "TalkCfg",
                                 "id": "8105", "patch": {"roleName": "罗晓纯"}})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["roleIds"], [101])

    def test_create_phone_msg_without_role_rejected(self):
        """短信（PhoneMsgCfg）只填内容不填发送者 role，应报错引导补角色 ID。"""
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "social", "cfg": "PhoneMsgCfg",
                                 "data": {"id": 8201, "content": "周末来我家玩"}})
        self.assertEqual(status, 400)
        self.assertIn("role", payload["error"])
        self.assertIn("get_game_dicts", payload["error"])

    def test_create_phone_msg_with_role_ok(self):
        """短信（PhoneMsgCfg）填了发送者 role 应正常创建。"""
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "social", "cfg": "PhoneMsgCfg",
                                 "data": {"id": 8202, "content": "周末来我家玩",
                                          "role": 102}})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["role"], 102)

    def test_create_kzone_content_without_role_rejected(self):
        """空间动态（KZoneContentCfg）只填内容不填发布者 role，应报错。"""
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "social", "cfg": "KZoneContentCfg",
                                 "data": {"id": 8301, "content": "今天天气真好"}})
        self.assertEqual(status, 400)
        self.assertIn("role", payload["error"])

    def test_update_phone_msg_content_keeps_existing_role(self):
        """已有发送者 role 的短信只改 content 应放行，role 保持不变。"""
        sample = {"8203": {"id": 8203, "content": "旧短信", "role": 102}}
        status, _ = _call(self.port, "PUT", "/api/cfg/PhoneMsgCfg", {"data": sample})
        self.assertEqual(status, 200)
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "social", "cfg": "PhoneMsgCfg",
                                 "id": "8203", "patch": {"content": "新短信"}})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["role"], 102)

    def test_create_non_content_table_untouched(self):
        """非内容归属表（如 PersonCfg）不受角色校验影响。"""
        status, payload = _call(self.port, "POST", "/api/ai/domain/item",
                                {"domain": "character", "cfg": "PersonCfg",
                                 "data": {"id": 8401, "name": "测试角色"}})
        self.assertEqual(status, 200, payload)


class ImageApiTest(unittest.TestCase):
    """AI 图片生成 API（openai-image-api：images/generations / images/edits）。

    仅验证参数校验（发往上游之前拦截），不发起真实 OpenAI 请求。
    """

    port = None

    @classmethod
    def setUpClass(cls):
        from editor.server import start_server
        _, cls.port = start_server()

    def test_generate_requires_api_key(self):
        status, payload = _call(self.port, "POST", "/api/ai/image/generate",
                                {"prompt": "一个校园场景"})
        self.assertEqual(status, 400)
        self.assertIn("API Key", payload.get("error", ""))

    def test_generate_requires_prompt(self):
        status, payload = _call(self.port, "POST", "/api/ai/image/generate",
                                {"api_key": "sk-test", "n": 1})
        self.assertEqual(status, 400)
        self.assertIn("prompt", payload.get("error", ""))

    def test_generate_bad_n_rejected(self):
        status, payload = _call(self.port, "POST", "/api/ai/image/generate",
                                {"api_key": "sk-test", "prompt": "x", "n": "many"})
        self.assertEqual(status, 400)
        self.assertIn("n", payload.get("error", ""))

    def test_generate_bad_size_rejected(self):
        status, payload = _call(self.port, "POST", "/api/ai/image/generate",
                                {"api_key": "sk-test", "prompt": "x", "size": "999x999"})
        self.assertEqual(status, 400)
        self.assertIn("size", payload.get("error", ""))

    def test_edit_requires_image(self):
        status, payload = _call(self.port, "POST", "/api/ai/image/edit",
                                {"api_key": "sk-test", "prompt": "改成夜晚"})
        self.assertEqual(status, 400)
        self.assertIn("image", payload.get("error", ""))

    def test_edit_requires_api_key(self):
        status, payload = _call(self.port, "POST", "/api/ai/image/edit",
                                {"prompt": "x", "image_base64": "aGk="})
        self.assertEqual(status, 400)
        self.assertIn("API Key", payload.get("error", ""))

    def test_edit_invalid_base64_rejected(self):
        status, payload = _call(self.port, "POST", "/api/ai/image/edit",
                                {"api_key": "sk-test", "prompt": "x",
                                 "image_base64": "!!!not-base64!!!"})
        self.assertEqual(status, 400)
        self.assertIn("image", payload.get("error", ""))


class StageApiTest(unittest.TestCase):
    """AI 舞台调度 API：人物站位/移动/入场退场/表情/动作 的语义化修改。"""

    port = None
    mod = "_stage_test_mod"

    @classmethod
    def setUpClass(cls):
        from editor.server import start_server
        _, cls.port = start_server()

    def setUp(self):
        status, _ = _call(self.port, "POST", "/api/mods/create",
                          {"title": self.mod, "desc": "stage smoke"})
        self.assertEqual(status, 200)
        status, _ = _call(self.port, "POST", "/api/mods/select",
                          {"name": self.mod})
        self.assertEqual(status, 200)
        sample = {"7001": {"id": 7001, "content": "你好", "roles": []}}
        status, _ = _call(self.port, "PUT", "/api/cfg/TalkCfg", {"data": sample})
        self.assertEqual(status, 200)

    def tearDown(self):
        _call(self.port, "POST", "/api/mods/delete", {"name": self.mod})

    def test_stage_dicts(self):
        status, payload = _call(self.port, "GET", "/api/ai/stage/dicts")
        self.assertEqual(status, 200)
        expr_ids = [e["id"] for e in payload["expressions"]]
        self.assertIn(1, expr_ids)                       # 开心
        self.assertIn(8, expr_ids)                       # 惊讶
        act_by_type = {a["type"]: a for a in payload["actions"]}
        for tid in (1001, 2001, 3000, 3004, 4001):
            self.assertIn(tid, act_by_type, "动作类型缺失: %s" % tid)
        self.assertTrue(act_by_type[1001]["role"])       # 入场作用于角色
        self.assertFalse(act_by_type[4001]["role"])      # 屏幕抖动为屏幕特效
        self.assertEqual([p["name"] for p in payload["positions"]], ["左", "右", "中"])
        self.assertTrue(payload["roles"])                # 角色列表非空

    def test_stage_encode_and_write_roundtrip(self):
        commands = [
            {"action": "入场", "role": "薛诗蕾", "mode": "滑动", "pos": "左"},
            {"action": "表情", "role": "102", "expr": "开心"},
            {"action": "移动", "role": "102", "value": -80},
            {"action": "退场", "role": "102", "mode": "直接"},
        ]
        status, payload = _call(self.port, "POST", "/api/ai/stage/encode",
                                {"talk_id": "7001", "commands": commands})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["old_roles"], [])
        self.assertEqual(payload["new_roles"],
                         [[102, 1001, 1, 1], [102, 3000, 1], [102, 3004, -80], [102, 2002]])
        self.assertIn("薛诗蕾", payload["new_desc"])
        self.assertIn("开心", payload["new_desc"])
        self.assertIn("80", payload["new_desc"])

        # 写回（复用领域工具，含备份与 schema 校验）
        status, payload = _call(self.port, "PUT", "/api/ai/domain/item",
                                {"domain": "story", "cfg": "TalkCfg", "id": "7001",
                                 "patch": {"roles": payload["new_roles"]}})
        self.assertEqual(status, 200, payload)
        status, payload = _call(self.port, "GET", "/api/ai/stage/roles?talk_id=7001")
        self.assertEqual(status, 200)
        self.assertIn("薛诗蕾滑动到左侧", payload["desc"])
        self.assertIn("薛诗蕾表情：开心", payload["desc"])
        self.assertIn("直接退场", payload["desc"])

        # 默认追加：保留原有指令
        status, payload = _call(self.port, "POST", "/api/ai/stage/encode",
                                {"talk_id": "7001",
                                 "commands": [{"action": "屏幕特效", "type": "屏幕抖动"}]})
        self.assertEqual(status, 200)
        self.assertEqual(len(payload["new_roles"]), 5)
        # clear=true：清空后只保留新指令
        status, payload = _call(self.port, "POST", "/api/ai/stage/encode",
                                {"talk_id": "7001", "clear": True,
                                 "commands": [{"action": "表情", "role": "102", "expr": "8"}]})
        self.assertEqual(status, 200)
        self.assertEqual(payload["new_roles"], [[102, 3000, 8]])
        self.assertIn("惊讶", payload["new_desc"])

    def test_stage_encode_errors(self):
        # 未知角色
        status, payload = _call(self.port, "POST", "/api/ai/stage/encode",
                                {"talk_id": "7001",
                                 "commands": [{"action": "入场", "role": "不存在的人"}]})
        self.assertEqual(status, 400)
        self.assertIn("找不到角色", payload["error"])
        # 未知 action
        status, payload = _call(self.port, "POST", "/api/ai/stage/encode",
                                {"talk_id": "7001", "commands": [{"action": "起飞"}]})
        self.assertEqual(status, 400)
        self.assertIn("未知 action", payload["error"])
        # 缺少 talk_id
        status, payload = _call(self.port, "POST", "/api/ai/stage/encode",
                                {"commands": [{"action": "表情", "role": "1", "expr": "1"}]})
        self.assertEqual(status, 400)
        self.assertIn("talk_id", payload["error"])
        # 对白不存在
        status, payload = _call(self.port, "POST", "/api/ai/stage/encode",
                                {"talk_id": "999999",
                                 "commands": [{"action": "表情", "role": "1", "expr": "1"}]})
        self.assertEqual(status, 400)
        self.assertIn("不存在", payload["error"])
        # commands 非数组
        status, payload = _call(self.port, "POST", "/api/ai/stage/encode",
                                {"talk_id": "7001", "commands": "bad"})
        self.assertEqual(status, 400)
        self.assertIn("数组", payload["error"])
        # 舞台读取：talk_id 缺失
        status, _ = _call(self.port, "GET", "/api/ai/stage/roles?talk_id=")
        self.assertEqual(status, 400)


class EventPreviewApiTest(unittest.TestCase):
    """事件场景预览接口测试（本体数据依赖 aa_index 缓存，无缓存时跳过）。"""

    port = None

    @classmethod
    def setUpClass(cls):
        from editor.server import start_server
        _, cls.port = start_server()

    @classmethod
    def _cache_path(cls):
        from editor.server.api import _editor_root
        return os.path.join(_editor_root(), "_cache", "aa_index", "aa_index.json")

    def test_preview_requires_evt_id(self):
        status, payload = _call(self.port, "POST", "/api/preview/event", {"evt_id": ""})
        self.assertEqual(status, 400)
        self.assertIn("evt_id", payload.get("error", ""))

    def test_preview_missing_event(self):
        status, payload = _call(self.port, "POST", "/api/preview/event",
                                {"evt_id": "99999999"})
        self.assertEqual(status, 400)
        self.assertIn("不存在", payload.get("error", ""))

    def test_preview_base_event_structure(self):
        """本体事件预览：对白链 / 选项 / 舞台快照 / 资源映射结构完整。"""
        if not os.path.exists(self._cache_path()):
            self.skipTest("no aa_index cache available")
        status, payload = _call(self.port, "POST", "/api/preview/event",
                                {"evt_id": "320101"})
        self.assertEqual(status, 200, payload)
        self.assertTrue(payload.get("ok"))
        self.assertGreater(payload.get("talk_count", 0), 0)
        self.assertTrue(payload.get("talks"))
        self.assertIn("meta", payload)
        meta = payload["meta"]
        for k in ("roles", "bgs", "bgKeys", "charKeys"):
            self.assertIn(k, meta)
        # 起始对白存在且带舞台快照
        starts = payload.get("starts") or []
        self.assertTrue(starts)
        first = payload["talks"].get(starts[0])
        self.assertIsNotNone(first, "起始对白应在 talks 中")
        self.assertIn("stage", first)
        self.assertIn("chars", first["stage"])
        # 背景映射：talk.bg 非 0 时应给出 tex key
        for t in payload["talks"].values():
            bg = (t.get("stage") or {}).get("bg")
            if bg and bg.get("id") != "0":
                self.assertIn(bg["id"], meta["bgKeys"])
                break

    def test_preview_mod_data_priority(self):
        """mod 配置表优先：事件/对白来自当前 mod 而非本体。"""
        mod = "_preview_test_mod"
        try:
            status, payload = _call(self.port, "POST", "/api/mods/create",
                                    {"title": mod, "desc": "preview smoke"})
            self.assertEqual(status, 200, payload)
            status, _ = _call(self.port, "POST", "/api/mods/select", {"name": mod})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/EvtCfg",
                              {"data": {"5": {"id": 5, "title": "预览测试事件", "talkId": [5001]}}})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/TalkCfg",
                              {"data": {"5001": {"id": 5001, "content": "预览台词",
                                                 "roleIds": [1],
                                                 "bg": 0,
                                                 "roles": [[101, 1001, 1, 1]]}}})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/PersonCfg",
                              {"data": {"101": {"id": 101, "name": "测试角色", "url": ["role_xiaochun"]}}})
            self.assertEqual(status, 200)

            status, payload = _call(self.port, "POST", "/api/preview/event",
                                    {"evt_id": "5"})
            self.assertEqual(status, 200, payload)
            self.assertEqual(payload.get("event_title"), "预览测试事件")
            talk = payload["talks"]["5001"]
            self.assertEqual(talk.get("content"), "预览台词")
            self.assertEqual(talk.get("roleIds"), ["1"])
            # 舞台：101 入场到左，立绘 key 使用 mod PersonCfg 提供的 url
            chars = talk["stage"]["chars"]
            hit = next((c for c in chars if c["roleId"] == "101"), None)
            self.assertIsNotNone(hit)
            self.assertEqual(hit["pos"], "left")
            self.assertEqual(hit["tex"], "role_xiaochun")
            self.assertEqual(payload["meta"]["roles"].get("101"), "测试角色")
        finally:
            _call(self.port, "POST", "/api/mods/delete", {"name": mod})

    def test_preview_bg_meta_merges_mod_and_base(self):
        """mod 部分覆盖 BgCfg 时，本体背景 id 仍能解析出 tex key（合并而非二选一）。"""
        mod = "_preview_bgmerge_mod"
        try:
            status, payload = _call(self.port, "POST", "/api/mods/create",
                                    {"title": mod, "desc": "bg merge"})
            self.assertEqual(status, 200, payload)
            status, _ = _call(self.port, "POST", "/api/mods/select", {"name": mod})
            self.assertEqual(status, 200)
            # mod 的 BgCfg 只有一条自定义背景（1102001），不覆盖本体 202361
            status, _ = _call(self.port, "PUT", "/api/cfg/BgCfg",
                              {"data": {"1102001": {"id": 1102001,
                                                    "url": "Mods/xxx/BGcat.png"}}})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/EvtCfg",
                              {"data": {"5": {"id": 5, "title": "合并背景事件",
                                              "talkId": [5001]}}})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/TalkCfg",
                              {"data": {"5001": {"id": 5001, "content": "测试",
                                                 "bg": 202361}}})
            self.assertEqual(status, 200)

            status, payload = _call(self.port, "POST", "/api/preview/event",
                                    {"evt_id": "5"})
            self.assertEqual(status, 200, payload)
            meta = payload["meta"]
            # mod 自定义背景保留
            self.assertEqual(meta["bgKeys"].get("1102001"), "Mods/xxx/BGcat.png")
            # 本体背景 202361 从本体合并而来，仍能解析出 tex key
            self.assertEqual(meta["bgKeys"].get("202361"), "img_jietijiaoshi")
            talk = payload["talks"]["5001"]
            self.assertEqual(talk["stage"]["bg"]["id"], "202361")
            self.assertEqual(talk["stage"]["bg"]["key"], "img_jietijiaoshi")
        finally:
            _call(self.port, "POST", "/api/mods/delete", {"name": mod})


    def test_preview_char_tex_fallback_and_normalize(self):
        """立绘 tex 选择：表情变体缺失回退 base；大小写/扩展名规范化（单元级）。"""
        from editor.server.preview_service import _pick_char_tex

        class FakeIdx(object):
            def __init__(self, keys):
                self._keys = set(keys)

            def has_tex(self, k):
                return k in self._keys

        idx = FakeIdx({'role_male', 'role_male2_1', 'role_dad', 'role_yeye'})
        # 表情编号超范围（变体缺失）→ 回退 base
        self.assertEqual(_pick_char_tex({'base': 'role_male', 'base2': 'role_male2'}, 8, idx),
                         'role_male')
        # 变体存在 → 优先变体
        self.assertEqual(_pick_char_tex({'base': 'role_male', 'base2': 'role_male2'}, 1, idx),
                         'role_male2_1')
        # 该角色无表情变体资源 → 回退 base
        self.assertEqual(_pick_char_tex({'base': 'role_dad', 'base2': 'role_dad2'}, 1, idx),
                         'role_dad')
        # 仅配置 url2（base 为空）→ 用 base2 本身
        self.assertEqual(_pick_char_tex({'base': '', 'base2': 'role_yeye'}, 0, idx),
                         'role_yeye')
        # 大小写不一致 → 返回索引规范 key
        self.assertEqual(_pick_char_tex({'base': 'Role_Male', 'base2': 'role_male2'}, 0, idx),
                         'role_male')
        # 索引不可用（如无游戏本体）→ 按原规则返回首个候选
        self.assertEqual(_pick_char_tex({'base': 'role_male', 'base2': 'role_male2'}, 8, None),
                         'role_male2_8')
        # 无任何立绘资源 → 空
        self.assertEqual(_pick_char_tex({'base': '', 'base2': ''}, 0, idx), '')

    def test_preview_char_tex_fallback_integration(self):
        """mod 角色表情超范围时，预览 stage.chars 回退到存在的 base key。"""
        if not os.path.exists(self._cache_path()):
            self.skipTest("no aa_index cache available")
        mod = "_preview_texfallback_mod"
        try:
            status, payload = _call(self.port, "POST", "/api/mods/create",
                                    {"title": mod, "desc": "tex fallback"})
            self.assertEqual(status, 200, payload)
            status, _ = _call(self.port, "POST", "/api/mods/select", {"name": mod})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/PersonCfg",
                              {"data": {"101": {"id": 101, "name": "测试角色",
                                                "url": ["role_male"], "url2": ["role_male2"]}}})
            self.assertEqual(status, 200)
            status, _ = _call(self.port, "PUT", "/api/cfg/EvtCfg",
                              {"data": {"5": {"id": 5, "title": "立绘回退事件",
                                              "talkId": [5001]}}})
            self.assertEqual(status, 200)
            # 入场到左 + 表情 8（该编号在本体索引中不存在）
            status, _ = _call(self.port, "PUT", "/api/cfg/TalkCfg",
                              {"data": {"5001": {"id": 5001, "content": "测试",
                                                 "roles": [[101, 1001, 1, 1], [101, 3000, 8]]}}})
            self.assertEqual(status, 200)

            status, payload = _call(self.port, "POST", "/api/preview/event",
                                    {"evt_id": "5"})
            self.assertEqual(status, 200, payload)
            chars = payload["talks"]["5001"]["stage"]["chars"]
            hit = next((c for c in chars if c["roleId"] == "101"), None)
            self.assertIsNotNone(hit)
            # 表情变体 role_male2_8 缺失 → 回退 base role_male
            self.assertEqual(hit["tex"], "role_male")
        finally:
            _call(self.port, "POST", "/api/mods/delete", {"name": mod})


class GuideRulesLogicTest(unittest.TestCase):
    """guide_rules 纯逻辑：指南 ID 格式、单表语义、跨表引用、ID 建议（无需 HTTP）。"""

    def test_id_format_checks(self):
        from editor.core.guide_rules import check_event_id, check_dialog_id, check_option_id
        # 指南示例：1314170/1903271/1999999/1000000 合法；123/7123456/12345678 非法
        self.assertIsNone(check_event_id(1314170))
        self.assertIsNone(check_event_id(1000000))
        self.assertIsNotNone(check_event_id(123))
        self.assertIsNotNone(check_event_id(7123456))
        self.assertIsNotNone(check_event_id(12345678))
        # 对话ID：10位，前7位=事件ID，后3位 001~999
        self.assertIsNone(check_dialog_id(1234567001, 1234567))
        self.assertIsNone(check_dialog_id(1234567999, 1234567))
        self.assertIsNotNone(check_dialog_id(1234567000, 1234567))
        self.assertIsNotNone(check_dialog_id(1234567001, 7654321))
        self.assertIsNotNone(check_dialog_id(12345671))
        # 选项ID：9位，后两位 01~99
        self.assertIsNone(check_option_id(123456701, 1234567))
        self.assertIsNotNone(check_option_id(123456700))
        self.assertIsNotNone(check_option_id(12345671))

    def test_validate_record_evt(self):
        from editor.core.guide_rules import validate_record
        ok = validate_record("EvtCfg", "1314170",
                             {"id": 1314170, "rate": 0.5, "type": 4,
                              "talkId": [1314170001]})
        self.assertFalse([1 for lv, _ in ok if lv == "error"], ok)
        bad = validate_record("EvtCfg", "7123456",
                              {"id": 7123456, "rate": 5, "type": 2, "npc": 0,
                               "talkId": []})
        self.assertTrue(any(lv == "error" for lv, _ in bad))
        self.assertTrue(any(lv == "warn" and ".rate" in m for lv, m in bad))
        self.assertTrue(any(lv == "warn" and ".npc" in m for lv, m in bad))
        self.assertTrue(any(lv == "warn" and ".talkId" in m for lv, m in bad))
        # 事件ID与首句对话ID前缀不匹配 → error（指南：无法预览）
        mis = validate_record("EvtCfg", "123", {"id": 123, "talkId": [123001]})
        self.assertTrue(any(lv == "error" and "talkId" in m for lv, m in mis))

    def test_validate_record_talk(self):
        from editor.core.guide_rules import validate_record
        ok = validate_record("TalkCfg", "1234567001",
                             {"id": 1234567001, "screenEffect": [4001, 0.5],
                              "roles": [[0, 3000, 1], [102, 1001, 0, 2]],
                              "highlights": [102], "bg": -1})
        self.assertFalse([1 for lv, _ in ok if lv in ("error", "warn")], ok)
        bad = validate_record("TalkCfg", "1234567001",
                              {"id": 1234567001, "roles": [[0, 1001, 1, 2], [0, 9999]],
                               "screenEffect": [9999], "highlights": [8888],
                               "bg": 77777})
        self.assertTrue(any("roles" in m for lv, m in bad if lv == "warn"))
        self.assertTrue(any("screenEffect" in m for lv, m in bad if lv == "warn"))
        self.assertTrue(any("highlights" in m for lv, m in bad if lv == "warn"))
        self.assertTrue(any(lv == "warn" and ".bg" in m for lv, m in bad))

    def test_validate_record_option(self):
        from editor.core.guide_rules import validate_record
        self.assertFalse(validate_record("OptionCfg", "123456701", {"id": 123456701}))
        self.assertTrue(any(lv == "error" for lv, _ in
                            validate_record("OptionCfg", "999", {"id": 999})))

    def test_describe_rows(self):
        from editor.core.guide_rules import describe_screen_row, describe_action_row
        d, e = describe_screen_row([4001, 0.5])
        self.assertEqual(d, "屏幕抖动 0.5 秒")
        self.assertFalse(e)
        self.assertTrue(describe_screen_row([9999])[1])
        d, e = describe_action_row([102, 1001, 0, 2])
        self.assertIn("薛诗蕾", d)
        self.assertFalse(e)
        self.assertTrue(describe_action_row([0, 1001, 1, 2])[1])  # 入场第3位应为0
        self.assertTrue(describe_action_row([0, 9999])[1])        # 未知指令
        self.assertIn("像素", describe_action_row([0, 3004, -100])[0])

    def test_validate_cross(self):
        from editor.core.guide_rules import validate_cross
        tables = {"EvtCfg": {"1314170": {"id": 1314170, "talkId": [9999999999]}},
                  "TalkCfg": {"1314170001": {"id": 1314170001,
                                             "nextTalk": [1314170002]}},
                  "OptionCfg": {}}
        issues = validate_cross(tables)
        self.assertTrue(any(lv == "error" and "首句" in m for lv, m in issues))
        self.assertTrue(any(lv == "warn" and "下一句" in m for lv, m in issues))
        clean = {"EvtCfg": {"1314170": {"id": 1314170, "talkId": [1314170001]}},
                 "TalkCfg": {"1314170001": {"id": 1314170001}},
                 "OptionCfg": {}}
        self.assertFalse([1 for lv, _ in validate_cross(clean)
                          if lv in ("error", "warn")])
        base = validate_cross({"EvtCfg": {"1314170": {"id": 1314170}},
                               "TalkCfg": {}, "OptionCfg": {}},
                              base_ids={"EvtCfg": {1314170}})
        self.assertTrue(any(lv == "info" and "覆盖原版" in m for lv, m in base))

    def test_suggest_next_id(self):
        from editor.core.guide_rules import suggest_next_id
        nid = suggest_next_id("EvtCfg", {"1314170": {}, "1000000": {}})
        self.assertTrue(nid is not None and 1000000 <= nid <= 1999999
                        and nid not in (1314170, 1000000))
        self.assertEqual(suggest_next_id("TalkCfg", {"1314170001": {}, "1314170002": {}}),
                         1314170003)
        self.assertEqual(suggest_next_id("OptionCfg", {"131417001": {}, "131417002": {}}),
                         131417003)
        self.assertEqual(suggest_next_id("TalkCfg", {}), 1000000001)
        self.assertEqual(suggest_next_id("ItemCfg", {"5": {}, "3": {}}), 6)
        nid = suggest_next_id("EvtCfg", {"1314170": {}},
                              base_ids={"EvtCfg": {1000000, 1234567}})
        self.assertNotIn(nid, (1314170, 1000000, 1234567))

    def test_validate_cfg_integration(self):
        from editor.cli.utils import validate_cfg
        issues = validate_cfg("EvtCfg", {"7123456": {"id": 7123456, "title": "x"}})
        self.assertTrue(any(lv == "error" for lv, _ in issues), issues)


if __name__ == "__main__":
    unittest.main()
