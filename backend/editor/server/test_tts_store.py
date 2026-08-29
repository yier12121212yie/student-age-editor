# -*- coding: utf-8 -*-
"""tts_store 单测：验证素材保存/列表/读取/删除的路径回环、audio/tts 子目录
越界拒绝、AudioCfg 并发登记的 id 唯一性与 url 约定、键名净化兜底。

运行方式（在 backend 目录下）：
    python -m unittest editor.server.test_tts_store -v
"""
import json
import os
import tempfile
import threading
import unittest
from unittest import mock

from editor.server import tts_store as s


class TtsStoreTestBase(unittest.TestCase):
    """每个用例一个临时 mod 根；音频目录由 save_audio 自动创建。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.mod_root = os.path.join(self._tmp.name, "mod")
        os.makedirs(self.mod_root)
        # AudioCfg 登记目标目录（register_audio_cfg 只依赖 cfg_dir）
        self.cfg_dir = os.path.join(self.mod_root, "Cfgs", "zh-cn")

    def _save(self, key="hello", ext="wav", audio=b"RIFF....fake"):
        return s.save_audio(self.mod_root, audio, ext, key=key, ogg=False)


class SaveListTest(TtsStoreTestBase):
    def test_list_returns_full_rel_path(self):
        # 保存后 list_materials 应返回 audio/tts/<key>.<ext> 完整相对路径，
        # 而非裸文件名（裸名传回 read/delete 会因前缀检查报 400）
        info = self._save(key="hello")
        self.assertEqual(info["path"], "audio/tts/hello.wav")
        items = s.list_materials(self.mod_root)
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["path"], "audio/tts/hello.wav")
        self.assertEqual(items[0]["ext"], "wav")
        self.assertEqual(items[0]["size"], len(b"RIFF....fake"))

    def test_list_empty_when_dir_missing(self):
        self.assertEqual(s.list_materials(self.mod_root), [])


class ReadDeleteRoundTripTest(TtsStoreTestBase):
    def test_read_and_delete_with_full_path(self):
        self._save(key="hello")
        blob = s.read_audio(self.mod_root, "audio/tts/hello.wav")
        self.assertEqual(blob, b"RIFF....fake")
        deleted = s.delete_material(self.mod_root, "audio/tts/hello.wav")
        self.assertEqual(deleted, "audio/tts/hello.wav")
        # 删除后再读取应报"不存在"
        with self.assertRaises(s.TtsStoreError) as cm:
            s.read_audio(self.mod_root, "audio/tts/hello.wav")
        self.assertIn("不存在", str(cm.exception))


class PathTraversalTest(TtsStoreTestBase):
    def setUp(self):
        super().setUp()
        # 造一个 audio/tts/ 之外的文件，用于验证 .. 穿越被拒绝
        os.makedirs(os.path.join(self.mod_root, "audio", "tts"))
        cfgs = os.path.join(self.mod_root, "Cfgs")
        os.makedirs(cfgs)
        with open(os.path.join(cfgs, "x.json"), "w", encoding="utf-8") as f:
            f.write("{}")

    def test_read_rejects_parent_escape(self):
        with self.assertRaises(s.TtsStoreError):
            s.read_audio(self.mod_root, "audio/tts/../Cfgs/x.json")
        # 被拒后目标文件必须仍然完好
        self.assertTrue(os.path.isfile(
            os.path.join(self.mod_root, "Cfgs", "x.json")))

    def test_delete_rejects_parent_escape(self):
        with self.assertRaises(s.TtsStoreError):
            s.delete_material(self.mod_root, "audio/tts/../Cfgs/x.json")
        self.assertTrue(os.path.isfile(
            os.path.join(self.mod_root, "Cfgs", "x.json")))


class SaveErrorTest(TtsStoreTestBase):
    def test_save_wraps_oserror(self):
        # 落盘失败（只读目录/磁盘满）必须包装成 TtsStoreError，而非裸 OSError
        with mock.patch("os.makedirs", side_effect=OSError("read-only")):
            with self.assertRaises(s.TtsStoreError) as cm:
                s.save_audio(self.mod_root, b"RIFF....", "wav",
                             key="k1", ogg=False)
        self.assertIn("保存音频失败", str(cm.exception))


class SymlinkEscapeTest(TtsStoreTestBase):
    def test_read_and_delete_reject_symlink_outside(self):
        # mod 内指向 audio/tts/ 外文件的 symlink：读/删都必须被拒
        secret = os.path.join(self.mod_root, "secret.txt")
        with open(secret, "w", encoding="utf-8") as f:
            f.write("top-secret")
        link_dir = os.path.join(self.mod_root, "audio", "tts")
        os.makedirs(link_dir)
        link = os.path.join(link_dir, "evil.wav")
        try:
            os.symlink(secret, link)
        except (OSError, NotImplementedError):
            self.skipTest("当前环境不允许创建符号链接")
        with self.assertRaises(s.TtsStoreError):
            s.read_audio(self.mod_root, "audio/tts/evil.wav")
        with self.assertRaises(s.TtsStoreError):
            s.delete_material(self.mod_root, "audio/tts/evil.wav")
        # 目标文件必须未被读取/删除影响
        with open(secret, "r", encoding="utf-8") as f:
            self.assertEqual(f.read(), "top-secret")


class RegisterAudioCfgTest(TtsStoreTestBase):
    def test_ids_increment_and_url_convention(self):
        # 空目录首次登记 id=1，再次登记 id=2；url 与落盘路径一致、不带扩展名
        self.assertEqual(
            s.register_audio_cfg(self.cfg_dir, "talk_intro", title="开场白"), 1)
        self.assertEqual(
            s.register_audio_cfg(self.cfg_dir, "talk_outro", title="结尾"), 2)
        with open(os.path.join(self.cfg_dir, "AudioCfg.json"),
                  "r", encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(data["1"]["url"], "audio/tts/talk_intro")
        self.assertEqual(data["2"]["url"], "audio/tts/talk_outro")
        self.assertEqual(data["1"]["name"], "开场白")

    def test_name_truncated_to_24_chars(self):
        long_title = "这" * 30
        s.register_audio_cfg(self.cfg_dir, "k1", title=long_title)
        with open(os.path.join(self.cfg_dir, "AudioCfg.json"),
                  "r", encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(len(data["1"]["name"]), 24)

    def test_concurrent_register_ids_unique(self):
        # 5 个线程同时登记：读-扫-写在锁内整体串行，id 必须互不重复
        barrier = threading.Barrier(5)
        ids = []
        errors = []
        lock = threading.Lock()

        def worker(n):
            try:
                barrier.wait()
                new_id = s.register_audio_cfg(self.cfg_dir, "k%d" % n)
                with lock:
                    ids.append(new_id)
            except Exception as e:  # noqa: BLE001
                with lock:
                    errors.append(e)

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(5)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        self.assertEqual(sorted(ids), [1, 2, 3, 4, 5])

    def test_missing_cfg_dir_rejected(self):
        with self.assertRaises(s.TtsStoreError):
            s.register_audio_cfg("", "k1")

    def test_register_wraps_oserror(self):
        # 登记写盘失败同样包装成 TtsStoreError（HTTP 路由/CLI 据此降级为 warning）
        with mock.patch("os.makedirs", side_effect=OSError("read-only")):
            with self.assertRaises(s.TtsStoreError) as cm:
                s.register_audio_cfg(self.cfg_dir, "k1")
        self.assertIn("登记 AudioCfg", str(cm.exception))


class SafeKeyTest(unittest.TestCase):
    def test_invalid_key_falls_back_to_timestamp(self):
        key = s._safe_key("bad key!/@#")
        self.assertRegex(key, r"^tts_\d+$")

    def test_empty_key_falls_back_to_timestamp(self):
        self.assertRegex(s._safe_key("  "), r"^tts_\d+$")
        self.assertRegex(s._safe_key(None), r"^tts_\d+$")

    def test_valid_key_kept(self):
        self.assertEqual(s._safe_key("talk_intro-01"), "talk_intro-01")


if __name__ == "__main__":
    unittest.main()
