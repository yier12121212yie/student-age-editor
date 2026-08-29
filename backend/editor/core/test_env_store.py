# -*- coding: utf-8 -*-
"""env_store 单测：temperature=0 保持（确定性采样）不被 or 0.7 吞掉、
温度/数值字段夹取、写路径并发不丢更新。

运行方式（在 backend 目录下）：
    python -m unittest editor.core.test_env_store -v
"""
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from editor.core import env_store as s


class _EnvStoreBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.ai_path = Path(self._tmp.name) / ".editor_ai.json"
        self.env_path = Path(self._tmp.name) / "editor_env.json"

    def _patch_ai_path(self):
        return mock.patch.object(s, "ai_settings_path", return_value=self.ai_path)

    def _patch_env_path(self):
        return mock.patch.object(s, "env_path", return_value=self.env_path)


class NormalizeTest(unittest.TestCase):
    def test_zero_temperature_preserved(self):
        # 0.0 是合法值（确定性采样），不得被 `or 0.7` 替换
        out = s.normalize_ai_settings({"temperature": 0})
        self.assertEqual(out["temperature"], 0.0)

    def test_temperature_clamped_and_defaulted(self):
        self.assertEqual(s.normalize_ai_settings({"temperature": 99})["temperature"], 2.0)
        out = s.normalize_ai_settings({})
        self.assertEqual(out["temperature"], 0.7)
        self.assertEqual(s.normalize_ai_settings({"temperature": "abc"})["temperature"], 0.7)

    def test_tts_numeric_fields(self):
        out = s.normalize_ai_settings({"ttsSpeed": 5, "ttsVolume": 5, "ttsPitch": 99})
        self.assertEqual(out["ttsSpeed"], 2.0)
        self.assertEqual(out["ttsVolume"], 2.0)
        self.assertEqual(out["ttsPitch"], 12)

    def test_tts_zero_speed_volume_clamped_not_defaulted(self):
        # 0.0/0 是合法输入（静音/极慢），不得被 `or 1.0` 替换成 1.0
        out = s.normalize_ai_settings({"ttsSpeed": 0, "ttsVolume": 0})
        self.assertEqual(out["ttsSpeed"], 0.5)
        self.assertEqual(out["ttsVolume"], 0.5)

    def test_tts_provider_case_normalized(self):
        # 大小写/空白归一后才做取值域校验，避免 "MiniMax" 被静默清空
        self.assertEqual(
            s.normalize_ai_settings({"ttsProvider": "MiniMax"})["ttsProvider"],
            "minimax")
        self.assertEqual(
            s.normalize_ai_settings({"ttsProvider": "ALIYUN "})["ttsProvider"],
            "aliyun")
        self.assertEqual(
            s.normalize_ai_settings({"ttsProvider": "openai"})["ttsProvider"],
            "")

    def test_retry_settings_defaulted_and_clamped(self):
        out = s.normalize_ai_settings({})
        self.assertEqual(out["maxRetries"], 3)
        self.assertEqual(out["retryDelayMs"], 1000)
        out = s.normalize_ai_settings({"maxRetries": 99, "retryDelayMs": 99999})
        self.assertEqual(out["maxRetries"], 10)
        self.assertEqual(out["retryDelayMs"], 30000)
        out = s.normalize_ai_settings({"maxRetries": -1, "retryDelayMs": -5})
        self.assertEqual(out["maxRetries"], 0)
        self.assertEqual(out["retryDelayMs"], 0)

    def test_retry_zero_preserved_not_defaulted(self):
        # maxRetries=0 是合法值（关闭自动重连），不得被 `or` 兜底替换
        out = s.normalize_ai_settings({"maxRetries": 0})
        self.assertEqual(out["maxRetries"], 0)

    def test_retry_invalid_values_fall_back(self):
        out = s.normalize_ai_settings({"maxRetries": "abc", "retryDelayMs": "x"})
        self.assertEqual(out["maxRetries"], 3)
        self.assertEqual(out["retryDelayMs"], 1000)
        out = s.normalize_ai_settings({"maxRetries": "5", "retryDelayMs": "2500"})
        self.assertEqual(out["maxRetries"], 5)
        self.assertEqual(out["retryDelayMs"], 2500)


class WriteRoundTripTest(_EnvStoreBase):
    def test_zero_temperature_persists(self):
        with self._patch_ai_path():
            s.write_ai_settings({"temperature": 0.0})
            cur = s.read_ai_settings()
        self.assertEqual(cur["temperature"], 0.0)

    def test_patch_merges_and_keeps_other_fields(self):
        with self._patch_ai_path():
            s.write_ai_settings({"apiKey": "k1", "model": "m1"})
            s.write_ai_settings({"temperature": 1.0})
            cur = s.read_ai_settings()
        self.assertEqual(cur["apiKey"], "k1")
        self.assertEqual(cur["model"], "m1")
        self.assertEqual(cur["temperature"], 1.0)


class ConcurrentWriteTest(_EnvStoreBase):
    """并发写不丢更新：每个线程写 editor_env.json 的独立字段，全部完成后
    所有字段必须都在。读-合并-替换若不加锁串行，后写者会用读到的旧全量
    快照覆盖先写者的字段。"""

    def test_merge_editor_env_concurrent_distinct_keys(self):
        with self._patch_env_path():
            barrier = threading.Barrier(8)
            errors = []
            lock = threading.Lock()

            def worker(i):
                try:
                    barrier.wait()
                    s.merge_editor_env({"field_%d" % i: i * 10})
                except Exception as e:  # noqa: BLE001
                    with lock:
                        errors.append(e)

            threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            self.assertEqual(errors, [])
            merged = s.read_json(self.env_path)
        for i in range(8):
            self.assertEqual(merged.get("field_%d" % i), i * 10)


if __name__ == "__main__":
    unittest.main()