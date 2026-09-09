// wip/P5/cloud_routes.cpp — api.py:2714-3002 ported 1:1 (18 endpoints).
//
// Error-mapping discipline per route (matches Python's except-chains exactly):
//   * "ValueError -> 400 str(e), anything else -> 500 'Type: msg'"  (the
//     providers/test/sync/file family)
//   * "/api/cloud/file" additionally maps FileNotFoundError -> 404 str(e)
//   * realtime config POST/PUT swallow *everything* into 400 'Type: msg'
//   * list/local_files/status/stop/events funnel everything into 500
#include "cloud_routes.h"

#include <set>
#include <string>
#include <vector>

#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "server/state.h"
#include "cloud_sync.h"
#include "p5_util.h"
#include "realtime.h"

#include "server/services/p4_util.h"

namespace sa {
namespace {

namespace sp = sa_core::str;
namespace spath = sa_core::paths;

std::string current_mod_name() {
    std::lock_guard<std::mutex> lk(STATE().mu_);
    return STATE().mod_name;
}

std::string qget(const Req& req, const std::string& key) {
    auto it = req.query.find(key);
    return it == req.query.end() ? std::string() : it->second;
}

const json& bget(const json& body, const char* key) {
    static const json null_json(nullptr);
    if (!body.is_object()) return null_json;
    auto it = body.find(key);
    return it == body.end() ? null_json : it.value();
}

// `body = _body or {}` — falsy values collapse to {}, truthy non-dicts raise
// the AttributeError the first .get() would hit in Python.
json dict_body(const json& body) {
    if (body.is_null()) return json::object();
    if (body.is_object()) return body;
    if (!p5::py_truthy(body)) return json::object();
    throw ApiError("AttributeError",
                   "'" + std::string(p5::py_type_name(body)) + "' object has no attribute 'get'");
}

// "%s: %s" % (type(e).__name__, e)
std::string py_exc_full(const std::exception& e) {
    if (auto* py = dynamic_cast<const cloud::PyError*>(&e)) return py->what();
    if (auto* ae = dynamic_cast<const ApiError*>(&e)) return ae->what();
    return std::string("RuntimeError: ") + e.what();
}

Resp err400(const std::string& msg) {
    json b;
    b["error"] = msg;
    return Resp::Json(400, std::move(b));
}
Resp err404(const std::string& msg) {
    json b;
    b["error"] = msg;
    return Resp::Json(404, std::move(b));
}
Resp err500(const std::string& full) {
    json b;
    b["error"] = full;
    return Resp::Json(500, std::move(b));
}

// `except ValueError: 400 / except Exception: 500 "<Type>: <msg>"`
Resp map_value_then_generic(const std::exception& e) {
    if (auto* py = dynamic_cast<const cloud::PyError*>(&e)) {
        if (py->type_name == "ValueError") return err400(py->str_msg);
        return err500(py->what());
    }
    return err500(py_exc_full(e));
}

// `(v or "upload").lower()` — truthy non-str mirrors AttributeError('lower').
std::string lowered_or_default(const json& v, const std::string& def) {
    if (!p5::py_truthy(v)) return def;
    return sp::lower(p5::str_or_throw(v, "lower"));
}

// mod_name slots: Python feeds the raw value into the sync engine where
// `".." in mod_name` raises TypeError on non-strings; mirror at the boundary
// (fires at extraction, one guard earlier than the Python engine — see the
// STATUS.md 实现层差异 note on malformed-client ordering).
std::string mod_name_or_throw(const json& v) {
    if (!p5::py_truthy(v)) return "";
    if (v.is_string()) return v.get<std::string>();
    throw cloud::PyError("TypeError",
                         "argument of type '" + std::string(p5::py_type_name(v)) +
                             "' is not iterable");
}

}  // namespace

void register_cloud_routes(Router& r) {
    // ------------------------------------------------------------------
    // GET /api/cloud/providers — api.py:2715-2729 (token/password/pass mask).
    // ------------------------------------------------------------------
    r.get(R"(/api/cloud/providers)", [](const Req&) -> Resp {
        json safe = json::array();
        try {
            for (const auto& p : cloud::list_providers()) {
                if (!p.is_object()) {
                    safe.push_back(p);
                    continue;
                }
                json cfg =
                    p.contains("config") && p["config"].is_object() ? p["config"] : json::object();
                for (auto it = cfg.begin(); it != cfg.end(); ++it) {
                    std::string lk = sp::lower(it.key());
                    if (lk.find("token") != std::string::npos ||
                        lk.find("password") != std::string::npos ||
                        lk.find("pass") != std::string::npos) {
                        it.value() = p5::py_truthy(it.value()) ? json("***") : json("");
                    }
                }
                json entry;
                bool replaced = false;
                for (auto it = p.begin(); it != p.end(); ++it) {
                    if (it.key() == "config") {
                        entry["config"] = cfg;
                        replaced = true;
                    } else {
                        entry[it.key()] = it.value();
                    }
                }
                if (!replaced) entry["config"] = cfg;  // {**p, "config": cfg} appends
                safe.push_back(entry);
            }
            json drivers = json::array();
            for (const auto& [name, f] : cloud::drivers()) drivers.push_back(name);
            json body;
            body["providers"] = safe;
            body["drivers"] = drivers;
            return Resp::Json(200, std::move(body));
        } catch (const std::exception& e) {
            return err500(py_exc_full(e));
        }
    });

    // ------------------------------------------------------------------
    // POST /api/cloud/providers — api.py:2731-2740.
    // ------------------------------------------------------------------
    r.post(R"(/api/cloud/providers)", [](const Req& req) -> Resp {
        json body = dict_body(req.body);
        try {
            json entry = cloud::add_provider(body);
            json out;
            out["provider"] = entry;
            return Resp::Json(200, std::move(out));
        } catch (const std::exception& e) {
            return map_value_then_generic(e);
        }
    });

    // ------------------------------------------------------------------
    // PUT /api/cloud/providers/<pid> — api.py:2742-2762, incl. the "***"
    // masked-writeback restore pre-pass.
    // ------------------------------------------------------------------
    r.put(R"(/api/cloud/providers/(?P<pid>[^/]+))", [](const Req& req) -> Resp {
        json body = dict_body(req.body);
        const std::string pid = req.params.count("pid") ? req.params.at("pid") : "";
        try {
            if (body.contains("config") && body["config"].is_object()) {
                auto orig = cloud::get_provider(pid);
                if (orig && orig->contains("config") && (*orig)["config"].is_object()) {
                    const json& orig_cfg = (*orig)["config"];
                    for (auto it = body["config"].begin(); it != body["config"].end(); ++it) {
                        if (it.value().is_string() && it.value().get<std::string>() == "***" &&
                            orig_cfg.contains(it.key())) {
                            it.value() = orig_cfg[it.key()];
                        }
                    }
                }
            }
        } catch (...) {
            // Python wraps the whole pre-pass in try/except: pass.
        }
        try {
            json entry = cloud::update_provider(pid, body);
            json out;
            out["provider"] = entry;
            return Resp::Json(200, std::move(out));
        } catch (const std::exception& e) {
            return map_value_then_generic(e);
        }
    });

    // ------------------------------------------------------------------
    // DELETE /api/cloud/providers/<pid> — api.py:2764-2772.
    // ------------------------------------------------------------------
    r.del(R"(/api/cloud/providers/(?P<pid>[^/]+))", [](const Req& req) -> Resp {
        const std::string pid = req.params.count("pid") ? req.params.at("pid") : "";
        try {
            cloud::remove_provider(pid);
        } catch (const std::exception& e) {
            return map_value_then_generic(e);
        }
        json out;
        out["ok"] = true;
        return Resp::Json(200, std::move(out));
    });

    // ------------------------------------------------------------------
    // POST /api/cloud/test — api.py:2774-2795.
    // ------------------------------------------------------------------
    r.post(R"(/api/cloud/test)", [](const Req& req) -> Resp {
        json body = dict_body(req.body);
        // provider_id = body.provider_id or body.id or ""
        json pidv = bget(body, "provider_id");
        if (!p5::py_truthy(pidv)) pidv = bget(body, "id");
        try {
            std::shared_ptr<cloud::Driver> drv;
            if (p5::py_truthy(pidv)) {
                if (!pidv.is_string()) return err404("provider not found");  // never matches
                auto prov = cloud::get_provider(pidv.get<std::string>());
                if (!prov) return err404("provider not found");
                drv = cloud::get_driver(prov->contains("type") ? (*prov)["type"] : json(nullptr),
                                        prov->contains("config") ? (*prov)["config"]
                                                                 : json::object());
            } else {
                // ptype = body.type or body.driver or ""
                json tv = bget(body, "type");
                if (!p5::py_truthy(tv)) tv = bget(body, "driver");
                if (!p5::py_truthy(tv)) return err400("type or provider_id required");
                json cfgv = bget(body, "config");
                if (!p5::py_truthy(cfgv)) cfgv = json::object();
                drv = cloud::get_driver(tv, cfgv);
            }
            drv->test();
        } catch (const std::exception& e) {
            return map_value_then_generic(e);
        }
        json out;
        out["ok"] = true;
        return Resp::Json(200, std::move(out));
    });

    // ------------------------------------------------------------------
    // GET /api/cloud/status — api.py:2797-2799.
    // ------------------------------------------------------------------
    r.get(R"(/api/cloud/status)", [](const Req&) -> Resp {
        return Resp::Json(200, cloud::sync_status());
    });

    // ------------------------------------------------------------------
    // POST /api/cloud/sync — api.py:2801-2844.
    // ------------------------------------------------------------------
    r.post(R"(/api/cloud/sync)", [](const Req& req) -> Resp {
        json body = dict_body(req.body);
        json pidv = bget(body, "provider_id");
        if (!p5::py_truthy(pidv)) pidv = bget(body, "id");
        std::string direction = lowered_or_default(bget(body, "direction"), "upload");
        // mod_name = body.mod_name or body.mod or STATE.mod_name
        std::string mod_name;
        {
            const json& a = bget(body, "mod_name");
            const json& b = bget(body, "mod");
            if (p5::py_truthy(a)) mod_name = mod_name_or_throw(a);
            else if (p5::py_truthy(b)) mod_name = mod_name_or_throw(b);
            else mod_name = current_mod_name();
        }
        json rel_paths(nullptr);
        for (const char* k : {"files", "rel_paths", "paths"}) {
            if (p5::py_truthy(bget(body, k))) {
                rel_paths = bget(body, k);
                break;
            }
        }
        if (rel_paths.is_null()) rel_paths = json::array();
        bool dry_run = p5::py_truthy(bget(body, "dry_run")) || p5::py_truthy(bget(body, "dryRun"));
        bool delete_extra =
            p5::py_truthy(bget(body, "delete_extra")) || p5::py_truthy(bget(body, "deleteExtra"));
        if (!p5::py_truthy(pidv)) return err400("provider_id required");
        if (direction != "upload" && direction != "download" && direction != "delete_remote" &&
            direction != "delete_local" && direction != "sync") {
            return err400("invalid direction");
        }
        if (mod_name.empty()) return err400("mod_name required (select mod first)");
        if (rel_paths.is_string()) rel_paths = json::array({rel_paths});
        if (p5::py_truthy(bget(body, "file"))) rel_paths = json::array({bget(body, "file")});
        if (p5::py_truthy(bget(body, "rel_path")))
            rel_paths = json::array({bget(body, "rel_path")});
        bool is_folder = p5::py_truthy(bget(body, "folder")) || p5::py_truthy(bget(body, "full")) ||
                         p5::py_truthy(bget(body, "all"));
        std::string provider_id =
            pidv.is_string() ? pidv.get<std::string>() : std::string("\x01never-match");
        if (!p5::py_truthy(rel_paths) || is_folder) {
            std::string folder_dir = (direction == "upload" || direction == "download" ||
                                      direction == "sync")
                                         ? direction
                                         : std::string("upload");
            try {
                return Resp::Json(200, cloud::sync_mod_folder(provider_id, folder_dir, mod_name,
                                                              dry_run, delete_extra));
            } catch (const std::exception& e) {
                return map_value_then_generic(e);
            }
        }
        try {
            return Resp::Json(200, cloud::sync_mod_files(provider_id, direction, mod_name,
                                                         rel_paths, dry_run));
        } catch (const std::exception& e) {
            return map_value_then_generic(e);
        }
    });

    // ------------------------------------------------------------------
    // POST /api/cloud/file — api.py:2846-2864 (FileNotFoundError -> 404).
    // ------------------------------------------------------------------
    r.post(R"(/api/cloud/file)", [](const Req& req) -> Resp {
        json body = dict_body(req.body);
        std::string provider_id;
        {
            const json& v = bget(body, "provider_id");
            if (p5::py_truthy(v)) {
                // A truthy non-string id never matches a stored (string) id in
                // the provider list — mirror that by keeping it unmatched.
                provider_id = v.is_string() ? v.get<std::string>()
                                            : std::string("\x01never-match");
            }
        }
        std::string direction = lowered_or_default(bget(body, "direction"), "upload");
        std::string mod_name;
        if (p5::py_truthy(bget(body, "mod_name"))) {
            mod_name = mod_name_or_throw(bget(body, "mod_name"));
        } else {
            mod_name = current_mod_name();
        }
        std::string rel_path;
        if (p5::py_truthy(bget(body, "rel_path"))) {
            rel_path = p5::str_or_throw(bget(body, "rel_path"), "replace");  // _norm_remote
        } else if (p5::py_truthy(bget(body, "file"))) {
            rel_path = p5::str_or_throw(bget(body, "file"), "replace");
        }
        bool dry_run = p5::py_truthy(bget(body, "dry_run"));
        if (provider_id.empty() || rel_path.empty()) {
            return err400("provider_id and rel_path required");
        }
        try {
            return Resp::Json(200, cloud::sync_single_file(provider_id, direction, mod_name,
                                                           rel_path, dry_run));
        } catch (const cloud::PyError& e) {
            if (e.type_name == "ValueError") return err400(e.str_msg);
            if (e.type_name == "FileNotFoundError") return err404(e.str_msg);
            return err500(e.what());
        } catch (const std::exception& e) {
            return err500(py_exc_full(e));
        }
    });

    // ------------------------------------------------------------------
    // GET /api/cloud/list — api.py:2866-2885 (all errors -> 500).
    // ------------------------------------------------------------------
    r.get(R"(/api/cloud/list)", [](const Req& req) -> Resp {
        std::string provider_id = qget(req, "provider_id");
        if (provider_id.empty()) provider_id = qget(req, "id");
        std::string mod_name = qget(req, "mod_name");
        if (mod_name.empty()) mod_name = qget(req, "mod");
        std::string sub = qget(req, "path");
        if (sub.empty()) sub = qget(req, "dir");
        if (provider_id.empty()) return err400("provider_id required");
        auto prov = cloud::get_provider(provider_id);
        if (!prov) return err404("provider not found");
        try {
            auto drv = cloud::get_driver(prov->contains("type") ? (*prov)["type"] : json(nullptr),
                                         prov->contains("config") ? (*prov)["config"]
                                                                  : json::object());
            std::string remote = cloud::remote_path_for(*prov, mod_name, sub);
            auto objs = drv->list(remote);
            json out;
            out["remote"] = remote;
            json arr = json::array();
            for (const auto& o : objs) arr.push_back(o.to_dict());
            out["objects"] = arr;
            return Resp::Json(200, std::move(out));
        } catch (const std::exception& e) {
            return err500(py_exc_full(e));
        }
    });

    // ------------------------------------------------------------------
    // GET /api/cloud/local_files — api.py:2887-2908 (all errors -> 500).
    // ------------------------------------------------------------------
    r.get(R"(/api/cloud/local_files)", [](const Req& req) -> Resp {
        std::string mod_name = qget(req, "mod_name");
        if (mod_name.empty()) mod_name = qget(req, "mod");
        if (mod_name.empty()) mod_name = current_mod_name();
        if (mod_name.empty()) return err400("mod_name required");
        try {
            std::string mod_dir = cloud::get_mod_dir(mod_name);
            if (mod_dir.empty() || !spath::is_dir(mod_dir)) {
                json out;
                out["error"] = "mod not found: " + mod_name;
                out["mod_dir"] = mod_dir;
                return Resp::Json(404, std::move(out));
            }
            json entries = json::array();
            for (const auto& [rel, tup] : cloud::list_local_files(mod_name, false)) {
                json e;
                e["name"] = rel;
                e["type"] = "file";
                e["size"] = std::get<0>(tup);
                e["mtime"] = std::get<1>(tup);
                entries.push_back(std::move(e));
            }
            json out;
            out["mod"] = mod_name;
            out["root"] = mod_dir;
            out["entries"] = entries;
            out["count"] = static_cast<long long>(entries.size());
            return Resp::Json(200, std::move(out));
        } catch (const std::exception& e) {
            return err500(py_exc_full(e));
        }
    });

    // ------------------------------------------------------------------
    // GET /api/cloud/drivers — api.py:2910-2924 (schema per registered key).
    // ------------------------------------------------------------------
    r.get(R"(/api/cloud/drivers)", [](const Req&) -> Resp {
        json out = json::object();
        try {
            for (const auto& [name, factory] : cloud::drivers()) {
                json schema;
                try {
                    auto inst = factory(json::object());
                    schema = inst->config_schema();
                } catch (...) {
                    schema = json::object();
                }
                out[name] = schema;
            }
            json body;
            body["drivers"] = out;
            return Resp::Json(200, std::move(body));
        } catch (const std::exception& e) {
            return err500(py_exc_full(e));
        }
    });

    // ------------------------------------------------------------------
    // realtime config GET/POST/PUT — api.py:2929-2955.
    // ------------------------------------------------------------------
    r.get(R"(/api/cloud/realtime/config)", [](const Req&) -> Resp {
        try {
            json body;
            body["config"] = realtime::rt_get_config();
            return Resp::Json(200, std::move(body));
        } catch (const std::exception& e) {
            return err500(py_exc_full(e));
        }
    });
    auto config_write = [](const Req& req) -> Resp {
        try {
            json body = dict_body(req.body);
            json patch =
                (body.contains("config") && body["config"].is_object()) ? body["config"] : body;
            json cfg = realtime::rt_update_config(p5::py_truthy(patch) ? patch : json::object());
            json out;
            out["config"] = cfg;
            return Resp::Json(200, std::move(out));
        } catch (const std::exception& e) {
            return err400(py_exc_full(e));  // note: 400 for everything
        }
    };
    r.post(R"(/api/cloud/realtime/config)", config_write);
    r.put(R"(/api/cloud/realtime/config)", config_write);

    // ------------------------------------------------------------------
    // GET /api/cloud/realtime/status — api.py:2957-2964.
    // ------------------------------------------------------------------
    r.get(R"(/api/cloud/realtime/status)", [](const Req&) -> Resp {
        try {
            return Resp::Json(200, realtime::rt_get_status());
        } catch (const std::exception& e) {
            return err500(py_exc_full(e));
        }
    });

    // ------------------------------------------------------------------
    // POST /api/cloud/realtime/start — api.py:2966-2982.
    // ------------------------------------------------------------------
    r.post(R"(/api/cloud/realtime/start)", [](const Req& req) -> Resp {
        try {
            json body = dict_body(req.body);
            if (p5::py_truthy(body)) {
                json patch =
                    (body.contains("config") && body["config"].is_object()) ? body["config"]
                                                                            : body;
                static const std::set<std::string> known = {
                    "provider_id",            "mod_name",    "mods",
                    "direction",              "debounce_ms", "poll_interval_ms",
                    "remote_poll_interval_ms", "delete_extra", "auto_start",
                    "watch_all_mods",         "enabled",
                };
                json filtered = json::object();
                if (patch.is_object()) {
                    for (auto it = patch.begin(); it != patch.end(); ++it) {
                        if (known.count(it.key())) filtered[it.key()] = it.value();
                    }
                }
                if (!filtered.empty()) realtime::rt_update_config(filtered);
            }
            return Resp::Json(200, realtime::rt_start());
        } catch (const std::exception& e) {
            return map_value_then_generic(e);
        }
    });

    // ------------------------------------------------------------------
    // POST /api/cloud/realtime/stop — api.py:2984-2990.
    // ------------------------------------------------------------------
    r.post(R"(/api/cloud/realtime/stop)", [](const Req&) -> Resp {
        try {
            return Resp::Json(200, realtime::rt_stop());
        } catch (const std::exception& e) {
            return err500(py_exc_full(e));
        }
    });

    // ------------------------------------------------------------------
    // GET /api/cloud/realtime/events — api.py:2992-3002.
    // ------------------------------------------------------------------
    r.get(R"(/api/cloud/realtime/events)", [](const Req& req) -> Resp {
        try {
            std::string limit_s = qget(req, "limit");
            long long limit = 50;
            if (!limit_s.empty()) {
                auto iv = sa_core::py_int(limit_s);
                if (!iv) p4::raise_int_error(limit_s);  // -> 500 below
                limit = *iv;
            }
            limit = std::max(1LL, std::min(200LL, limit));
            json st = realtime::rt_get_status();
            json ev = json::array();
            const json& all_ev = st["events"];
            for (size_t i = 0;
                 i < std::min<size_t>(static_cast<size_t>(limit), all_ev.size()); ++i) {
                ev.push_back(all_ev[i]);
            }
            json out;
            out["events"] = ev;
            out["stats"] = st.contains("stats") ? st["stats"] : json::object();
            out["running"] = st.contains("running") ? st["running"] : json(nullptr);
            out["enabled"] = st.contains("enabled") ? st["enabled"] : json(nullptr);
            return Resp::Json(200, std::move(out));
        } catch (const std::exception& e) {
            return err500(py_exc_full(e));
        }
    });

    // auto_start wiring — api.py:3147-3150 runs it while building the router.
    realtime::rt_auto_start();
}

}  // namespace sa
