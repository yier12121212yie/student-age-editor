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
#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/utf8.h"
#include "server/state.h"

namespace sa {
namespace {

namespace cs = sa_core::paths;

using p3b::json_str;
using p3b::json_truthy;
using p3b::PyValueError;

constexpr std::size_t kInstallMaxBytes = 100ull * 1024 * 1024;  // api.py:3026

// ---------------------------------------------------------------------------
// 目录与 manifest（plugin_system.plugins_root / _read_manifest）
// ---------------------------------------------------------------------------

std::string plugins_root() {
    // plugin_system.plugins_root: EDITOR_PLUGINS_ROOT or <app_data>/plugins.
    // getenv_utf8: the override is a path and may contain CJK on Windows.
    std::string env = cs::getenv_utf8("EDITOR_PLUGINS_ROOT");
    std::string root = !env.empty() ? env : cs::join(sa::editor_root(), "plugins");
    cs::create_dirs(root);  // best-effort like Python
    return root;
}

// _read_manifest(d) with the §5 "ignore broken plugins" rule: nullopt when
// manifest.json is absent, not utf-8-sig-decodable, unparsable or not an
// object (Python falls back to {} and keeps listing the directory).
std::optional<json> read_manifest(const std::string& dir) {
    auto raw = cs::read_bytes(cs::join(dir, "manifest.json"));
    if (!raw) return std::nullopt;
    auto text = sa_core::decode_utf8_sig_strict(*raw);  // utf-8-sig read
    if (!text) return std::nullopt;
    json parsed = json::parse(*text, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object()) return std::nullopt;
    return parsed;
}

// _safe_pid (plugin_system.py:93-96) — the guard every <pid> route runs first,
// before the id is ever joined onto the root.
bool safe_pid(const std::string& pid) {
    if (pid.empty()) return false;
    for (char c : pid) {
        if (c == '/' || c == '\\' || c == ':') return false;
    }
    return pid.find("..") == std::string::npos;
}

struct Found {
    std::string pid;
    json manifest;
};

// §1 discovery: every sub-directory of plugins_root(), sorted by name
// (listdir_sorted == os.listdir + sorted -> UTF-8 byte order == code point
// order, same as Python's sorted()); __pycache__ excluded as in _reconcile.
std::vector<Found> scan_plugins() {
    std::vector<Found> out;
    const std::string root = plugins_root();
    bool ok = false;
    const std::vector<std::string> names = cs::listdir_sorted(root, &ok);
    if (!ok) return out;
    for (const auto& pid : names) {
        if (pid == "__pycache__") continue;
        const std::string dir = cs::join(root, pid);
        if (!cs::is_dir(dir)) continue;  // plugins.json and stray files are not plugins
        auto manifest = read_manifest(dir);
        if (!manifest) continue;
        out.push_back(Found{pid, std::move(*manifest)});
    }
    return out;
}

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
    e["error"] = "";
    e["risk_ack_at"] = "";
    // §2 manifest passthroughs. Python had no such keys in _entry_for (its
    // ui/service data only surfaced through the aggregation endpoints); kept
    // here so a client can read a plugin's declarations without a second GET.
    if (manifest.contains("ui")) e["ui"] = manifest.at("ui");
    if (manifest.contains("service")) e["service"] = manifest.at("service");
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
            if (!c.is_object()) continue;
            json card = json::object();
            for (const char* k : {"type_id", "name", "icon", "color", "applies_to", "match",
                                  "body_fields", "hidden_ports", "description"}) {
                card[k] = c.contains(k) ? c.at(k) : json();
            }
            card["plugin_id"] = pid;  // setdefault in the engine; inject here
            if (c.contains("plugin_id") && json_truthy(c.at("plugin_id"))) {
                card["plugin_id"] = c.at("plugin_id");
            }
            out.push_back(std::move(card));
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
    for (const char* r : {"agent", "ui", "reload", "install", "install_path"}) {
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

    // GET /api/plugins/ui — api.py:3059-3061 / ui_panels():665.
    r.get(R"(/api/plugins/ui)", [](const Req&) -> Resp {
        json body = json::object();
        body["panels"] = declarative_panels();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/ui/flow_cards — api.py:3063-3065 / flow_cards():676.
    r.get(R"(/api/plugins/ui/flow_cards)", [](const Req&) -> Resp {
        json body = json::object();
        body["flow_cards"] = declarative_flow_cards();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/<pid>/panel/<panel_id> — content of one declared panel.
    // The frontend PluginPane requests this per opened panel; declarative
    // manifests only declare (title/icon/description), so the description is
    // served as a markdown block. Registered here (not retired) because the
    // panel list endpoint advertises these panels as openable.
    r.get(R"(/api/plugins/(?P<pid>[^/]+)/panel/(?P<panel_id>[^/]+))",
          [](const Req& req) -> Resp {
              const std::string pid = req.params.count("pid") ? req.params.at("pid") : "";
              const std::string panel_id =
                  req.params.count("panel_id") ? req.params.at("panel_id") : "";
              auto content = declarative_panel_content(pid, panel_id);
              if (!content) return Resp::Json(404, json{{"error", "panel not found"}});
              return Resp::Json(200, std::move(*content));
          });

    // GET /api/plugins/agent/tools — api.py:3067-3069 / agent_tool_defs():600.
    // Declarative plugins contribute no executable tools, so this stays the
    // empty aggregate until §4 service self-descriptions land.
    r.get(R"(/api/plugins/agent/tools)", [](const Req&) -> Resp {
        json body = json::object();
        body["tools"] = json::array();
        return Resp::Json(200, std::move(body));
    });

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
            json body = json::object();
            body["ok"] = true;
            body["id"] = result.at("id");
            body["plugin"] = result.at("plugin");
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
            json body = json::object();
            body["ok"] = true;
            body["id"] = result.at("id");
            body["plugin"] = result.at("plugin");
            return Resp::Json(200, std::move(body));
        } catch (const PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // POST /api/plugins/reload — api.py:3051-3057. The declarative reader
    // scans the directory on every request, so "reload" is a re-scan by
    // construction (no cache to clear) and therefore idempotent.
    r.post(R"(/api/plugins/reload)", [](const Req&) -> Resp {
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
        return Resp::Json(200, json{{"ok", true}});
    });
}

}  // namespace sa
