# -*- coding: utf-8 -*-
"""OOBE 向导落盘单测：apply_setup 的 AI 助手 / 云存储 / 完成标记扩展。

运行方式（在 backend 目录下）：
    python -m unittest editor.cli.test_oobe -v
"""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from editor.cli import oobe
from editor.core import env_store
from editor.server import cloud_sync


class _OobeBase(unittest.TestCase):
    """把 oobe.env_path 与 env_store.ai_settings_path 隔离到临时目录。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.env_file = root / "editor_env.json"
        self.ai_file = root / ".editor_ai.json"
        self.ws = root / "workspace"
        self._patches = [
            mock.patch.object(oobe, "env_path", return_value=self.env_file),
            mock.patch.object(env_store, "ai_settings_path", return_value=self.ai_file),
        ]
        for p in self._patches:
            p.start()
        self.addCleanup(self._stop_patches)

    def _stop_patches(self):
        for p in self._patches:
            p.stop()


class ApplySetupExtrasTest(_OobeBase):
    def test_ai_settings_written_and_marked_done(self):
        result = oobe.apply_setup(
            workspace=str(self.ws),
            ai_settings={"provider": "openai_compatible", "apiKey": "sk-test", "model": "m1"},
        )
        self.assertTrue(result["ai_settings"])
        self.assertTrue(result["done"])
        data = json.loads(self.ai_file.read_text(encoding="utf-8"))
        self.assertEqual(data["apiKey"], "sk-test")
        self.assertEqual(data["model"], "m1")
        env = json.loads(self.env_file.read_text(encoding="utf-8"))
        self.assertTrue(env["oobe_completed"])
        self.assertEqual(env["workspace_root"], str(self.ws))

    def test_empty_fields_not_overwrite_existing(self):
        # 先写一份含既有 TTS 的配置，再 apply_setup 只传空字符串，不得覆盖/清空
        env_store.write_ai_settings({"ttsProvider": "minimax", "ttsApiKey": "k0"})
        oobe.apply_setup(
            workspace=str(self.ws),
            ai_settings={"baseUrl": "", "apiKey": "", "ttsGroupId": ""},
        )
        data = json.loads(self.ai_file.read_text(encoding="utf-8"))
        self.assertEqual(data["ttsProvider"], "minimax")
        self.assertEqual(data["ttsApiKey"], "k0")

    def test_tts_fields_written(self):
        oobe.apply_setup(
            ai_settings={
                "ttsProvider": "minimax",
                "ttsApiKey": "k1",
                "ttsGroupId": "g1",
                "ttsVoice": "Cherry",
            },
        )
        data = json.loads(self.ai_file.read_text(encoding="utf-8"))
        self.assertEqual(data["ttsProvider"], "minimax")
        self.assertEqual(data["ttsGroupId"], "g1")
        self.assertEqual(data["ttsVoice"], "Cherry")


class ApplySetupCloudTest(_OobeBase):
    def setUp(self):
        super().setUp()
        # 云存储路径隔离：不落真实 workspace / cache
        self.cloud_file = Path(self._tmp.name) / "cloud_config.json"
        self._cloud_patch = mock.patch.object(
            cloud_sync, "_cloud_config_path", return_value=str(self.cloud_file))
        self._cloud_patch.start()
        self.addCleanup(self._cloud_patch.stop)

    def test_cloud_provider_written(self):
        result = oobe.apply_setup(
            workspace=str(self.ws),
            cloud_provider={"name": "本地", "type": "local",
                            "config": {"root": str(self.ws)}},
        )
        self.assertTrue(result["cloud_provider"])
        self.assertTrue(self.cloud_file.exists())
        data = json.loads(self.cloud_file.read_text(encoding="utf-8"))
        self.assertEqual(data["providers"][0]["type"], "local")
        self.assertEqual(data["providers"][0]["name"], "本地")
        self.assertEqual(data["providers"][0]["remote_root"], "mods")

    def test_unsupported_driver_does_not_block_done(self):
        result = oobe.apply_setup(
            ai_settings={"apiKey": "sk-1"},
            cloud_provider={"name": "x", "type": "bad_driver", "config": {}},
        )
        self.assertNotIn("cloud_provider", result)
        self.assertTrue(result.get("ai_settings"))
        self.assertTrue(result["done"])


if __name__ == "__main__":
    unittest.main()