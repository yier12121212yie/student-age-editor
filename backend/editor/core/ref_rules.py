# -*- coding: utf-8 -*-
"""跨表引用完整性规则：字段级 表→表/字典 引用校验。

guide_rules.validate_cross 只覆盖 EvtCfg/TalkCfg/OptionCfg 的主角跳转边
（talkId/nextTalk/nextTalk2/option/talkId2/nextEvtId）；本模块以声明式规则
覆盖其余配置表中指向 PersonCfg/MapCfg/BgCfg/AudioCfg/MinigameCfg/TalkCfg/
EvtCfg/OptionCfg/ActionCfg/ItemCfg 等目标表的字段引用。

引用语义：
- 目标为表：值 ∈ Mod 表 id ∪ 原版数据 id ∪ 豁免值（默认 {0, -1, -2}）
- 目标为字典池：值 ∈ 字典 key ∪ 豁免值
非法值按条上报（warn 级），不中断扫描。字段形态包括 Number 单值与
1D/2D Array，均展平为 int 列表后逐值判定。目标表完全没有数据（Mod 与原版
均无）时跳过该规则，避免误报。
"""
from editor.core.data_dicts import (
    ROLE_DICT, RELATION_DICT, ATTR_DICT, MAP_DICT, JOB_DICT, ITEM_DICT,
    BG_DICT, STATE_DICT, TEXT_DICT, NEGOTIATION_SKILL_DICT,
    NEGOTIATION_BUFF_DICT, GAME_DICT, KZONE_POST_DICT, KZONE_MESSAGE_DICT,
    PHONE_MSG_DICT,
)

# 默认豁免值：0 / -1 / -2 在游戏语义中通常表示"无/无限制"，不算悬挂引用。
DEFAULT_EXEMPT = (0, -1, -2)

# 声明式规则。array=True 表示字段按数组形态展开（1D/2D 均可）；
# target 为目标表名（字典池目标见 _dict_keys 映射）。
REF_RULES = [
    # --- 事件 / 对白 ---
    {"cfg": "EvtCfg", "field": "npc", "target": "PersonCfg"},
    {"cfg": "EvtCfg", "field": "mapId", "target": "MapCfg"},
    {"cfg": "EvtCfg", "field": "miniGame", "target": "MinigameCfg", "array": True},
    {"cfg": "TalkCfg", "field": "audio", "target": "AudioCfg"},
    {"cfg": "TalkCfg", "field": "roleIds", "target": "PersonCfg", "array": True},
    {"cfg": "TalkCfg", "field": "miniGame", "target": "MinigameCfg", "array": True},
    # --- 地点行为 ---
    {"cfg": "ActionCfg", "field": "evtId", "target": "EvtCfg"},
    {"cfg": "ActionCfg", "field": "map", "target": "MapCfg"},
    {"cfg": "ActionCfg", "field": "audio", "target": "AudioCfg"},
    {"cfg": "ActionCfg", "field": "bg", "target": "BgCfg"},
    {"cfg": "ActionCfg", "field": "next", "target": "ActionCfg"},
    {"cfg": "ActionEvtCfg", "field": "evts", "target": "EvtCfg", "array": True},
    # --- 物品 / 赠礼 ---
    {"cfg": "ItemCfg", "field": "talkId", "target": "TalkCfg"},
    {"cfg": "GiftEvtCfg", "field": "item", "target": "ItemCfg"},
    {"cfg": "GiftEvtCfg", "field": "npc", "target": "PersonCfg", "array": True},
    {"cfg": "GiftEvtCfg", "field": "talkId", "target": "TalkCfg", "array": True},
    # --- 互动 / 社交 ---
    {"cfg": "InteractCfg", "field": "npc", "target": "PersonCfg"},
    {"cfg": "InteractCfg", "field": "map", "target": "MapCfg", "array": True},
    {"cfg": "InteractCfg", "field": "talkId", "target": "TalkCfg"},
    {"cfg": "LoveDrawCfg", "field": "talkId", "target": "TalkCfg", "array": True},
    {"cfg": "LoveGreetingCfg", "field": "talkId", "target": "TalkCfg"},
    # --- 事件挂载 ---
    {"cfg": "TripSpotCfg", "field": "evtId", "target": "EvtCfg"},
    {"cfg": "ExpoEvtCfg", "field": "evtId", "target": "EvtCfg"},
    {"cfg": "AnimeConCfg", "field": "evtId", "target": "EvtCfg"},
    # --- 人物关联 ---
    {"cfg": "NegotiationPlayerCfg", "field": "npcId", "target": "PersonCfg"},
    {"cfg": "RenshengguanMemoryCfg", "field": "npcId", "target": "PersonCfg", "array": True},
    {"cfg": "NpcActivityCfg", "field": "map", "target": "MapCfg"},
    {"cfg": "NpcActivityCfg", "field": "npc", "target": "PersonCfg"},
    {"cfg": "NpcActivityCfg", "field": "talkId", "target": "TalkCfg", "array": True},
    {"cfg": "TalkInputMinigameCfg", "field": "talkId", "target": "TalkCfg", "array": True},
    # --- 场景 / 音频 ---
    {"cfg": "MapCfg", "field": "bg", "target": "BgCfg"},
    {"cfg": "BgCfg", "field": "audio", "target": "AudioCfg"},
    # --- 事件内对白表 ---
    {"cfg": "MovieCfg", "field": "talks", "target": "TalkCfg", "array": True},
    {"cfg": "NegotiationCfg", "field": "talks", "target": "TalkCfg", "array": True},
]


def _to_int_loose(v):
    """宽松数字归一：int / float(整数值) / "123" / "123.0" → int；其余 None。"""
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v) if v.is_integer() else None
    if isinstance(v, str):
        s = v.strip()
        if s.isdigit():
            return int(s)
        if s.endswith(".0") and s[:-2].isdigit():
            return int(s[:-2])
        return None
    return None


def _norm_ids(value):
    """展平任意形态（Number 单值 / 1D / 2D Array）为 int 列表。"""
    out = []

    def walk(v):
        if v is None:
            return
        if isinstance(v, list):
            for x in v:
                walk(x)
            return
        n = _to_int_loose(v)
        if n is not None:
            out.append(n)

    walk(value)
    return out


def _table_id_strs(table_data, extra):
    """目标表 id 集合（str 归一，容错 int/float/"123.0" 键与记录内 id 字段）。"""
    ids = set()
    for k in (table_data or {}):
        n = _to_int_loose(k)
        if n is None:
            ids.add(str(k))
        else:
            ids.add(str(n))
        if isinstance(table_data, dict) and isinstance(table_data.get(k), dict):
            rid = _to_int_loose(table_data[k].get("id"))
            if rid is not None:
                ids.add(str(rid))
    for k in (extra or ()):
        n = _to_int_loose(k)
        ids.add(str(n) if n is not None else str(k))
    return ids


def _dict_keys(dict_name):
    """字典池映射（与 bugfix_service 的字典定义保持一致）。"""
    return _DICT_POOL_MAP.get(dict_name)


# A12：映射表提为模块常量——旧实现每条规则调用都重建一次 14 项 dict
_DICT_POOL_MAP = {
    "PersonCfg": ROLE_DICT, "RelationCfg": RELATION_DICT,
    "ItemCfg": ITEM_DICT, "MapCfg": MAP_DICT, "BgCfg": BG_DICT,
    "PersonStateCfg": STATE_DICT, "TextCfg": TEXT_DICT,
    "NegotiationSkillCfg": NEGOTIATION_SKILL_DICT,
    "NegotiationBuffCfg": NEGOTIATION_BUFF_DICT,
    "GameCfg": GAME_DICT, "KZoneContentCfg": KZONE_POST_DICT,
    "AnimeKzoneContentCfg": KZONE_POST_DICT,
    "KZoneMessageBoardCfg": KZONE_MESSAGE_DICT,
    "PhoneMsgCfg": PHONE_MSG_DICT,
}


def check_refs(tables, extra_ids=None):
    """校验全部规则。tables: {cfg: {id: rec}}；extra_ids: {cfg: set/iterable}（原版数据 id）。

    返回 issues 列表，每项：
      {"cfg", "rid", "field", "value", "target", "array", "healed", "desc"}
    - value：字段原始值（供展示）；
    - healed：array 字段给出剔除悬挂引用后的 int 列表（可自动修复）；
      单值字段为 None（仅报告，不自动修）。
    """
    # 不能用 `or {}`：bugfix_service 的 _LazyIdSets 是常空 dict（数据存
    # self._src，下标访问时才构建），真值判定会把整个懒加载映射替换成 {}
    if extra_ids is None:
        extra_ids = {}
    issues = []
    # A12：目标表 id 集合按 target 缓存——TalkCfg 被约 9 条规则当目标，
    # 旧实现每条规则都重建一次大表 id 全集
    table_ids_cache = {}
    for rule in REF_RULES:
        data = tables.get(rule["cfg"]) or {}
        if not isinstance(data, dict):
            continue
        target = rule["target"]
        # 合法值集合 = 豁免值 ∪ 字典池（若该表有内置字典，如 ROLE_DICT/MAP_DICT）
        #           ∪ 目标表数据（Mod）∪ 原版数据（extra_ids）
        pool = _dict_keys(target)
        # extra_ids 可能是 bugfix_service 的 _LazyIdSets（下标访问时惰性构建）：
        # 必须走下标访问取原版 id 全集（dict.get 不触发惰性构建）；
        # 普通 dict 缺键时回退 None，语义不变
        try:
            extra = extra_ids[target]
        except KeyError:
            extra = None
        if target not in table_ids_cache:
            table_ids_cache[target] = _table_id_strs(tables.get(target), extra)
        table_ids = table_ids_cache[target]
        valid = set(str(e) for e in DEFAULT_EXEMPT)
        if pool:
            valid |= set(str(k) for k in pool)
        if table_ids:
            valid |= table_ids
        elif pool is None and not extra:
            # 目标表无字典池、Mod 与原版均无数据：无法判定悬挂，跳过该规则
            continue

        for rid, rec in data.items():
            if not isinstance(rec, dict):
                continue
            raw = rec.get(rule["field"])
            if raw is None or raw == "":
                continue
            vals = _norm_ids(raw)
            if not vals:
                continue
            bad = [v for v in vals if str(v) not in valid]
            if not bad:
                continue
            healed = None
            if rule.get("array"):
                # healed 的契约（见 docstring）是"剔除悬挂引用后的 int 列表"：
                # 豁免值 0/-1/-2 是合法语义（无/无限制），必须原样保留。
                healed = [v for v in vals if str(v) in valid]
            issues.append({
                "cfg": rule["cfg"], "rid": str(rid), "field": rule["field"],
                "value": raw, "target": target, "array": bool(rule.get("array")),
                "healed": healed,
                "desc": "字段'%s'引用了不存在的%s id %s" % (
                    rule["field"], target, "、".join(str(v) for v in bad)),
            })
    return issues