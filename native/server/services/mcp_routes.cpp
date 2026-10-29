// server/services/mcp_routes.cpp — see mcp_routes.h.
//
// 与 tools/mcp_bridge/mcp_bridge.py 逐字段对齐：协议版本、工具集（名称/描述/
// inputSchema/只写标记）都从同一份定义搬过来，因此外部 Agent 用 stdio 桥还是
// HTTP 端点看到的工具完全一致。执行层不走 REST 自转发，直接调 p3b/stage/state
// 的领域服务，省掉一次 JSON 往返与「自己请求自己」的回路。
#include "mcp_routes.h"

#include <cctype>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

#include "server/ai_dicts_route.h"  // dicts_view（与 /api/ai/dicts 同一实现）
#include "p3b_domain_service.h"     // 领域条目读写
#include "p3b_fs_tools.h"           // list_dir / read_file
#include "p3b_support.h"            // json_str / json_truthy
#include "sa_core/json_wire.h"      // py_dumps
#include "sa_core/paths.h"
#include "server/state.h"  // SandboxError / list_mods / sandbox_root / STATE
#include "stage_service.h"  // 舞台调度编解码

namespace sa {
namespace {

constexpr const char* kProtocolVersion = "2025-03-26";
constexpr const char* kServerName = "student-age-editor-bridge";
constexpr const char* kServerVersion = "1.0.0";

// JSON-RPC 2.0 标准错误码（与 mcp_bridge.py 的同名常量一致）。
constexpr int kInvalidRequest = -32600;
constexpr int kMethodNotFound = -32601;
constexpr int kInvalidParams = -32602;
constexpr int kInternalError = -32603;

// 工具执行失败（参数缺失 / 领域服务拒绝 / 后端不可用）——按 MCP 约定包成
// content + isError=true 的「工具结果」，而不是 JSON-RPC 错误。
struct McpToolError : std::runtime_error {
    explicit McpToolError(const std::string& msg) : std::runtime_error(msg) {}
};

// Streamable HTTP 会话头。本实现无服务端会话状态（每个 POST 都是自足的
// JSON-RPC 往返），但按 MCP 规范回一个稳定 id，方便客户端/代理串联日志，
// 也让浏览器侧能被 `Access-Control-Expose-Headers` 读到。
const std::string& session_id() {
    static const std::string kId = [] {
        std::random_device rd;
        const char* hex = "0123456789abcdef";
        std::string s = "mcp-";
        s.reserve(36);
        for (int i = 0; i < 32; ++i) s.push_back(hex[rd() & 0xF]);
        return s;
    }();
    return kId;
}

Resp with_session(Resp r) {
    r.headers.emplace_back("Mcp-Session-Id", session_id());
    return r;
}

Resp mcp_json(int status, json payload) {
    return with_session(Resp::Json(status, std::move(payload)));
}

// 通知（无 id）不产生响应体：202 + 空包体（MCP 的 "Accepted" 语义）。
Resp mcp_accepted() { return with_session(Resp::Bytes(202, std::string())); }

json rpc_result(const json& id, json result) {
    json m = json::object();
    m["jsonrpc"] = "2.0";
    m["id"] = id;
    m["result"] = std::move(result);
    return m;
}

json rpc_error(const json& id, int code, const std::string& message) {
    json err = json::object();
    err["code"] = code;
    err["message"] = message;
    json m = json::object();
    m["jsonrpc"] = "2.0";
    m["id"] = id;
    m["error"] = std::move(err);
    return m;
}

json tool_content(const std::string& text, bool is_error) {
    json item = json::object();
    item["type"] = "text";
    item["text"] = text;
    json arr = json::array();
    arr.push_back(std::move(item));
    json out = json::object();
    out["content"] = std::move(arr);
    out["isError"] = is_error;
    return out;
}

// ---------------------------------------------------------------------------
// 工具定义（与 mcp_bridge.py 的 _build_tools() 同构，顺序也保持一致：
// 先 9 个只读工具，再 4 个写工具）。
// ---------------------------------------------------------------------------

const char kToolsJson[] = R"JSON([
  {
    "name": "list_domains",
    "description": "修改 mod 的第一步：列出所有可修改的创作领域（剧情、背景、人物、社交、恋爱等）及各领域包含的配置表。其他领域工具的参数 domain 从这里取值，用户要求改内容时先调用它",
    "inputSchema": {"type": "object", "properties": {}}
  },
  {
    "name": "get_game_dicts",
    "description": "查询游戏内置字典（角色/物品/地点/职业/属性/关系/背景/回合/事件类型/羽毛球模型等）的 id→名称对照。填写 role/npc/item/mapId/type 等 ID 字段前，先用它核对名称避免填错 ID。name 为空时列出可用字典；q 为关键词（匹配 id 或名称，可留空）",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {"type": "string", "description": "字典 id，如 roles/items/maps/jobs/attrs/relations/bgs/turns/evt_types/badminton_models；留空列出全部"},
        "q": {"type": "string", "description": "关键词，可选，如角色名"},
        "limit": {"type": "integer", "description": "返回条数上限，默认 30 最大 100"}
      }
    }
  },
  {
    "name": "list_domain_items",
    "description": "列出某领域下的条目（如剧情领域列出所有事件/对话/选项）。domain 见 list_domains；q 为关键词（匹配 id/名称/内容，可留空）；table 可限定单表；limit 默认 50 最大 200",
    "inputSchema": {
      "type": "object",
      "properties": {
        "domain": {"type": "string", "description": "领域 id（先调 list_domains 获取，如 story=剧情、background=背景）"},
        "q": {"type": "string", "description": "关键词，可选"},
        "table": {"type": "string", "description": "限定单表名（如 EvtCfg），可选"},
        "limit": {"type": "integer", "description": "返回条数上限，可选"}
      },
      "required": ["domain"]
    }
  },
  {
    "name": "get_domain_item",
    "description": "读取某领域单个条目的完整内容（含全部字段）。修改前务必先读取，确认理解后再改",
    "inputSchema": {
      "type": "object",
      "properties": {
        "domain": {"type": "string", "description": "领域 id（见 list_domains）"},
        "cfg": {"type": "string", "description": "配置表名，如 EvtCfg/TalkCfg/BgCfg/PersonCfg"},
        "id": {"type": "string", "description": "条目 id（来自 list_domain_items）"}
      },
      "required": ["domain", "cfg", "id"]
    }
  },
  {
    "name": "list_files",
    "description": "列出模组或工作区目录下的文件（只读探索用；scope: mod=当前模组, workspace=工作区；path 为相对路径，空为根目录）",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "相对路径，默认根目录"},
        "scope": {"type": "string", "enum": ["mod", "workspace"], "description": "mod=当前模组目录, workspace=工作区"}
      }
    }
  },
  {
    "name": "read_file",
    "description": "读取模组文件内容（只读探索用，修改内容请使用领域工具 update_domain_item）。path 为相对模组根目录的路径",
    "inputSchema": {
      "type": "object",
      "properties": {"path": {"type": "string"}},
      "required": ["path"]
    }
  },
  {
    "name": "list_mods",
    "description": "列出所有可用模组",
    "inputSchema": {"type": "object", "properties": {}}
  },
  {
    "name": "get_stage_dicts",
    "description": "查询剧情对白的「舞台调度」字典：人物表情（0-26）、人物动作/入场退场/移动类型、站位（左/中/右）、角色列表。修改人物站位、移动、入场退场、表情、动作前先调用它核对名称与ID",
    "inputSchema": {"type": "object", "properties": {}}
  },
  {
    "name": "get_talk_stage",
    "description": "读取某条对白（TalkCfg 条目）当前的人物舞台安排（站位/移动/入场退场/表情/动作），返回描述。修改舞台前先调用，确认理解当前状态",
    "inputSchema": {
      "type": "object",
      "properties": {"talk_id": {"type": "string", "description": "对白ID（TalkCfg 条目 id，来自 list_domain_items）"}},
      "required": ["talk_id"]
    }
  },
  {
    "name": "update_domain_item",
    "description": "修改某领域条目的字段（patch 为要改的字段集合，只改给出的字段，其余保持不动）。经本桥调用会直接写入后端生效，调用前请自行向用户展示改动并确认",
    "inputSchema": {
      "type": "object",
      "properties": {
        "domain": {"type": "string", "description": "领域 id（见 list_domains）"},
        "cfg": {"type": "string", "description": "配置表名"},
        "id": {"type": "string", "description": "条目 id"},
        "patch": {"type": "object", "description": "要修改的字段，如 {\"title\": \"新标题\"}；修改对白（TalkCfg）的说话人时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds"}
      },
      "required": ["domain", "cfg", "id", "patch"]
    }
  },
  {
    "name": "create_domain_item",
    "description": "在某领域配置表新建条目。data 需包含 id 及至少一个字段；id 与现有条目重复会失败。经本桥调用会直接写入后端生效，调用前请自行向用户确认",
    "inputSchema": {
      "type": "object",
      "properties": {
        "domain": {"type": "string", "description": "领域 id（见 list_domains）"},
        "cfg": {"type": "string", "description": "配置表名"},
        "data": {"type": "object", "description": "新条目内容，如 {\"id\": 101, \"name\": \"新角色\"}；创建对白（TalkCfg）时 roleIds（说话人群组）必填、短信/动态（PhoneMsgCfg/KZoneContentCfg）的 role（发送者）必填，roleName 只是可选显示名，不能替代 roleIds"}
      },
      "required": ["domain", "cfg", "data"]
    }
  },
  {
    "name": "delete_domain_item",
    "description": "删除某领域配置表的条目（不可恢复）。经本桥调用会直接写入后端生效，调用前请自行向用户确认",
    "inputSchema": {
      "type": "object",
      "properties": {
        "domain": {"type": "string", "description": "领域 id（见 list_domains）"},
        "cfg": {"type": "string", "description": "配置表名"},
        "id": {"type": "string", "description": "条目 id"}
      },
      "required": ["domain", "cfg", "id"]
    }
  },
  {
    "name": "set_talk_stage",
    "description": "修改某条对白的人物舞台：人物站位（入场到左/中/右）、移动、入场退场、人物表情、人物动作。commands 为语义化指令数组，每条含 action（入场/退场/移动/表情/动作/屏幕特效），role 用角色名或ID，其余按动作类型补参数。示例：[{\"action\":\"入场\",\"role\":\"薛诗蕾\",\"mode\":\"滑动\",\"pos\":\"左\"},{\"action\":\"表情\",\"role\":\"102\",\"expr\":\"开心\"},{\"action\":\"移动\",\"role\":\"102\",\"value\":-80},{\"action\":\"退场\",\"role\":\"102\",\"mode\":\"滑动\"},{\"action\":\"动作\",\"role\":\"102\",\"type\":\"转身\"},{\"action\":\"屏幕特效\",\"type\":\"屏幕抖动\",\"value\":2}]。clear 为 true 时先清空该对白原有舞台指令，默认保留并追加。写前先 get_talk_stage 查看当前安排、get_stage_dicts 核对动作/表情/站位名称；经本桥调用会直接写入后端生效，调用前请自行向用户确认",
    "inputSchema": {
      "type": "object",
      "properties": {
        "talk_id": {"type": "string", "description": "对白ID（TalkCfg 条目）"},
        "commands": {"type": "array", "description": "舞台指令数组，每项为对象，字段见 description 示例（action/role/mode/pos/expr/type/value/axis）"},
        "clear": {"type": "boolean", "description": "是否先清空原有舞台指令，默认 false"}
      },
      "required": ["talk_id", "commands"]
    }
  }
])JSON";

const json& all_tools() {
    static const json kTools = [] {
        json parsed = json::parse(kToolsJson, nullptr, false);
        if (parsed.is_discarded() || !parsed.is_array()) return json::array();
        return parsed;
    }();
    return kTools;
}

// 写工具（默认在 `?readonly=1` 下既不暴露也不放行）。
bool is_write_tool(const std::string& name) {
    return name == "update_domain_item" || name == "create_domain_item" ||
           name == "delete_domain_item" || name == "set_talk_stage";
}

// ---------------------------------------------------------------------------
// 参数辅助（与 mcp_bridge.py 的 _require/_opt 语义一致）
// ---------------------------------------------------------------------------

bool has_arg(const json& a, const char* key) {
    return a.is_object() && a.contains(key) && !a.at(key).is_null();
}

// 必填参数：缺失/null/空串都按「缺少」处理（桥的 _require 规则）。
std::string require_arg(const json& a, const char* key) {
    if (!has_arg(a, key)) throw McpToolError(std::string("缺少必填参数：") + key);
    std::string v = a.at(key).is_string() ? a.at(key).get<std::string>()
                                          : p3b::json_str(a.at(key));
    if (v.empty()) throw McpToolError(std::string("缺少必填参数：") + key);
    return v;
}

// 可选参数透传：None 与空串一律省略（与前端 mcp_bridge 行为一致）。
json opt_arg(const json& a, const char* key) {
    if (!has_arg(a, key)) return json();
    const json& v = a.at(key);
    if (v.is_string() && v.get_ref<const std::string&>().empty()) return json();
    return v;
}

std::string str_arg(const json& a, const char* key, const std::string& def = "") {
    if (!has_arg(a, key)) return def;
    return a.at(key).is_string() ? a.at(key).get<std::string>() : p3b::json_str(a.at(key));
}

// ---------------------------------------------------------------------------
// 工具执行（映射到 C++ 领域服务；失败抛 McpToolError / SandboxError）
// ---------------------------------------------------------------------------

std::string run_tool(const std::string& name, const json& a) {
    if (name == "list_domains") {
        json body = json::object();
        body["domains"] = p3b::get_domains();
        return sa_core::py_dumps(body);
    }
    if (name == "get_game_dicts") {
        const std::string dict_name = str_arg(a, "name");
        if (dict_name.empty()) {
            json body = json::object();
            body["dicts"] = dicts_view::list_dicts();
            return sa_core::py_dumps(body);
        }
        const std::string limit = str_arg(a, "limit");
        return sa_core::py_dumps(
            dicts_view::get_dict(dict_name, str_arg(a, "q"), limit.empty() ? nullptr : &limit));
    }
    if (name == "list_domain_items") {
        const std::string domain = require_arg(a, "domain");
        return sa_core::py_dumps(p3b::list_domain_items(domain, opt_arg(a, "q"),
                                                        opt_arg(a, "limit"), opt_arg(a, "table")));
    }
    if (name == "get_domain_item") {
        // 顺序须与 mcp_bridge.py 的 _require(a, "domain", "cfg", "id") 一致：
        // 不能写成嵌套实参 require_arg(...) —— C++ 实参求值顺序未定义，MSVC
        // 从右往左会先抛 "id"，缺失文案与桥对不上。
        const std::string domain = require_arg(a, "domain");
        const std::string cfg = require_arg(a, "cfg");
        const std::string id = require_arg(a, "id");
        return sa_core::py_dumps(p3b::get_domain_item(domain, cfg, json(id)));
    }
    if (name == "list_files") {
        const std::string scope = str_arg(a, "scope", "mod");
        const std::string path = str_arg(a, "path");
        const std::string root = sandbox_root(scope.empty() ? "mod" : scope);
        json body = json::object();
        body["root"] = root;
        body["path"] = path;
        if (!sa_core::paths::is_dir(root)) {
            body["entries"] = json::array();  // 缺失根 == 空列表（同 /api/tools/list）
            return sa_core::py_dumps(body);
        }
        body["entries"] = p3b::list_dir(root, path, true);
        return sa_core::py_dumps(body);
    }
    if (name == "read_file") {
        const std::string path = require_arg(a, "path");
        return sa_core::py_dumps(p3b::read_file(sandbox_root("mod"), path, false));
    }
    if (name == "list_mods") {
        json body = json::object();
        body["mods"] = list_mods();
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            body["selected"] = STATE().mod_name;
            body["workspace"] = STATE().workspace_root;
        }
        return sa_core::py_dumps(body);
    }
    if (name == "get_stage_dicts") return sa_core::py_dumps(stage::get_stage_dicts());
    if (name == "get_talk_stage") {
        return sa_core::py_dumps(stage::get_talk_stage(require_arg(a, "talk_id")));
    }
    if (name == "update_domain_item") {
        const std::string domain = require_arg(a, "domain");
        const std::string cfg = require_arg(a, "cfg");
        const std::string id = require_arg(a, "id");
        if (!has_arg(a, "patch")) throw McpToolError("缺少必填参数：patch");
        const json& patch = a.at("patch");
        if (!patch.is_object() || patch.empty())
            throw McpToolError("patch 必须是非空对象，如 {\"title\": \"新标题\"}");
        return sa_core::py_dumps(p3b::update_domain_item(domain, cfg, json(id), patch));
    }
    if (name == "create_domain_item") {
        const std::string domain = require_arg(a, "domain");
        const std::string cfg = require_arg(a, "cfg");
        if (!has_arg(a, "data")) throw McpToolError("缺少必填参数：data");
        const json& data = a.at("data");
        if (!data.is_object() || data.empty())
            throw McpToolError("data 必须是非空对象，且需包含 id");
        // key 传 null：与桥一致，交给领域服务按 data.id / 自动分配处理。
        return sa_core::py_dumps(p3b::create_domain_item(domain, cfg, json(), data));
    }
    if (name == "delete_domain_item") {
        // 同 get_domain_item：顺序化求值，保证「首个缺失」与桥一致。
        const std::string domain = require_arg(a, "domain");
        const std::string cfg = require_arg(a, "cfg");
        const std::string id = require_arg(a, "id");
        return sa_core::py_dumps(p3b::delete_domain_item(domain, cfg, json(id)));
    }
    if (name == "set_talk_stage") {
        const std::string talk_id = require_arg(a, "talk_id");
        if (!has_arg(a, "commands")) throw McpToolError("缺少必填参数：commands");
        const json& commands = a.at("commands");
        if (!commands.is_array() || commands.empty())
            throw McpToolError("commands 必须是非空数组");
        const bool clear = has_arg(a, "clear") && p3b::json_truthy(a.at("clear"));
        // 第一步：encode 校验并合并指令（不写盘）；第二步：写回 TalkCfg.roles。
        const json enc = stage::encode_talk_stage(talk_id, commands, clear);
        json new_roles = enc.contains("new_roles") ? enc.at("new_roles") : json();
        if (new_roles.is_null())
            throw McpToolError("encode 未返回 new_roles：" + sa_core::py_dumps(enc));
        json patch = json::object();
        patch["roles"] = new_roles;
        const json put = p3b::update_domain_item("story", "TalkCfg", json(talk_id), patch);
        json out = json::object();
        out["talk_id"] = talk_id;
        out["new_desc"] = enc.contains("new_desc") ? enc.at("new_desc") : json();
        out["update_result"] = put;
        return sa_core::py_dumps(out);
    }
    throw McpToolError("Unknown tool: " + name);
}

// ---------------------------------------------------------------------------
// JSON-RPC 分发
// ---------------------------------------------------------------------------

// 返回 null json == 「无需响应」（通知/应忽略的消息）。
json handle_message(const json& msg, bool readonly) {
    if (!msg.is_object())
        return rpc_error(json(), kInvalidRequest, "Invalid Request：不是 JSON 对象");
    const bool is_notification = !msg.contains("id");
    const json id = msg.contains("id") ? msg.at("id") : json();
    if (!msg.contains("method") || !msg.at("method").is_string()) {
        if (!is_notification && !msg.contains("result") && !msg.contains("error"))
            return rpc_error(id, kInvalidRequest, "Invalid Request：缺少 method");
        return json();  // 客户端响应回声 / 未知通知：静默忽略
    }
    const std::string method = msg.at("method").get<std::string>();
    try {
        if (method == "initialize") {
            json result = json::object();
            result["protocolVersion"] = kProtocolVersion;
            json caps = json::object();
            caps["tools"] = json::object();
            result["capabilities"] = std::move(caps);
            json info = json::object();
            info["name"] = kServerName;
            info["version"] = kServerVersion;
            result["serverInfo"] = std::move(info);
            return rpc_result(id, std::move(result));
        }
        if (method == "notifications/initialized") return json();
        if (method == "ping") return rpc_result(id, json::object());
        if (method == "tools/list") {
            json tools = json::array();
            for (const auto& t : all_tools()) {
                const std::string tn = t.value("name", "");
                if (readonly && is_write_tool(tn)) continue;
                tools.push_back(t);
            }
            json result = json::object();
            result["tools"] = std::move(tools);
            return rpc_result(id, std::move(result));
        }
        if (method == "tools/call") {
            const json params = msg.contains("params") ? msg.at("params") : json();
            if (!params.is_object() || !params.contains("name") || !params.at("name").is_string())
                return rpc_error(id, kInvalidParams, "tools/call 需要 params.name");
            const std::string name = params.at("name").get<std::string>();
            json args = json::object();
            if (params.contains("arguments") && !params.at("arguments").is_null()) {
                args = params.at("arguments");
                if (!args.is_object())
                    return rpc_error(id, kInvalidParams, "tools/call params.arguments 必须是对象");
            }
            bool known = false;
            for (const auto& t : all_tools())
                if (t.value("name", "") == name) { known = true; break; }
            if (!known) {
                if (is_notification) return json();
                return rpc_error(id, kInvalidParams, "Unknown tool: " + name);
            }
            if (readonly && is_write_tool(name)) {
                if (is_notification) return json();
                return rpc_error(id, kInvalidParams,
                                 "写工具 " + name +
                                     " 在只读模式下不可用（请改用读写令牌，或去掉 URL 的 "
                                     "readonly=1）");
            }
            json payload;
            try {
                payload = tool_content(run_tool(name, args), false);
            } catch (const McpToolError& e) {
                payload = tool_content(e.what(), true);
            } catch (const SandboxError& e) {
                payload = tool_content(e.what(), true);
            } catch (const std::exception& e) {
                // 兜底：单个工具失败不能让整个端点崩掉（与桥的 except 同义）。
                payload = tool_content(std::string("内部错误：") + e.what(), true);
            }
            if (is_notification) return json();
            return rpc_result(id, std::move(payload));
        }
        if (is_notification) return json();  // 未知通知一律忽略
        return rpc_error(id, kMethodNotFound, "Method not found: " + method);
    } catch (const std::exception& e) {
        if (is_notification) return json();
        return rpc_error(id, kInternalError, std::string("Internal error: ") + e.what());
    }
}

bool query_flag(const Req& req, const char* key) {
    auto it = req.query.find(key);
    if (it == req.query.end()) return false;
    std::string v = it->second;
    for (char& c : v) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

Resp handle_post(const Req& req) {
    const bool readonly = query_flag(req, "readonly");
    if (req.body.is_array()) {
        json out = json::array();
        for (const auto& m : req.body) {
            json r = handle_message(m, readonly);
            if (!r.is_null()) out.push_back(std::move(r));
        }
        if (out.empty()) return mcp_accepted();
        return mcp_json(200, std::move(out));
    }
    if (!req.body.is_object()) {
        return mcp_json(200, rpc_error(json(), kInvalidRequest,
                                       "Invalid Request：请求体不是 JSON-RPC 消息"));
    }
    json r = handle_message(req.body, readonly);
    if (r.is_null()) return mcp_accepted();
    return mcp_json(200, std::move(r));
}

Resp handle_get(const Req& req) {
    // 部分 MCP 客户端先 GET 建流（SSE）。本实现无服务端推送，回一个
    // endpoint 事件即关闭（`?sse=1` 显式请求时）；否则回健康元数据，
    // 方便浏览器/探活脚本确认端点存在。
    if (query_flag(req, "sse")) {
        return with_session(Resp::BytesTyped(200, "event: endpoint\ndata: /api/mcp\n\n",
                                            "text/event-stream"));
    }
    json body = json::object();
    body["status"] = "ok";
    body["mcp"] = "student-age-editor";
    body["protocolVersion"] = kProtocolVersion;
    body["readonly"] = query_flag(req, "readonly");
    body["tools"] = static_cast<int>(all_tools().size());
    return mcp_json(200, std::move(body));
}

}  // namespace

void register_mcp_routes(Router& r) {
    r.post(R"(/api/mcp)", [](const Req& req) -> Resp { return handle_post(req); });
    r.get(R"(/api/mcp)", [](const Req& req) -> Resp { return handle_get(req); });
}

}  // namespace sa
