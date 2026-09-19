// server/services/cfg_routes.cpp — /api/cfg*, /api/history* (port of
// api.py:949-1216 with the three-layer caches from api.py:333-604).
//
// Route contract per CONVENTIONS 5.3/5.4:
//   GET  /api/cfg            mod + cfg_files listing
//   GET  /api/cfg/<name>     full payload / ?keys=1 / ?meta=1 / ?prefix=..&suffix=N
//   PUT  /api/cfg/<name>     full write, or PATCH branch when body has "patch"
//   GET  /api/history?cfg=X  disk snapshot listing (new -> old)
//   POST /api/history/undo|redo {cfg}
#include <algorithm>
#include <set>
#include <string>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/perf.h"
#include "server/state.h"
#include "server/revision_manager.h"
#include "server/deleted_talks_manager.h"

namespace sa {
namespace {

namespace cs = sa_core::paths;

// api.py:1054-1058 / 1126-1130: `int(expect) if expect is not None else None`
// inside a try/(TypeError, ValueError) -> None. JSON floats truncate toward zero.
std::optional<long long> parse_expect(const json& v) {
    if (v.is_null()) return std::nullopt;
    if (v.is_number_integer()) return v.get<long long>();
    if (v.is_number_unsigned()) return static_cast<long long>(v.get<unsigned long long>());
    if (v.is_number_float()) return static_cast<long long>(v.get<double>());
    if (v.is_string()) return sa_core::py_int(v.get<std::string>());
    return std::nullopt;
}

// Parse revision string from request body
std::optional<std::string> parse_revision(const json& v) {
    if (v.is_null()) return std::nullopt;
    if (v.is_string()) return v.get<std::string>();
    return std::nullopt;
}

// api.py:508-513 _parse_prefix_query
std::optional<std::set<std::string>> parse_prefix_query(const std::string* raw) {
    if (raw == nullptr || raw->empty()) return std::nullopt;
    std::set<std::string> prefixes;
    size_t pos = 0;
    while (pos <= raw->size()) {
        size_t comma = raw->find(',', pos);
        std::string piece = sa_core::str::trim(raw->substr(
            pos, comma == std::string::npos ? std::string::npos : comma - pos));
        if (!piece.empty()) prefixes.insert(piece);
        if (comma == std::string::npos) break;
        pos = comma + 1;
    }
    if (prefixes.empty()) return std::nullopt;
    return prefixes;
}

// api.py:515-519 _prefix_match (frontend PrefixMatcher parity): strip the last
// `suffix` chars of str(key) (whole string when len <= suffix), exact set hit.
bool prefix_match(const std::string& key, const std::set<std::string>& prefixes, int suffix) {
    std::string p = static_cast<long>(key.size()) > suffix ? key.substr(0, key.size() - suffix)
                                                           : key;
    return prefixes.count(p) > 0;
}

// api.py:1039-1097 _do_cfg_patch — S2 contract: the PATCH branch is picked by
// the "patch" key in the PUT body (S2: there is no PATCH verb on this server).
Resp do_cfg_patch(const std::string& cfg_name, const std::string& path, const json& body,
                  const json& patch) {
    if (!patch.is_object()) {
        return Resp::Json(400, json{{"error", "patch must be an object {set, remove}"},
                                    {"cfg", cfg_name}});
    }
    
    // P5 Revision check before processing patch
    std::optional<std::string> client_revision = parse_revision(body.contains("revision") ? body.at("revision") : json());
    if (client_revision.has_value() && !client_revision->empty()) {
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        if (!mod_root.empty()) {
            revision_manager::set_workspace_root(mod_root);
            if (!revision_manager::verify_revision(*client_revision)) {
                // 409 Conflict with fresh revision
                std::string fresh_revision = revision_manager::compute_revision_cached(false);
                json env;
                env["error"] = "conflict";
                env["cfg"] = cfg_name;
                env["reason"] = "revision_mismatch";
                env["detail"] = "文件已被外部修改或与其他会话冲突";
                env["current_revision"] = fresh_revision;
                return Resp::Json(409, std::move(env));
            }
        }
    }
    
    // B2: lossy source guard, same semantics as the full write.
    auto probe = load_table_cached(path, cfg_name);
    if (probe.state == "ok" && probe.lossy && !truthy(body.contains("force") ? body.at("force")
                                                                              : json())) {
        return Resp::Json(409, json{{"error", "non-utf8-source"},
                                    {"cfg", cfg_name},
                                    {"detail",
                                     "源文件不是合法 UTF-8，覆盖写入会毁掉非 ASCII 内容；"
                                     "确认放弃原文请带 force=true"}});
    }
    std::optional<long long> expect =
        parse_expect(body.contains("expect_mtime_ns") ? body.at("expect_mtime_ns") : json());
    const json* if_match = nullptr;
    if (body.contains("if_match") && !body.at("if_match").is_null()) {
        if (!body.at("if_match").is_object()) {
            return Resp::Json(400, json{{"error", "if_match must be an object {key: 期望值}"},
                                        {"cfg", cfg_name}});
        }
        if_match = &body.at("if_match");
    }
    json patch_set = json::object();
    json patch_remove = json::array();
    bool set_is_dict = patch.contains("set") && patch.at("set").is_object();
    bool remove_is_list = patch.contains("remove") && patch.at("remove").is_array();
    if (set_is_dict) patch_set = patch.at("set");
    if (remove_is_list) patch_remove = patch.at("remove");
    bool force = truthy(body.contains("force") ? body.at("force") : json());

    json result = cfg_store::apply_patch(path, patch_set, patch_remove, if_match, expect, nullptr,
                                         force);
    if (!result.value("ok", false)) {
        if (result.value("conflict", false)) {
            if (result.value("reason", "") == "rows") {
                json env;
                env["error"] = "conflict";
                env["cfg"] = cfg_name;
                env["reason"] = "rows";
                env["conflicting_keys"] =
                    result.contains("conflicting_keys") ? result.at("conflicting_keys")
                                                        : json::array();
                env["mtime_ns"] = result.contains("mtime_ns") ? result.at("mtime_ns") : json();
                return Resp::Json(409, std::move(env));
            }
            json env;
            env["error"] = "conflict";
            env["cfg"] = cfg_name;
            env["mtime_ns"] = result.contains("mtime_ns") ? result.at("mtime_ns") : json();
            env["data"] = result.contains("data") ? result.at("data") : json();
            return Resp::Json(409, std::move(env));
        }
        std::string msg = result.value("error", std::string());
        return Resp::Json(500, json{{"error", msg.empty() ? "写入失败" : msg},
                                    {"cfg", cfg_name}});
    }
    // Write success quartet (api.py:1083-1091): invalidate -> seed -> note ->
    // preview invalidate. Seeding is what makes the next GET a zero-work hit.
    invalidate_table_cache(path);
    json merged = result.value("data", json::object());
    seed_table_cache(path, cfg_name, merged,
                     result.contains("mtime_ns") && result.at("mtime_ns").is_number()
                         ? std::optional<long long>(result.at("mtime_ns").get<long long>())
                         : std::nullopt);
    note_mod_cfgs_write(cfg_name, merged, path);
    invalidate_preview_cache();

    json applied = result.value("applied", json::object());
    json env;
    env["ok"] = true;
    env["cfg"] = cfg_name;
    // Optimized: only return counts instead of full objects to reduce body size <10KB
    long long set_count = applied.contains("set") && applied.at("set").is_object() 
                          ? static_cast<long long>(applied.at("set").size()) 
                          : 0;
    long long remove_count = applied.contains("remove") && applied.at("remove").is_array()
                             ? static_cast<long long>(applied.at("remove").size())
                             : 0;
    env["applied_set_count"] = set_count;
    env["applied_remove_count"] = remove_count;
    env["mtime_ns"] = result.contains("mtime_ns") ? result.at("mtime_ns") : json();
    env["snapshot"] = result.contains("snapshot") ? result.at("snapshot") : json();
    return Resp::Json(200, std::move(env));
}

}  // namespace

void register_cfg_routes(Router& r) {
    install_parse_provider();

    // GET /api/cfg — api.py:949-955.
    r.get(R"(/api/cfg)", [](const Req&) -> Resp {
        std::string mod_name, mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_name = STATE().mod_name;
            mod_root = STATE().mod_root;
        }
        json info;
        json mods = list_mods();
        for (const auto& m : mods) {
            if (m.value("name", "") == mod_name) {
                info = m;
                break;
            }
        }
        if (info.is_null() && !mod_root.empty()) info = mod_info(mod_name, mod_root);
        json body;
        body["mod"] = mod_name;
        body["cfg_files"] =
            info.is_object() && info.contains("cfg_files") ? info.at("cfg_files") : json::array();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/cfg/<name> — api.py:957-1019.
    r.get(R"(/api/cfg/(?P<name>[^/]+))", [](const Req& req) -> Resp {
        const std::string name = req.params.count("name") ? req.params.at("name") : std::string();
        std::string cfg_name = cfg_name_of(name);
        std::string path;
        try {
            path = cfg_path(cfg_name);
        } catch (const SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}, {"cfg", cfg_name}});
        }

        const auto& q = req.query;
        auto qv = [&](const char* k) -> const std::string* {
            auto it = q.find(k);
            return it == q.end() ? nullptr : &it->second;
        };
        const bool meta_only = qv("meta") != nullptr && *qv("meta") == "1";
        const bool want_keys = qv("keys") != nullptr && *qv("keys") == "1";
        auto prefixes = parse_prefix_query(qv("prefix"));
        int suffix = 3;
        if (const std::string* s = qv("suffix")) {
            auto v = sa_core::py_int(*s);
            suffix = v.has_value() ? static_cast<int>(std::clamp(*v, 1LL, 8LL)) : 3;
        }

        auto res = load_table_cached(path, cfg_name);
        if (res.state == "missing") {
            sa::bump(lc::kCfgReads);
            json body;
            body["cfg"] = cfg_name;
            body["data"] = json::object();
            body["exists"] = false;
            body["mtime_ns"] = nullptr;
            return Resp::Json(200, std::move(body));
        }
        if (res.state == "error") {
            return Resp::Json(400, json{{"error", res.error}, {"cfg", cfg_name}});
        }
        const json& data = *res.data;
        long long mtime_ns = *res.mtime_ns;
        sa::bump(lc::kCfgReads);

        if (meta_only) {
            json body;
            body["cfg"] = cfg_name;
            body["exists"] = true;
            body["mtime_ns"] = mtime_ns;
            body["count"] = static_cast<long long>(data.size());
            if (res.lossy) body["lossy"] = true;
            return Resp::Json(200, std::move(body));
        }
        if (prefixes) {
            json filtered = json::object();
            for (auto it = data.begin(); it != data.end(); ++it) {
                if (prefix_match(it.key(), *prefixes, suffix)) filtered[it.key()] = it.value();
            }
            json body;
            body["cfg"] = cfg_name;
            body["data"] = std::move(filtered);
            body["exists"] = true;
            body["mtime_ns"] = mtime_ns;
            if (res.lossy) body["lossy"] = true;
            return Resp::Json(200, std::move(body));
        }
        if (!want_keys) {
            // S1 hot path: pre-serialized body straight to the socket — no
            // re-serialization and NO cfg.dumps bump (api.py:1004-1009).
            if (auto body = table_cache_body_for(path, mtime_ns)) {
                return Resp::Bytes(200, std::move(*body));
            }
            json env;
            env["cfg"] = cfg_name;
            env["data"] = data;
            env["exists"] = true;
            env["mtime_ns"] = mtime_ns;
            if (res.lossy) env["lossy"] = true;
            return Resp::Json(200, std::move(env));
        }
        std::vector<std::string> keys;
        for (auto it = data.begin(); it != data.end(); ++it) keys.push_back(it.key());
        std::sort(keys.begin(), keys.end());  // sorted(data.keys())
        json keys_arr = json::array();
        for (auto& k : keys) keys_arr.push_back(k);
        json body;
        body["cfg"] = cfg_name;
        body["data"] = data;
        body["keys"] = std::move(keys_arr);
        body["exists"] = true;
        body["mtime_ns"] = mtime_ns;
        if (res.lossy) body["lossy"] = true;
        return Resp::Json(200, std::move(body));
    });

    // PUT /api/cfg/<name> — api.py:1099-1159 (+patch branch 1039-1097).
    r.put(R"(/api/cfg/(?P<name>[^/]+))", [](const Req& req) -> Resp {
        const json& body = req.body;
        const std::string name = req.params.count("name") ? req.params.at("name") : std::string();
        std::string cfg_name = cfg_name_of(name);
        std::string path;
        try {
            path = cfg_path(cfg_name);
        } catch (const SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}, {"cfg", cfg_name}});
        }
        const bool has_body = body.is_object();
        if (has_body && body.contains("patch") && !body.at("patch").is_null()) {
            return do_cfg_patch(cfg_name, path, body, body.at("patch"));
        }
        json data = has_body && body.contains("data") ? body.at("data") : json();
        if (!data.is_object()) {
            return Resp::Json(400, json{{"error", "data must be a dict"}});
        }
        
        // P5 Revision check (revision_manager): verify client_revision matches current workspace hash
        std::optional<std::string> client_revision = parse_revision(has_body && body.contains("revision") ? body.at("revision") : json());
        if (client_revision.has_value() && !client_revision->empty()) {
            std::string mod_root;
            {
                std::lock_guard<std::mutex> lk(STATE().mu_);
                mod_root = STATE().mod_root;
            }
            if (!mod_root.empty()) {
                revision_manager::set_workspace_root(mod_root);
                if (!revision_manager::verify_revision(*client_revision)) {
                    // 409 Conflict with fresh revision
                    std::string fresh_revision = revision_manager::compute_revision_cached(false);
                    json env;
                    env["error"] = "conflict";
                    env["cfg"] = cfg_name;
                    env["reason"] = "revision_mismatch";
                    env["detail"] = "文件已被外部修改或与其他会话冲突";
                    env["current_revision"] = fresh_revision;
                    return Resp::Json(409, std::move(env));
                }
            }
        }
        
        // B2: never silently overwrite a source whose bytes are not UTF-8.
        auto probe = load_table_cached(path, cfg_name);
        if (probe.state == "ok" && probe.lossy &&
            !truthy(has_body && body.contains("force") ? body.at("force") : json())) {
            return Resp::Json(409, json{{"error", "non-utf8-source"},
                                        {"cfg", cfg_name},
                                        {"detail",
                                         "源文件不是合法 UTF-8，覆盖写入会毁掉非 ASCII 内容；"
                                         "确认放弃原文请带 force=true"}});
        }
        std::optional<long long> expect =
            parse_expect(has_body && body.contains("expect_mtime_ns") ? body.at("expect_mtime_ns")
                                                                      : json());
        json result = cfg_store::write_cfg(path, data, expect, nullptr,
                                           truthy(has_body && body.contains("force")
                                                      ? body.at("force")
                                                      : json()),
                                           true);
        if (!result.value("ok", false)) {
            if (result.value("conflict", false)) {
                json env;
                env["error"] = "conflict";
                env["cfg"] = cfg_name;
                env["mtime_ns"] = result.contains("mtime_ns") ? result.at("mtime_ns") : json();
                env["data"] = result.contains("data") ? result.at("data") : json();
                return Resp::Json(409, std::move(env));
            }
            std::string msg = result.value("error", std::string());
            return Resp::Json(500, json{{"error", msg.empty() ? "写入失败" : msg},
                                        {"cfg", cfg_name}});
        }
        invalidate_table_cache(path);
        seed_table_cache(path, cfg_name, data,
                         result.contains("mtime_ns") && result.at("mtime_ns").is_number()
                             ? std::optional<long long>(result.at("mtime_ns").get<long long>())
                             : std::nullopt);
        note_mod_cfgs_write(cfg_name, data, path);
        invalidate_preview_cache();
        json env;
        env["ok"] = true;
        env["cfg"] = cfg_name;
        env["mtime_ns"] = result.contains("mtime_ns") ? result.at("mtime_ns") : json();
        env["snapshot"] = result.contains("snapshot") ? result.at("snapshot") : json();
        return Resp::Json(200, std::move(env));
    });

    // GET /api/history?cfg=X — api.py:1162-1171.
    r.get(R"(/api/history)", [](const Req& req) -> Resp {
        auto it = req.query.find("cfg");
        std::string cfg_name = it == req.query.end() ? std::string() : cfg_name_of(it->second);
        if (cfg_name.empty()) return Resp::Json(400, json{{"error", "cfg required"}});
        std::string path;
        try {
            path = cfg_path(cfg_name);
        } catch (const SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
        json body;
        body["cfg"] = cfg_name;
        body["entries"] = cfg_store::list_history(path);
        return Resp::Json(200, std::move(body));
    });

    // POST /api/history/undo|redo — api.py:1173-1216. Failures (including
    // "nothing to undo") answer 400 with the store's result body verbatim.
    auto history_op = [](const Req& req, const char* op) -> Resp {
        std::string cfg_name;
        if (req.body.is_object() && req.body.contains("cfg")) {
            const json& v = req.body.at("cfg");
            cfg_name = cfg_name_of(v.is_string() ? v.get<std::string>() : sa_core::py_str(v));
        }
        if (cfg_name.empty()) return Resp::Json(400, json{{"error", "cfg required"}});
        json result;
        try {
            std::string path = cfg_path(cfg_name);
            result = std::string(op) == "undo" ? cfg_store::undo(path) : cfg_store::redo(path);
        } catch (const SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
        if (!result.value("ok", false)) {
            // 结构化空栈标记：前端按 code 判定「没有可撤销/重做」，不再依赖
            // 英文报错文案（文案一改/本地化就会把空栈误报成失败）。
            const std::string err = result.value("error", std::string());
            if (err == "nothing to undo" || err == "nothing to redo")
                result["code"] = "empty";
            return Resp::Json(400, result);
        }
        // Success: the mod-wide view is stale after an on-disk revert.
        invalidate_mod_cfgs_cache();
        invalidate_preview_cache();
        return Resp::Json(200, std::move(result));
    };
    r.post(R"(/api/history/undo)", [history_op](const Req& req) { return history_op(req, "undo"); });
    r.post(R"(/api/history/redo)", [history_op](const Req& req) { return history_op(req, "redo"); });

    // DELETE /api/cfg/<name>/<id> — Delete with tombstone semantics (P8 feature).
    // Replaces hard-delete with persistent mapping: old_id -> replacement_ids|null.
    // Preserves reference integrity by following tombstones on next_talk resolution.
    r.delete(R"(/api/cfg/(?P<name>[^/]+)/(?P<id>[^/]+))", [](const Req& req) -> Resp {
        const std::string name = req.params.count("name") ? req.params.at("name") : std::string();
        const std::string id = req.params.count("id") ? req.params.at("id") : std::string();
        
        // P5 Revision check before processing delete
        std::optional<std::string> client_revision = parse_revision(req.body.contains("revision") ? req.body.at("revision") : json());
        std::string cfg_name = cfg_name_of(name);
        std::string path;
        try {
            path = cfg_path(cfg_name);
        } catch (const SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}, {"cfg", cfg_name}});
        }
        
        if (client_revision.has_value() && !client_revision->empty()) {
            std::string mod_root;
            {
                std::lock_guard<std::mutex> lk(STATE().mu_);
                mod_root = STATE().mod_root;
            }
            if (!mod_root.empty()) {
                revision_manager::set_workspace_root(mod_root);
                if (!revision_manager::verify_revision(*client_revision)) {
                    // 409 Conflict with fresh revision
                    std::string fresh_revision = revision_manager::compute_revision_cached(false);
                    json env;
                    env["error"] = "conflict";
                    env["cfg"] = cfg_name;
                    env["reason"] = "revision_mismatch";
                    env["detail"] = "文件已被外部修改或与其他会话冲突";
                    env["current_revision"] = fresh_revision;
                    return Resp::Json(409, std::move(env));
                }
            }
        }
        
        // B2: Never delete from lossy source
        auto probe = load_table_cached(path, cfg_name);
        if (probe.state == "ok" && probe.lossy) {
            return Resp::Json(409, json{{"error", "non-utf8-source"},
                                        {"cfg", cfg_name},
                                        {"detail", "源文件不是合法 UTF-8，无法删除"}});
        }
        
        // Get current table data
        auto res = load_table_cached(path, cfg_name);
        if (res.state != "ok") {
            return Resp::Json(res.state == "missing" ? 404 : 400, 
                            json{{"error", res.state == "missing" ? "table not found" : res.error}});
        }
        
        // Check if ID exists
        const json& data = *res.data;
        auto it = data.find(id);
        if (it == data.end()) {
            return Resp::Json(404, json{{"error", "record not found"}, {"cfg", cfg_name}, {"id", id}});
        }
        
        // P8 Tombstone: calculate new IDs for redirect (if TalkCfg, may replace with multiple new IDs)
        std::vector<std::string> replacement_ids;
        
        // Smart ID allocation strategy (similar to competitor #2):
        // - Generate new IDs based on existing pattern (incrementing or hash-based)
        // - Support multiple replacements for complex reference trees
        // - For TalkCfg, allocate at most N replacements where N is the number of dependent talks
        
        // Strategy 1: Calculate replacement count from talk content structure
        // Look at the record being deleted to determine if it has structured references
        const auto& record = *it;
        long long expected_replacements = 0;
        
        if (record.is_object()) {
            // Check for common reference patterns in TalkCfg
            if (record.contains("next_talk") && !record["next_talk"].is_null()) {
                expected_replacements = 1;
            } else if (record.contains("dependencies") && record["dependencies"].is_array()) {
                expected_replacements = static_cast<long long>(record["dependencies"].size());
            }
        }
        
        // Strategy 2: Allocate sequential IDs if needed
        if (expected_replacements > 0) {
            // Find the max existing ID in this cfg to avoid collisions
            long long max_id = 0;
            for (auto dict_it = data.begin(); dict_it != data.end(); ++dict_it) {
                try {
                    long long current_id = sa_core::py_int(dict_it.key()).value_or(0);
                    if (current_id > max_id) max_id = current_id;
                } catch (...) {
                    // Skip non-numeric keys
                }
            }
            
            // Generate replacement IDs: incrementally allocated
            for (long long i = 0; i < expected_replacements; i++) {
                replacement_ids.push_back(std::to_string(max_id + 1 + i));
            }
        }
        
        // If no replacements needed, permanent tombstone (null = inert placeholder)
        // Register tombstone BEFORE removing record
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        if (!mod_root.empty()) {
            deleted_talks_manager::set_workspace_root(mod_root);
            deleted_talks_manager::register_tombstone(id, replacement_ids);
        }
        
        // Remove record from memory
        json updated_data = data;
        updated_data.erase(id);
        
        // Persist deletion
        std::optional<long long> expect = std::nullopt;  // No mtime check needed
        json result = cfg_store::write_cfg(path, updated_data, expect, nullptr, true, true);
        if (!result.value("ok", false)) {
            std::string msg = result.value("error", std::string());
            return Resp::Json(500, json{{"error", msg.empty() ? "删除失败" : msg},
                                        {"cfg", cfg_name}});
        }
        
        // Persist tombstones
        if (!deleted_talks_manager::persist()) {
            // Non-fatal: log error but continue
            sa::bump("tombstones.persist_failed");
        }
        
        invalidate_table_cache(path);
        seed_table_cache(path, cfg_name, updated_data,
                         result.contains("mtime_ns") && result.at("mtime_ns").is_number()
                             ? std::optional<long long>(result.at("mtime_ns").get<long long>())
                             : std::nullopt);
        note_mod_cfgs_write(cfg_name, updated_data, path);
        invalidate_preview_cache();
        
        json out;
        out["ok"] = true;
        out["cfg"] = cfg_name;
        out["id"] = id;
        out["tombstone_created"] = true;
        out["replacement_ids"] = replacement_ids;
        return Resp::Json(200, std::move(out));
    });
}

}  // namespace sa
