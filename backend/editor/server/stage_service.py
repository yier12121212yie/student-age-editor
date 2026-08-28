# -*- coding: utf-8 -*-
"""AI 舞台调度服务：把语义化的人物舞台指令（站位 / 移动 / 入场退场 / 表情 / 动作）
编码为 TalkCfg.roles 的二维指令数组，并可反向解码为中文描述。

供 AI 侧栏以自然语言修改剧情对白（TalkCfg）的人物表现，避免 AI 直接面对
roles 的数字编码。编码规范与官方 story_importer 的 ScriptParser 保持一致：

    - 角色指令： [角色ID, 动作类型ID, 参数...]
      - 3000 表情    [role, 3000, 表情ID]
      - 1001/1002/1003 入场（滑动/直接/底部） [role, 10xx, 1, 站位(1左2右3中)]
      - 2001/2002 退场（滑动/直接）           [role, 20xx]
      - 3004/3008 移动（左右/上下）           [role, 30xx, 位移]
      - 3001 微动 / 3002 震动 / 3005 转身 / 3006 换装 / 3007 镜像 / 3009 气泡
    - 屏幕/全局指令： [动作类型ID, 参数...]
      - 4001 屏幕抖动 / 4002 模糊 / 4003 清空特效 / 4004 展示道具 / 4006 延时
      - 4008 挂电话 / 4009 做旧 / 4010 反色 / 4011 睁眼闭眼 / 4012 闪白
      - 4015 播放CG / 4017 结束CG / 5001 纸条（编码为 [0, 5001, 纸条ID]）

本模块不依赖 HTTP，可直接被 selftest / 其他服务调用。
"""
import re

from editor.server.fs_tools import SandboxError

try:
    from editor.core.data_dicts import ROLE_DICT as _ROLE_DICT_SRC
except Exception:
    _ROLE_DICT_SRC = {}


# ---------------------------------------------------------------------------
# 舞台字典（与 story_service 的 EXPRESSION_MAP / ScriptParser 一致）
# ---------------------------------------------------------------------------

STAGE_EXPRESSIONS = {
    "0": "默认", "1": "开心", "2": "生气", "3": "伤心", "4": "害羞",
    "5": "喜欢", "6": "认真", "7": "疑惑", "8": "惊讶", "9": "得意",
    "10": "微笑", "11": "坏笑", "12": "担心", "13": "害怕", "14": "难过",
    "15": "咆哮", "16": "窘迫", "17": "不满", "18": "冷笑", "19": "无语",
    "20": "苦笑", "21": "挫败", "22": "尴尬", "23": "迷茫", "24": "嫌弃",
    "25": "俏皮", "26": "尴尬",
}

STAGE_POSITIONS = {"1": "左", "2": "右", "3": "中"}

# 动作类型表：type -> {name, aliases, category, role, params}
# category 同时是命令里的 action 取值；role=True 表示作用于某个角色。
# params 的 key 统一为 value / pos / expr / mode，含义见 desc。
STAGE_ACTIONS = {
    1001: {"name": "滑动入场", "aliases": ["入场"], "category": "入场", "role": True,
           "params": [{"key": "pos", "desc": "站位：左/中/右", "default": "中"}]},
    1002: {"name": "直接入场", "aliases": ["直接出现"], "category": "入场", "role": True,
           "params": [{"key": "pos", "desc": "站位：左/中/右", "default": "中"}]},
    1003: {"name": "底部入场", "aliases": ["从底部入场"], "category": "入场", "role": True,
           "params": [{"key": "pos", "desc": "站位：左/中/右", "default": "中"}]},
    2001: {"name": "滑动退场", "aliases": ["退场"], "category": "退场", "role": True,
           "params": []},
    2002: {"name": "直接退场", "aliases": ["消失"], "category": "退场", "role": True,
           "params": []},
    3000: {"name": "表情", "aliases": ["表情"], "category": "表情", "role": True,
           "params": [{"key": "expr", "desc": "表情名或表情ID（如 开心 / 1）", "required": True}]},
    3001: {"name": "微动", "aliases": ["跳一跳", "轻轻动"], "category": "动作", "role": True,
           "params": []},
    3002: {"name": "震动", "aliases": ["人物抖动"], "category": "动作", "role": True,
           "params": []},
    3004: {"name": "左右移动", "aliases": ["移动"], "category": "移动", "role": True,
           "params": [{"key": "value", "desc": "位移像素值（负=向左 正=向右）", "required": True}]},
    3005: {"name": "转身", "aliases": ["回头"], "category": "动作", "role": True,
           "params": []},
    3006: {"name": "换装", "aliases": ["换衣服"], "category": "动作", "role": True,
           "params": [{"key": "value", "desc": "服装ID（ClothTypeCfg）", "required": True}]},
    3007: {"name": "镜像", "aliases": ["左右翻转"], "category": "动作", "role": True,
           "params": []},
    3008: {"name": "上下移动", "aliases": [], "category": "移动", "role": True,
           "params": [{"key": "value", "desc": "位移像素值（负=向下 正=向上）", "required": True}]},
    3009: {"name": "气泡", "aliases": ["气泡表情", "emoji"], "category": "动作", "role": True,
           "params": [{"key": "value", "desc": "气泡ID", "required": True}]},
    4001: {"name": "屏幕抖动", "aliases": ["抖屏"], "category": "屏幕特效", "role": False,
           "params": [{"key": "value", "desc": "抖动强度，默认 1", "default": 1}]},
    4002: {"name": "模糊", "aliases": ["画面模糊"], "category": "屏幕特效", "role": False,
           "params": []},
    4003: {"name": "清空特效", "aliases": ["清除特效"], "category": "屏幕特效", "role": False,
           "params": []},
    4004: {"name": "展示道具", "aliases": ["显示道具"], "category": "屏幕特效", "role": False,
           "params": [{"key": "value", "desc": "道具ID（ItemCfg）", "required": True}]},
    4006: {"name": "延时", "aliases": ["等待", "一段时间"], "category": "屏幕特效", "role": False,
           "params": [{"key": "value", "desc": "延时秒数，默认 1", "default": 1}]},
    4008: {"name": "挂电话", "aliases": ["挂断"], "category": "屏幕特效", "role": False,
           "params": []},
    4009: {"name": "做旧", "aliases": ["陈旧效果"], "category": "屏幕特效", "role": False,
           "params": []},
    4010: {"name": "反色", "aliases": ["颜色反转"], "category": "屏幕特效", "role": False,
           "params": []},
    4011: {"name": "睁眼/闭眼", "aliases": ["睁眼", "闭眼"], "category": "屏幕特效", "role": False,
           "params": [{"key": "value", "desc": "0=睁眼 1=闭眼", "default": 0}]},
    4012: {"name": "闪白", "aliases": ["白闪"], "category": "屏幕特效", "role": False,
           "params": [{"key": "value", "desc": "闪白次数，默认 1", "default": 1}]},
    4015: {"name": "播放CG", "aliases": ["显示CG"], "category": "屏幕特效", "role": False,
           "params": [{"key": "value", "desc": "CG ID（CGCfg）", "required": True}]},
    4017: {"name": "结束CG", "aliases": ["关闭CG"], "category": "屏幕特效", "role": False,
           "params": []},
    5001: {"name": "纸条", "aliases": ["小纸条"], "category": "屏幕特效", "role": False,
           "params": [{"key": "value", "desc": "纸条ID", "required": True}]},
}

# action（命令的第一级分类）-> 允许的动作类型范围
ACTION_CATEGORY_TYPES = {
    "入场": {1001, 1002, 1003},
    "退场": {2001, 2002},
    "移动": {3004, 3008},
    "表情": {3000},
    "动作": {3001, 3002, 3005, 3006, 3007, 3009},
    "屏幕特效": set(STAGE_ACTIONS) - {1001, 1002, 1003, 2001, 2002, 3000,
                                      3001, 3002, 3004, 3005, 3006, 3007, 3008, 3009},
}

_ACTION_NAME_MAP = {}  # 名称（含别名）-> type
for _tid, _tdef in STAGE_ACTIONS.items():
    _ACTION_NAME_MAP[_tdef["name"]] = _tid
    for _alias in _tdef.get("aliases", []):
        _ACTION_NAME_MAP.setdefault(_alias, _tid)

_EXPR_NAME_MAP = {}
for _eid, _ename in STAGE_EXPRESSIONS.items():
    _EXPR_NAME_MAP[_ename] = int(_eid)
    # 数字字符串直接按数字处理（见 resolve_expr），这里仅收集名称
_EXPR_NAME_MAP.pop("尴尬", None)  # 22 与 26 重名，保留后者
_EXPR_NAME_MAP["尴尬"] = 26

_POS_NAME_MAP = {v: int(k) for k, v in STAGE_POSITIONS.items()}

_MODE_ENTER = {"滑动": 1001, "直接": 1002, "底部": 1003}
_MODE_LEAVE = {"滑动": 2001, "直接": 2002}


def get_role_dict():
    """角色 id -> 名称 字典（含旁白 -1）。"""
    return dict(_ROLE_DICT_SRC)


# ---------------------------------------------------------------------------
# 字典查询（供 AI 工具 get_stage_dicts）
# ---------------------------------------------------------------------------

def get_stage_dicts():
    """返回舞台调度全部字典：表情、动作、站位、角色。"""
    expressions = [{"id": int(k), "name": v} for k, v in
                   sorted(STAGE_EXPRESSIONS.items(), key=lambda kv: int(kv[0]))]
    actions = []
    for tid in sorted(STAGE_ACTIONS):
        t = STAGE_ACTIONS[tid]
        params = "；".join("%s：%s%s" % (p["key"], p["desc"],
                                         "" if p.get("required") else "（可选）")
                           for p in t["params"]) or "无参数"
        actions.append({
            "type": tid,
            "name": t["name"],
            "category": t["category"],
            "role": t["role"],
            "params": params,
        })
    positions = [{"id": int(k), "name": v} for k, v in
                 sorted(STAGE_POSITIONS.items(), key=lambda kv: int(kv[0]))]
    roles = [{"id": str(k), "name": v} for k, v in get_role_dict().items()]
    return {
        "expressions": expressions,
        "actions": actions,
        "positions": positions,
        "roles": roles,
    }


# ---------------------------------------------------------------------------
# 角色 / 表情 / 动作类型 解析
# ---------------------------------------------------------------------------

def resolve_role(ref, role_dict=None):
    """角色名或 ID -> 角色 ID（int）。支持「陈晓」/「101」等写法。"""
    if ref is None:
        raise SandboxError("缺少 role 参数（角色名或角色ID）")
    s = str(ref).strip()
    if not s:
        raise SandboxError("role 参数为空")
    if s.lstrip("-").isdigit():
        return int(s)
    d = role_dict if role_dict is not None else get_role_dict()
    for k, v in d.items():
        name = v if isinstance(v, str) else (v[0] if isinstance(v, (list, tuple)) and v else "")
        if name == s:
            try:
                return int(k)
            except (TypeError, ValueError):
                return k
    raise SandboxError("找不到角色「%s」，可先用 get_game_dicts(name=roles) 或 get_stage_dicts 核对角色名/ID" % s)


def resolve_expr(ref):
    """表情名或 ID -> 表情 ID（int，0-26）。"""
    if ref is None:
        raise SandboxError("缺少 expr 参数（表情名或表情ID）")
    s = str(ref).strip()
    if not s:
        raise SandboxError("expr 参数为空")
    if s.lstrip("-").isdigit():
        eid = int(s)
        if str(eid) in STAGE_EXPRESSIONS:
            return eid
        raise SandboxError("表情ID %s 不在范围内（0-26）" % s)
    eid = _EXPR_NAME_MAP.get(s)
    if eid is None:
        raise SandboxError("找不到表情「%s」，可先用 get_stage_dicts 查看表情列表" % s)
    return eid


def resolve_action_type(ref, category=None):
    """动作类型名或 ID -> 类型 ID（int）。category 限定时只接受该分类内的类型。"""
    if ref is None:
        raise SandboxError("缺少 type 参数（动作/特效名称或类型ID）")
    s = str(ref).strip()
    if not s:
        raise SandboxError("type 参数为空")
    tid = None
    if s.lstrip("-").isdigit():
        tid = int(s)
        if tid not in STAGE_ACTIONS:
            raise SandboxError("动作类型ID %s 不在舞台指令表中" % s)
    else:
        tid = _ACTION_NAME_MAP.get(s)
        if tid is None:
            raise SandboxError("找不到动作「%s」，可先用 get_stage_dicts 查看动作列表" % s)
    if category is not None and tid not in ACTION_CATEGORY_TYPES.get(category, set()):
        names = sorted(STAGE_ACTIONS[t2]["name"] for t2 in ACTION_CATEGORY_TYPES[category])
        raise SandboxError("动作「%s」不属于分类「%s」，该分类可用：%s" % (
            STAGE_ACTIONS[tid]["name"], category, "、".join(names)))
    return tid


def _as_int(value, label, default=None, minimum=None):
    """把命令参数转成 int；缺失用 default，非法抛错。"""
    if value is None:
        if default is not None:
            return default
        raise SandboxError("缺少 %s 参数（数值）" % label)
    try:
        v = int(str(value).strip().lstrip("+"))
    except (TypeError, ValueError):
        raise SandboxError("%s 应为数值，收到: %r" % (label, value))
    if minimum is not None and v < minimum:
        raise SandboxError("%s 不能小于 %s，收到: %s" % (label, minimum, v))
    return v


# ---------------------------------------------------------------------------
# 语义化指令 -> roles 编码
# ---------------------------------------------------------------------------

def _encode_one(cmd, role_dict):
    """把单条语义化舞台指令编码为 roles 中的一行。cmd 必须为 dict。"""
    if not isinstance(cmd, dict):
        raise SandboxError("指令应为对象，收到: %r" % (cmd,))
    action = (cmd.get("action") or "").strip()
    if not action:
        raise SandboxError("缺少 action 字段（入场/退场/移动/表情/动作/屏幕特效）")
    if action not in ACTION_CATEGORY_TYPES:
        raise SandboxError("未知 action「%s」，可选：%s" % (
            action, "、".join(sorted(ACTION_CATEGORY_TYPES))))

    if action == "表情":
        role = resolve_role(cmd.get("role"), role_dict)
        if role == -1:
            raise SandboxError("旁白（-1）不能设置表情")
        return [role, 3000, resolve_expr(cmd.get("expr"))]

    if action == "入场":
        role = resolve_role(cmd.get("role"), role_dict)
        if role == -1:
            raise SandboxError("旁白（-1）不能入场")
        mode = (cmd.get("mode") or "滑动").strip()
        if mode not in _MODE_ENTER:
            raise SandboxError("入场 mode 可选：滑动/直接/底部，收到: %r" % mode)
        pos = (cmd.get("pos") or "中").strip()
        if pos not in _POS_NAME_MAP:
            raise SandboxError("站位 pos 可选：左/中/右，收到: %r" % pos)
        return [role, _MODE_ENTER[mode], 1, _POS_NAME_MAP[pos]]

    if action == "退场":
        role = resolve_role(cmd.get("role"), role_dict)
        if role == -1:
            raise SandboxError("旁白（-1）不能退场")
        mode = (cmd.get("mode") or "滑动").strip()
        if mode not in _MODE_LEAVE:
            raise SandboxError("退场 mode 可选：滑动/直接，收到: %r" % mode)
        return [role, _MODE_LEAVE[mode]]

    if action == "移动":
        role = resolve_role(cmd.get("role"), role_dict)
        if role == -1:
            raise SandboxError("旁白（-1）不能移动")
        axis = (cmd.get("axis") or "横").strip()
        tid = 3004 if axis in ("横", "左右") else 3008 if axis in ("纵", "上下") else None
        if tid is None:
            raise SandboxError("移动 axis 可选：横/纵，收到: %r" % axis)
        value = _as_int(cmd.get("value"), "移动 value")
        return [role, tid, value]

    # 动作 / 屏幕特效：先解析 type，再按类型的参数要求补全
    category = action
    tid = resolve_action_type(cmd.get("type"), category=category)
    tdef = STAGE_ACTIONS[tid]
    base = [tid] if not tdef["role"] else [resolve_role(cmd.get("role"), role_dict), tid]
    if tdef["role"] and base[0] == -1:
        raise SandboxError("旁白（-1）不能执行动作「%s」" % tdef["name"])
    value = cmd.get("value")

    if tid == 4011:
        # 睁眼/闭眼：直接按别名区分
        raw = (cmd.get("type") or "").strip()
        return base + [1 if raw == "闭眼" else 0]
    if not tdef["params"]:
        return base
    # 必填参数统一由 value 承载（见 STAGE_ACTIONS.params），缺失时 _as_int 报错
    return base + [_as_int(value, "「%s」的 value" % tdef["name"],
                           default=next((p["default"] for p in tdef["params"]
                                         if "default" in p), None))]


def encode_commands(commands, role_dict=None):
    """把语义化舞台指令列表编码为 roles 二维数组。任一指令非法即整体报错。"""
    if commands is None:
        return []
    if not isinstance(commands, list):
        raise SandboxError("commands 应为指令数组")
    errors = []
    for idx, cmd in enumerate(commands):
        try:
            _encode_one(cmd, role_dict)
        except SandboxError as e:
            errors.append("第 %d 条%s" % (idx + 1, e))
    if errors:
        raise SandboxError("舞台指令解析失败，请修正后重试：\n" + "\n".join(errors))
    return [_encode_one(cmd, role_dict) for cmd in commands]


# ---------------------------------------------------------------------------
# roles -> 中文描述
# ---------------------------------------------------------------------------

def _clean_num(v):
    """数字清理：去末尾 .0。"""
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def describe_roles(roles, role_dict=None):
    """把 roles 二维数组解码为逐行中文描述（每行一条舞台指令）。"""
    if not roles:
        return "(无舞台指令)"
    d = role_dict if role_dict is not None else get_role_dict()
    out = []
    for item in roles:
        if not isinstance(item, (list, tuple)) or len(item) < 2:
            out.append("[未知指令] %s" % (item,))
            continue
        item = [_clean_num(x) for x in item]
        tid = item[1] if isinstance(item[1], int) and item[1] in STAGE_ACTIONS else None
        # 角色指令：[角色ID, 类型, 参数...]；否则尝试屏幕指令：[类型, 参数...]
        if tid is not None and STAGE_ACTIONS[tid]["role"]:
            out.append(_describe_role_cmd(item[0], tid, item[2:], d))
        elif item[0] in STAGE_ACTIONS and not STAGE_ACTIONS[item[0]]["role"]:
            out.append(_describe_screen_cmd(item[0], item[1:], d))
        elif len(item) >= 2 and item[1] == 5001:
            # 纸条编码为 [0, 5001, id]
            out.append("纸条：%s" % item[2] if len(item) > 2 else "纸条")
        else:
            out.append("[未知指令] %s" % (item,))
    return "\n".join(out)


def _role_name(role_id, role_dict):
    return role_dict.get(str(role_id), str(role_id))


def _describe_role_cmd(role_id, tid, params, role_dict):
    name = _role_name(role_id, role_dict)
    tdef = STAGE_ACTIONS[tid]
    if tid in (1001, 1002, 1003):
        pos = STAGE_POSITIONS.get(str(params[1]) if len(params) > 1 else "3", "?")
        return "%s%s到%s侧" % (name, tdef["name"].replace("入场", ""), pos)
    if tid in (2001, 2002):
        return "%s%s" % (name, tdef["name"])
    if tid == 3000:
        expr_id = str(params[0]) if params else "0"
        return "%s表情：%s" % (name, STAGE_EXPRESSIONS.get(expr_id, expr_id))
    if tid in (3004, 3008):
        val = params[0] if params else 0
        if tid == 3004:
            direction = "左" if val < 0 else "右"
        else:
            direction = "下" if val < 0 else "上"
        return "%s%s %s%s" % (name, tdef["name"], abs(val), direction)
    if tid == 3006 and params:
        return "%s换装（服装ID=%s）" % (name, params[0])
    if tid == 3009 and params:
        return "%s气泡（ID=%s）" % (name, params[0])
    return "%s%s" % (name, tdef["name"])


def _describe_screen_cmd(tid, params, role_dict):
    tdef = STAGE_ACTIONS[tid]
    if tid == 4011:
        return "画面%s" % ("闭眼" if params and params[0] == 1 else "睁眼")
    if tid == 5001:
        return "纸条：%s" % (params[0] if params else "?")
    if params:
        return "%s（%s）" % (tdef["name"], "、".join(str(p) for p in params))
    return tdef["name"]


# ---------------------------------------------------------------------------
# 对白舞台（TalkCfg 条目级）
# ---------------------------------------------------------------------------

def _load_talk(talk_id):
    """读取 TalkCfg 条目，返回 (talk_id, record)。"""
    from editor.server import ai_domain_service
    talk_id = str(talk_id).strip()
    if not talk_id:
        raise SandboxError("缺少 talk_id 参数")
    if not ai_domain_service.cfg_exists("TalkCfg"):
        from editor.server.ai_domain_service import _missing_cfg_error
        raise _missing_cfg_error("TalkCfg")
    data = ai_domain_service.load_cfg("TalkCfg")
    if talk_id not in data:
        raise SandboxError("TalkCfg 中不存在对白 id=%s（可用 list_domain_items(domain=story, table=TalkCfg) 查看）" % talk_id)
    record = data[talk_id]
    if not isinstance(record, dict):
        raise SandboxError("TalkCfg 的 id=%s 不是对象" % talk_id)
    return talk_id, record


def get_talk_stage(talk_id):
    """读取某条对白当前的舞台指令（roles）并解码为中文描述。"""
    tid, record = _load_talk(talk_id)
    roles = record.get("roles") or []
    return {
        "talk_id": tid,
        "roles": roles,
        "desc": describe_roles(roles),
    }


def encode_talk_stage(talk_id, commands, clear=False):
    """把语义化舞台指令编码为 roles，与当前对白已有指令合并后返回预览（不写盘）。"""
    tid, record = _load_talk(talk_id)
    old_roles = record.get("roles") or []
    added = encode_commands(commands, get_role_dict())
    new_roles = ([] if clear else list(old_roles)) + added
    return {
        "talk_id": tid,
        "clear": bool(clear),
        "old_roles": old_roles,
        "new_roles": new_roles,
        "old_desc": describe_roles(old_roles),
        "new_desc": describe_roles(new_roles),
        "added": len(added),
    }
