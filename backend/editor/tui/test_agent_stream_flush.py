# -*- coding: utf-8 -*-
"""TUI Agent 聊天流式攒批刷新回归测试。

回归背景：流式 delta 曾逐条 call_from_thread + 全量替换 TextArea.text（整篇重折行、
光标归零、滚动条跳动），表现为流式输出画面抽搐。现在 worker 只入队 _pending，
UI 侧 set_interval(0.1) 攒批做增量 insert。

本测试不依赖网络与真实 .editor_ai.json（fake 掉 read_ai_settings 走未配置分支）。
"""

import asyncio
import threading

import pytest
from textual.app import App
from textual.widgets import TextArea

from editor.tui.app import AgentChatScreen


class _Harness(App):
    def on_mount(self):
        self.push_screen(AgentChatScreen())


def _fake_settings():
    return {"provider": "openai_compatible", "baseUrl": "", "apiKey": "",
            "model": "", "temperature": 0.7}


@pytest.fixture()
def unconfigured(monkeypatch):
    monkeypatch.setattr("editor.core.env_store.read_ai_settings", _fake_settings)


def _mount_screen(pilot):
    screen = pilot.app.screen
    assert isinstance(screen, AgentChatScreen)
    return screen


def test_stream_burst_is_batched_and_lossless(unconfigured, monkeypatch):
    """worker 线程高频投递 300 条 delta：内容零丢失，且插入次数被攒批压缩。"""
    deltas = [f"词{i} " + ("\n" if i % 17 == 0 else "") for i in range(300)]
    expected_body = "".join(deltas)

    insert_calls = []
    orig_insert = TextArea.insert

    def counting_insert(self, text, location=None, **kwargs):
        insert_calls.append(text)
        return orig_insert(self, text, location, **kwargs)

    monkeypatch.setattr(TextArea, "insert", counting_insert)

    async def scenario():
        app = _Harness()
        async with app.run_test() as pilot:
            await pilot.pause()
            screen = _mount_screen(pilot)
            baseline = screen._transcript

            def burst():
                for d in deltas:
                    screen._on_text(d)

            worker = threading.Thread(target=burst)
            worker.start()
            worker.join()
            await asyncio.sleep(0.3)  # ≥ 3 个 flush 周期
            await pilot.pause()

            expected = baseline + expected_body
            assert screen._pending.empty()
            assert screen._transcript == expected
            assert screen.query_one("#agent-log", TextArea).text == expected
            # 攒批生效：300 条 delta 不应逐条 insert（旧行为会是 300）
            assert len(insert_calls) <= 5, len(insert_calls)

    asyncio.run(scenario())


def test_local_echo_flushes_immediately(unconfigured):
    """_append（本地回显）不受攒批影响，调用后立即可见。"""

    async def scenario():
        app = _Harness()
        async with app.run_test() as pilot:
            await pilot.pause()
            screen = _mount_screen(pilot)
            screen._append("你：把标题改掉\n")
            assert screen.query_one("#agent-log", TextArea).text.endswith("你：把标题改掉\n")

    asyncio.run(scenario())


def test_tool_result_and_round_text_flow_through_queue(unconfigured):
    """工具结果 / 轮边界也走同一队列，顺序与内容正确。"""
    async def scenario():
        app = _Harness()
        async with app.run_test() as pilot:
            await pilot.pause()
            screen = _mount_screen(pilot)
            baseline = screen._transcript

            screen._on_text("第一轮回复")
            screen._on_round_text("")
            screen._on_tool_result("update_record", "ok\n已更新 320101")
            await asyncio.sleep(0.25)
            await pilot.pause()

            expected = baseline + "第一轮回复\n" + "⚙ update_record → ok\n"
            assert screen._transcript == expected
            assert screen.query_one("#agent-log", TextArea).text == expected

    asyncio.run(scenario())
