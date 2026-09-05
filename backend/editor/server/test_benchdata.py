# -*- coding: utf-8 -*-
"""benchdata 生成器回归：

- _join_rows 不得产出尾随逗号的非法 JSON（曾 join 后再拼一个分隔符）
- 单行按字节预算补齐到 ~405B（曾 padding 变量计算后弃用，总尺寸到不了
  40MB，generate 的 ±5% 断言直接 RuntimeError）

运行方式（在 backend 目录下）：
    python -m pytest editor/server/test_benchdata.py -q
"""
import json

from editor.server import benchdata as bd


def test_join_rows_produces_valid_json():
    rows = [bd._generate_row(i) for i in range(5)]  # id 0..4
    text = bd._join_rows(rows)
    data = json.loads(text)  # 尾随逗号会在此抛 JSONDecodeError
    assert isinstance(data, dict)
    assert set(data.keys()) == {"0", "1", "2", "3", "4"}


def test_row_padded_to_byte_budget():
    for rid in (0, 1, 12345, 98962):
        row = bd._generate_row(rid)  # 形如 '"12345": {...}' 的键控行片段
        assert len(row.encode("utf-8")) == bd._ROW_TARGET_BYTES, rid
        # 包一层花括号后必须是合法 JSON（无引号/反斜杠注入）
        json.loads("{" + row + "}")


def test_full_generation_within_size_tolerance(monkeypatch):
    # 缩规模全链路验证（500 行）：尺寸须落在 TARGET ±5% 内且整体可解析
    monkeypatch.setattr(bd, "NUM_ROWS", 500)
    expected = 500 * bd._ROW_TARGET_BYTES + 2 * 499 + 4  # 行间 ",\n" + 头尾
    monkeypatch.setattr(bd, "TARGET_SIZE", expected)
    monkeypatch.setattr(bd, "_TEXT_CACHE", None)
    text = bd.generate_synthetic_talk_cfg()
    data = json.loads(text)
    assert len(data) == 500
    assert bd.get_text_cache() == text
    # 真实规模只验证尺寸（40MB 全量解析过重）
    monkeypatch.setattr(bd, "_TEXT_CACHE", None)
    full = bd.generate_synthetic_talk_cfg()
    assert abs(len(full.encode("utf-8")) - bd.TARGET_SIZE) <= bd.TARGET_SIZE * 0.05
    assert full.startswith('{\n"0": {"id": "0"')
    assert full.endswith('"evt_type": 1}\n}')
