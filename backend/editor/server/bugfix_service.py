# -*- coding: utf-8 -*-
"""Mod 数据诊断与一键修复服务。

剥离自友商 services/bug_fixer.py 的 BugFixerDialog（scan_bugs / apply_single_fix）。
utils.format_to_display / parse_from_display 因依赖 PyQt6 而内联为纯逻辑副本。
无 GUI 依赖，供 HTTP API 层复用。
"""
import json

from editor.core.game_schema import GAME_SCHEMA
from editor.core.data_dicts import (
    ROLE_DICT, RELATION_DICT, ATTR_DICT, MAP_DICT, JOB_DICT, ITEM_DICT,
    STATE_DICT, TEXT_DICT, NEGOTIATION_SKILL_DICT, NEGOTIATION_BUFF_DICT,
    GAME_DICT, KZONE_POST_DICT, KZONE_MESSAGE_DICT, PHONE_MSG_DICT,
    CONDITION_SECONDARY_TEMPLATE_INDEX, EFFECT_SECONDARY_TEMPLATE_INDEX,
    validate_secondary_item,
)


# ---------------- format_to_display / parse_from_display（纯逻辑副本，原版见 utils.py） ----------------

def _field_type(key, cfg_name=None):
    try:
        return (GAME_SCHEMA.get(cfg_name or "", {}) or {}).get(key, "")
    except Exception:
        return ""


def format_to_display(val, key, cfg_name=None):
    if val is None:
        return ""
    field_type = _field_type(key, cfg_name)

    if field_type in ("String", "Number"):
        return str(val)

    if field_type == "2D Array" and isinstance(val, list):
        def extract_1d_arrays(arr):
            out = []
            for item in arr:
                if isinstance(item, list):
                    if len(item) > 0 and all(not isinstance(x, list) for x in item):
                        out.append(item)
                    else:
                        out.extend(extract_1d_arrays(item))
            return out

        flat_val = extract_1d_arrays(val)
        if not flat_val:
            return ""
        return ", ".join(json.dumps(x, ensure_ascii=False) for x in flat_val)

    if isinstance(val, list) and len(val) == 1 and isinstance(val[0], str):
        return val[0]
    s = json.dumps(val, ensure_ascii=False)
    if s.startswith("[") and s.endswith("]"):
        return s[1:-1].strip()
    return s


def parse_from_display(text, key, original_val=None, cfg_name=None):
    text = str(text).strip().rstrip(",; ")
    if text.lower() == "null" or text == "missing_key":
        text = ""

    field_type = _field_type(key, cfg_name)

    if field_type == "String":
        if not text:
            return "" if original_val == "" else None
        return text

    if not text:
        if field_type == "2D Array":
            return []
        if field_type == "1D Array":
            return []
        if field_type == "Number":
            return 0
        return original_val if original_val is not None else ""

    try:
        res = json.loads(text)
    except Exception:
        try:
            res = json.loads("[%s]" % text)
        except Exception:
            res = []

    if not isinstance(res, list):
        res = [res]

    if original_val is not None and field_type not in ("1D Array", "2D Array", "Number"):
        if isinstance(original_val, int):
            v = res[0]
            if isinstance(v, list) and len(v) > 0:
                v = v[0]
            try:
                return int(v)
            except Exception:
                return 0
        elif isinstance(original_val, list):
            if len(original_val) > 0 and isinstance(original_val[0], list):
                out = []
                for item in res:
                    if isinstance(item, list):
                        out.append(item)
                    else:
                        out.append([item])
                return out
            else:
                flat = []
                for item in res:
                    if isinstance(item, list):
                        flat.extend(item)
                    else:
                        flat.append(item)
                return flat

    if field_type == "1D Array":
        is_path_style = (original_val is None or (isinstance(original_val, list) and all(isinstance(x, str) for x in original_val)))
        if not res and is_path_style:
            return [part.strip() for part in text.split(",") if part.strip()]
        flat = []
        for item in res:
            if isinstance(item, list):
                flat.extend(item)
            else:
                flat.append(item)
        return flat

    elif field_type == "2D Array":
        if len(res) > 0 and all(not isinstance(x, list) for x in res):
            return [res]

        def flatten_to_2d(raw_list):
            out = []
            for item in raw_list:
                if isinstance(item, list):
                    if len(item) > 0 and any(isinstance(x, list) for x in item):
                        out.extend(flatten_to_2d(item))
                    else:
                        if len(item) == 0:
                            continue
                        out.append(item)
                else:
                    out.append([item])
            return out

        return flatten_to_2d(res)

    elif field_type == "Number":
        if len(res) > 0:
            v = res[0]
            if isinstance(v, list) and len(v) > 0:
                v = v[0]
            if isinstance(v, (int, float)):
                return v
            if isinstance(v, str) and v.lstrip("-").isdigit():
                return int(v)
            try:
                return float(v)
            except Exception:
                pass
        return 0
    else:
        return res[0] if res else 0


# ---------------- 扫描 ----------------

def _safe_array_value(mod_data, bugs, cfg_name, item_id, key, value, array_shape_bug_keys):
    """数组字段防呆：null/对象 → 报 bug 并返回 []；单值 → 包一层。"""
    if isinstance(value, list):
        return value
    if value is None or isinstance(value, dict):
        bug_key = (cfg_name, str(item_id), key)
        if bug_key in array_shape_bug_keys:
            return []
        array_shape_bug_keys.add(bug_key)
        bad_type = "null" if value is None else "object"
        bugs.append({
            "cfg": cfg_name, "id": str(item_id), "key": key, "val": value,
            "healed": [], "desc": "Field '%s' should be an array [], but is %s." % (key, bad_type),
            "flag": "SCHEMA_HEAL",
        })
        return []
    return [value]


def scan_bugs(mod_data, base_data, only_tables=None):
    """深度扫描 Mod 数据结构异常。返回 bug 列表（与友商 BugFixerDialog.scan_bugs 等价）。

    only_tables：可选表名集合。A11 一键修复的 remaining 重扫只需要被 touched
    的表——传入时跳过其他表的逐表扫描（跨表合法 id 全集仍按完整数据构建，
    避免只传子集时产生虚假「致命断层」）。
    """
    bugs = []
    if not GAME_SCHEMA:
        return [{"cfg": "", "id": "", "key": "", "val": None, "healed": None,
                 "desc": "未能加载 game_schema.py，无法进行深入扫描！", "flag": "ERROR"}]
    m_data = mod_data
    b_data = base_data or {}
    array_shape_bug_keys = set()

    def _skip(cfg_name):
        return only_tables is not None and cfg_name not in only_tables

    def add_bug(*args):
        if len(args) == 4:
            cfg_name, item_id, bug_level, detail = args
            bugs.append({"cfg": cfg_name, "id": str(item_id), "key": bug_level,
                         "val": detail, "healed": None, "desc": detail, "flag": "LOGIC"})
        elif len(args) == 7:
            cfg_name, item_id, key, original_val, healed_val, desc, fix_type = args
            bugs.append({"cfg": cfg_name, "id": str(item_id), "key": key, "val": original_val,
                         "healed": healed_val, "desc": desc, "flag": fix_type})

    # ================== 0. 准备全局合法数据库 ==================
    all_talks = set(str(k) for k in m_data.get("TalkCfg", {}) or {}).union(
        str(k) for k in (b_data.get("TalkCfg", {}) or {}))
    all_options = set(str(k) for k in m_data.get("OptionCfg", {}) or {}).union(
        str(k) for k in (b_data.get("OptionCfg", {}) or {}))

    valid_roles = set(str(k) for k in ROLE_DICT.keys())
    valid_relations = set(str(k) for k in RELATION_DICT.keys())
    valid_attrs = set(str(k) for k in ATTR_DICT.keys())
    valid_maps = set(str(k) for k in MAP_DICT.keys())
    valid_jobs = set(str(k) for k in JOB_DICT.keys())
    valid_items = set(str(k) for k in ITEM_DICT.keys())
    valid_states = set(str(k) for k in STATE_DICT.keys())
    valid_texts = set(str(k) for k in TEXT_DICT.keys())
    valid_negotiation_skills = set(str(k) for k in NEGOTIATION_SKILL_DICT.keys())
    valid_negotiation_buffs = set(str(k) for k in NEGOTIATION_BUFF_DICT.keys())
    valid_games = set(str(k) for k in GAME_DICT.keys())
    valid_kzone_posts = set(str(k) for k in KZONE_POST_DICT.keys())
    valid_kzone_messages = set(str(k) for k in KZONE_MESSAGE_DICT.keys())
    valid_phone_msgs = set(str(k) for k in PHONE_MSG_DICT.keys())

    for cfg_name_target, target_set in [
        ("PersonCfg", valid_roles),
        # 职业允许 mod 在 JobCfg 里自定义扩展：只拿内置 JOB_DICT 判定会把
        # 自定义职业 id 误报「严重越界」，甚至被一键修复改掉
        ("JobCfg", valid_jobs),
        ("RelationCfg", valid_relations),
        ("ItemCfg", valid_items),
        ("MapCfg", valid_maps),
        ("BgCfg", valid_maps),
        ("PersonStateCfg", valid_states),
        ("TextCfg", valid_texts),
        ("NegotiationSkillCfg", valid_negotiation_skills),
        ("NegotiationBuffCfg", valid_negotiation_buffs),
        ("GameCfg", valid_games),
        ("KZoneContentCfg", valid_kzone_posts),
        ("AnimeKzoneContentCfg", valid_kzone_posts),
        ("KZoneMessageBoardCfg", valid_kzone_messages),
        ("PhoneMsgCfg", valid_phone_msgs),
    ]:
        target_set.update(str(k) for k in (m_data.get(cfg_name_target, {}) or {}).keys())
        target_set.update(str(k) for k in (b_data.get(cfg_name_target, {}) or {}).keys())

    # ================== 1. 智能行为规则引擎 ==================
    available_secondary_dicts = {
        "ROLE": valid_roles, "RELATION": valid_relations, "ATTR": valid_attrs,
        "MAP": valid_maps, "JOB": valid_jobs, "ITEM": valid_items,
        "STATE": valid_states, "TEXT": valid_texts,
        "NEGOTIATION_SKILL": valid_negotiation_skills, "NEGOTIATION_BUFF": valid_negotiation_buffs,
        "GAME": valid_games, "KZONE_POST": valid_kzone_posts,
        "KZONE_MESSAGE": valid_kzone_messages, "PHONE_MSG": valid_phone_msgs,
    }

    # ================== 2. 逻辑断层与二维数组深度扫描 ==================
    array_keys = ["cond", "effect", "effect2", "precondition", "condition", "stateCond"]

    for cfg_name, cfg_dict in m_data.items():
        if not isinstance(cfg_dict, dict) or _skip(cfg_name):
            continue
        for item_id, item_data in cfg_dict.items():
            if not isinstance(item_data, dict):
                continue

            for key in ["talkId", "talkId2", "nextTalk", "nextTalk2"]:
                if key in item_data:
                    tids = _safe_array_value(m_data, bugs, cfg_name, item_id, key, item_data[key], array_shape_bug_keys)
                    for tid in tids:
                        tid_str = str(tid).replace("[", "").replace("]", "").strip()
                        if tid_str and tid_str != "0" and tid_str.lstrip("-").isdigit() and tid_str not in all_talks:
                            add_bug(cfg_name, item_id, "致命断层", "[%s] 指向了不存在的对话节点: %s" % (key, tid_str))

            for ak in array_keys:
                if ak not in item_data:
                    continue
                arr_2d = item_data[ak]
                if arr_2d is None or isinstance(arr_2d, dict):
                    _safe_array_value(m_data, bugs, cfg_name, item_id, ak, arr_2d, array_shape_bug_keys)
                    continue
                if isinstance(arr_2d, list) and len(arr_2d) > 0 and not isinstance(arr_2d[0], list):
                    if str(arr_2d[0]).lstrip("-").isdigit():
                        add_bug(cfg_name, item_id, ak, arr_2d, [arr_2d],
                                "💥降维异常：缺少外层方括号，引擎必须要求二维数组格式！", "SCHEMA_HEAL")
                        arr_2d = [arr_2d]
                if not isinstance(arr_2d, list):
                    continue
                for sub_arr in arr_2d:
                    if not isinstance(sub_arr, list) or len(sub_arr) == 0:
                        continue
                    current_index = EFFECT_SECONDARY_TEMPLATE_INDEX if ak in {"effect", "effect2"} else CONDITION_SECONDARY_TEMPLATE_INDEX
                    result = validate_secondary_item(sub_arr, current_index, available_secondary_dicts)
                    for error in result["errors"]:
                        add_bug(cfg_name, item_id, "严重越界", "[%s] %s" % (ak, error))

    # ================== 3. 特殊对话校验 ==================
    for talk_id, talk in (m_data.get("TalkCfg", {}) or {}).items():
        if _skip("TalkCfg"):
            break
        if not isinstance(talk, dict):
            continue
        for opt in _safe_array_value(m_data, bugs, "TalkCfg", talk_id, "option", talk.get("option", []), array_shape_bug_keys):
            opt_str = str(opt).replace("[", "").replace("]", "").strip()
            if opt_str and opt_str != "0" and opt_str.lstrip("-").isdigit() and opt_str not in all_options:
                add_bug("TalkCfg", talk_id, "致命断层", "选项数组包含不存在的 OptionCfg ID: %s" % opt_str)

        roles = _safe_array_value(m_data, bugs, "TalkCfg", talk_id, "roles", talk.get("roles", []), array_shape_bug_keys)
        if isinstance(roles, list):
            for r in roles:
                if isinstance(r, list) and len(r) > 0:
                    role_id = str(r[0]).replace("[", "").replace("]", "").strip()
                    if role_id and role_id not in ("0", "-1") and role_id.lstrip("-").isdigit() and role_id not in valid_roles:
                        add_bug("TalkCfg", talk_id, "角色异常", "发言人指向了不存在的人物ID: %s" % role_id)

    # ================== 4. 格式与规范扫描 ==================
    opt_cfg = m_data.get("OptionCfg", {}) or {}
    if not _skip("OptionCfg") and ("1" in opt_cfg or 1 in opt_cfg):
        add_bug("OptionCfg", "1", "id", 1, None,
                "💥恶性异常：发现由官方编辑器引发的选项ID为1报错，会使游戏引擎字典冲突卡死！", "FIX_OPTION_1")

    for tid, t_data in (m_data.get("TalkCfg", {}) or {}).items():
        if _skip("TalkCfg"):
            break
        if not isinstance(t_data, dict):
            continue
        opts = _safe_array_value(m_data, bugs, "TalkCfg", tid, "option", t_data.get("option", []), array_shape_bug_keys)
        if 1 in opts or "1" in opts or [1] in opts or ["1"] in opts:
            add_bug("TalkCfg", tid, "option", opts, None,
                    "💥恶性异常：引用的对话选项ID为1，将导致游戏读取字典冲突卡死！", "FIX_TALK_1")

    for gid, gdata in (m_data.get("GiftEvtCfg", {}) or {}).items():
        if _skip("GiftEvtCfg"):
            break
        if not isinstance(gdata, dict):
            continue
        if "npcId" in gdata:
            add_bug("GiftEvtCfg", gid, "npcId", gdata["npcId"], None,
                    "旧版数据 'npcId' 需要升级为 'npc'", "RENAME_NPC")
        if "condition" in gdata:
            add_bug("GiftEvtCfg", gid, "condition", gdata["condition"], None,
                    "旧版数据 'condition' 需要升级为 'cond'", "RENAME_COND")

    for cfg_name, cfg_data in m_data.items():
        if cfg_name not in GAME_SCHEMA or not isinstance(cfg_data, dict) or _skip(cfg_name):
            continue
        schema_rules = GAME_SCHEMA[cfg_name]
        for item_id, item_data in cfg_data.items():
            if not isinstance(item_data, dict):
                continue
            for key, original_val in list(item_data.items()):
                if key not in schema_rules:
                    continue
                try:
                    if schema_rules[key] in ("1D Array", "2D Array") and (original_val is None or isinstance(original_val, dict)):
                        _safe_array_value(m_data, bugs, cfg_name, item_id, key, original_val, array_shape_bug_keys)
                        continue
                    text_format = format_to_display(original_val, key, cfg_name=cfg_name)
                    healed_val = parse_from_display(text_format, key, original_val, cfg_name=cfg_name)

                    def check_overflow(v):
                        if isinstance(v, int) and not isinstance(v, bool):
                            return v > 2147483647 or v < -2147483648
                        if isinstance(v, list):
                            return any(check_overflow(x) for x in v)
                        return False

                    if check_overflow(healed_val) or check_overflow(original_val):
                        add_bug(cfg_name, item_id, key, original_val, None,
                                "💥 数值过大！超过引擎极限 2147483647 将直接崩溃！", "ERROR")
                        continue

                    if str(original_val) != str(healed_val):
                        add_bug(cfg_name, item_id, key, original_val, healed_val,
                                "格式错乱或冗余。底层要求为 %s 格式。" % schema_rules[key], "SCHEMA_HEAL")
                except Exception as e:
                    add_bug(cfg_name, item_id, key, original_val, None, "引擎解析失败: %s" % e, "ERROR")

    # ================== 5. 跨表引用完整性（声明式规则，ref_rules.py） ==================
    # 覆盖 guide_rules.validate_cross 之表的字段级引用（npc/mapId/audio/bg/evtId…）。
    # 数组字段给出 healed（剔除悬挂引用后可一键修复）；单值字段仅报告。
    # A16：base id 全集惰性构建——只为实际被引用到的目标表建 set，不预建全部表。
    try:
        from editor.core import ref_rules as _ref

        class _LazyIdSets(dict):
            def __init__(self, src):
                super().__init__()
                self._src = src

            def __getitem__(self, cfg):
                # 显式 Python 级 __getitem__：dict.get 不会触发惰性构建，
                # ref_rules.check_refs 以 `extra_ids[target]` 下标访问取原版
                # id 全集（见 check_refs 内 `is None` 判空注释——本实例恒为
                # 空 dict，靠真值判定会把它整体替换掉）
                s = self.get(cfg)
                if s is None:
                    s = set((self._src.get(cfg) or {}).keys())
                    self[cfg] = s
                return s

        base_ids = _LazyIdSets(b_data)
        for it in _ref.check_refs(m_data, base_ids):
            if _skip(it["cfg"]):
                continue
            desc = it["desc"]
            if it["healed"] is not None:
                add_bug(it["cfg"], it["rid"], it["field"], it["value"], it["healed"],
                        "%s（可一键修复：剔除悬挂引用）" % desc, "REF")
            else:
                add_bug(it["cfg"], it["rid"], it["field"], it["value"], None,
                        desc, "REF")
    except Exception as e:
        # B8：扫描器自身异常不得伪装成「无问题」——显式报 ERROR 条目
        bugs.append({"cfg": "", "id": "", "key": "", "val": None, "healed": None,
                     "desc": "引用完整性校验未完成（扫描器异常，非无问题）: %s: %s"
                             % (type(e).__name__, e),
                     "flag": "ERROR"})

    return bugs


# ---------------- 修复 ----------------

def _option_values(talk_data):
    if not isinstance(talk_data, dict):
        return []
    value = talk_data.get("option", [])
    if isinstance(value, list):
        return value
    if value is None or isinstance(value, dict):
        return []
    return [value]


def _row_key(bucket, _id):
    """在 bucket 里定位 _id 对应的真实键。

    内存表可能来自 json.load（键恒为 str）也可能来自其他链路（键为 int），
    依次试 `_id` / `int(_id)` / `str(int(_id))` 三种形态，让 int 键表也能修。
    找不到返回 None。
    """
    if not isinstance(bucket, dict):
        return None
    for cand in (_id, _try_int(_id), _int_key_str(_id)):
        if cand is not None and cand in bucket:
            return cand
    return None


def _try_int(_id):
    try:
        return int(str(_id))
    except (TypeError, ValueError):
        return None


def _int_key_str(_id):
    n = _try_int(_id)
    return None if n is None else str(n)


def _next_option_suffix(opt_cfg, evt_id):
    """扫描 evt_id 事件段内已用的选项 id 后缀，返回 max+1。

    B9：旧实现 `int(str(k)[-2:])` 只看末两位——后缀 ≥100 的历史键会被
    截错位、进而撞进其他事件的 id 段（事件×100+2 位是引擎硬约定）。
    这里按「去掉事件前缀后的剩余数字」完整解析，任何位数都不截断。
    后缀耗尽（>99）由调用方放弃自动修复，交回 remaining 让用户手工分配。
    """
    used = []
    for k in opt_cfg.keys():
        ks = str(k)
        if not ks.startswith(evt_id):
            continue
        tail = ks[len(evt_id):]
        if tail.isdigit():
            used.append(int(tail))
    return (max(used) + 1) if used else 1


def apply_fix(mod_data, bug):
    """应用单个修复（对应友商 apply_single_fix）。返回是否发生了修改。

    bug 结构：{"cfg", "id", "key", "val", "healed", "desc", "flag"}。
    LOGIC / ERROR 类不参与自动修复，返回 False。
    """
    cfg = bug.get("cfg")
    _id = str(bug.get("id"))
    key = bug.get("key")
    flag = bug.get("flag")

    if flag in ("LOGIC", "ERROR"):
        return False

    cfg_bucket = mod_data.get(cfg, {})
    row_key = _row_key(cfg_bucket, _id)
    if row_key is None and flag not in ("FIX_OPTION_1", "FIX_TALK_1"):
        return False

    changed = False

    if flag in ("FIX_OPTION_1", "FIX_TALK_1"):
        talk_cfg = mod_data.get("TalkCfg", {}) or {}
        opt_cfg = mod_data.get("OptionCfg", {}) or {}

        evt_id = None
        for tid, t_data in talk_cfg.items():
            opts = _option_values(t_data)
            if 1 in opts or "1" in opts or [1] in opts or ["1"] in opts:
                evt_id = str(tid)[:-3] if len(str(tid)) > 3 else str(tid)
                break

        if evt_id:
            # B9：事件段内完整解析已用后缀取 max+1；后缀 >99 会跨进他事件
            # id 段（引擎硬约定），此时放弃自动修复返回 False 交回 remaining
            new_suffix = _next_option_suffix(opt_cfg, evt_id)
            if new_suffix > 99:
                return False
            new_opt_id = int("%s%02d" % (evt_id, new_suffix))

            one_key = _row_key(opt_cfg, "1")
            if one_key is not None:
                opt_data = opt_cfg.pop(one_key)
                opt_data["id"] = new_opt_id
                opt_cfg[str(new_opt_id)] = opt_data
                changed = True

            for tid, t_data in talk_cfg.items():
                opts = _option_values(t_data)
                if 1 in opts or "1" in opts or [1] in opts or ["1"] in opts:
                    t_data["option"] = [new_opt_id if str(x).strip("[]") == "1" else x for x in opts]
                    changed = True
        return changed

    if flag == "RENAME_NPC":
        old_val = cfg_bucket[row_key].pop(key, [])
        text_format = format_to_display(old_val, "npc", cfg_name=cfg)
        cfg_bucket[row_key]["npc"] = parse_from_display(text_format, "npc", old_val, cfg_name=cfg)
        return True
    if flag == "RENAME_COND":
        old_val = cfg_bucket[row_key].pop(key, [])
        text_format = format_to_display(old_val, "cond", cfg_name=cfg)
        cfg_bucket[row_key]["cond"] = parse_from_display(text_format, "cond", old_val, cfg_name=cfg)
        return True

    if "healed" in bug and bug["healed"] is not None:
        cfg_bucket[row_key][key] = bug["healed"]
        return True
    return changed
