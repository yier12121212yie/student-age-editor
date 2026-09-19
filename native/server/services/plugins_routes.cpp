// server/services/plugins_routes.cpp — see plugins_routes.h (PLUGIN_SPEC §5).
//
// Semantics oracle: backend/editor/core/plugin_system.py (_entry_for:167,
// _read_manifest:127, _install_zip:195, install_plugin:249,
// install_plugin_from_path:263, uninstall_plugin:283, list_plugins:403,
// get_plugin_info:410, ui_panels:665) and the response shapes of
// backend/editor/server/api.py:3006-3127.
//
// Documented deviations from the Python engine (all mandated by PLUGIN_SPEC §5,
// "声明型插件常开无启用态"):
//   * no plugins.json registry is ever written and no enable/disable state is
//     kept — entries are synthesized with enabled/loaded == true and
//     error/risk_ack_at empty (no code, hence no risk-acknowledgement step);
//   * a directory whose manifest.json is missing / unparsable / not an object is
//     dropped from every collection, where Python would still list it with
//     default metadata (_read_manifest falls back to {});
//   * `_install_zip`'s "plugin entry file missing" probe is gone: declarative
//     plugins carry no executable entry, so a zip with just manifest.json
//     installs fine;
//   * the id check is a hand-rolled ^[a-z][a-z0-9_-]{0,63}$ (no std::regex):
//     CPython's `$` also matches before a trailing newline, so "abc\n" would
//     pass there and does not here — strictly stricter, never looser.
#include "plugins_routes.h"

#include <cstdlib>
#include <optional>
#include <string>
#include <vector>

#include "p3b_resource_pack.h"  // p3b::PyValueError: the ValueError -> 400 analogue
#include "p3b_support.h"        // strict base64, miniz ZipReader, py_strip/py_repr
#include "plugin_service.h"     // §4 infrastructure: discovery, cache, proxy
#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/utf8.h"
#include "server/state.h"

namespace sa {
namespace ps = plugin_service;

namespace {

namespace cs = sa_core::paths;

using p3b::json_str;
using p3b::json_truthy;
using p3b::PyValueError;

// §1 discovery primitives moved to plugin_service.cpp (the §4 fetcher needs
// the exact same rules); aliased here so the call sites read as before.
using ps::Found;
using ps::plugins_root;
using ps::read_manifest;
using ps::safe_pid;
using ps::scan_plugins;

constexpr std::size_t kInstallMaxBytes = 100ull * 1024 * 1024;  // api.py:3026

// ---------------------------------------------------------------------------
// 条目合成（plugin_system._entry_for）
// ---------------------------------------------------------------------------

// `manifest.get(key) or fallback` keeping the raw JSON value when truthy
// (Python does not str() it; e.g. a numeric "version" survives as a number).
json or_raw(const json& manifest, const char* key, const json& fallback) {
    if (manifest.is_object() && manifest.contains(key) && json_truthy(manifest.at(key))) {
        return manifest.at(key);
    }
    return fallback;
}

json plugin_entry(const std::string& pid, const json& manifest) {
    json e = json::object();
    e["id"] = pid;
    e["name"] = or_raw(manifest, "name", pid);
    e["version"] = or_raw(manifest, "version", std::string());
    e["author"] = or_raw(manifest, "author", std::string());
    e["description"] = or_raw(manifest, "description", std::string());
    e["entry"] = or_raw(manifest, "entry", std::string("plugin.py"));
    // Declarative plugins are always on and always "loaded" (there is nothing
    // to load), so there is no error string and no risk-ack time (PLUGIN_SPEC 5).
    e["enabled"] = true;
    e["loaded"] = true;
    // §4: a service plugin's last refresh verdict lands here ("plugin service
    // unavailable" / "invalid service url: ..."). Read paths never touch the
    // network, so a declarative-only row — and any service row before the
    // first refresh — still carries the Python-compatible "".
    e["error"] = ps::error_of(pid);
    e["risk_ack_at"] = "";
    // §2 manifest passthroughs. Python had no such keys in _entry_for (its
    // ui/service data only surfaced through the aggregation endpoints); kept
    // here so a client can read a plugin's declarations without a second GET.
    if (manifest.contains("ui")) e["ui"] = manifest.at("ui");
    if (manifest.contains("service")) {
        e["service"] = manifest.at("service");
        json status = ps::service_status(pid, manifest);
        if (!status.is_null()) e["service_status"] = std::move(status);
    }
    return e;
}

json plugin_entries() {
    json out = json::array();
    for (const auto& f : scan_plugins()) out.push_back(plugin_entry(f.pid, f.manifest));
    return out;
}

// ---------------------------------------------------------------------------
// 声明型贡献（flow_cards 线格式冻结；panels 同风格聚合）
// ---------------------------------------------------------------------------

// §3 field whitelist + plugin_id injection — ONE normalization shared by the
// manifest reader and the §4 service self-descriptions (PLUGIN_SPEC §4: a
// service's flow_cards carry "与 §3 同字段"). Returns null for a non-object
// element (caller skips), mirroring the "单元素非对象 → 跳过" rule.
json normalize_flow_card(const json& c, const std::string& pid) {
    if (!c.is_object()) return json();
    json card = json::object();
    for (const char* k : {"type_id", "name", "icon", "color", "applies_to", "match",
                          "body_fields", "hidden_ports", "description"}) {
        card[k] = c.contains(k) ? c.at(k) : json();
    }
    card["plugin_id"] = pid;  // setdefault in the engine; inject here
    if (c.contains("plugin_id") && json_truthy(c.at("plugin_id"))) {
        card["plugin_id"] = c.at("plugin_id");
    }
    return card;
}

// The retired plugin engine collected cards registered in-process. The C++
// stub keeps the wire shape ({"flow_cards": [...]}) and serves DECLARATIVE
// manifests only: <plugins_root>/<pid>/manifest.json -> "ui"."flow_cards"
// (or top-level "flow_cards") list entries, plugin_id injected, pids sorted.
// Moved verbatim out of p3b_domain_tools_routes.cpp (R4) — golden
// api_plugins_ui_flow_cards.json pins the field set and key order.
json declarative_flow_cards() {
    json out = json::array();
    const std::string root = plugins_root();
    bool ok = false;
    const std::vector<std::string> names = cs::listdir_sorted(root, &ok);
    if (!ok) return out;
    for (const auto& pid : names) {
        const std::string dir = cs::join(root, pid);
        if (!cs::is_dir(dir)) continue;
        auto manifest = read_manifest(dir);
        if (!manifest) continue;
        const json* cards = nullptr;
        if (manifest->contains("ui") && manifest->at("ui").is_object() &&
            manifest->at("ui").contains("flow_cards") &&
            manifest->at("ui").at("flow_cards").is_array()) {
            cards = &manifest->at("ui").at("flow_cards");
        } else if (manifest->contains("flow_cards") && manifest->at("flow_cards").is_array()) {
            cards = &manifest->at("flow_cards");
        }
        if (cards == nullptr) continue;
        for (const auto& c : *cards) {
            json card = normalize_flow_card(c, pid);
            if (!card.is_null()) out.push_back(std::move(card));
        }
    }
    return out;
}

// ui_panels() analogue: manifest "ui"."panels" array elements passed through
// as-is with plugin_id injected (same style as declarative_flow_cards). The
// retired engine only ever exposed the four declared panel fields, so a
// whitelist would drop forward-compatible keys — §5 leaves the field set open.
json declarative_panels() {
    json out = json::array();
    for (const auto& f : scan_plugins()) {
        const json& manifest = f.manifest;
        if (!manifest.contains("ui") || !manifest.at("ui").is_object()) continue;
        const json& ui = manifest.at("ui");
        if (!ui.contains("panels") || !ui.at("panels").is_array()) continue;
        for (const auto& p : ui.at("panels")) {
            if (!p.is_object()) continue;
            json panel = p;
            panel["plugin_id"] = f.pid;
            if (p.contains("plugin_id") && json_truthy(p.at("plugin_id"))) {
                panel["plugin_id"] = p.at("plugin_id");
            }
            out.push_back(std::move(panel));
        }
    }
    return out;
}

// §4: contributions served from the cached service self-descriptions. These
// read the cache ONLY (plugin_service::describe never touches the network);
// the pid order comes from scan_plugins(), so the merge with the declarative
// halves below stays deterministic (per pid: manifest first, service after).
json service_flow_cards() {
    json out = json::array();
    for (const auto& f : scan_plugins()) {
        json desc = ps::describe(f.pid);
        if (desc.is_null()) continue;
        if (!desc.contains("flow_cards") || !desc.at("flow_cards").is_array()) continue;
        for (const auto& c : desc.at("flow_cards")) {
            json card = normalize_flow_card(c, f.pid);
            if (!card.is_null()) out.push_back(std::move(card));
        }
    }
    return out;
}

json service_panels() {
    json out = json::array();
    for (const auto& f : scan_plugins()) {
        json desc = ps::describe(f.pid);
        if (desc.is_null()) continue;
        if (!desc.contains("panels") || !desc.at("panels").is_array()) continue;
        for (const auto& p : desc.at("panels")) {
            if (!p.is_object()) continue;
            json panel = p;
            panel["plugin_id"] = f.pid;
            if (p.contains("plugin_id") && json_truthy(p.at("plugin_id"))) {
                panel["plugin_id"] = p.at("plugin_id");
            }
            out.push_back(std::move(panel));
        }
    }
    return out;
}

// get_plugin_info(): entry + the retired engine's empty in-process
// contributions block (routes/tools/commands are gone for good; panels and
// flow_cards are served by the aggregation endpoints from the manifest).
json plugin_info(const std::string& pid) {
    // _safe_pid runs before any join, so a "..\\x" style pid can never steer the
    // scan outside the root. __pycache__ is excluded exactly like
    // _reconcile():407 — it never enters the registry, hence 404 there too.
    if (!safe_pid(pid) || pid == "__pycache__") return json();
    const std::string dir = cs::join(plugins_root(), pid);
    if (!cs::is_dir(dir)) return json();
    auto manifest = read_manifest(dir);
    if (!manifest) return json();
    json entry = plugin_entry(pid, *manifest);
    json contrib = json::object();
    contrib["routes"] = json::array();
    contrib["tools"] = json::array();
    contrib["commands"] = json::array();
    contrib["panels"] = json::array();
    contrib["flow_cards"] = json::array();
    entry["contributions"] = std::move(contrib);
    return entry;
}

// GET /api/plugins/<pid>/panel/<panel_id> payload (plugin_pane.dart consumes
// {"title", "blocks"}). Declarative plugins carry no executable panels, so the
// only content available is the manifest declaration itself: the description is
// rendered as a markdown block. Returns nullopt when the plugin or the declared
// panel_id does not exist (caller answers 404), mirroring the panel list served
// by GET /api/plugins/ui (declarative_panels above).
std::optional<json> declarative_panel_content(const std::string& pid,
                                              const std::string& panel_id) {
    if (!safe_pid(pid) || panel_id.empty()) return std::nullopt;
    const std::string dir = cs::join(plugins_root(), pid);
    if (!cs::is_dir(dir)) return std::nullopt;
    auto manifest = read_manifest(dir);
    if (!manifest) return std::nullopt;
    if (!manifest->contains("ui") || !manifest->at("ui").is_object()) return std::nullopt;
    const json& ui = manifest->at("ui");
    if (!ui.contains("panels") || !ui.at("panels").is_array()) return std::nullopt;
    for (const auto& p : ui.at("panels")) {
        if (!p.is_object()) continue;
        if (!p.contains("panel_id") || !p.at("panel_id").is_string()) continue;
        if (p.at("panel_id").get<std::string>() != panel_id) continue;
        json out = json::object();
        out["title"] = p.contains("title") ? p.at("title") : json(panel_id);
        json blocks = json::array();
        if (p.contains("description") && p.at("description").is_string() &&
            !p.at("description").get<std::string>().empty()) {
            blocks.push_back(json{{"type", "markdown"},
                                  {"text", p.at("description")}});
        }
        out["blocks"] = std::move(blocks);
        return out;
    }
    return std::nullopt;
}

// ---------------------------------------------------------------------------
// 安装 / 卸载（plugin_system._install_zip / install_plugin* / uninstall_plugin）
// ---------------------------------------------------------------------------

// _PLUGIN_ID_RE + RESERVED_IDS (plugin_system.py:26-28).
bool plugin_id_valid(const std::string& pid) {
    if (pid.empty() || pid.size() > 64) return false;
    if (pid[0] < 'a' || pid[0] > 'z') return false;
    for (char c : pid) {
        const bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) return false;
    }
    return true;
}

bool reserved_id(const std::string& pid) {
    // "service" joins the list with §4: a plugin directory named "service"
    // would be shadowed by the /api/plugins/service/<pid>/<subpath> proxy.
    for (const char* r : {"agent", "ui", "reload", "install", "install_path", "service"}) {
        if (pid == r) return true;
    }
    return false;
}

void validate_pid(const std::string& pid) {
    if (!plugin_id_valid(pid)) throw PyValueError("invalid plugin id: " + p3b::py_repr(json(pid)));
    if (reserved_id(pid)) throw PyValueError("reserved plugin id: " + pid);
}

// _manifest_id: only a string "id" counts, trimmed.
std::string manifest_id(const json& manifest) {
    if (!manifest.is_object() || !manifest.contains("id")) return {};
    const json& mid = manifest.at("id");
    if (!mid.is_string()) return {};
    return p3b::py_strip(mid.get<std::string>());
}

// _id_from_filename: basename -> drop extension -> strip -> lower -> non
// [a-z0-9_-] -> "_" (per CODE POINT, as Python's re.sub does — a UTF-8 lead
// byte would otherwise become one "_" per byte) -> "plugin" when empty ->
// "p_" prefix when it does not start a-z -> truncate to 64.
std::string id_from_filename(const std::string& filename) {
    std::string base = cs::basename(filename);
    const size_t dot = base.rfind('.');
    if (dot != std::string::npos && dot != 0) base = base.substr(0, dot);
    base = p3b::py_strip(base);
    std::string safe;
    size_t i = 0;
    while (i < base.size()) {
        const unsigned char c = static_cast<unsigned char>(base[i]);
        size_t len = 1;
        if (c >= 0xF0) len = 4;
        else if (c >= 0xE0) len = 3;
        else if (c >= 0xC0) len = 2;
        if (len > 1) {
            safe.push_back('_');  // non-ASCII code point -> single "_"
        } else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
            safe.push_back(static_cast<char>(c));
        } else if (c >= 'A' && c <= 'Z') {
            safe.push_back(static_cast<char>(c - 'A' + 'a'));
        } else {
            safe.push_back('_');
        }
        i += len > base.size() - i ? base.size() - i : len;
    }
    if (safe.empty()) safe = "plugin";
    if (!(safe[0] >= 'a' && safe[0] <= 'z')) safe = "p_" + safe;
    if (safe.size() > 64) safe.resize(64);  // all ASCII: byte == code point
    return safe;
}

// _install_zip without the entry-file probe and without the plugins.json
// registry write (declarative plugins are usable right after install).
json install_zip(const p3b::ZipReader& z, const std::string& filename) {
    const std::vector<std::string> names = z.names();
    if (names.empty()) throw PyValueError("empty zip");
    for (const auto& n : names) {
        // Python: `n.startswith("/") or ".." in n or ":" in n`.
        if ((!n.empty() && n[0] == '/') || n.find("..") != std::string::npos ||
            n.find(':') != std::string::npos) {
            throw PyValueError("illegal entry: " + p3b::py_repr(json(n)));
        }
    }
    if (!z.has("manifest.json")) throw PyValueError("zip missing manifest.json");
    json manifest;
    if (auto buf = z.read("manifest.json")) {
        if (auto text = sa_core::decode_utf8_sig_strict(*buf)) {
            json parsed = json::parse(*text, nullptr, false);
            if (!parsed.is_discarded() && parsed.is_object()) manifest = std::move(parsed);
        }
    }
    if (!manifest.is_object()) manifest = json::object();
    std::string pid = manifest_id(manifest);
    if (pid.empty()) pid = id_from_filename(filename);
    validate_pid(pid);
    const std::string dest = cs::join(plugins_root(), pid);
    if (cs::exists(dest)) throw PyValueError("plugin already exists: " + pid);
    cs::create_dirs(dest);
    if (!z.extract_all(dest)) {
        cs::remove_tree(dest);
        throw PyValueError("extract failed: zip extraction error");
    }
    // manifest.setdefault(name/version/author/description) + manifest["id"]=pid
    // (insertion order matches Python's setdefault chain; the write is
    // ensure_ascii=False, indent=2 like Python's json.dump).
    if (!manifest.contains("name")) manifest["name"] = pid;
    if (!manifest.contains("version")) manifest["version"] = "1.0.0";
    if (!manifest.contains("author")) manifest["author"] = "";
    if (!manifest.contains("description")) manifest["description"] = "";
    manifest["id"] = pid;
    try {
        sa_core::write_text_atomic(cs::join(dest, "manifest.json"),
                                   sa_core::py_dumps_indent(manifest));
    } catch (...) {
        // best-effort (Python wraps the dump in try/except)
    }
    json out = json::object();
    out["id"] = pid;
    out["plugin"] = plugin_entry(pid, manifest);
    return out;
}

// install_plugin(zip_bytes, filename)
json install_plugin_bytes(std::string_view zip_bytes, const std::string& filename) {
    if (zip_bytes.empty() || zip_bytes.size() < 4) throw PyValueError("empty zip");
    if (zip_bytes.size() > 500ull * 1024 * 1024) throw PyValueError("zip too large (>500MB)");
    auto z = p3b::ZipReader::open_bytes(zip_bytes);
    if (!z) throw PyValueError("invalid zip: File is not a zip file");
    return install_zip(*z, filename);
}

// install_plugin_from_path(path, filename)
json install_plugin_from_path(const std::string& path, const std::string& filename) {
    if (path.empty() || !cs::is_file(path)) throw PyValueError("file not found: " + path);
    const long long size = cs::file_size(path);
    if (size <= 0) throw PyValueError("empty file");
    if (size > 4ll * 1024 * 1024 * 1024) throw PyValueError("zip too large (>4GB)");
    auto z = p3b::ZipReader::open_file(path);
    if (!z) throw PyValueError("invalid zip: File is not a zip file");
    return install_zip(*z, filename.empty() ? cs::basename(path) : filename);
}

// uninstall_plugin(pid) — pure directory removal: there is no enabled state to
// check ("请先停用该插件再卸载" is gone with the engine) and no registry entry.
void uninstall_plugin(const std::string& pid) {
    if (!safe_pid(pid)) throw PyValueError("invalid plugin id");
    const std::string d = cs::join(plugins_root(), pid);
    if (!cs::is_dir(d)) throw PyValueError("plugin not found: " + pid);
    cs::remove_tree(d);
}

// install 后的响应条目：install_zip 在 §4 刷新之前合成了 entry，这里从盘上
// manifest 重合成一次，让刷新结果（error / service_status）如实出现在安装响应里。
json fresh_entry(const std::string& pid) {
    auto manifest = ps::read_manifest(cs::join(ps::plugins_root(), pid));
    return plugin_entry(pid, manifest ? *manifest : json::object());
}

// §4 代理 / agent exec 的转发体：raw_body 原样（传输层保留的 wire 副本）；
// 没有副本时回退到解析视图的再序列化——包括 {"_raw": text} 这个解析失败标记，
// 其 text 才是真正的请求体。
std::string forward_body(const Req& req) {
    if (!req.raw_body.empty()) return req.raw_body;
    if (req.body.is_null()) return {};
    if (req.body.is_object() && req.body.size() == 1 && req.body.contains("_raw") &&
        req.body.at("_raw").is_string()) {
        return req.body.at("_raw").get<std::string>();
    }
    return sa_core::py_dumps(req.body);
}

// ---------------------------------------------------------------------------
// body helpers (api.py reads every plugin body as a dict)
// ---------------------------------------------------------------------------

// `body.get(key)` without the JSON copy: a 100MB+ base64 install payload must
// not be duplicated on the way to the size gate.
const json& b_ref(const Req& req, const char* key) {
    static const json kNull;
    if (!req.body.is_object()) return kNull;
    auto it = req.body.find(key);
    return it == req.body.end() ? kNull : it.value();
}

// `body.get(key) or fallback` rendered to a string (Python passes the raw
// value on; non-strings only ever reach str() coercions or a base64 reject,
// which json_str reproduces for scalars).
std::string body_str_or(const Req& req, const char* key, const std::string& fallback) {
    const json& v = b_ref(req, key);
    return json_truthy(v) ? json_str(v) : fallback;
}

}  // namespace

void register_plugins_routes(Router& r) {
    // Static paths first: the transport dispatches in registration order
    // (httpd.cpp:488-495, fullmatch per method bucket), so the /<pid> patterns
    // below must not get a chance to swallow "ui"/"install"/"reload"/...
    // Registration order otherwise follows api.py:3006-3127.

    // GET /api/plugins — api.py:3006-3012 / list_plugins():403.
    r.get(R"(/api/plugins)", [](const Req&) -> Resp {
        json body = json::object();
        body["plugins"] = plugin_entries();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/ui — api.py:3059-3061 / ui_panels():665, extended with
    // the §4 service self-description panels (declarative rows first, pid
    // order preserved; read-only over the refresh cache).
    r.get(R"(/api/plugins/ui)", [](const Req&) -> Resp {
        json body = json::object();
        json panels = declarative_panels();
        const json served = service_panels();
        for (const auto& p : served) panels.push_back(p);
        body["panels"] = std::move(panels);
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/ui/flow_cards — api.py:3063-3065 / flow_cards():676,
    // extended with the §4 service cards run through the same §3 whitelist.
    r.get(R"(/api/plugins/ui/flow_cards)", [](const Req&) -> Resp {
        json body = json::object();
        json cards = declarative_flow_cards();
        const json served = service_flow_cards();
        for (const auto& c : served) cards.push_back(c);
        body["flow_cards"] = std::move(cards);
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/<pid>/panel/<panel_id> — content of one declared panel.
    // The frontend PluginPane requests this per opened panel; declarative
    // manifests only declare (title/icon/description), so the description is
    // served as a markdown block. Registered here (not retired) because the
    // panel list endpoint advertises these panels as openable. §4: when the
    // declaration has no such panel but the plugin declares a service, the
    // panel content is proxied (GET <url>/panel/<panel_id>) — the dynamic
    // {"title","blocks"} contract the retired engine's panels used to serve.
    r.get(R"(/api/plugins/(?P<pid>[^/]+)/panel/(?P<panel_id>[^/]+))",
          [](const Req& req) -> Resp {
              const std::string pid = req.params.count("pid") ? req.params.at("pid") : "";
              const std::string panel_id =
                  req.params.count("panel_id") ? req.params.at("panel_id") : "";
              auto content = declarative_panel_content(pid, panel_id);
              if (content) return Resp::Json(200, std::move(*content));
              if (safe_pid(pid) && !panel_id.empty()) {
                  auto manifest = ps::read_manifest(cs::join(ps::plugins_root(), pid));
                  if (manifest && manifest->contains("service")) {
                      return ps::proxy(pid, "GET", "panel/" + panel_id, "", "");
                  }
              }
              return Resp::Json(404, json{{"error", "panel not found"}});
          });

    // GET /api/plugins/agent/tools — api.py:3067-3069 / agent_tool_defs():600.
    // Declarative plugins contribute no executable tools; §4 service plugins
    // do, through their cached self-descriptions (each tool carries plugin_id;
    // execution goes through POST /api/plugins/agent/exec below).
    r.get(R"(/api/plugins/agent/tools)", [](const Req&) -> Resp {
        json body = json::object();
        body["tools"] = ps::agent_tools();
        return Resp::Json(200, std::move(body));
    });

    // POST /api/plugins/agent/exec — §5 target state: the retired in-process
    // engine is gone, and an agent tool call is routed THROUGH the §4 service
    // proxy to the owning plugin's HTTP service. The body ({"name","args"})
    // is forwarded verbatim; the upstream response passes through untouched
    // (the AI panel reads {"result": ...}).
    r.post(R"(/api/plugins/agent/exec)", [](const Req& req) -> Resp {
        const std::string name = body_str_or(req, "name", "");
        if (name.empty()) return Resp::Json(400, json{{"error", "name required"}});
        return ps::exec_tool(name, forward_body(req));
    });

    // §4 service proxy — ALL verbs on /api/plugins/service/<pid>/<subpath>.
    // Registered before the /<pid> patterns can ever see "service" (reserved
    // id since §4, so no plugin directory can shadow these). Errors: 400 bad
    // pid/subpath/query/declaration, 404 unknown plugin, 502 upstream down.
    const auto service_proxy = [](const Req& req) -> Resp {
        const std::string pid = req.params.count("pid") ? req.params.at("pid") : "";
        const std::string subpath = req.params.count("subpath") ? req.params.at("subpath") : "";
        return ps::proxy(pid, req.method, subpath, req.raw_query, forward_body(req));
    };
    r.get(R"(/api/plugins/service/(?P<pid>[^/]+)/(?P<subpath>.+))", service_proxy);
    r.post(R"(/api/plugins/service/(?P<pid>[^/]+)/(?P<subpath>.+))", service_proxy);
    r.put(R"(/api/plugins/service/(?P<pid>[^/]+)/(?P<subpath>.+))", service_proxy);
    r.del(R"(/api/plugins/service/(?P<pid>[^/]+)/(?P<subpath>.+))", service_proxy);

    // POST /api/plugins/install — api.py:3014-3034.
    r.post(R"(/api/plugins/install)", [](const Req& req) -> Resp {
        const std::string b64 = body_str_or(req, "data", "");
        if (b64.empty()) return Resp::Json(400, json{{"error", "zip data required"}});
        auto raw = p3b::b64_decode_strict(b64);  // base64.b64decode(..., validate=True)
        if (!raw) return Resp::Json(400, json{{"error", "invalid base64"}});
        if (raw->size() > kInstallMaxBytes) {
            return Resp::Json(400, json{{"error", "zip too large (>100MB)"}});
        }
        try {
            json result = install_plugin_bytes(*raw, body_str_or(req, "filename", "plugin.zip"));
            const std::string pid = result.at("id").get<std::string>();
            ps::refresh_one(pid);  // §4: a declared service is fetched right away
            json body = json::object();
            body["ok"] = true;
            body["id"] = pid;
            body["plugin"] = fresh_entry(pid);
            return Resp::Json(200, std::move(body));
        } catch (const PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // POST /api/plugins/install_path — api.py:3036-3049.
    r.post(R"(/api/plugins/install_path)", [](const Req& req) -> Resp {
        const std::string path = body_str_or(req, "path", "");
        if (path.empty()) return Resp::Json(400, json{{"error", "path required"}});
        const std::string filename = body_str_or(req, "filename", cs::basename(path));
        try {
            json result = install_plugin_from_path(path, filename.empty() ? "plugin.zip" : filename);
            const std::string pid = result.at("id").get<std::string>();
            ps::refresh_one(pid);  // §4: a declared service is fetched right away
            json body = json::object();
            body["ok"] = true;
            body["id"] = pid;
            body["plugin"] = fresh_entry(pid);
            return Resp::Json(200, std::move(body));
        } catch (const PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // POST /api/plugins/reload — api.py:3051-3057. The declarative reader
    // scans the directory on every request, so "reload" is a re-scan by
    // construction (no cache to clear) and therefore idempotent. §4 adds the
    // one thing that IS cached: the service self-descriptions are re-fetched
    // synchronously here (4s total budget), so the returned rows carry the
    // fresh error/service_status verdicts.
    r.post(R"(/api/plugins/reload)", [](const Req&) -> Resp {
        ps::refresh_all();
        json body = json::object();
        body["ok"] = true;
        body["plugins"] = plugin_entries();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/<pid> — api.py:3086-3094 / get_plugin_info():410.
    r.get(R"(/api/plugins/(?P<pid>[^/]+))", [](const Req& req) -> Resp {
        const std::string pid = req.params.count("pid") ? req.params.at("pid") : "";
        json info = plugin_info(pid);
        if (info.is_null()) return Resp::Json(404, json{{"error", "plugin not found"}});
        return Resp::Json(200, std::move(info));
    });

    // POST /api/plugins/<pid>/enable|disable — api.py:3096-3117. §5 retires the
    // lifecycle permanently (declarative plugins have no off state). Registered
    // on purpose so the answer is an explicit 410 instead of a bare 404.
    const auto retired = [](const Req&) -> Resp {
        return Resp::Json(410, json{{"error", "声明型插件常开无启用态，enable/disable 已废弃"}});
    };
    r.post(R"(/api/plugins/(?P<pid>[^/]+)/enable)", retired);
    r.post(R"(/api/plugins/(?P<pid>[^/]+)/disable)", retired);

    // DELETE /api/plugins/<pid> — api.py:3119-3127 / uninstall_plugin():283.
    r.del(R"(/api/plugins/(?P<pid>[^/]+))", [](const Req& req) -> Resp {
        const std::string pid = req.params.count("pid") ? req.params.at("pid") : "";
        try {
            uninstall_plugin(pid);
        } catch (const PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
        ps::refresh_one(pid);  // §4: a gone directory drops its service verdict
        return Resp::Json(200, json{{"ok", true}});
    });
}

}  // namespace sa
