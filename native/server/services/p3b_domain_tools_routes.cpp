// wip/P3b — see p3b_domain_tools_routes.h. Port of the api.py families:
//   AI 工具沙箱 (api.py:1618-1666), AI 细分领域 (api.py:1670-1752),
//   AI 共享配置 /api/ai/settings (api.py:851-869), 附件上传 (api.py:1997-2020),
//   官方模组 manifest/status (api.py:2023-2051), 资源包 (api.py:2636-2712).
// The plugins family (api.py:3006-3127) moved out to plugins_routes.cpp with
// R4 (PLUGIN_SPEC §5 declarative implementation).
#include <cstdlib>
#include <optional>
#include <string>
#include <vector>

#include "env_store_ai.h"  // R3: single AI-settings store (shared with tts.cpp)
#include "p3b_ai_files.h"
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
#include "upload_staging.h"  // 网页版 M0.5: /api/resource_packs/import_upload

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

// ---------------- 安全批次 B：API Key 掩码与保留哨兵 ----------------
//
// GET /api/ai/settings 曾把 apiKey/imageApiKey/ttsApiKey 明文下发给任意
// HTTP 客户端（浏览器页面、本机其他进程都能读到三端共享的密钥）。现在：
// 上送（PUT）侧用「保留哨兵」区分「用户没改 key」与「用户填了新 key」。

// PUT 的保留哨兵：前端在用户未修改掩码回显时改发该值，后端见值即沿用
// 共享文件中的现值。注意：哨兵不可作为真实 key —— 含 *** 的字符串不是
// 任何服务商的密钥形态，因此「用户真的想把 key 设为字面 ***UNCHANGED***」
// 不需要支持，该字面值永远按哨兵解释（想清空 key 应上送空串）。
constexpr const char* kKeyUnchangedSentinel = "***UNCHANGED***";

// 掩码规则：>=8 字符保留前 4 后 4、中间以 *** 代替；更短的非空密钥整串
// 替换为 ***MASKED***（太短无法再截断，保留任何片段都等于泄露）。
// 空串不掩码：空 key 无内容可泄露，掩码反而会让前端把「未配置」误显示成
// 「已配置」，且空串回传也不会命中哨兵、可以正常覆盖为空。
std::string mask_secret(const std::string& s) {
    if (s.empty()) return s;
    if (s.size() < 8) return "***MASKED***";
    return s.substr(0, 4) + "***" + s.substr(s.size() - 4);
}

// 上送值是否表示「保留现值」：字面哨兵，或与当前存储值的掩码结果完全一致
// （兼容直接回传 GET 掩码的旧客户端）。掩码必然含 ***，而真实密钥不会，
// 等值比对不会误伤用户新填的 key。
bool is_key_unchanged(const std::string& v, const std::string& current) {
    if (v == kKeyUnchangedSentinel) return true;
    return !current.empty() && v == mask_secret(current);
}

// 上送的 key 类字段（含 api.py 时代的蛇形别名）→ 归一后的存储字段名，
// 用于取现值做掩码比对；非 key 字段返回 ""。别名表与 env_store_ai.cpp
// 的 aliases_for 对应，normalize 本会忽略别名，但哨兵判定要先拦截。
std::string secret_canonical(const std::string& key) {
    if (key == "apiKey" || key == "api_key" || key == "apikey") return "apiKey";
    if (key == "imageApiKey" || key == "image_api_key") return "imageApiKey";
    if (key == "ttsApiKey" || key == "tts_api_key") return "ttsApiKey";
    return "";
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
    // 安全批次 B：key 类字段掩码后下发（见 mask_secret 注释），真实值只留
    // 在服务端 .editor_ai.json 里，供 TTS/生图等服务端调用方使用。
    r.get(R"(/api/ai/settings)", [](const Req&) -> Resp {
        json settings = env_store_ai::read_ai_settings(sa::editor_root());
        if (settings.is_object()) {
            for (const char* k : {"apiKey", "imageApiKey", "ttsApiKey"}) {
                auto it = settings.find(k);
                if (it != settings.end() && it->is_string()) {
                    settings[k] = mask_secret(it->get_ref<const std::string&>());
                }
            }
        }
        json body = json::object();
        body["settings"] = std::move(settings);
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
        // 安全批次 B：保留哨兵——掩码回显（GET 已掩码）或字面 ***UNCHANGED***
        // 都代表「用户没改这个 key」。命中即从 patch 中剔除该字段，让
        // write_ai_settings 的 read-merge-write 自然沿用共享文件里的现值，
        // 而不是把掩码串当成新 key 写进去、毁掉三端共享的密钥。
        // 只比对不落库，故这里临时读一次现值；真实新值/空串（清空）不受影响。
        {
            const json current = env_store_ai::read_ai_settings(sa::editor_root());
            for (auto it = patch.begin(); it != patch.end();) {
                const std::string canonical = secret_canonical(it.key());
                if (canonical.empty() || !it.value().is_string()) {
                    ++it;
                    continue;
                }
                const json& cur =
                    current.is_object() && current.contains(canonical)
                        ? current.at(canonical)
                        : json();
                const std::string cur_str =
                    cur.is_string() ? cur.get_ref<const std::string&>() : std::string();
                if (is_key_unchanged(it.value().get_ref<const std::string&>(), cur_str)) {
                    it = patch.erase(it);  // 剔除即保留现值
                } else {
                    ++it;
                }
            }
        }
        json body = json::object();
        body["ok"] = true;
        body["settings"] = env_store_ai::write_ai_settings(sa::editor_root(), patch);
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

    // POST /api/resource_packs/import_upload — 网页版 M0.5：浏览器拿不到本机
    // 路径，zip 以 {filename, data_base64} JSON 上传，落临时文件后走与
    // import_path 完全相同的导入管线（响应包络一致）。解码上限 100MB。
    r.post(R"(/api/resource_packs/import_upload)", [](const Req& req) -> Resp {
        try {
            return upload::install_from_upload(
                req,
                [](const std::string& path, const std::string& filename) {
                    return rp::install_pack_from_path(path, filename);
                },
                "pack.zip");
        } catch (const p3b::PyValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });
}

}  // namespace sa
