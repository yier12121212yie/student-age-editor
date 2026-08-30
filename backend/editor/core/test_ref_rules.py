# -*- coding: utf-8 -*-
"""ref_rules 跨表引用完整性测试。"""
from editor.core import ref_rules
from editor.core.guide_rules import validate_cross
from editor.server.bugfix_service import scan_bugs, apply_fix


def _mk(*args):
    return dict(args)


def test_valid_table_refs_pass():
    tables = {
        "ActionCfg": {"1": {"id": 1, "evtId": 1000001, "map": 101, "bg": 3}},
        "EvtCfg": {"1000001": {"id": 1000001}},
        "MapCfg": {"101": {"id": 101}},
        "BgCfg": {"3": {"id": 3}},
    }
    assert ref_rules.check_refs(tables) == []


def test_dangling_single_value_reported_no_heal():
    tables = {
        "EvtCfg": {"1000001": {"id": 1000001}},
        "ActionCfg": {"1": {"id": 1, "evtId": 9999999}},
    }
    issues = ref_rules.check_refs(tables)
    assert len(issues) == 1
    it = issues[0]
    assert it["cfg"] == "ActionCfg" and it["field"] == "evtId"
    assert it["target"] == "EvtCfg" and it["healed"] is None


def test_array_field_heals_dangling():
    tables = {
        "MapCfg": {"101": {"id": 101}, "102": {"id": 102}},
        "TalkCfg": {"1000001001": {"id": 1000001001}},
        "NpcActivityCfg": {"5": {"id": 5, "talkId": [1000001001, 2000000001]}},
    }
    issues = ref_rules.check_refs(tables)
    dangling = [i for i in issues if i["field"] == "talkId"]
    assert len(dangling) == 1
    assert dangling[0]["healed"] == [1000001001]


def test_exempt_values_pass():
    tables = {
        "ActionCfg": {"1": {"id": 1, "evtId": 0, "next": -1, "map": -2}},
        "EvtCfg": {"1000001": {"id": 1000001}},
    }
    assert ref_rules.check_refs(tables) == []


def test_extra_base_ids_satisfy():
    tables = {
        "PersonCfg": {"101": {"id": 101}},
        "BgCfg": {"5": {"id": 5}},
        "MapCfg": {"5": {"id": 5, "bg": 55}},
    }
    # 背景 55 只存在于原版数据（extra_ids），不应报悬挂
    extra = {"BgCfg": {55, 5}}
    assert ref_rules.check_refs(tables, extra) == []


def test_2d_array_flatten():
    tables = {
        "TalkCfg": {"1000001001": {"id": 1000001001}, "1000001002": {"id": 1000001002}},
        "GiftEvtCfg": {"1": {"id": 1, "talkId": [[1000001001], [7777777001]]}},
    }
    issues = ref_rules.check_refs(tables)
    dangling = [i for i in issues if i["field"] == "talkId"]
    assert len(dangling) == 1
    assert dangling[0]["value"] == [[1000001001], [7777777001]]
    assert dangling[0]["healed"] == [1000001001]


def test_missing_target_table_skipped():
    # 目标表 MinigameCfg 完全不存在：规则跳过，不误报
    tables = {
        "TalkCfg": {"1000001001": {"id": 1000001001, "miniGame": [1, 2]}},
    }
    assert ref_rules.check_refs(tables) == []


def test_float_string_id_normalized():
    tables = {
        "EvtCfg": {"1000001": {"id": 1000001}},
        "ActionCfg": {"1": {"id": 1, "evtId": "1000001.0"}},
    }
    assert ref_rules.check_refs(tables) == []


def test_guide_rules_cross_integration():
    tables = {
        "EvtCfg": {"1000001": {"id": 1000001}},
        "MapCfg": {"101": {"id": 101}},
        "ActionCfg": {"1": {"id": 1, "map": 999}},
    }
    issues = validate_cross(tables, {})
    assert any(l == "warn" and "ActionCfg" in m and "map" in m and "999" in m
               for l, m in issues)


def test_bugfix_scan_ref_and_apply():
    mod = {
        "TalkCfg": {"1000001001": {"id": 1000001001}, "1000001002": {"id": 1000001002}},
        "NpcActivityCfg": {"5": {"id": 5, "talkId": [1000001001, 2000000001]}},
    }
    bugs = scan_bugs(mod, {})
    ref_bugs = [b for b in bugs if b["flag"] == "REF"]
    assert ref_bugs, "应产出 REF 悬挂引用条目"
    assert ref_bugs[0]["healed"] == [1000001001]
    # apply_fix 支持剔除悬挂引用
    changed = apply_fix(mod, ref_bugs[0])
    assert changed
    assert mod["NpcActivityCfg"]["5"]["talkId"] == [1000001001]
    # 单值悬挂引用（无 healed）不自动修
    mod2 = {
        "EvtCfg": {"1000001": {"id": 1000001}},
        "ActionCfg": {"1": {"id": 1, "evtId": 9999999}},
    }
    bugs2 = scan_bugs(mod2, {})
    single = [b for b in bugs2 if b["flag"] == "REF" and b["key"] == "evtId"]
    assert single and single[0]["healed"] is None
    assert not apply_fix(mod2, single[0])