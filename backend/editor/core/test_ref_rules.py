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


def test_healed_keeps_exempt_sentinels():
    # 一键修复只剔除悬挂引用：合法豁免值 0/-1/-2（无/无限制语义）必须保留，
    # 否则 roleIds=[0,99999,6] 会被修成只剩 [6]，悄悄删掉「无说话人」哨兵。
    tables = {
        "PersonCfg": {"6": {"id": 6}},
        "TalkCfg": {"1": {"id": 1, "roleIds": [0, 99999, 6]}},
    }
    issues = ref_rules.check_refs(tables)
    dangling = [i for i in issues if i["cfg"] == "TalkCfg" and i["field"] == "roleIds"]
    assert len(dangling) == 1
    assert dangling[0]["healed"] == [0, 6]


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


class _LazyIds(dict):
    """模拟 bugfix_service._LazyIdSets：下标访问时惰性构建（显式 __getitem__），
    dict.get() 对缺键返回 None（这正是曾让原版 id 全集失效的坑）。"""

    def __init__(self, src):
        super().__init__()
        self._src = src

    def __getitem__(self, cfg):
        s = self.get(cfg)
        if s is None:
            s = set((self._src.get(cfg) or {}).keys())
            self[cfg] = s
        return s


def test_lazy_extra_ids_satisfy():
    tables = {
        "TalkCfg": {"1000001001": {"id": 1000001001}},
        "NpcActivityCfg": {"5": {"id": 5, "talkId": [2000000001]}},
    }
    # talkId 2000000001 只存在于原版：懒加载 extra 必须经下标访问取得
    extra = _LazyIds({"TalkCfg": {"2000000001": {"id": 2000000001}}})
    assert ref_rules.check_refs(tables, extra) == []


def test_lazy_extra_ids_enable_dangling_detection():
    # Mod 无目标表数据时，原版 id 全集也要支撑悬挂判定（不得整条规则静默跳过）
    tables = {"ActionCfg": {"1": {"id": 1, "evtId": 9999999}}}
    extra = _LazyIds({"EvtCfg": {"1000001": {"id": 1000001}}})
    issues = ref_rules.check_refs(tables, extra)
    assert len(issues) == 1
    assert issues[0]["cfg"] == "ActionCfg" and issues[0]["field"] == "evtId"


def test_bugfix_scan_base_ids_no_false_positive():
    # 端到端：scan_bugs 的 _LazyIdSets 传入原版数据，引用本体 TalkCfg id
    # 不应被误报（曾因 dict.get() 取不到 extra 而一律误报、可被一键修复误删）
    mod = {
        "TalkCfg": {"1000001001": {"id": 1000001001}},
        "NpcActivityCfg": {"5": {"id": 5, "talkId": [2000000001]}},
    }
    base = {"TalkCfg": {"2000000001": {"id": 2000000001}}}
    bugs = scan_bugs(mod, base)
    assert not [b for b in bugs if b["flag"] == "REF"]


def test_bg_cfg_pool_is_bg_dict():
    # 曾把 BgCfg 误映射到 MAP_DICT：地图 id 会被当成合法背景 id
    assert ref_rules._dict_keys("BgCfg") is ref_rules.BG_DICT


def _int_keys(d):
    out = set()
    for k in d:
        try:
            out.add(int(k))
        except (TypeError, ValueError):
            pass
    return out


def test_bg_field_rejects_map_only_ids():
    bg_only = _int_keys(ref_rules.BG_DICT) - _int_keys(ref_rules.MAP_DICT)
    map_only = _int_keys(ref_rules.MAP_DICT) - _int_keys(ref_rules.BG_DICT)
    assert bg_only and map_only, "BG_DICT 与 MAP_DICT 键集应有差异"
    tables = {"ActionCfg": {"1": {"id": 1, "bg": min(bg_only)}}}
    assert ref_rules.check_refs(tables) == []  # 字典池内的背景 id 合法
    tables_bad = {"ActionCfg": {"1": {"id": 1, "bg": min(map_only)}}}
    issues = ref_rules.check_refs(tables_bad)
    assert len(issues) == 1 and issues[0]["target"] == "BgCfg"


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