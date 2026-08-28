# -*- coding: utf-8 -*-
"""Agent 工具注册表与离线执行器——ai_panel.dart _tools/_runTool 的 Python 移植。

14 个工具——13 个文本工具（GUI 的 generate_image / edit_image 不在终端版范围内）
+ 1 个终端版专属的并行子代理派生工具：
  领域 CRUD×6  list_domains / list_domain_items / get_domain_item /
               update_domain_item / create_domain_item / delete_domain_item
  字典         get_game_dicts
  文件（只读） list_files / read_file
  模组         list_mods
  舞台×3       get_stage_dicts / get_talk_stage / set_talk_stage
  子代理       spawn_subagents（由 engine 特判执行，把只读调研子任务
               并行分派给只读克隆工具集的子代理，见 READ_ONLY_TOOLS）

数据面直接复用 server 离线服务（ai_domain_service / stage_service / fs_tools），
经 ai_domain_service.set_offline_cfg_dir 注入「当前模组」，与 GUI 同一份逻辑
（schema 校验、自动备份、角色必填补全），不走 HTTP。

与 GUI 一致的安全语义：
  - update/create/delete/set_talk_stage 必须经 confirm(title, detail) -> bool 审批；
    未提供审批回调时写操作直接拒绝。
  - execute 的任何异常都折算成「工具执行失败: …」字符串回填给模型（对齐 dart）。
"""

import json
import os
from pathlib import Path

from ..server import ai_domain_service
from ..server import fs_tools
from ..server import stage_service
from ..server.fs_tools import SandboxError
from .client import ToolCall

# list_files 结果截断（与 dart _runTool 的 take(300) 一致）
_LIST_FILES_CAP = 300

# 子代理允许的只读工具（并行执行安全、无需审批；写操作一律由主代理完成）
READ_ONLY_TOOLS = frozenset({
    "list_domains", "get_game_dicts", "list_domain_items", "get_domain_item",
    "list_files", "read_file", "list_mods", "get_stage_dicts", "get_talk_stage",
})


def _jstr(data) -> str:
    """紧凑 JSON（对齐 dart jsonEncode：非 ASCII 不转义、无空格）。"""
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"))


def _diff_json(old: dict, new: dict) -> str:
    """字段级 diff（对齐 dart _diffJson：未变行原样、变更行 -/+ 成对）。"""
    keys = sorted(set(old) | set(new))
    lines = []
    for k in keys:
        ov = _jstr(old.get(k)) if k in old else None
        nv = _jstr(new.get(k)) if k in new else None
        if k in old and k in new and ov == nv:
            lines.append('  "%s": %s,' % (k, ov))
        else:
            if k in old:
                lines.append('- "%s": %s,' % (k, ov))
            if k in new:
                lines.append('+ "%s": %s,' % (k, nv))
    return "\n".join(lines)


class AgentTools:
    """离线工具执行器。use_mod() 设置「当前模组」上下文后即可 execute()。"""

    def __init__(self):
        self._mod_root: Path | None = None
        self._workspace_root: Path | None = None
        # 只读克隆标记（clone_readonly 置 True）：仅暴露/放行 READ_ONLY_TOOLS
        self._readonly: bool = False

    # ------------------------------------------------------------------ 上下文
    def use_mod(self, mod_root, workspace_root=None):
        """统一设置离线上下文：域服务的配置目录 + 文件工具的沙箱根。

        mod_root 为模组根目录；域服务注入的是其下 Cfgs/zh-cn
        （set_offline_cfg_dir 的约定，见 ai_domain_service）。传 None 清空注入，
        域服务回退 server.STATE（等价 GUI 行为）。
        """
        self._mod_root = Path(mod_root) if mod_root else None
        self._workspace_root = Path(workspace_root) if workspace_root else None
        cfg_dir = None
        if self._mod_root is not None:
            if self._mod_root.name == "zh-cn" and self._mod_root.parent.name == "Cfgs":
                cfg_dir = self._mod_root  # 允许直接传 Cfgs/zh-cn 路径
            else:
                cfg_dir = self._mod_root / "Cfgs" / "zh-cn"
        ai_domain_service.set_offline_cfg_dir(cfg_dir)

    def clone_readonly(self) -> "AgentTools":
        """克隆一个只读工具集（并行子代理专用）：继承当前模组/工作区上下文。

        只复制 use_mod 设置的 _mod_root/_workspace_root 两个属性；不重设
        域服务的全局注入（与 self 共用同一份离线上下文，线程内只读安全）。
        克隆打上 _readonly=True 后，tool_defs() 只暴露 READ_ONLY_TOOLS，
        _dispatch() 对其余工具一律拒绝（双保险），写操作不可能发生。
        """
        clone = AgentTools()
        clone._mod_root = self._mod_root
        clone._workspace_root = self._workspace_root
        clone._readonly = True
        return clone

    def _workspace(self) -> Path:
        """工作区根：显式指定 > CLI 工作区发现（env/注册表/创意工坊）> editor 根。"""
        if self._workspace_root:
            return self._workspace_root
        try:
            from ..cli import utils as cli_utils

            ws = cli_utils.resolve_workspace(None)
            if ws:
                return Path(ws)
        except Exception:
            pass
        from ..core.env_store import _editor_root

        return _editor_root()

    def _sandbox_root(self, scope: str) -> Path:
        """对齐 server/api.py EditorState.sandbox_root 的 scope→根目录语义。"""
        if scope == "workspace":
            return self._workspace()
        return self._mod_root or self._workspace()

    @property
    def mod_root(self) -> Path | None:
        return self._mod_root

    # ------------------------------------------------------------------ 工具定义
    # 参数 schema 与 dart _tools 逐字段一致（模型可见的描述文本不引入三端漂移）。
    TOOL_DEFS: list = [
        {
            "name": "list_domains",
            "description": "修改 mod 的第一步：列出所有可修改的创作领域（剧情、背景、人物、社交、恋爱等）及各领域包含的配置表。其他领域工具的参数 domain 从这里取值，用户要求改内容时先调用它",
            "parameters": {"type": "object", "properties": {}},
        },
        {
            "name": "get_game_dicts",
            "description": "查询游戏内置字典（角色/物品/地点/职业/属性/关系/背景/回合/事件类型/羽毛球模型等）的 id→名称对照。填写 role/npc/item/mapId/type 等 ID 字段前，先用它核对名称避免填错 ID。name 为空时列出可用字典；q 为关键词（匹配 id 或名称，可留空）",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "字典 id，如 roles/items/maps/jobs/attrs/relations/bgs/turns/evt_types/badminton_models；留空列出全部"},
                    "q": {"type": "string", "description": "关键词，可选，如角色名"},
                    "limit": {"type": "integer", "description": "返回条数上限，默认 30 最大 100"},
                },
            },
        },
        {
            "name": "list_domain_items",
            "description": "列出某领域下的条目（如剧情领域列出所有事件/对话/选项）。domain 见 list_domains；q 为关键词（匹配 id/名称/内容，可留空）；table 可限定单表；limit 默认 50 最大 200",
            "parameters": {
                "type": "object",
                "required": ["domain"],
                "properties": {
                    "domain": {"type": "string", "description": "领域 id（先调 list_domains 获取，如 story=剧情、background=背景）"},
                    "q": {"type": "string", "description": "关键词，可选"},
                    "table": {"type": "string", "description": "限定单表名（如 EvtCfg），可选"},
                    "limit": {"type": "integer", "description": "返回条数上限，可选"},
                },
            },
        },
        {
            "name": "get_domain_item",
            "description": "读取某领域单个条目的完整内容（含全部字段）。修改前务必先读取，确认理解后再改",
            "parameters": {
                "type": "object",
                "required": ["domain", "cfg", "id"],
                "properties": {
                    "domain": {"type": "string", "description": "领域 id（见 list_domains）"},
                    "cfg": {"type": "string", "description": "配置表名，如 EvtCfg/TalkCfg/BgCfg/PersonCfg"},
                    "id": {"type": "string", "description": "条目 id（来自 list_domain_items）"},
                },
            },
        },
        {
            "name": "update_domain_item",
            "description": "修改某领域条目的字段（patch 为要改的字段集合，只改给出的字段，其余保持不动）。会先展示改动并等待用户确认",
            "parameters": {
                "type": "object",
                "required": ["domain", "cfg", "id", "patch"],
                "properties": {
                    "domain": {"type": "string", "description": "领域 id（见 list_domains）"},
                    "cfg": {"type": "string", "description": "配置表名"},
                    "id": {"type": "string", "description": "条目 id"},
                    "patch": {"type": "object", "description": "要修改的字段，如 {\"title\": \"新标题\"}；修改对白（TalkCfg）的说话人时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds"},
                },
            },
        },
        {
            "name": "create_domain_item",
            "description": "在某领域配置表新建条目。data 需包含 id 及至少一个字段；id 与现有条目重复会失败",
            "parameters": {
                "type": "object",
                "required": ["domain", "cfg", "data"],
                "properties": {
                    "domain": {"type": "string", "description": "领域 id（见 list_domains）"},
                    "cfg": {"type": "string", "description": "配置表名"},
                    "data": {"type": "object", "description": "新条目内容，如 {\"id\": 101, \"name\": \"新角色\"}；创建对白（TalkCfg）时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds"},
                },
            },
        },
        {
            "name": "delete_domain_item",
            "description": "删除某领域配置表的条目（不可恢复，需用户确认）",
            "parameters": {
                "type": "object",
                "required": ["domain", "cfg", "id"],
                "properties": {
                    "domain": {"type": "string", "description": "领域 id（见 list_domains）"},
                    "cfg": {"type": "string", "description": "配置表名"},
                    "id": {"type": "string", "description": "条目 id"},
                },
            },
        },
        {
            "name": "list_files",
            "description": "列出模组或工作区目录下的文件（只读探索用；scope: mod=当前模组, workspace=工作区；path 为相对路径，空为根目录）",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "相对路径，默认根目录"},
                    "scope": {"type": "string", "enum": ["mod", "workspace"], "description": "mod=当前模组目录, workspace=工作区"},
                },
            },
        },
        {
            "name": "read_file",
            "description": "读取模组文件内容（只读探索用，修改内容请使用领域工具 update_domain_item）。path 为相对模组根目录的路径",
            "parameters": {
                "type": "object",
                "required": ["path"],
                "properties": {
                    "path": {"type": "string"},
                },
            },
        },
        {
            "name": "list_mods",
            "description": "列出所有可用模组",
            "parameters": {"type": "object", "properties": {}},
        },
        {
            "name": "get_stage_dicts",
            "description": "查询剧情对白的「舞台调度」字典：人物表情（0-26）、人物动作/入场退场/移动类型、站位（左/中/右）、角色列表。修改人物站位、移动、入场退场、表情、动作前先调用它核对名称与ID",
            "parameters": {"type": "object", "properties": {}},
        },
        {
            "name": "get_talk_stage",
            "description": "读取某条对白（TalkCfg 条目）当前的人物舞台安排（站位/移动/入场退场/表情/动作），返回中文描述。修改舞台前先调用，确认理解当前状态",
            "parameters": {
                "type": "object",
                "required": ["talk_id"],
                "properties": {
                    "talk_id": {"type": "string", "description": "对白ID（TalkCfg 条目 id，来自 list_domain_items）"},
                },
            },
        },
        {
            "name": "set_talk_stage",
            "description": "修改某条对白的人物舞台：人物站位（入场到左/中/右）、移动、入场退场、人物表情、人物动作。commands 为语义化指令数组，每条含 action（入场/退场/移动/表情/动作/屏幕特效），role 用角色名或ID，其余按动作类型补参数。示例：[{\"action\":\"入场\",\"role\":\"薛诗蕾\",\"mode\":\"滑动\",\"pos\":\"左\"},{\"action\":\"表情\",\"role\":\"102\",\"expr\":\"开心\"},{\"action\":\"移动\",\"role\":\"102\",\"value\":-80},{\"action\":\"退场\",\"role\":\"102\",\"mode\":\"滑动\"},{\"action\":\"动作\",\"role\":\"102\",\"type\":\"转身\"},{\"action\":\"屏幕特效\",\"type\":\"屏幕抖动\",\"value\":2}]。clear 为 true 时先清空该对白原有舞台指令，默认保留并追加。写前先 get_talk_stage 查看当前安排、get_stage_dicts 核对动作/表情/站位名称；修改会先展示改动并等待用户确认",
            "parameters": {
                "type": "object",
                "required": ["talk_id", "commands"],
                "properties": {
                    "talk_id": {"type": "string", "description": "对白ID（TalkCfg 条目）"},
                    "commands": {"type": "array", "description": "舞台指令数组，每项为对象，字段见 description 示例（action/role/mode/pos/expr/type/value/axis）"},
                    "clear": {"type": "boolean", "description": "是否先清空原有舞台指令，默认 false"},
                },
            },
        },
        {
            "name": "spawn_subagents",
            "description": "把可独立完成的只读调研子任务并行分派给多个子代理（1-4 个，并行执行）。每个子代理只有只读查询工具（list_domains/get_game_dicts/list_domain_items/get_domain_item/list_files/read_file/list_mods/get_stage_dicts/get_talk_stage）、看不到主对话历史，所以 task 必须自包含全部上下文：写清要查的领域、关键词/ID、输出要求；name 是简短标题。适合同时查多个领域、批量核对多条数据等互不依赖的调研；写操作一律由你自己完成，子代理只返回调研结论",
            "parameters": {
                "type": "object",
                "required": ["tasks"],
                "properties": {
                    "tasks": {
                        "type": "array",
                        "description": "子任务列表（1-4 个）",
                        "items": {
                            "type": "object",
                            "required": ["name", "task"],
                            "properties": {
                                "name": {"type": "string", "description": "简短标题"},
                                "task": {"type": "string", "description": "完整自包含的任务描述"},
                            },
                        },
                    },
                },
            },
        },
    ]

    def tool_defs(self) -> list:
        """返回工具定义（openai function 格式；anthropic 由 client 层转换）。

        只读克隆（_readonly=True）只返回 name 在 READ_ONLY_TOOLS 里的定义
        （spawn_subagents 等不对子代理暴露，防止递归派生）。
        """
        if self._readonly:
            return [t for t in self.TOOL_DEFS if t.get("name") in READ_ONLY_TOOLS]
        return self.TOOL_DEFS

    # ------------------------------------------------------------------ 执行
    def execute(self, call: ToolCall, confirm=None) -> str:
        """执行一次工具调用并返回结果字符串（直接回填给模型）。

        confirm(title, detail) -> bool 为写操作审批回调，由 UI 层注入
        （CLI 终端 y/N、TUI 弹窗）；None 时写操作一律拒绝。
        """
        try:
            return self._dispatch(call, confirm)
        except Exception as exc:  # 与 dart _runTool 的 catch 一致：错误回填模型
            return f"工具执行失败: {exc}"

    def _dispatch(self, call: ToolCall, confirm) -> str:
        # 只读克隆的双保险：即使模型越权调用写工具也在此拒绝
        if getattr(self, "_readonly", False) and call.name not in READ_ONLY_TOOLS:
            return "错误：子代理仅允许只读工具，%s 已被拒绝" % call.name
        args = call.arguments or {}
        handler = getattr(self, "_tool_" + call.name, None)
        if handler is None:
            return f"错误：未知工具 {call.name}"
        return handler(args, confirm)

    # ---- 领域（只读） ----
    def _tool_list_domains(self, args, confirm) -> str:
        domains = ai_domain_service.get_domains()
        blocks = []
        for dom in domains:
            tables = "、".join(dom["tables"].keys())
            blocks.append("%s（%s）：%s\n  包含表：%s" % (dom["id"], dom["name"], dom["desc"], tables))
        return "\n\n".join(blocks) if blocks else "(无领域)"

    def _tool_get_game_dicts(self, args, confirm) -> str:
        name = str(args.get("name") or "")
        q = str(args.get("q") or "")
        limit = args.get("limit")
        if not name:
            lines = ["%s（%s）：%s 项" % (d["id"], d["name"], d["count"])
                     for d in ai_domain_service.list_dicts()]
            return "可用字典：\n" + "\n".join(lines)
        result = ai_domain_service.get_dict(name, q=q or None, limit=limit)
        items = "\n".join("%s · %s" % (it["id"], it["name"]) for it in result["items"])
        return "[%s] 共 %s 条匹配：\n%s" % (result["cn"], result["total"], items)

    def _tool_list_domain_items(self, args, confirm) -> str:
        domain = str(args.get("domain") or "")
        if not domain:
            return "错误：缺少 domain 参数"
        result = ai_domain_service.list_domain_items(
            domain,
            q=str(args.get("q") or "") or None,
            table=str(args.get("table") or "") or None,
            limit=args.get("limit"),
        )
        lines = []
        for it in result["items"]:
            name = (it.get("name") or "").strip()
            summary = (it.get("summary") or "").strip()
            label = "id=%s" % it["id"] if not name else "「%s」(id=%s)" % (name, it["id"])
            extra = "" if not summary else " — %s" % summary
            lines.append("[%s] %s%s" % (it["cfg"], label, extra))
        return "\n".join(lines) if lines else "(该领域暂无条目，或关键词无匹配)"

    def _tool_get_domain_item(self, args, confirm) -> str:
        domain, cfg, key = str(args.get("domain") or ""), str(args.get("cfg") or ""), str(args.get("id") or "")
        if not (domain and cfg and key):
            return "错误：缺少 domain/cfg/id 参数"
        result = ai_domain_service.get_domain_item(domain, cfg, key)
        return "[%s] id=%s\n%s" % (result.get("cfg_cn") or cfg, key, _jstr(result["data"]))

    # ---- 领域（写，需审批） ----
    def _tool_update_domain_item(self, args, confirm) -> str:
        domain, cfg, key = str(args.get("domain") or ""), str(args.get("cfg") or ""), str(args.get("id") or "")
        patch = args.get("patch")
        if not (domain and cfg and key):
            return "错误：缺少 domain/cfg/id 参数"
        if not isinstance(patch, dict) or not patch:
            return "错误：patch 必须是非空对象"
        old = ai_domain_service.get_domain_item(domain, cfg, key)
        old_data = old["data"] if isinstance(old["data"], dict) else {}
        new_data = {**old_data, **patch}
        if not self._ask(confirm, "AI 请求修改「%s」id=%s" % (old.get("cfg_cn") or cfg, key),
                         _diff_json(old_data, new_data)):
            return "用户拒绝修改。请停止该操作并向用户说明。"
        result = ai_domain_service.update_domain_item(domain, cfg, key, patch)
        if result.get("changed"):
            return "已修改字段：%s\n新内容：%s" % ("、".join(result["patched_fields"]), _jstr(result["data"]))
        return "未改动（%s）" % (result.get("note") or "patch 与原内容一致")

    def _tool_create_domain_item(self, args, confirm) -> str:
        domain, cfg = str(args.get("domain") or ""), str(args.get("cfg") or "")
        data = args.get("data")
        if not (domain and cfg):
            return "错误：缺少 domain/cfg 参数"
        if not isinstance(data, dict) or not data:
            return "错误：data 必须是非空对象"
        if not self._ask(confirm, "AI 请求在「%s」新建条目" % cfg, "(新条目)\n\n" + _jstr(data)):
            return "用户拒绝新建。请停止该操作并向用户说明。"
        result = ai_domain_service.create_domain_item(domain, cfg, None, data)
        return "已新建 id=%s：%s" % (result["id"], _jstr(result["data"]))

    def _tool_delete_domain_item(self, args, confirm) -> str:
        domain, cfg, key = str(args.get("domain") or ""), str(args.get("cfg") or ""), str(args.get("id") or "")
        if not (domain and cfg and key):
            return "错误：缺少 domain/cfg/id 参数"
        old = ai_domain_service.get_domain_item(domain, cfg, key)
        if not self._ask(confirm, "AI 请求删除「%s」id=%s" % (old.get("cfg_cn") or cfg, key),
                         "(被删除内容)\n\n" + _jstr(old["data"])):
            return "用户拒绝删除。请停止该操作并向用户说明。"
        ai_domain_service.delete_domain_item(domain, cfg, key)
        return "已删除：%s id=%s" % (cfg, key)

    # ---- 文件（只读） ----
    def _tool_list_files(self, args, confirm) -> str:
        path = str(args.get("path") or "")
        scope = str(args.get("scope") or "mod")
        root = self._sandbox_root(scope)
        if not os.path.isdir(str(root)):
            return "(空目录)"
        entries = fs_tools.list_dir(root, path, deep=True)
        lines = []
        for entry in entries[:_LIST_FILES_CAP]:
            is_dir = entry.get("type") == "dir"
            lines.append(("[目录] " if is_dir else "[文件] ") + str(entry.get("name")))
        return "\n".join(lines) if lines else "(空目录)"

    def _tool_read_file(self, args, confirm) -> str:
        path = str(args.get("path") or "")
        if not path:
            return "错误：缺少 path 参数"
        payload = fs_tools.read_file(self._sandbox_root("mod"), path)
        text = payload.get("text")
        if text is None:
            return "错误：二进制文件或读取失败"
        return text

    # ---- 模组 ----
    def _tool_list_mods(self, args, confirm) -> str:
        from ..cli import utils as cli_utils

        mods = cli_utils.list_mods()
        names = [m["name"] for m in mods]
        return "\n".join(names) if names else "(无模组)"

    # ---- 舞台 ----
    def _tool_get_stage_dicts(self, args, confirm) -> str:
        sr = stage_service.get_stage_dicts()
        exprs = " ".join("%s=%s" % (e["id"], e["name"]) for e in sr["expressions"])
        actions = "\n".join(
            "[%s] %s（%s/%s）：%s" % (
                a["type"], a["name"], a["category"],
                "作用于角色" if a.get("role") else "屏幕特效", a["params"],
            )
            for a in sr["actions"]
        )
        poses = " ".join("%s=%s" % (p["id"], p["name"]) for p in sr["positions"])
        roles = " ".join("%s=%s" % (r["id"], r["name"]) for r in sr["roles"][:80])
        return ("人物表情：%s\n\n动作类型：\n%s\n\n站位：%s\n\n"
                "角色（前 80 个，完整列表可用 get_game_dicts(name=roles)）：\n%s"
                % (exprs, actions, poses, roles))

    def _tool_get_talk_stage(self, args, confirm) -> str:
        talk_id = str(args.get("talk_id") or "")
        if not talk_id:
            return "错误：缺少 talk_id 参数"
        result = stage_service.get_talk_stage(talk_id)
        return "对白 %s 当前人物舞台：\n%s" % (result["talk_id"], result["desc"])

    def _tool_set_talk_stage(self, args, confirm) -> str:
        talk_id = str(args.get("talk_id") or "")
        commands = args.get("commands")
        clear = args.get("clear") is True
        if not talk_id:
            return "错误：缺少 talk_id 参数"
        if not isinstance(commands, list) or not commands:
            return "错误：commands 必须是非空数组"
        # 先编码预览（后端校验并合并原有指令，不写盘）
        preview = stage_service.encode_talk_stage(talk_id, commands, clear=clear)
        detail = ("修改前：\n%s\n\n修改后：\n%s\n\n编码结果（roles 字段）：\n%s"
                  % ((preview["old_desc"] or "").strip(),
                     (preview["new_desc"] or "").strip(),
                     _jstr(preview["new_roles"])))
        if not self._ask(confirm, "AI 请求修改对白 %s 的人物舞台" % talk_id, detail):
            return "用户拒绝修改舞台。请停止该操作并向用户说明。"
        ai_domain_service.update_domain_item("story", "TalkCfg", talk_id, {"roles": preview["new_roles"]})
        return "已更新对白 %s 的人物舞台：\n%s" % (talk_id, preview["new_desc"])

    # ------------------------------------------------------------------ 审批
    @staticmethod
    def _ask(confirm, title: str, detail: str) -> bool:
        if confirm is None:
            return False  # 未接入审批回调：写操作一律拒绝（安全默认）
        return bool(confirm(title, detail))


if __name__ == "__main__":  # 手工调试：python -m editor.agent.tools
    import sys

    tools = AgentTools()
    if len(sys.argv) > 1:
        tools.use_mod(sys.argv[1])
    for name in ("list_domains", "list_mods"):
        out = tools.execute(ToolCall(id="x", name=name, arguments={}),
                            confirm=lambda t, d: False)
        print("== %s ==\n%s\n" % (name, out[:1500]))
