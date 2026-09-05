# -*- coding: utf-8 -*-
"""官方《学生时代》Mod指南驱动的语义校验与 ID 建议。

规则来源：《学生时代》Mod指南（editor/《学生时代》Mod指南.note.html）：
- 事件ID固定为7位数（1XXXXXX），左边第一位固定为1，且应当唯一；
  非法：123（不足7位）、7123456（首位非1）、12345678（超过7位）。
- 第一句对话ID = 事件ID + 3位数（001~999，建议001）；不符合规则将无法预览。
- 对话ID为10位数，前7位为事件ID，后3位为001~999。
- 选项ID为9位数，前7位为事件ID，后两位为01~99（最多99个选项）。
- 发生概率（EvtCfg.rate）：0~1，1为100%、0为绝对不发生。
- 一句话只能填写一个屏幕效果；多个效果用分号间隔。
- 社交事件（type=2）需指定人物ID（指定对象）。
- 效果/前提文本框只允许数字、英文点号、英文逗号、英文分号（不含空格）。

本模块只做「指南语义层」校验，不关心 JSON 字段类型（那是 GAME_SCHEMA 的职责）。
校验结果与现有 validate_cfg 相同：返回 [(level, msg)]，level ∈ {"info","warn","error"}。
"""

import random
from collections import Counter

# ---------------------------------------------------------------------------
# 屏幕效果（指南第六节：常用屏幕效果）
#   screenEffect 为 1D Array，整行扁平存储：[code, arg1, arg2, ...]
#   spec: code -> (名称, (最少参数, 最多参数))
# ---------------------------------------------------------------------------
SCREEN_EFFECT_SPEC = {
    4001: ("屏幕抖动", (0, 1)),        # 4001 / 4001,X(X为秒)
    4002: ("背景模糊", (0, 0)),
    4003: ("清空背景特效", (0, 0)),
    4004: ("展示物品", (1, 1)),       # 4004,I（物品/书籍ID）
    4006: ("黑屏片刻后恢复", (0, 0)),
    4007: ("打电话", (2, 2)),         # 4007,Bg,Npc
    4008: ("挂断电话", (0, 0)),
    4009: ("背景陈旧", (0, 0)),
    4010: ("背景反色", (0, 0)),
    4011: ("闭眼程度(0睁眼~1全闭)", (1, 1)),   # 4011,X，X∈[0,1]
    4012: ("闪白屏(0不抖,X为抖X下)", (0, 1)),
    4015: ("播放CG", (1, 1)),         # 4015,CG
    4017: ("结束播放CG", (0, 0)),
}

# ---------------------------------------------------------------------------
# 人物控制指令（指南第五节：常用动作指令）
#   roles 为 2D Array，每行 [Npc, cmd, arg...]
#   spec: cmd -> (名称, (最少参数, 最多参数), 参数说明)
# ---------------------------------------------------------------------------
ACTION_CMD_SPEC = {
    1001: ("滑动入场", (2, 2), "第3位为0，第4位S∈{1左,2右,3中}"),
    1002: ("渐变出现入场", (2, 2), "第3位为0，第4位S∈{1左,2右,3中}"),
    1003: ("从底下钻出入场", (2, 2), "第3位为0，第4位S∈{1左,2右,3中}"),
    2001: ("滑出退场", (0, 0), ""),
    2002: ("原地退场(渐变)", (0, 0), ""),
    3000: ("设置表情", (1, 1), "E为表情ID"),
    3001: ("跳一跳", (0, 1), "X为跳跃次数"),
    3002: ("抖动", (0, 1), "X为秒数"),
    3004: ("水平移动", (1, 1), "X为像素(屏宽2560，向右为正)"),
    3005: ("水平翻转", (0, 0), ""),
    3006: ("设置服饰", (1, 1), "C为服饰ID(0常服，1校服)"),
    3007: ("镜像", (0, 0), ""),
    3008: ("垂直移动", (1, 1), "X为像素(屏高1440，向上为正)"),
    3009: ("设置Emoji", (1, 1), "Emoji为Emoji ID"),
}

# 表情ID（指南附录）：0为默认表情，仅用于展示/提示，非硬性校验（第八节允许自定义差分ID）。
EXPRESSION_DICT = {
    0: "无表情", 1: "高兴", 2: "生气", 3: "伤心", 4: "害羞", 5: "喜欢",
    6: "认真", 7: "疑惑", 8: "惊讶", 9: "得意", 10: "微笑", 11: "坏笑",
    12: "担心", 13: "害怕", 14: "难过", 15: "咆哮", 16: "窘迫", 17: "不满",
    18: "冷笑", 19: "无语", 20: "苦笑", 21: "挫败", 22: "喜极而泣",
    23: "迷茫", 24: "嫌弃", 25: "俏皮", 26: "尴尬",
}


# ---------------------------------------------------------------------------
# 通用小工具
# ---------------------------------------------------------------------------

def _to_int(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v) if float(v).is_integer() else None
    if isinstance(v, str):
        s = v.strip()
        if s.lstrip("-").isdigit():
            return int(s)
    return None


def _to_float(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        s = v.strip()
        try:
            return float(s)
        except ValueError:
            return None
    return None


def _norm_cfg_name(raw):
    """纯本地规范化：尽量对齐 GAME_SCHEMA 的驼峰表名（避免与 cli.utils 循环依赖）。"""
    raw = (raw or "").strip()
    if not raw:
        return raw
    base = raw.rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    if base.lower().endswith(".json"):
        base = base[:-5]
    try:
        from editor.core.game_schema import GAME_SCHEMA as GS
    except Exception:
        GS = {}
    if base in GS:
        return base
    low = base.lower()
    for key in GS:
        if key.lower() == low:
            return key
    return base


# ---------------------------------------------------------------------------
# ID 格式检查（指南第二章）
# ---------------------------------------------------------------------------

def check_event_id(value):
    """事件ID须为7位数且首位为1。返回错误消息或 None。"""
    n = _to_int(value)
    if n is None:
        return None  # 非数字由 validate_cfg 的 Number 类型检查负责
    s = str(n)
    if len(s) != 7 or not s.startswith("1"):
        return ("事件ID %s 不符合指南规则（须为7位数且首位为1，如 1314170）；"
                "非法示例：123（不足7位）、7123456（首位非1）、12345678（超过7位）" % s)
    return None


def check_dialog_id(value, event_id=None):
    """对话ID须为10位数，前7位为事件ID，后3位为001~999。返回消息或 None。"""
    n = _to_int(value)
    if n is None:
        return None
    s = str(n)
    if len(s) != 10:
        return ("对话ID %s 不是10位数（前7位为事件ID，后3位为001~999，如 1234567001）" % s)
    if not ("001" <= s[-3:] <= "999"):
        return ("对话ID %s 的后3位应为 001~999" % s)
    if event_id is not None and s[:7] != str(event_id):
        return ("对话ID %s 的前7位（%s）应等于事件ID %s" % (s, s[:7], event_id))
    return None


def check_option_id(value, event_id=None):
    """选项ID须为9位数，前7位为事件ID，后两位为01~99。返回消息或 None。"""
    n = _to_int(value)
    if n is None:
        return None
    s = str(n)
    if len(s) != 9:
        return ("选项ID %s 不是9位数（前7位为事件ID，后两位为01~99）" % s)
    if not ("01" <= s[-2:] <= "99"):
        return ("选项ID %s 的后两位应为 01~99" % s)
    if event_id is not None and s[:7] != str(event_id):
        return ("选项ID %s 的前7位（%s）应等于事件ID %s" % (s, s[:7], event_id))
    return None


# ---------------------------------------------------------------------------
# 单表规则
# ---------------------------------------------------------------------------

def _role_name(rid):
    try:
        from editor.core.data_dicts import ROLE_DICT
        return ROLE_DICT.get(str(rid))
    except Exception:
        return None


def _bg_name(bgid):
    try:
        from editor.core.data_dicts import BG_DICT
        return BG_DICT.get(str(bgid))
    except Exception:
        return None


def _validate_evt(rid, rec):
    issues = []
    eid = _to_int(rec.get("id"))

    if eid is None:
        issues.append(("warn", "%s: 事件缺少数字 ID（指南要求事件ID为7位数 1XXXXXX）" % rid))
    else:
        msg = check_event_id(eid)
        if msg:
            issues.append(("error", "%s.id: %s" % (rid, msg)))
        kid = _to_int(rid)
        if kid is not None and kid != eid:
            issues.append(("warn", "%s: 记录键名与 id 字段（%s）不一致，游戏按 id 读取" % (rid, eid)))

    # 指南：发生概率 0~1（1为100%，0为绝对不发生）
    rate = rec.get("rate")
    if rate is not None:
        fv = _to_float(rate)
        if fv is not None and fv and (fv < 0 or fv > 1):
            issues.append(("warn", "%s.rate: 发生概率 %s 超出 0~1（指南：1 为 100%% 发生，0 为绝对不发生）" % (rid, fv)))

    # 指南：社交事件需指定人物ID
    if _to_int(rec.get("type")) == 2 and not _to_int(rec.get("npc")):
        issues.append(("warn", "%s.npc: 社交触发事件（类型2）应指定人物ID，否则无法在对应人物身上发生剧情" % rid))

    # 指南：第一句对话ID = 事件ID + 3位数（001~999，建议001），不符合将无法预览
    talk_ids = rec.get("talkId")
    if not isinstance(talk_ids, list) or not talk_ids:
        issues.append(("warn", "%s.talkId: 事件缺少首句对话ID，游戏内将无法预览剧情" % rid))
    else:
        for t in talk_ids:
            msg = check_dialog_id(t, event_id=eid)
            if msg:
                issues.append(("error", "%s.talkId: %s" % (rid, msg)))

    # 事件ID唯一性、与原版覆盖：在 validate_cross 阶段处理
    return issues


def _validate_talk(rid, rec):
    issues = []
    tid = rec.get("id")
    msg = check_dialog_id(tid)
    if tid is None:
        issues.append(("warn", "%s: 对话缺少数字 ID（指南要求对话ID为10位数，后3位为001~999）" % rid))
    elif msg:
        issues.append(("error", "%s.id: %s" % (rid, msg)))

    # 屏幕效果（1D Array，整行扁平存储 [code, arg...]）
    se = rec.get("screenEffect")
    if isinstance(se, list) and se:
        _desc, errs = describe_screen_row(se)
        for e in errs:
            issues.append(("warn", "%s.screenEffect: %s" % (rid, e)))

    # 人物控制指令（2D Array，每行 [Npc, cmd, arg...]）
    roles = rec.get("roles")
    if isinstance(roles, list):
        for i, row in enumerate(roles):
            if not isinstance(row, list):
                issues.append(("warn", "%s.roles[%d]: 应为数组 [人物ID, 指令, 参数...]" % (rid, i)))
                continue
            _desc, errs = describe_action_row(row)
            for e in errs:
                issues.append(("warn", "%s.roles[%d]: %s" % (rid, i, e)))

    # 高亮人物：应为已知人物ID
    hl = rec.get("highlights")
    if isinstance(hl, list):
        for h in hl:
            if _role_name(h) is None:
                issues.append(("warn", "%s.highlights: 人物ID %s 不在人物字典中" % (rid, h)))

    # 背景：0=保留原背景，-1/-2=切换；其他应为已知背景图ID
    bg = rec.get("bg")
    if bg is not None:
        bi = _to_int(bg)
        if bi is None:
            issues.append(("warn", "%s.bg: 背景ID应为数字（0=保留原背景，-1/-2=切换）" % rid))
        elif bi not in (0, -1, -2) and _bg_name(bi) is None:
            issues.append(("warn", "%s.bg: 背景图ID %s 不在背景字典中（0=保留原背景，-1/-2=切换）" % (rid, bi)))

    return issues


def _validate_opt(rid, rec):
    issues = []
    oid = _to_int(rec.get("id"))
    if oid is None:
        issues.append(("warn", "%s: 选项缺少数字 ID（指南要求选项ID为9位数）" % rid))
    else:
        msg = check_option_id(oid)
        if msg:
            issues.append(("error", "%s.id: %s" % (rid, msg)))
        kid = _to_int(rid)
        if kid is not None and kid != oid:
            issues.append(("warn", "%s: 记录键名与 id 字段（%s）不一致" % (rid, oid)))
    return issues


def validate_record(cfg_name, rid, record):
    """对单条记录按指南做语义校验。返回 [(level, msg)]。

    与 validate_cfg 的分工：本函数处理指南规则（ID格式、概率、屏幕效果、动作指令等），
    不含字段类型检查；字段类型由 GAME_SCHEMA 校验。
    """
    if not isinstance(record, dict):
        return []
    cfg = _norm_cfg_name(cfg_name)
    if cfg == "EvtCfg":
        return _validate_evt(rid, record)
    if cfg == "TalkCfg":
        return _validate_talk(rid, record)
    if cfg == "OptionCfg":
        return _validate_opt(rid, record)
    return []


# ---------------------------------------------------------------------------
# 跨表引用校验
# ---------------------------------------------------------------------------

def _id_set(tables, cfg_name, base_ids):
    ids = set()
    data = tables.get(cfg_name) or {}
    if isinstance(data, dict):
        for k, v in data.items():
            n = _to_int(k)
            if n is None and isinstance(v, dict):
                n = _to_int(v.get("id"))
            if n is not None:
                ids.add(n)
    if base_ids:
        ids |= set(base_ids.get(cfg_name, ()))
    return ids


def _ref_entries(value):
    """把 1D Array 字段（可能是 int / list）归一成 iterable of int。"""
    if value is None:
        return []
    if isinstance(value, (int, str)):
        n = _to_int(value)
        return [n] if n is not None else []
    if isinstance(value, list):
        out = []
        for x in value:
            n = _to_int(x)
            if n is not None and n != 0:
                out.append(n)
        return out
    return []


def validate_cross(tables, base_ids=None):
    """跨表校验配置表之间的引用关系。tables: {cfg_name: data}。

    返回 [(level, msg)]。
    - 首句对话ID缺失（本Mod与原版均未找到）→ error（指南：无法预览）
    - 对话/选项/跳转引用缺失 → warn
    - 事件ID与原版事件冲突 → info（实机加载将覆盖原版）
    """
    # 同 ref_rules.check_refs：不能用真值判定，防止把常空的懒加载 id 映射
    # （如 bugfix_service._LazyIdSets）整体替换成 {}
    if base_ids is None:
        base_ids = {}
    evt_ids = _id_set(tables, "EvtCfg", base_ids)
    talk_ids = _id_set(tables, "TalkCfg", base_ids)
    opt_ids = _id_set(tables, "OptionCfg", base_ids)
    issues = []

    evt_data = tables.get("EvtCfg") or {}
    if isinstance(evt_data, dict):
        for rid, rec in evt_data.items():
            if not isinstance(rec, dict):
                continue
            eid = _to_int(rec.get("id"))
            if eid is not None:
                if base_ids.get("EvtCfg") and eid in base_ids["EvtCfg"]:
                    issues.append(("info", "事件 %s: 事件ID %s 与原版事件相同，实机加载时将覆盖原版事件" % (rid, eid)))
            for t in _ref_entries(rec.get("talkId")):
                if t not in talk_ids:
                    issues.append(("error", "事件 %s: 首句对话ID %s 在本Mod与原版中均不存在，无法预览剧情" % (rid, t)))
            for o in _ref_entries(rec.get("options")):
                if o not in opt_ids:
                    issues.append(("warn", "事件 %s: 引用的选项ID %s 不存在（本Mod与原版均未找到）" % (rid, o)))

    talk_data = tables.get("TalkCfg") or {}
    if isinstance(talk_data, dict):
        for rid, rec in talk_data.items():
            if not isinstance(rec, dict):
                continue
            tid = _to_int(rec.get("id"))
            if tid is not None and len(str(tid)) >= 7:
                prefix = str(tid)[:7]
                if int(prefix) not in evt_ids:
                    issues.append(("warn", "对话 %s: 对话ID %s 的前7位（%s）不对应任何事件ID" % (rid, tid, prefix)))
            for nt in _ref_entries(rec.get("nextTalk")) + _ref_entries(rec.get("nextTalk2")):
                if nt not in talk_ids:
                    issues.append(("warn", "对话 %s: 下一句对话ID %s 不存在（本Mod与原版均未找到）" % (rid, nt)))
            for o in _ref_entries(rec.get("option")):
                if o not in opt_ids:
                    issues.append(("warn", "对话 %s: 引用的选项ID %s 不存在（本Mod与原版均未找到）" % (rid, o)))

    opt_data = tables.get("OptionCfg") or {}
    if isinstance(opt_data, dict):
        for rid, rec in opt_data.items():
            if not isinstance(rec, dict):
                continue
            oid = _to_int(rec.get("id"))
            if oid is not None and len(str(oid)) >= 7:
                prefix = str(oid)[:7]
                if int(prefix) not in evt_ids:
                    issues.append(("warn", "选项 %s: 选项ID %s 的前7位（%s）不对应任何事件ID" % (rid, oid, prefix)))
            for t in _ref_entries(rec.get("talkId")) + _ref_entries(rec.get("talkId2")):
                if t not in talk_ids:
                    issues.append(("warn", "选项 %s: 跳转对话ID %s 不存在（本Mod与原版均未找到）" % (rid, t)))
            ne = _to_int(rec.get("nextEvtId"))
            if ne and ne not in evt_ids:
                issues.append(("warn", "选项 %s: 下一事件ID %s 不存在（本Mod与原版均未找到）" % (rid, ne)))

    # ---- 扩展：声明式跨表引用规则（其余表的字段级引用，见 ref_rules.py） ----
    # 仅在调用方传入全量表时生效（bugfix 全量扫描 / CLI-TUI validate）；
    # /api/validate 只载入三张核心表，超出范围的规则自然不触发。
    try:
        from editor.core import ref_rules as _ref
        for it in _ref.check_refs(tables, base_ids):
            issues.append(("warn", "%s %s: %s" % (it["cfg"], it["rid"], it["desc"])))
    except Exception:
        pass

    return issues


# ---------------------------------------------------------------------------
# 屏幕效果 / 动作指令 的描述与校验（供 API 的 validate/suggest 复用）
# ---------------------------------------------------------------------------

def describe_screen_row(row):
    """描述一行屏幕效果（扁平数组 [code, arg...]）。返回 (描述, [错误])。"""
    if not isinstance(row, list) or not row:
        return "", []
    code = _to_int(row[0])
    errs = []
    if code is None or code not in SCREEN_EFFECT_SPEC:
        return ("", ["不认识的屏幕效果代码 %r（指南第六节定义了 4001~4017 中的部分代码）" % (row[0] if code is None else code)])
    name, (lo, hi) = SCREEN_EFFECT_SPEC[code]
    nargs = len(row) - 1
    parts = []
    desc = name
    if nargs > 0:
        # 尝试翻译参数
        args_txt = ", ".join(str(x) for x in row[1:])
        if code == 4001 and nargs >= 1:
            desc = "屏幕抖动 %s 秒" % row[1]
        elif code == 4004 and nargs >= 1:
            desc = "展示物品/书籍 %s" % row[1]
        elif code == 4007 and nargs >= 2:
            bg = _bg_name(row[1]) or row[1]
            npc = _role_name(row[2]) or row[2]
            desc = "与背景图(%s)中的 %s 打电话" % (bg, npc)
        elif code == 4011 and nargs >= 1:
            desc = "闭眼程度 %s (0睁眼~1全闭)" % row[1]
        elif code == 4015 and nargs >= 1:
            desc = "播放CG %s" % row[1]
        else:
            desc = "%s (%s)" % (name, args_txt)
    if nargs < lo or nargs > hi:
        if lo == hi:
            expected = "应填 %d 个参数" % lo if lo else "不需参数"
        else:
            expected = "参数个数应为 %d~%d" % (lo, hi)
        errs.append("屏幕效果 %s %s（当前 %d 个）" % (code, expected, nargs))
    return desc, errs


def describe_action_row(row):
    """描述一行人物控制指令 [Npc, cmd, arg...]。返回 (描述, [错误])。"""
    if not isinstance(row, list) or len(row) < 2:
        return ("", ["动作指令应为数组 [人物ID, 指令, 参数...]（如 [0, 3000, 1]）"])
    npc = _to_int(row[0])
    cmd = _to_int(row[1])
    if npc is None:
        return ("", ["首项人物ID %r 不是数字" % (row[0])])
    if cmd is None or cmd not in ACTION_CMD_SPEC:
        return ("", ["不认识的指令代码 %r（指南第五节定义了 1001~3009 中的部分指令）" % (row[1] if cmd is not None else cmd)])
    name, (lo, hi), param_note = ACTION_CMD_SPEC[cmd]
    nargs = len(row) - 2
    errs = []
    if 1001 <= cmd <= 1003:
        # 入场：需 [Npc, cmd, 0, S]，S∈{1,2,3}
        if nargs != 2:
            errs.append("入场指令 %s 格式为 [人物ID, %s, 0, S]（S=1左/2右/3中）" % (cmd, cmd))
        elif row[2] not in (0, "0"):
            errs.append("入场指令 %s 第3位应为 0（如 [0, %s, 0, 1]）" % (cmd, cmd))
        elif _to_int(row[3]) not in (1, 2, 3):
            errs.append("入场指令 %s 的S（第4位）应为 1左/2右/3中" % cmd)
    elif nargs < lo or nargs > hi:
        if lo == hi:
            expected = "应填 %d 个参数" % lo if lo else "不需参数"
        else:
            expected = "参数个数应为 %d~%d" % (lo, hi)
        errs.append("指令 %s %s（当前 %d 个）" % (cmd, expected, nargs))
    # 数值范围软提示
    if cmd == 3000 and nargs >= 1:
        e = _to_int(row[2])
        if e is not None and e != 0 and e not in EXPRESSION_DICT:
            errs.append("表情ID %s 不在指南内置表（0默认/1-26常用；自定义差分ID可忽略此提示）" % e)
    if cmd == 3004 and nargs >= 1 and _to_float(row[2]) is None:
        errs.append("水平移动参数应为像素数值（屏宽2560，向右为正）")
    if cmd == 3008 and nargs >= 1 and _to_float(row[2]) is None:
        errs.append("垂直移动参数应为像素数值（屏高1440，向上为正）")
    npc_txt = _role_name(npc) or str(npc)
    desc = "%s %s" % (npc_txt, name)
    if nargs >= 1:
        if cmd == 3000:
            e = _to_int(row[2])
            desc = "%s 设置表情 %s" % (npc_txt, EXPRESSION_DICT.get(e, row[2]) if e is not None else row[2])
        elif cmd == 3006:
            c = row[2]
            cname = {0: "常服", 1: "校服"}.get(_to_int(c), c)
            desc = "%s 设置服饰 %s" % (npc_txt, cname)
        elif cmd in (3001, 3002):
            desc = "%s %s (%s)" % (npc_txt, name, row[2])
        elif cmd in (3004, 3008):
            desc = "%s %s %s 像素" % (npc_txt, name, row[2])
        elif cmd == 3009:
            desc = "%s 设置Emoji %s" % (npc_txt, row[2])
    return desc, errs


# ---------------------------------------------------------------------------
# 新建记录 ID 建议（指南第二章）
# ---------------------------------------------------------------------------

def _most_common_prefix(data):
    """统计现有记录 ID 前7位（事件ID段）的众数，作为对话/选项ID建议前缀。"""
    counter = Counter()
    for k, v in (data or {}).items():
        n = _to_int(k)
        if n is None and isinstance(v, dict):
            n = _to_int(v.get("id"))
        if n is not None and len(str(n)) >= 7:
            counter[str(n)[:7]] += 1
    if counter:
        return counter.most_common(1)[0][0]
    return "1000000"


def suggest_next_id(cfg_name, data, base_ids=None):
    """为新记录建议一个符合官方指南的下一个ID。

    - EvtCfg：随机 1XXXXXX，避开当前表已有 ID 与原版事件 ID（指南建议随机避免冲突）。
    - TalkCfg：取表内现有对话ID前7位段（众数，空表回退 1000000）+ 下一个 001~999。
    - OptionCfg：同上 + 下一个 01~99（最多99个选项）。
    - 其他表：沿用 max+1。
    返回 int 或 None（找不到合适ID）。
    """
    cfg = _norm_cfg_name(cfg_name)
    taken = set()
    for k in (data or {}):
        n = _to_int(k)
        if n is not None:
            taken.add(n)
    if base_ids:
        taken |= set(base_ids.get(cfg, ()))

    if cfg == "EvtCfg":
        for _ in range(1000):
            cand = 1_000_000 + random.randint(0, 999999)
            if cand not in taken:
                return cand
        cand = 1_000_000
        while cand in taken and cand < 10_000_000:
            cand += 1
        return cand if cand < 10_000_000 else None

    if cfg in ("TalkCfg", "OptionCfg"):
        prefix = _most_common_prefix(data)
        if cfg == "TalkCfg":
            span, width = (999, 3)
        else:
            span, width = (99, 2)
        for suf in range(1, span + 1):
            cand = int(prefix + str(suf).zfill(width))
            if cand not in taken:
                return cand
        return None

    return max(taken) + 1 if taken else None
