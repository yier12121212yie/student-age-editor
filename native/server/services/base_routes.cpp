// wip/P4/base_routes.cpp — see base_routes.h (port of api.py base_* routes).
#include "base_routes.h"

#include <string>

#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/revision_manager.h"
#include "server/state.h"
#include "p4_util.h"
#include "base_store.h"

namespace sa {
namespace {

// api.py `bool(body.get("force"))` — Python truthiness (NOT _truthy): any
// non-null / non-zero / non-empty value is True.
bool py_bool(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get<std::string>().empty();
    if (v.is_object()) return !v.empty();
    if (v.is_array()) return !v.empty();
    return true;
}

std::string qget(const Req& req, const std::string& key, const std::string& def = "") {
    auto it = req.query.find(key);
    return it == req.query.end() ? def : it->second;
}

long long pint(const std::string& s, long long def) {
    auto v = sa_core::py_int(s);
    return v.value_or(def);
}

}  // namespace

void register_base_routes(Router& r) {
    // Wire the stores_api seam for P1 (/api/base_ids) + P3a (/api/search/talk)
    // and do a best-effort initial load (idle when no artifact is configured).
    register_p4_base_store();
    auto store = base_store_instance();

    // GET /api/base/status — api.py:2385-2387.
    r.get(R"(/api/base/status)", [store](const Req&) -> Resp {
        return Resp::Json(200, store->status_dict());
    });

    // POST /api/base/load — api.py:2389-2394 (async in Python; sync here).
    r.post(R"(/api/base/load)", [store](const Req& req) -> Resp {
        bool force = req.body.is_object() && req.body.contains("force") &&
                     py_bool(req.body.at("force"));
        bool started = store->status() != "loading";
        store->load(force);
        json body = store->status_dict();
        // "started" comes first (Python dict order: {"started":..., **status}).
        json out;
        out["started"] = started;
        for (auto it = body.begin(); it != body.end(); ++it) out[it.key()] = it.value();
        return Resp::Json(200, std::move(out));
    });

    // GET /api/base/events — api.py:2396-2408.
    r.get(R"(/api/base/events)", [store](const Req& req) -> Resp {
        if (store->status() != "ready") {
            // Python `{"error":"base data not ready", **status_dict()}` — the
            // unpacked status_dict carries its own "error":"" which wins the
            // key collision (last-wins), so the 409 body equals status_dict.
            return Resp::Json(409, store->status_dict());
        }
        return Resp::Json(200, store->search_events(qget(req, "q", ""), qget(req, "npc", ""),
                                                    qget(req, "type", ""),
                                                    pint(qget(req, "page", "1"), 1),
                                                    pint(qget(req, "per_page", "50"), 50)));
    });

    // POST /api/base/extract — api.py:2410-2432 (imports a base event into the
    // current mod; writes go through cfg_store like every other write path).
    r.post(R"(/api/base/extract)", [store](const Req& req) -> Resp {
        std::string evt_id;
        if (req.body.is_object() && req.body.contains("evt_id"))
            evt_id = sa_core::py_str(req.body.at("evt_id"));
        evt_id = p4::strip(evt_id);
        if (evt_id.empty()) return Resp::Json(400, json{{"error", "evt_id required"}});
        if (store->status() != "ready")
            return Resp::Json(409, json{{"error", "base data not ready"}});
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        if (mod_root.empty()) return Resp::Json(400, json{{"error", "no mod selected"}});
        json delta = store->extract_event(evt_id);
        if (delta.empty())
            return Resp::Json(404, json{{"error", "event not found in base data: " + evt_id}});
        json counts = json::object();
        for (auto it = delta.begin(); it != delta.end(); ++it) {
            const std::string& cfg_name = it.key();
            const json& records = it.value();
            json bucket = fork_mod_table(cfg_name);  // G3: private writable copy
            for (auto rt = records.begin(); rt != records.end(); ++rt) bucket[rt.key()] = rt.value();
            counts[cfg_name] = static_cast<long long>(records.size());
            std::string path = cfg_path(cfg_name);
            cfg_store::write_cfg(path, bucket, std::nullopt, nullptr, false, true);
            note_mod_cfgs_write(cfg_name, bucket, path);
        }
        invalidate_mod_cfgs_cache();
        invalidate_preview_cache();
        json out;
        out["ok"] = true;
        out["evt_id"] = evt_id;
        out["imported"] = std::move(counts);
        return Resp::Json(200, std::move(out));
    });

    // GET /api/workspace/revision — Compute workspace content fingerprint (SHA-256[:20]).
    // Used by frontend before save operations to detect external modifications.
    r.get(R"(/api/workspace/revision)", [](const Req&) -> Resp {
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        if (mod_root.empty()) {
            return Resp::Json(400, json{{"error", "no mod selected"}});
        }
        
        revision_manager::set_workspace_root(mod_root);
        std::string revision = revision_manager::get_current_revision();
        
        if (revision.empty()) {
            return Resp::Json(500, json{{"error", "failed to compute revision"}});
        }
        
        json body;
        body["revision"] = revision;
        body["computed_at_ms"] = revision_manager::debug_last_compute_time_ms();
        body["files_scanned"] = revision_manager::debug_files_scanned_count();
        return Resp::Json(200, std::move(body));
    });
}

}  // namespace sa
