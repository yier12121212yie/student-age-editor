# -*- coding: utf-8 -*-
"""TTS 配音打通：bind_talk_audio 写回 TalkCfg.audio（引擎逐句配音通道）测试。"""
import json
import os
import tempfile
import unittest

from editor.server import tts_store


class BindTalkAudioTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.mod_root = os.path.join(self._tmp.name, "mod")
        self.cfg_dir = os.path.join(self.mod_root, "Cfgs", "zh-cn")
        os.makedirs(self.cfg_dir)
        self.talk_path = os.path.join(self.cfg_dir, "TalkCfg.json")
        with open(self.talk_path, "w", encoding="utf-8") as f:
            json.dump({
                "1000001001": {"id": 1000001001, "content": "h"},
                "1000001002": {"id": 1000001002, "content": "i"},
            }, f, ensure_ascii=False, indent=2)

    def _read(self):
        with open(self.talk_path, "r", encoding="utf-8-sig") as f:
            return json.load(f)

    def test_bind_sets_audio_with_snapshot(self):
        r = tts_store.bind_talk_audio(self.mod_root, "1000001002", 7)
        self.assertEqual(r, {"talkId": "1000001002", "audioCfgId": 7})
        data = self._read()
        self.assertEqual(data["1000001002"]["audio"], 7)
        # 只写目标对白，不影响其他记录
        self.assertNotIn("audio", data["1000001001"])
        # 覆盖前走 cfg_store 留了 .editor_history 快照
        hist = os.path.join(self.mod_root, ".editor_history")
        snaps = os.listdir(hist) if os.path.isdir(hist) else []
        self.assertTrue(any("TalkCfg" in s and s.endswith(".json") for s in snaps))

    def test_rebind_overwrites(self):
        tts_store.bind_talk_audio(self.mod_root, "1000001001", 3)
        tts_store.bind_talk_audio(self.mod_root, "1000001001", 9)
        self.assertEqual(self._read()["1000001001"]["audio"], 9)

    def test_missing_talk_raises(self):
        with self.assertRaises(tts_store.TtsStoreError):
            tts_store.bind_talk_audio(self.mod_root, "9999999001", 7)

    def test_missing_file_raises(self):
        mod2 = os.path.join(self._tmp.name, "mod2")
        os.makedirs(mod2)
        with self.assertRaises(tts_store.TtsStoreError):
            tts_store.bind_talk_audio(mod2, "1000001001", 7)


if __name__ == "__main__":
    unittest.main()