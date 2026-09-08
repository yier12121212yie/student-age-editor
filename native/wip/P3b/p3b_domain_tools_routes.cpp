// wip/P3b — see p3b_domain_tools_routes.h. Port of the api.py families:
//   AI 工具沙箱 (api.py:1618-1666), AI 细分领域 (api.py:1670-1752),
//   AI 共享配置 /api/ai/settings (api.py:851-869), 附件上传 (api.py:1997-2020),
//   官方模组 manifest/status (api.py:2023-2051), 资源包 (api.py:2636-2712),
//   plugins 只读桩 (api.py:3006-3127, retired engine -> golden shape).
#include <cstdlib>
#include <optional>
#include <string>
#include <vector>

#include "p3b_ai_files.h"
#include "p3b_ai_settings.h"
#include "p3b_domain_service.h"
#include "p3b_domain_tools_routes.h"
#include "p3b_fs_tools.h"
#include "p3b_resource_pack.h"
#include "p3b_support.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/state.h"

namespace sa {
namespace {

namespace rp = p3b::resource_pack;

const std::map<std::string, std::string>& empty_query() {
    static const std::map<std::string, std::string> kEmpty;
    return kEmpty;
}

// Python `(_query or {}).get(key, default)` — the query map is already
// last-wins decoded by the transport (httpd.py:132-134).
std::string q_get(const Req& req, const std::string& key, const std::string& def = "") {
    const auto& q = req.query.empty() ? empty_query() : req.query;
    auto it = q.find(key);
    return it == q.end() ? def : it->second;
}

// json value -> Python truthy (shared helper).
using p3b::json_truthy;
using p3b::json_str;

// `body.get(k)` as json: null when missing OR body not an object (Python body
// is always a dict here; _raw bodies behave like {} for .get).
json b_get(const Req& req, const char* key) {
    if (!req.body.is_object()) return json();
    auto it = req.body.find(key);
    return it == req.body.end() ? json() : it.value();
}

// `x or default` chain over json bodies (returns json).
json b_or(const json& v, const char* key) {
    if (json_truthy(v)) return v;
    // caller already fetched the first candidate; this overload fetches next
    (void)key;
    return v;
}

Resp sandbox_400(const SandboxError& e) {
    return Resp::Json(400, json{{"error", e.what()}});
}

// ---------------------------------------------------------------------------
// plugins 只读桩 helpers
// ---------------------------------------------------------------------------

std::string plugins_root() {
    // plugin_system.plugins_root: EDITOR_PLUGINS_ROOT or <app_data>/plugins.
    const char* env = std::getenv("EDITOR_PLUGINS_ROOT");
    std::string root = (env && *env) ? std::string(env) : sa_core::paths::join(sa::editor_root(), "plugins");
    sa_core::paths::create_dirs(root);  // best-effort like Python
    return root;
}

// The retired plugin engine collected cards registered in-process. The C++
// stub keeps the wire shape ({"flow_cards": [...]}) and serves DECLARATIVE
// manifests only: <plugins_root>/<pid>/manifest.json -> "ui"."flow_cards"
// (or top-level "flow_cards") list entries, plugin_id injected, pids sorted.
json declarative_flow_cards() {
    json out = json::array();
    const std::string root = plugins_root();
    bool ok = false;
    const std::vector<std::string> names = sa_core::paths::listdir_sorted(root, &ok);
    if (!ok) return out;
    for (const auto& pid : names) {
        const std::string dir = sa_core::paths::join(root, pid);
        if (!sa_core::paths::is_dir(dir)) continue;
        auto raw = sa_core::paths::read_bytes(sa_core::paths::join(dir, "manifest.json"));
        if (!raw) continue;
        auto text = sa_core::decode_utf8_sig_strict(*raw);  // utf-8-sig read
        if (!text) continue;
        json manifest = json::parse(*text, nullptr, false);
        if (manifest.is_discarded() || !manifest.is_object()) continue;
        const json* cards = nullptr;
        if (manifest.contains("ui") && manifest.at("ui").is_object() &&
            manifest.at("ui").contains("flow_cards") && manifest.at("ui").at("flow_cards").is_array()) {
            cards = &manifest.at("ui").at("flow_cards");
        } else if (manifest.contains("flow_cards") && manifest.at("flow_cards").is_array()) {
            cards = &manifest.at("flow_cards");
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

}  // namespace

void register_domain_tools_routes(Router& r) {
    // ------------------------------------------------------------------ tools
    // GET /api/tools/list — api.py:1618-1630.
    r.get(R"(/api/tools/list)", [](const Req& req) -> Resp {
        const std::string scope = q_get(req, "scope", "mod");
        const std::string path = q_get(req, "path", "");
        const std::string deep_v = q_get(req, "deep", "");
        const bool deep = deep_v == "1" || deep_v == "true" || deep_v == "yes";
        const std::string root = sandbox_root(scope);
        json body = json::object();
        body["root"] = root;
        body["path"] = path;
        if (!sa_core::paths::is_dir(root)) {
            body["entries"] = json::array();  // missing root == empty listing
            return Resp::Json(200, std::move(body));
        }
        try {
            body["entries"] = p3b::list_dir(root, path, deep);
        } catch (const SandboxError& e) {
            return sandbox_400(e);
        }
        return Resp::Json(200, std::move(body));
    });

    // GET /api/tools/read — api.py:1632-1641.
    r.get(R"(/api/tools/read)", [](const Req& req) -> Resp {
        const std::string scope = q_get(req, "scope", "mod");
        const std::string path = q_get(req, "path", "");
        const std::string root = sandbox_root(scope);
        try {
            return Resp::Json(200, p3b::read_file(root, path, false));
        } catch (const SandboxError& e) {
            return sandbox_400(e);
        }
    });

    // PUT /api/tools/write — api.py:1643-1655.
    r.put(R"(/api/tools/write)", [](const Req& req) -> Resp {
        json scope_v = b_get(req, "scope");
        const std::string scope =
            req.body.is_object() && req.body.contains("scope") ? json_str(scope_v) : "mod";
        const std::string path = json_str(b_get(req, "path").is_null() ? json("") : b_get(req, "path"));
        // content: body.get("content", "") — a present null becomes str(None)
        // == "None" in Python, so distinguish missing vs null here.
        std::string content;
        if (req.body.is_object() && req.body.contains("content")) {
            content = json_str(req.body.at("content"));  // null -> "None"
        }
        const bool base64_mode = json_truthy(b_get(req, "base64"));
        const std::string root = sandbox_root(scope);
        try {
            return Resp::Json(200, p3b::write_file(root, path, content, base64_mode));
        } catch (const SandboxError& e) {
            return sandbox_400(e);
        }
    });

    // GET /api/tools/stat — api.py:1657-1666.
    r.get(R"(/api/tools/stat)", [](const Req& req) -> Resp {
        const std::string scope = q_get(req, "scope", "mod");
        const std::string path = q_get(req, "path", "");
        const std::string root = sandbox_root(scope);
        try {
            return Resp::Json(200, p3b::stat_path(root, path));
        } catch (const SandboxError& e) {
            return sandbox_400(e);
        }
    });

    // ---------------------------------------------------------------- ai 领域
    // GET /api/ai/domains — api.py:1670-1672.
    r.get(R"(/api/ai/domains)", [](const Req&) -> Resp {
        json body = json::object();
        body["domains"] = p3b::get_domains();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/ai/domain/items — api.py:1686-1698.
    r.get(R"(/api/ai/domain/items)", [](const Req& req) -> Resp {
        try {
            json qv;  // query values are strings; missing -> null (Python None)
            auto opt = [&](const char* k) -> json {
                const std::string v = q_get(req, k, "\x01missing");
                return v == "\x01missing" ? json() : json(v);
            };
            return Resp::Json(200, p3b::list_domain_items(q_get(req, "domain", ""), opt("q"),
                                                          opt("limit"), opt("table")));
        } catch (const SandboxError& e) {
            return sandbox_400(e);
        }
    });

    // GET /api/ai/domain/item — api.py:1700-1711.
    r.get(R"(/api/ai/domain/item)", [](const Req& req) -> Resp {
        try {
            return Resp::Json(200,
                              p3b::get_domain_item(q_get(req, "domain", ""), q_get(req, "cfg", ""),
                                                   json(q_get(req, "id", ""))));
        } catch (const SandboxError& e) {
            return sandbox_400(e);
        }
    });

    // PUT /api/ai/domain/item — api.py:1713-1725.
    r.put(R"(/api/ai/domain/item)", [](const Req& req) -> Resp {
        try {
            const std::string domain = json_str(b_get(req, "domain").is_null() ? json("")
                                                                              : b_get(req, "domain"));
            const std::string cfg = json_str(b_get(req, "cfg").is_null() ? json("")
                                                                         : b_get(req, "cfg"));
            const std::string id = json_str(b_get(req, "id").is_null() ? json("")
                                                                       : b_get(req, "id"));
            return Resp::Json(200, p3b::update_domain_item(domain, cfg, json(id), b_get(req, "patch")));
        } catch (const SandboxError& e) {
            return sandbox_400(e);
        }
    });

    // POST /api/ai/domain/item — api.py:1727-1739. id stays raw json (may be
    // absent -> null -> auto-allocation / data.id takeover).
    r.post(R"(/api/ai/domain/item)", [](const Req& req) -> Resp {
        try {
            const std::string domain = json_str(b_get(req, "domain").is_null() ? json("")
                                                                              : b_get(req, "domain"));
            const std::string cfg = json_str(b_get(req, "cfg").is_null() ? json("")
                                                                         : b_get(req, "cfg"));
            return Resp::Json(200,
                              p3b::create_domain_item(domain, cfg, b_get(req, "id"),
                                                      b_get(req, "data")));
        } catch (const SandboxError& e) {
            return sandbox_400(e);
        }
    });

    // DELETE /api/ai/domain/item — api.py:1741-1752.
    r.del(R"(/api/ai/domain/item)", [](const Req& req) -> Resp {
        try {
            return Resp::Json(200,
                              p3b::delete_domain_item(q_get(req, "domain", ""),
                                                      q_get(req, "cfg", ""),
                                                      json(q_get(req, "id", ""))));
        } catch (const SandboxError& e) {
            return sandbox_400(e);
        }
    });

    // -------------------------------------------------------------- ai settings
    // GET /api/ai/settings — api.py:851-857 (env_store.read_ai_settings).
    r.get(R"(/api/ai/settings)", [](const Req&) -> Resp {
        json body = json::object();
        body["settings"] = p3b::ai_settings::read_settings(sa::editor_root());
        return Resp::Json(200, std::move(body));
    });

    // PUT /api/ai/settings — api.py:859-869.
    r.put(R"(/api/ai/settings)", [](const Req& req) -> Resp {
        if (req.body.is_array() || (!req.body.is_object() && !req.body.is_null())) {
            throw ApiError("AttributeError", "'list' object has no attribute 'get'");
        }
        json inner = b_get(req, "settings");
        json patch;
        if (req.body.is_object() && req.body.contains("settings")) {
            if (!inner.is_object()) {
                return Resp::Json(400, json{{"error", "body must be a settings object"}});
            }
            patch = inner;
        } else {
            patch = req.body.is_object() ? req.body : json::object();
        }
        json body = json::object();
        body["ok"] = true;
        body["settings"] = p3b::ai_settings::write_settings(sa::editor_root(), patch);
        return Resp::Json(200, std::move(body));
    });

    // ---------------------------------------------------------------- ai upload
    // POST /api/ai/upload — api.py:1997-2020.
    r.post(R"(/api/ai/upload)", [](const Req& req) -> Resp {
        const std::string name = p3b::py_strip(json_str(b_get(req, "name").is_null()
                                                             ? json("")
                                                             : b_get(req, "name")));
        const std::string data = json_str(b_get(req, "data").is_null() ? json("")
                                                                       : b_get(req, "data"));
        if (name.empty()) return Resp::Json(400, json{{"error", "缺少文件名 name"}});
        if (data.empty()) return Resp::Json(400, json{{"error", "缺少文件内容 data（base64）"}});
        auto raw = p3b::b64_decode_strict(data);
        if (!raw) return Resp::Json(400, json{{"error", "data 不是合法的 base64 编码"}});
        if (raw->empty()) return Resp::Json(400, json{{"error", "文件内容为空"}});
        if (raw->size() > static_cast<size_t>(p3b::kUploadMaxFileBytes)) {
            return Resp::Json(400, json{{"error",
                                         "文件过大：最大 " +
                                             std::to_string(p3b::kUploadMaxFileBytes / (1024 * 1024)) +
                                             "MB"}});
        }
        json result;
        try {
            result = p3b::parse_upload_file(name, *raw);
        } catch (const p3b::UploadError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
        json body = json::object();
        body["ok"] = true;
        for (auto it = result.begin(); it != result.end(); ++it) body[it.key()] = it.value();
        return Resp::Json(200, std::move(body));
    });

    // ----------------------------------------------------------- manifest/status
    // GET /api/manifest/status — api.py:2023-2051.
    r.get(R"(/api/manifest/status)", [](const Req&) -> Resp {
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        json body = json::object();
        if (mod_root.empty()) {
            body["selected"] = false;
            body["checks"] = json::array();
            return Resp::Json(200, std::move(body));
        }
        body["selected"] = true;
        const std::string mpath = sa_core::paths::join(mod_root, "manifest.json");
        if (!sa_core::paths::is_file(mpath)) {
            body["has_manifest"] = false;
            body["checks"] = json::array({{{"key", "manifest.json"},
                                           {"ok", false},
                                           {"detail", "缺少 manifest.json"}}});
            return Resp::Json(200, std::move(body));
        }
        body["has_manifest"] = true;
        auto raw = sa_core::paths::read_bytes(mpath);
        auto text = raw ? sa_core::decode_utf8_sig_strict(*raw) : std::optional<std::string>();
        json manifest = text ? json::parse(*text, nullptr, false) : json();
        const bool parse_failed = !text || manifest.is_discarded() || !raw;
        if (parse_failed) {
            // str(JSONDecodeError) approximation (the golden env never hits this;
            // Python embeds the exact decode error text).
            const std::string detail = "解析失败: 文件内容不是合法 JSON";
            body["parse_error"] = "文件内容不是合法 JSON";
            body["checks"] = json::array({{{"key", "manifest.json"},
                                           {"ok", false},
                                           {"detail", detail}}});
            return Resp::Json(200, std::move(body));
        }
        if (!manifest.is_object()) {
            throw ApiError("AttributeError", "'list' object has no attribute 'get'");
        }
        json checks = json::array();
        for (auto& kv : std::vector<std::pair<std::string, std::string>>{
                 {"title", "标题"}, {"description", "简介"}, {"version", "版本"}}) {
            json v = manifest.contains(kv.first) ? manifest.at(kv.first) : json();
            json c = json::object();
            c["key"] = kv.first;
            c["label"] = kv.second;
            c["ok"] = json_truthy(v);
            c["detail"] = p3b::utf8_head(json_str(json_truthy(v) ? v : json("（缺失）")), 120);
            checks.push_back(std::move(c));
        }
        const std::string cfg = sa::cfg_dir();
        long long cfg_count = 0;
        if (!cfg.empty() && sa_core::paths::is_dir(cfg)) {
            bool ok = false;
            for (const auto& f : sa_core::paths::listdir_sorted(cfg, &ok)) {
                if (!ok) break;
                if (sa_core::str::ends_with(f, ".json")) ++cfg_count;  // listdir, no isfile()
            }
        }
        json c = json::object();
        c["key"] = "cfgs";
        c["label"] = "配置表";
        c["ok"] = cfg_count > 0;
        c["detail"] = std::to_string(cfg_count) + " 个 JSON 配置表";
        checks.push_back(std::move(c));
        body["manifest"] = std::move(manifest);
        body["checks"] = std::move(checks);
        return Resp::Json(200, std::move(body));
    });

    // ------------------------------------------------------------- resource packs
    // GET /api/resource_packs — api.py:2636-2642.
    r.get(R"(/api/resource_packs)", [](const Req&) -> Resp {
        try {
            return Resp::Json(200, rp::list_packs());
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(500, json{{"error", std::string("ValueError: ") + e.what()}});
        }
    });

    // POST /api/resource_packs/install — api.py:2644-2664.
    r.post(R"(/api/resource_packs/install)", [](const Req& req) -> Resp {
        json b64 = b_get(req, "data");
        if (!json_truthy(b64)) b64 = b_get(req, "zip_base64");
        if (!json_truthy(b64)) return Resp::Json(400, json{{"error", "zip_base64 required"}});
        json fn = b_get(req, "filename");
        if (!json_truthy(fn)) fn = b_get(req, "name");
        const std::string filename =
            json_truthy(fn) ? json_str(fn) : std::string("pack.zip");
        std::string raw;
        if (!b64.is_string()) {
            return Resp::Json(400, json{{"error", "invalid base64"}});
        }
        auto decoded = p3b::b64_decode_strict(b64.get<std::string>());
        if (!decoded) return Resp::Json(400, json{{"error", "invalid base64"}});
        raw = std::move(*decoded);
        if (raw.size() > 500ull * 1024 * 1024) {
            return Resp::Json(400, json{{"error", "zip too large"}});
        }
        try {
            return Resp::Json(200, rp::install_pack_bytes(raw, filename));
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // POST /api/resource_packs/active — api.py:2666-2676.
    r.post(R"(/api/resource_packs/active)", [](const Req& req) -> Resp {
        json pid = b_get(req, "id");
        if (!json_truthy(pid)) pid = b_get(req, "pack_id");
        const std::string id = json_truthy(pid) ? json_str(pid) : std::string();
        try {
            return Resp::Json(200, rp::set_active(id));
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // DELETE /api/resource_packs/<pid> — api.py:2678-2686.
    r.del(R"(/api/resource_packs/(?P<pid>[^/]+))", [](const Req& req) -> Resp {
        const std::string pid = req.params.count("pid") ? req.params.at("pid") : "";
        try {
            return Resp::Json(200, rp::uninstall_pack(pid));
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // GET /api/resource_packs/<pid> — api.py:2688-2693.
    r.get(R"(/api/resource_packs/(?P<pid>[^/]+))", [](const Req& req) -> Resp {
        const std::string pid = req.params.count("pid") ? req.params.at("pid") : "";
        json info = rp::get_pack_info(pid);
        if (info.is_null()) return Resp::Json(404, json{{"error", "pack not found"}});
        return Resp::Json(200, std::move(info));
    });

    // POST /api/resource_packs/import_path — api.py:2695-2712.
    r.post(R"(/api/resource_packs/import_path)", [](const Req& req) -> Resp {
        const std::string path = json_str(b_get(req, "path").is_null() ? json("")
                                                                       : b_get(req, "path"));
        if (path.empty()) return Resp::Json(400, json{{"error", "path required"}});
        json fn = b_get(req, "filename");
        std::string filename;
        if (json_truthy(fn)) {
            filename = json_str(fn);
        } else {
            filename = sa_core::paths::basename(path);
            if (filename.empty()) filename = "pack.zip";
        }
        try {
            return Resp::Json(200, rp::install_pack_from_path(path, filename));
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // ---------------------------------------------------------------- plugins
    // 只读桩：进程内 Python 插件机制已废弃；形状 = golden（空聚合）。
    // GET /api/plugins — api.py:3006-3012.
    r.get(R"(/api/plugins)", [](const Req&) -> Resp {
        json body = json::object();
        body["plugins"] = json::array();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/ui — api.py:3059-3061.
    r.get(R"(/api/plugins/ui)", [](const Req&) -> Resp {
        json body = json::object();
        body["panels"] = json::array();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/ui/flow_cards — api.py:3063-3065; the stub answers the
    // declarative manifest-directory reader (see declarative_flow_cards()).
    r.get(R"(/api/plugins/ui/flow_cards)", [](const Req&) -> Resp {
        json body = json::object();
        body["flow_cards"] = declarative_flow_cards();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/agent/tools — api.py:3067-3069.
    r.get(R"(/api/plugins/agent/tools)", [](const Req&) -> Resp {
        json body = json::object();
        body["tools"] = json::array();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/plugins/<pid> — api.py:3086-3094; no plugin can be loaded in
    // the retired engine, so always the golden's "plugin not found" 404.
    r.get(R"(/api/plugins/(?P<pid>[^/]+))", [](const Req&) -> Resp {
        return Resp::Json(404, json{{"error", "plugin not found"}});
    });
}

}  // namespace sa
