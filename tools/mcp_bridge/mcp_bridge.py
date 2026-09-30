#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「学生时代」模组编辑器 —— MCP stdio 桥接服务器。

把外部 agent（Claude Code / ZCode 等）经 MCP 协议（stdio、换行分隔
JSON-RPC 2.0）的工具调用，翻译成本地模组编辑器后端（C++/HTTP，默认
http://127.0.0.1:8765）的 REST 请求，让 agent 能读写模组内容。

工具定义与前端 frontend/lib/features/ai/ai_tools.dart 保持一致（精简）。

用法：
    python tools/mcp_bridge/mcp_bridge.py [--allow-write] [--backend URL]

    --allow-write   额外暴露写工具（update_domain_item/create_domain_item/
                    delete_domain_item/set_talk_stage），调用即直接写入后端，
                    请由外部 agent 侧自行向用户确认。默认只暴露只读工具。
    --backend URL   后端基址，优先级高于环境变量 EDITOR_BACKEND。

stdout 只输出 JSON-RPC 响应，日志一律走 stderr。
仅使用 Python 3 标准库。
"""

import argparse
import json
import os
import sys
import traceback
import urllib.error
import urllib.parse
import urllib.request

SERVER_NAME = "student-age-editor-bridge"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = "2025-03-26"
DEFAULT_BACKEND = "http://127.0.0.1:8765"
DEFAULT_TIMEOUT = 30.0

# JSON-RPC 2.0 标准错误码
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603


def log(message):
    """日志走 stderr，绝不污染 stdout 上的 JSON-RPC 流。"""
    print("[mcp-bridge] %s" % message, file=sys.stderr, flush=True)


class BridgeError(Exception):
    """工具执行失败（参数缺失 / REST 非 2xx / 后端不可达等），以 isError 返回。"""


class Tool:
    """一个 MCP 工具：名称 + 描述 + inputSchema + 执行函数 + 是否写操作。"""

    __slots__ = ("name", "description", "input_schema", "run", "write")

    def __init__(self, name, description, input_schema, run, write=False):
        self.name = name
        self.description = description
        self.input_schema = input_schema
        self.run = run
        self.write = write

    def to_list_entry(self):
        return {
            "name": self.name,
            "description": self.description,
            "inputSchema": self.input_schema,
        }


# ---------------------------------------------------------------------------
# 参数说明（与 ai_tools.dart 同构的 schema 片段）
# ---------------------------------------------------------------------------

_P_DOMAIN = {
    "type": "string",
    "description": "领域 id（先调 list_domains 获取，如 story=剧情、background=背景）",
}
_P_DOMAIN_SEE = {"type": "string", "description": "领域 id（见 list_domains）"}
_P_CFG = {"type": "string", "description": "配置表名，如 EvtCfg/TalkCfg/BgCfg/PersonCfg"}
_P_CFG_SHORT = {"type": "string", "description": "配置表名"}
_P_ID = {"type": "string", "description": "条目 id"}
_P_Q = {"type": "string", "description": "关键词，可选"}

_OBJ_SCHEMA = {"type": "object", "properties": {}}


def _schema(required, properties):
    s = {"type": "object", "properties": properties}
    if required:
        s["required"] = list(required)
    return s


class EditorBridge:
    """MCP 服务器核心：处理 JSON-RPC 消息，把工具调用映射到后端 REST。"""

    def __init__(self, backend=DEFAULT_BACKEND, allow_write=False, timeout=DEFAULT_TIMEOUT):
        self.backend = backend.rstrip("/")
        self.allow_write = allow_write
        self.timeout = float(timeout)
        # 注册顺序即 tools/list 顺序：先只读，后写
        self.tools = {}
        for tool in self._build_tools():
            self.tools[tool.name] = tool

    # ------------------------------------------------------------------
    # HTTP 客户端
    # ------------------------------------------------------------------

    def http(self, method, path, query=None, body=None):
        """请求后端 REST，返回解析后的 JSON（失败抛 BridgeError）。"""
        url = self.backend + path
        if query:
            pairs = {k: str(v) for k, v in query.items() if v is not None}
            if pairs:
                url += "?" + urllib.parse.urlencode(pairs)
        data = None
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        log("%s %s" % (method, url))
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            snippet = exc.read().decode("utf-8", "replace")[:500].strip()
            raise BridgeError(
                "后端 HTTP %d %s：%s" % (exc.code, exc.reason, snippet or "(无响应体)")
            )
        except urllib.error.URLError as exc:
            raise BridgeError(
                "无法连接后端 %s（请确认模组编辑器后端已启动）：%s" % (self.backend, exc.reason)
            )
        except OSError as exc:  # 超时等 socket 层错误
            raise BridgeError("访问后端 %s 失败：%s" % (self.backend, exc))
        if not raw.strip():
            return {}
        try:
            return json.loads(raw)
        except ValueError:
            return {"raw": raw}

    # ------------------------------------------------------------------
    # 参数辅助
    # ------------------------------------------------------------------

    @staticmethod
    def _require(arguments, *keys):
        out = {}
        for k in keys:
            v = arguments.get(k)
            if v is None or (isinstance(v, str) and not v.strip()):
                raise BridgeError("缺少必填参数：%s" % k)
            out[k] = v
        return out

    @staticmethod
    def _opt(arguments, *keys):
        """可选参数透传：None 与空串一律省略（与前端行为一致）。"""
        return {k: arguments[k] for k in keys if arguments.get(k) not in (None, "")}

    @staticmethod
    def _as_text(payload):
        return json.dumps(payload, ensure_ascii=False)

    # ------------------------------------------------------------------
    # 各工具实现（映射到后端 REST，与 ai_chat_controller.dart 同构）
    # ------------------------------------------------------------------

    def _t_list_domains(self, a):
        return self._as_text(self.http("GET", "/api/ai/domains"))

    def _t_get_game_dicts(self, a):
        query = self._opt(a, "name", "q", "limit")
        return self._as_text(self.http("GET", "/api/ai/dicts", query=query))

    def _t_list_domain_items(self, a):
        domain = self._require(a, "domain")["domain"]
        query = {"domain": domain}
        query.update(self._opt(a, "q", "table", "limit"))
        return self._as_text(self.http("GET", "/api/ai/domain/items", query=query))

    def _t_get_domain_item(self, a):
        r = self._require(a, "domain", "cfg", "id")
        return self._as_text(
            self.http("GET", "/api/ai/domain/item",
                      query={"domain": r["domain"], "cfg": r["cfg"], "id": r["id"]})
        )

    def _t_update_domain_item(self, a):
        r = self._require(a, "domain", "cfg", "id", "patch")
        if not isinstance(r["patch"], dict) or not r["patch"]:
            raise BridgeError("patch 必须是非空对象，如 {\"title\": \"新标题\"}")
        body = {"domain": r["domain"], "cfg": r["cfg"], "id": r["id"], "patch": r["patch"]}
        return self._as_text(self.http("PUT", "/api/ai/domain/item", body=body))

    def _t_create_domain_item(self, a):
        r = self._require(a, "domain", "cfg", "data")
        if not isinstance(r["data"], dict) or not r["data"]:
            raise BridgeError("data 必须是非空对象，且需包含 id")
        body = {"domain": r["domain"], "cfg": r["cfg"], "data": r["data"]}
        return self._as_text(self.http("POST", "/api/ai/domain/item", body=body))

    def _t_delete_domain_item(self, a):
        r = self._require(a, "domain", "cfg", "id")
        query = {"domain": r["domain"], "cfg": r["cfg"], "id": r["id"]}
        return self._as_text(self.http("DELETE", "/api/ai/domain/item", query=query))

    def _t_list_files(self, a):
        query = {
            "scope": a.get("scope") or "mod",
            "path": a.get("path") or "",
            "deep": "1",
        }
        return self._as_text(self.http("GET", "/api/tools/list", query=query))

    def _t_read_file(self, a):
        path = self._require(a, "path")["path"]
        return self._as_text(
            self.http("GET", "/api/tools/read", query={"scope": "mod", "path": path})
        )

    def _t_list_mods(self, a):
        return self._as_text(self.http("GET", "/api/mods"))

    def _t_get_stage_dicts(self, a):
        return self._as_text(self.http("GET", "/api/ai/stage/dicts"))

    def _t_get_talk_stage(self, a):
        talk_id = self._require(a, "talk_id")["talk_id"]
        return self._as_text(
            self.http("GET", "/api/ai/stage/roles", query={"talk_id": talk_id})
        )

    def _t_set_talk_stage(self, a):
        r = self._require(a, "talk_id", "commands")
        if not isinstance(r["commands"], list) or not r["commands"]:
            raise BridgeError("commands 必须是非空数组")
        clear = a.get("clear") is True
        # 第一步：POST /api/ai/stage/encode —— 后端校验并合并指令，不写盘
        enc = self.http("POST", "/api/ai/stage/encode", body={
            "talk_id": r["talk_id"],
            "commands": r["commands"],
            "clear": clear,
        })
        new_roles = enc.get("new_roles")
        if new_roles is None:
            raise BridgeError("encode 未返回 new_roles：%s" % self._as_text(enc))
        # 第二步：PUT /api/ai/domain/item 写回 TalkCfg 的 roles 字段
        put = self.http("PUT", "/api/ai/domain/item", body={
            "domain": "story",
            "cfg": "TalkCfg",
            "id": r["talk_id"],
            "patch": {"roles": new_roles},
        })
        return self._as_text({
            "talk_id": r["talk_id"],
            "new_desc": enc.get("new_desc"),
            "update_result": put,
        })

    # ------------------------------------------------------------------
    # 工具注册表
    # ------------------------------------------------------------------

    def _build_tools(self):
        return [
            Tool(
                "list_domains",
                "修改 mod 的第一步：列出所有可修改的创作领域（剧情、背景、人物、社交、恋爱等）及各领域包含的配置表。其他领域工具的参数 domain 从这里取值，用户要求改内容时先调用它",
                _OBJ_SCHEMA,
                self._t_list_domains,
            ),
            Tool(
                "get_game_dicts",
                "查询游戏内置字典（角色/物品/地点/职业/属性/关系/背景/回合/事件类型/羽毛球模型等）的 id→名称对照。填写 role/npc/item/mapId/type 等 ID 字段前，先用它核对名称避免填错 ID。name 为空时列出可用字典；q 为关键词（匹配 id 或名称，可留空）",
                _schema(None, {
                    "name": {
                        "type": "string",
                        "description": "字典 id，如 roles/items/maps/jobs/attrs/relations/bgs/turns/evt_types/badminton_models；留空列出全部",
                    },
                    "q": {"type": "string", "description": "关键词，可选，如角色名"},
                    "limit": {"type": "integer", "description": "返回条数上限，默认 30 最大 100"},
                }),
                self._t_get_game_dicts,
            ),
            Tool(
                "list_domain_items",
                "列出某领域下的条目（如剧情领域列出所有事件/对话/选项）。domain 见 list_domains；q 为关键词（匹配 id/名称/内容，可留空）；table 可限定单表；limit 默认 50 最大 200",
                _schema(["domain"], {
                    "domain": _P_DOMAIN,
                    "q": _P_Q,
                    "table": {"type": "string", "description": "限定单表名（如 EvtCfg），可选"},
                    "limit": {"type": "integer", "description": "返回条数上限，可选"},
                }),
                self._t_list_domain_items,
            ),
            Tool(
                "get_domain_item",
                "读取某领域单个条目的完整内容（含全部字段）。修改前务必先读取，确认理解后再改",
                _schema(["domain", "cfg", "id"], {
                    "domain": _P_DOMAIN_SEE,
                    "cfg": _P_CFG,
                    "id": {"type": "string", "description": "条目 id（来自 list_domain_items）"},
                }),
                self._t_get_domain_item,
            ),
            Tool(
                "list_files",
                "列出模组或工作区目录下的文件（只读探索用；scope: mod=当前模组, workspace=工作区；path 为相对路径，空为根目录）",
                _schema(None, {
                    "path": {"type": "string", "description": "相对路径，默认根目录"},
                    "scope": {
                        "type": "string",
                        "enum": ["mod", "workspace"],
                        "description": "mod=当前模组目录, workspace=工作区",
                    },
                }),
                self._t_list_files,
            ),
            Tool(
                "read_file",
                "读取模组文件内容（只读探索用，修改内容请使用领域工具 update_domain_item）。path 为相对模组根目录的路径",
                _schema(["path"], {"path": {"type": "string"}}),
                self._t_read_file,
            ),
            Tool(
                "list_mods",
                "列出所有可用模组",
                _OBJ_SCHEMA,
                self._t_list_mods,
            ),
            Tool(
                "get_stage_dicts",
                "查询剧情对白的「舞台调度」字典：人物表情（0-26）、人物动作/入场退场/移动类型、站位（左/中/右）、角色列表。修改人物站位、移动、入场退场、表情、动作前先调用它核对名称与ID",
                _OBJ_SCHEMA,
                self._t_get_stage_dicts,
            ),
            Tool(
                "get_talk_stage",
                "读取某条对白（TalkCfg 条目）当前的人物舞台安排（站位/移动/入场退场/表情/动作），返回描述。修改舞台前先调用，确认理解当前状态",
                _schema(["talk_id"], {
                    "talk_id": {
                        "type": "string",
                        "description": "对白ID（TalkCfg 条目 id，来自 list_domain_items）",
                    },
                }),
                self._t_get_talk_stage,
            ),
            # ---- 以下写工具默认不暴露，需 --allow-write ----
            Tool(
                "update_domain_item",
                "修改某领域条目的字段（patch 为要改的字段集合，只改给出的字段，其余保持不动）。经本桥调用会直接写入后端生效，调用前请自行向用户展示改动并确认",
                _schema(["domain", "cfg", "id", "patch"], {
                    "domain": _P_DOMAIN_SEE,
                    "cfg": _P_CFG_SHORT,
                    "id": _P_ID,
                    "patch": {
                        "type": "object",
                        "description": "要修改的字段，如 {\"title\": \"新标题\"}；修改对白（TalkCfg）的说话人时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds",
                    },
                }),
                self._t_update_domain_item,
                write=True,
            ),
            Tool(
                "create_domain_item",
                "在某领域配置表新建条目。data 需包含 id 及至少一个字段；id 与现有条目重复会失败。经本桥调用会直接写入后端生效，调用前请自行向用户确认",
                _schema(["domain", "cfg", "data"], {
                    "domain": _P_DOMAIN_SEE,
                    "cfg": _P_CFG_SHORT,
                    "data": {
                        "type": "object",
                        "description": "新条目内容，如 {\"id\": 101, \"name\": \"新角色\"}；创建对白（TalkCfg）时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds",
                    },
                }),
                self._t_create_domain_item,
                write=True,
            ),
            Tool(
                "delete_domain_item",
                "删除某领域配置表的条目（不可恢复）。经本桥调用会直接写入后端生效，调用前请自行向用户确认",
                _schema(["domain", "cfg", "id"], {
                    "domain": _P_DOMAIN_SEE,
                    "cfg": _P_CFG_SHORT,
                    "id": _P_ID,
                }),
                self._t_delete_domain_item,
                write=True,
            ),
            Tool(
                "set_talk_stage",
                "修改某条对白的人物舞台：人物站位（入场到左/中/右）、移动、入场退场、人物表情、人物动作。commands 为语义化指令数组，每条含 action（入场/退场/移动/表情/动作/屏幕特效），role 用角色名或ID，其余按动作类型补参数。示例：[{\"action\":\"入场\",\"role\":\"薛诗蕾\",\"mode\":\"滑动\",\"pos\":\"左\"},{\"action\":\"表情\",\"role\":\"102\",\"expr\":\"开心\"},{\"action\":\"移动\",\"role\":\"102\",\"value\":-80},{\"action\":\"退场\",\"role\":\"102\",\"mode\":\"滑动\"},{\"action\":\"动作\",\"role\":\"102\",\"type\":\"转身\"},{\"action\":\"屏幕特效\",\"type\":\"屏幕抖动\",\"value\":2}]。clear 为 true 时先清空该对白原有舞台指令，默认保留并追加。写前先 get_talk_stage 查看当前安排、get_stage_dicts 核对动作/表情/站位名称；经本桥调用会直接写入后端生效，调用前请自行向用户确认",
                _schema(["talk_id", "commands"], {
                    "talk_id": {"type": "string", "description": "对白ID（TalkCfg 条目）"},
                    "commands": {
                        "type": "array",
                        "description": "舞台指令数组，每项为对象，字段见 description 示例（action/role/mode/pos/expr/type/value/axis）",
                    },
                    "clear": {"type": "boolean", "description": "是否先清空原有舞台指令，默认 false"},
                }),
                self._t_set_talk_stage,
                write=True,
            ),
        ]

    def exposed_tools(self):
        return [t for t in self.tools.values() if self.allow_write or not t.write]

    # ------------------------------------------------------------------
    # JSON-RPC / MCP 分发
    # ------------------------------------------------------------------

    @staticmethod
    def _result(rid, result):
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    @staticmethod
    def _error(rid, code, message, data=None):
        err = {"code": code, "message": message}
        if data is not None:
            err["data"] = data
        return {"jsonrpc": "2.0", "id": rid, "error": err}

    def handle_message(self, msg):
        """处理一条 JSON-RPC 消息，返回响应 dict；通知/应忽略的消息返回 None。"""
        if not isinstance(msg, dict):
            return self._error(None, INVALID_REQUEST, "Invalid Request：不是 JSON 对象")
        rid = msg.get("id")
        is_notification = "id" not in msg
        method = msg.get("method")

        if not isinstance(method, str):
            # 没有 method 也没有 result/error 的带 id 消息 = 非法请求；其余（如客户端发来的
            # 响应回声）静默忽略。
            if not is_notification and "result" not in msg and "error" not in msg:
                return self._error(rid, INVALID_REQUEST, "Invalid Request：缺少 method")
            return None

        try:
            if method == "initialize":
                return self._result(rid, {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                })
            if method == "notifications/initialized":
                log("客户端初始化完成")
                return None
            if method == "ping":
                return self._result(rid, {})
            if method == "tools/list":
                return self._result(rid, {
                    "tools": [t.to_list_entry() for t in self.exposed_tools()],
                })
            if method == "tools/call":
                return self._handle_tools_call(rid, msg.get("params"), is_notification)
            if is_notification:
                return None  # 未知通知一律忽略
            return self._error(rid, METHOD_NOT_FOUND, "Method not found: %s" % method)
        except BridgeError as exc:
            if is_notification:
                return None
            return self._error(rid, INTERNAL_ERROR, str(exc))
        except Exception as exc:  # 兜底：不让桥因单个请求崩溃
            log("内部异常：%s\n%s" % (exc, traceback.format_exc()))
            if is_notification:
                return None
            return self._error(rid, INTERNAL_ERROR, "Internal error: %s" % exc)

    def _handle_tools_call(self, rid, params, is_notification):
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            return self._error(rid, INVALID_PARAMS, "tools/call 需要 params.name")
        name = params["name"]
        arguments = params.get("arguments")
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            return self._error(rid, INVALID_PARAMS, "tools/call params.arguments 必须是对象")

        tool = self.tools.get(name)
        if tool is None:
            if is_notification:
                return None
            return self._error(rid, INVALID_PARAMS, "Unknown tool: %s" % name)
        if tool.write and not self.allow_write:
            if is_notification:
                return None
            return self._error(
                rid, INVALID_PARAMS,
                "写工具 %s 默认未启用；如需模组写入能力，请以 --allow-write 重启本桥接" % name,
            )
        try:
            text = tool.run(arguments)
            payload = {"content": [{"type": "text", "text": text}], "isError": False}
        except BridgeError as exc:
            payload = {"content": [{"type": "text", "text": str(exc)}], "isError": True}
        if is_notification:
            return None
        return self._result(rid, payload)


# ---------------------------------------------------------------------------
# stdio 主循环
# ---------------------------------------------------------------------------

def resolve_backend(cli_value=None):
    return (cli_value or os.environ.get("EDITOR_BACKEND") or DEFAULT_BACKEND).rstrip("/")


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="mcp_bridge.py",
        description="「学生时代」模组编辑器的 MCP stdio 桥接服务器（详见 README.md）",
    )
    parser.add_argument(
        "--allow-write", action="store_true",
        help="额外暴露写工具（update/create/delete_domain_item、set_talk_stage），调用直接写入后端",
    )
    parser.add_argument(
        "--backend", default=None, metavar="URL",
        help="后端基址（默认 $EDITOR_BACKEND 或 %s）" % DEFAULT_BACKEND,
    )
    parser.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT,
        help="单次 REST 请求超时秒数（默认 %(default)s）",
    )
    args = parser.parse_args(argv)

    # 强制 UTF-8，保证 Windows 默认编码下 JSON 中文不乱码、stdout 干净
    for stream in (sys.stdin, sys.stdout):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass

    bridge = EditorBridge(backend=resolve_backend(args.backend),
                          allow_write=args.allow_write, timeout=args.timeout)
    log("启动：backend=%s allow_write=%s 工具数=%d"
        % (bridge.backend, bridge.allow_write, len(bridge.exposed_tools())))

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError as exc:
            emit({"jsonrpc": "2.0", "id": None,
                  "error": {"code": PARSE_ERROR, "message": "Parse error: %s" % exc}})
            continue
        response = bridge.handle_message(msg)
        if response is not None:
            emit(response)
    log("stdin 结束，桥接退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
