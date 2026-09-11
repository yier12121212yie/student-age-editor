// server/services/realtime.cpp — C++ port of backend/editor/server/realtime_sync.py.
// Python line numbers cited inline; error/log message strings verbatim.
//
// Implementation-layer deviation worth flagging up front: Python's watcher
// loop calls _rt_log() while holding the plain (non-reentrant)
// _rt_state_lock when the watched-mod set changes (realtime_sync.py:494-497)
// — that path would self-deadlock under CPython. C++ logs outside the lock;
// every observable state transition is identical.
#include "realtime.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <system_error>
#include <thread>
#include <tuple>
#include <vector>

#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/sha1.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "server/httpd.h"
#include "server/state.h"
#include "cloud_sync.h"
#include "p5_util.h"

#include "server/services/p4_util.h"

namespace sa {
namespace realtime {
namespace {

namespace sp = sa_core::str;
namespace spath = sa_core::paths;

// ---------------------------------------------------------------------------
// state (realtime_sync.py:145-168) — key insertion order frozen.
// ---------------------------------------------------------------------------
std::mutex g_state_mu;
json g_state = [] {
    json s;
    s["running"] = false;
    s["enabled"] = false;
    s["provider_id"] = "";
    s["mod_name"] = "";
    s["direction"] = "upload";
    s["last_sync"] = "";
    s["last_sync_result"] = nullptr;
    s["pending_count"] = 0;
    s["pending_files"] = json::array();
    s["error"] = "";
    s["events"] = json::array();
    json stats;
    stats["local_changes"] = 0;
    stats["remote_changes"] = 0;
    stats["sync_success"] = 0;
    stats["sync_failed"] = 0;
    s["stats"] = stats;
    s["watching_mods"] = json::array();
    s["next_remote_poll"] = 0;
    return s;
}();

// Watcher thread control (threading.Event analogue).
std::atomic<bool> g_stop{false};
std::atomic<bool> g_alive{false};
std::mutex g_sleep_mu;
std::condition_variable g_sleep_cv;  // interruptible sleep
std::mutex g_done_mu;
std::condition_variable g_done_cv;   // thread-exit signalling

// Serializes the start/stop lifecycle. Without it two concurrent POST
// /api/cloud/realtime/start calls both observe g_alive==false (it is only set
// inside the freshly detached watcher, or not yet set at all) and each spawn a
// watcher; the two threads then race the unsynchronized g_pending /
// g_prev_snapshots / g_remote_last_poll globals and can double-upload or
// double-delete. The watcher never takes this lock (its exit only sets
// g_alive/false + notifies), so wait_thread_done cannot deadlock against it.
std::mutex g_life_mu;

// Test-only: counts how many watcher threads rt_start has actually spawned.
std::atomic<int> g_watcher_starts{0};

std::mutex g_cfg_mu;  // _rt_config_lock

// _RT_AMBIG_SHA (250-251)
std::mutex g_ambig_mu;
std::map<std::pair<std::string, std::string>, std::string> g_ambig_sha;

// Watcher-owned globals (Python module level; only ever one live watcher —
// rt_start refuses to respawn while an old draining thread is alive).
std::map<std::string, std::pair<std::set<std::string>, std::set<std::string>>> g_pending;
std::map<std::string, std::map<std::string, std::pair<long long, long long>>>
    g_prev_snapshots;
double g_last_change_ts = 0;
double g_remote_last_poll = 0;

bool wait_stop(double seconds) {
    // _rt_stop.wait(x) — true when stop was requested.
    std::unique_lock<std::mutex> lk(g_sleep_mu);
    return g_sleep_cv.wait_for(lk,
                               std::chrono::milliseconds(
                                   static_cast<long long>(seconds * 1000.0)),
                               [] { return g_stop.load(); });
}

void wake_sleepers() { g_sleep_cv.notify_all(); }

const char* json_type_name(const json& v) {
    if (v.is_null()) return "NoneType";
    if (v.is_boolean()) return "bool";
    if (v.is_number_integer() || v.is_number_unsigned()) return "int";
    if (v.is_number_float()) return "float";
    if (v.is_string()) return "str";
    if (v.is_array()) return "list";
    return "dict";
}

// str(e) — same shape as cloud's helper (kept local to avoid cross-TU noise).
std::string exc_str(const std::exception& e) {
    if (auto* py = dynamic_cast<const cloud::PyError*>(&e)) return py->str_msg;
    if (auto* ae = dynamic_cast<const ApiError*>(&e)) {
        std::string w = ae->what();
        std::string pre = ae->type_name + ": ";
        return w.rfind(pre, 0) == 0 ? w.substr(pre.size()) : w;
    }
    return e.what();
}

// _rt_log (170-182)
void rt_log(const std::string& msg, const std::string& level = "info",
            const std::string& mod = "") {
    json entry;
    entry["time"] = p5::iso_now_local();
    entry["level"] = level;
    entry["msg"] = msg;
    if (!mod.empty()) entry["mod"] = mod;
    std::lock_guard<std::mutex> lk(g_state_mu);
    json ev = json::array();
    ev.push_back(entry);  // events.insert(0, entry)
    for (size_t i = 0; i < std::min<size_t>(119, g_state["events"].size()); ++i)
        ev.push_back(g_state["events"][i]);
    g_state["events"] = ev;
    if (level == "error") g_state["error"] = msg;
}

// ---------------------------------------------------------------------------
// config paths (29-57)
// ---------------------------------------------------------------------------

std::string config_path() {
    std::string ws;
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        ws = STATE().workspace_root;
    }
    if (!ws.empty() && spath::is_dir(ws)) return spath::join(ws, ".editor_realtime.json");
    return spath::join(spath::join(editor_root(), "_cache"), "realtime_config.json");
}

// Internal builder; the public sa::realtime::default_config() lives in the
// exports block below (it must have external linkage to satisfy realtime.h).
json make_default_config() {
    json c;
    c["enabled"] = false;
    c["provider_id"] = "";
    c["mod_name"] = "";
    c["mods"] = json::array();
    c["direction"] = "upload";
    c["debounce_ms"] = 2000;
    c["poll_interval_ms"] = 2000;
    c["remote_poll_interval_ms"] = 30000;
    c["delete_extra"] = false;
    c["auto_start"] = false;
    c["watch_all_mods"] = false;
    return c;
}

// int(cfg.get(k, dflt)) inside max(lo, min(hi, ...)) — raises the Python way.
long long clamp_ms(const json& v, long long lo, long long hi) {
    auto iv = p4::json_int(v);
    if (!iv) {
        if (v.is_string()) p4::raise_int_error(v.get<std::string>());
        throw cloud::PyError("TypeError",
                             "int() argument must be a string, a bytes-like object or a real "
                             "number, not '" +
                                 std::string(json_type_name(v)) + "'");
    }
    return std::max(lo, std::min(hi, *iv));
}

json load_config() {
    // _rt_load_config (63-86) — merge known keys; one try covers normalize,
    // so a raising clamp aborts the remaining steps (partially normalized
    // config stands, like Python).
    json cfg = make_default_config();
    std::string p = config_path();
    try {
        if (!spath::is_file(p)) return cfg;
        auto raw = spath::read_bytes(p);
        if (!raw.has_value()) return cfg;
        json data = json::parse(*raw);
        if (data.is_object()) {
            for (auto it = data.begin(); it != data.end(); ++it) {
                if (cfg.contains(it.key())) cfg[it.key()] = it.value();
            }
        }
    } catch (...) {
        return cfg;
    }
    try {
        if (p5::py_truthy(cfg["mods"]) && !cfg["mods"].is_array()) cfg["mods"] = json::array();
        const char* const dirs[] = {"upload", "download", "sync"};
        bool ok_dir = false;
        if (cfg["direction"].is_string()) {
            for (const char* d : dirs) {
                if (cfg["direction"].get<std::string>() == d) ok_dir = true;
            }
        }
        if (!ok_dir) cfg["direction"] = "upload";
        cfg["debounce_ms"] = clamp_ms(cfg["debounce_ms"], 300, 15000);
        cfg["poll_interval_ms"] = clamp_ms(cfg["poll_interval_ms"], 500, 10000);
        cfg["remote_poll_interval_ms"] = clamp_ms(cfg["remote_poll_interval_ms"], 5000, 300000);
    } catch (...) {
        // except Exception: pass
    }
    return cfg;
}

void save_config(const json& cfg) {
    std::string p = config_path();
    try {
        sa_core::write_text_atomic(p, sa_core::py_dumps_indent(cfg));
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[realtime] save config failed: %s\n", e.what());
    }
}

// ---------------------------------------------------------------------------
// mod resolution & snapshots
// ---------------------------------------------------------------------------

std::vector<std::string> get_all_mod_names() {
    // _get_all_mod_names (203-219)
    std::vector<std::string> out;
    bool from_state = true;
    try {
        json mods = list_mods();
        if (mods.is_array()) {
            for (const auto& m : mods) {
                if (m.is_object() && m.contains("name") && p5::py_truthy(m["name"])) {
                    out.push_back(m["name"].is_string() ? m["name"].get<std::string>()
                                                        : sa_core::py_str(m["name"]));
                }
            }
            return out;
        }
        from_state = false;
    } catch (...) {
        from_state = false;
    }
    if (from_state) return out;
    out.clear();
    try {
        std::string root = cloud::local_mods_root();
        if (spath::is_dir(root)) {
            bool ok = false;
            for (const auto& d : spath::listdir_sorted(root, &ok)) {
                if (ok && !sp::starts_with(d, ".") && !sp::starts_with(d, "_") &&
                    spath::is_dir(spath::join(root, d))) {
                    out.push_back(d);
                }
            }
        }
    } catch (...) {
    }
    return out;
}

std::string strip_or_throw(const json& v) {
    if (!p5::py_truthy(v)) return "";
    if (v.is_string()) return p4::strip(v.get<std::string>());
    throw ApiError("AttributeError",
                   "'" + std::string(json_type_name(v)) + "' object has no attribute 'strip'");
}

// _resolve_watch_mods (221-235)
std::vector<std::string> resolve_watch_mods(const json& cfg) {
    if (p5::py_truthy(cfg.contains("watch_all_mods") ? cfg["watch_all_mods"] : json(nullptr))) {
        return get_all_mod_names();
    }
    json mods = cfg.contains("mods") ? cfg["mods"] : json(nullptr);
    if (p5::py_truthy(mods)) {
        std::vector<std::string> out;
        if (mods.is_array()) {
            for (const auto& m : mods) {
                if (p5::py_truthy(m)) {
                    out.push_back(m.is_string() ? m.get<std::string>() : sa_core::py_str(m));
                }
            }
        }
        return out;
    }
    std::string single =
        strip_or_throw(cfg.contains("mod_name") ? cfg["mod_name"] : json(nullptr));
    if (!single.empty()) return {single};
    auto all = get_all_mod_names();
    if (all.size() > 20) all.resize(5);  // flood guard (231-234)
    return all;
}

using Snapshot = std::map<std::string, std::pair<long long, long long>>;

// os.path.join(dir, *rel.split("/")) — path-native separators.
std::string join_rel(const std::string& dir, const std::string& rel) {
    std::filesystem::path p = spath::to_path(dir);
    size_t pos = 0;
    while (pos <= rel.size()) {
        size_t slash = rel.find('/', pos);
        std::string seg =
            rel.substr(pos, slash == std::string::npos ? std::string::npos : slash - pos);
        if (!seg.empty()) p /= spath::to_path(seg);
        if (slash == std::string::npos) break;
        pos = slash + 1;
    }
    return spath::path_to_utf8(p);
}

// _snapshot_mod (237-247)
Snapshot snapshot_mod(const std::string& mod_name) {
    Snapshot snap;
    try {
        for (const auto& [rel, tup] : cloud::list_local_files(mod_name, false)) {
            snap[rel] = {std::get<0>(tup), std::get<1>(tup)};
        }
    } catch (const std::exception& e) {
        rt_log("snapshot " + mod_name + " failed: " + exc_str(e), "error", mod_name);
        return {};
    }
    return snap;
}

bool contains_sub(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

// _detect_changes._valid (294-305)
bool valid_rel(const std::string& rel) {
    std::string base = rel;
    size_t slash = rel.find_last_of('/');
    if (slash != std::string::npos) base = rel.substr(slash + 1);
    if (rel == ".editor_flow.json" || sp::starts_with(rel, ".editor_history/")) return false;
    if (sp::starts_with(base, ".") && !sp::ends_with(base, ".json")) return false;
    if (sp::starts_with(base, "~") || sp::ends_with(base, ".tmp") || sp::ends_with(base, ".swp"))
        return false;
    if (contains_sub(rel, "__pycache__") || sp::starts_with(rel, "_cache")) return false;
    return true;
}

bool is_cloud_busy() {
    json st = cloud::sync_status();
    return p5::py_truthy(st.contains("running") ? st["running"] : json(false));
}

// float(cfg.get(k, dflt)) in the watcher loop — bad values raise like Python
// (loop-level error handler logs + 2s backoff).
double cfg_float(const json& cfg, const char* k, long long dflt) {
    auto it = cfg.find(k);
    if (it == cfg.end() || it->is_null()) {
        if (it == cfg.end()) return static_cast<double>(dflt);
        throw cloud::PyError("TypeError",
                             "float() argument must be a string or a real number, not "
                             "'NoneType'");
    }
    auto iv = p4::json_int(*it);
    if (!iv) {
        if (it->is_string()) {
            throw cloud::PyError("ValueError",
                                 "could not convert string to float: " +
                                     sa_core::py_repr_str(it->get<std::string>()));
        }
        throw cloud::PyError("TypeError", "float() argument must be a string or a real number, not '" +
                                              std::string(json_type_name(*it)) + "'");
    }
    return static_cast<double>(*iv);
}

// _execute_sync (323-413)
json execute_sync(const std::string& provider_id, const std::string& mod_name,
                  const std::string& direction, const std::set<std::string>& changed_rels,
                  const std::set<std::string>& deleted_rels, bool delete_extra) {
    auto prov_opt = cloud::get_provider(provider_id);
    if (!prov_opt) cloud::raise_value_error("provider not found: " + provider_id);
    long long total_ops = 0;
    json results = json::array();
    if (!changed_rels.empty()) {
        std::vector<std::string> rel_list(changed_rels.begin(), changed_rels.end());
        if (direction == "upload") {
            try {
                json res =
                    cloud::sync_mod_files(provider_id, "upload", mod_name, json(rel_list), false);
                for (const auto& r : res["results"]) results.push_back(r);
                total_ops += static_cast<long long>(rel_list.size());
            } catch (const std::exception& e) {
                rt_log("sync upload " + mod_name + " failed: " + exc_str(e), "error", mod_name);
                throw;
            }
        } else if (direction == "download") {
            json shown = json::array();
            for (size_t i = 0; i < std::min<size_t>(3, rel_list.size()); ++i)
                shown.push_back(rel_list[i]);
            rt_log("local change ignored in download mode: " + mod_name + " " +
                       p5::py_list_repr(shown),
                   "warn", mod_name);
        } else if (direction == "sync") {
            for (const auto& rel : rel_list) {
                try {
                    auto driver = cloud::get_driver(
                        prov_opt->contains("type") ? (*prov_opt)["type"] : json(nullptr),
                        prov_opt->contains("config") ? (*prov_opt)["config"] : json(nullptr));
                    std::string remote = cloud::remote_path_for(*prov_opt, mod_name, rel);
                    std::string local_path = join_rel(cloud::get_mod_dir(mod_name), rel);
                    std::optional<cloud::Obj> remote_obj;
                    try {
                        remote_obj = driver->stat(remote);
                    } catch (...) {
                        remote_obj = std::nullopt;
                    }
                    if (remote_obj && remote_obj->mtime) {
                        try {
                            auto st = spath::stat(local_path);
                            if (st.has_value()) {
                                long long lm =
                                    static_cast<long long>(std::floor(st->mtime_ns / 1e9));
                                long long rm = remote_obj->mtime;
                                if (rm > lm + 2) {
                                    rt_log("skip upload " + rel + " (remote newer " +
                                               std::to_string(rm - lm) + "s)",
                                           "info", mod_name);
                                    json e;
                                    e["rel"] = rel;
                                    e["ok"] = true;
                                    e["action"] = "skip_remote_newer";
                                    results.push_back(e);
                                    continue;
                                }
                            }
                        } catch (...) {
                        }
                    }
                    cloud::sync_single_file(provider_id, "upload", mod_name, rel, false);
                    json e;
                    e["rel"] = rel;
                    e["ok"] = true;
                    e["action"] = "realtime_upload";
                    results.push_back(e);
                    total_ops += 1;
                } catch (const std::exception& e) {
                    json err;
                    err["rel"] = rel;
                    err["ok"] = false;
                    err["error"] = exc_str(e);
                    results.push_back(err);
                }
            }
        }
    }
    if (!deleted_rels.empty() && delete_extra) {
        if (direction == "upload" || direction == "sync") {
            auto prov2 = cloud::get_provider(provider_id);
            if (prov2) {
                auto driver = cloud::get_driver(
                    prov2->contains("type") ? (*prov2)["type"] : json(nullptr),
                    prov2->contains("config") ? (*prov2)["config"] : json(nullptr));
                for (const auto& rel : deleted_rels) {
                    try {
                        std::string remote = cloud::remote_path_for(*prov2, mod_name, rel);
                        driver->remove(remote);
                        json e;
                        e["rel"] = rel;
                        e["ok"] = true;
                        e["action"] = "realtime_delete_remote";
                        results.push_back(e);
                        total_ops += 1;
                        rt_log("deleted remote " + rel, "info", mod_name);
                    } catch (const std::exception& e) {
                        json err;
                        err["rel"] = rel;
                        err["ok"] = false;
                        err["error"] = exc_str(e);
                        results.push_back(err);
                    }
                }
            }
        }
    }
    json out;
    out["total"] = total_ops;
    out["results"] = results;
    return out;
}

// _poll_remote_and_sync (415-472)
std::optional<json> poll_remote_and_sync(const std::string& provider_id,
                                         const std::string& mod_name,
                                         const std::string& direction) {
    if (direction != "download" && direction != "sync") return std::nullopt;
    auto prov_opt = cloud::get_provider(provider_id);
    if (!prov_opt) return std::nullopt;
    try {
        auto driver = cloud::get_driver(
            prov_opt->contains("type") ? (*prov_opt)["type"] : json(nullptr),
            prov_opt->contains("config") ? (*prov_opt)["config"] : json(nullptr));
        std::string remote_base = cloud::remote_path_for(*prov_opt, mod_name, "");
        auto remote_map = cloud::list_remote_recursive(driver.get(), remote_base);
        auto local_map = cloud::list_local_files(mod_name, false);
        std::string mod_dir = cloud::get_mod_dir(mod_name);
        std::vector<std::string> to_download;
        for (const auto& [rel, obj] : remote_map) {
            auto li = local_map.find(rel);
            if (li == local_map.end()) {
                to_download.push_back(rel);
                continue;
            }
            long long ls = std::get<0>(li->second), lm = std::get<1>(li->second);
            std::string lh = std::get<2>(li->second);
            long long rs = obj.size, rm = obj.mtime;
            const std::string& rsha = obj.sha1;
            std::string local_full = join_rel(mod_dir, rel);
            if (lh.empty() && ls == rs && !rsha.empty()) lh = cloud::lazy_sha(local_full);
            if (cloud::need_sync(ls, lm, lh, rs, rm, rsha, local_full)) {
                if (direction == "download") {
                    to_download.push_back(rel);
                } else if (rm && lm && rm > lm) {
                    to_download.push_back(rel);
                } else if (!lm || !rm) {
                    if (ls != rs) to_download.push_back(rel);
                }
            }
        }
        if (to_download.empty()) {
            json out;
            out["total"] = 0;
            out["results"] = json::array();
            return out;
        }
        std::sort(to_download.begin(), to_download.end());
        if (to_download.size() > 100) to_download.resize(100);
        json shown = json::array();
        for (size_t i = 0; i < std::min<size_t>(3, to_download.size()); ++i)
            shown.push_back(to_download[i]);
        rt_log("remote changes " + std::to_string(remote_map.size()) + " -> download " +
                   std::to_string(to_download.size()) + " files: " + p5::py_list_repr(shown),
               "info", mod_name);
        return cloud::sync_mod_files(provider_id, "download", mod_name, json(to_download), false);
    } catch (const std::exception& e) {
        rt_log("remote poll " + mod_name + " failed: " + exc_str(e), "error", mod_name);
        return std::nullopt;
    }
}

// _watcher_loop (476-641)
void watcher_loop() {
    // g_alive is published by rt_start before the thread is detached, so a
    // concurrent start cannot race this entry point into a second watcher.
    try {
        rt_log("realtime watcher started", "info");
        json cfg = rt_get_config();
        auto mods = resolve_watch_mods(cfg);
        for (const auto& m : mods) g_prev_snapshots[m] = snapshot_mod(m);
        {
            std::lock_guard<std::mutex> lk(g_state_mu);
            g_state["watching_mods"] = mods;
            g_state["pending_files"] = json::array();
            g_state["pending_count"] = 0;
        }
        g_remote_last_poll = p5::epoch_now();
        while (!g_stop.load()) {
            try {
                cfg = rt_get_config();
                auto current_mods = resolve_watch_mods(cfg);
                bool mods_changed = false;
                {
                    std::lock_guard<std::mutex> lk(g_state_mu);
                    std::set<std::string> want(current_mods.begin(), current_mods.end());
                    std::set<std::string> have;
                    if (g_state["watching_mods"].is_array()) {
                        for (const auto& m : g_state["watching_mods"]) {
                            if (m.is_string()) have.insert(m.get<std::string>());
                        }
                    }
                    mods_changed = (want != have);
                }
                if (mods_changed) {
                    rt_log("watching mods changed: " + p5::py_list_repr(json(current_mods)),
                           "info");
                    {
                        std::lock_guard<std::mutex> lk(g_state_mu);
                        g_state["watching_mods"] = current_mods;
                    }
                    std::set<std::string> want(current_mods.begin(), current_mods.end());
                    for (const auto& nm : current_mods) {
                        if (!g_prev_snapshots.count(nm)) g_prev_snapshots[nm] = snapshot_mod(nm);
                    }
                    for (auto it = g_pending.begin(); it != g_pending.end();) {
                        if (!want.count(it->first)) it = g_pending.erase(it);
                        else ++it;
                    }
                }
                std::string provider_id;
                {
                    json v = cfg.contains("provider_id") ? cfg["provider_id"] : json(nullptr);
                    if (p5::py_truthy(v)) {
                        provider_id = v.is_string() ? v.get<std::string>() : sa_core::py_str(v);
                    }
                }
                std::string direction = cfg.contains("direction") && cfg["direction"].is_string()
                                            ? cfg["direction"].get<std::string>()
                                            : std::string("upload");
                bool delete_extra = p5::py_truthy(
                    cfg.contains("delete_extra") ? cfg["delete_extra"] : json(nullptr));
                double debounce = cfg_float(cfg, "debounce_ms", 2000) / 1000.0;
                double poll_interval = cfg_float(cfg, "poll_interval_ms", 2000) / 1000.0;
                double remote_poll_interval =
                    cfg_float(cfg, "remote_poll_interval_ms", 30000) / 1000.0;

                bool enabled =
                    p5::py_truthy(cfg.contains("enabled") ? cfg["enabled"] : json(nullptr));
                if (!enabled) {
                    if (wait_stop(std::min(poll_interval, 1.0))) break;
                    continue;
                }
                if (provider_id.empty()) {
                    if (wait_stop(std::min(poll_interval, 1.0))) break;
                    continue;
                }
                if (!cloud::get_provider(provider_id)) {
                    {
                        std::lock_guard<std::mutex> lk(g_state_mu);
                        g_state["error"] = "provider not found: " + provider_id;
                    }
                    if (wait_stop(2.0)) break;
                    continue;
                }

                // local polling (532-563)
                for (const auto& mod : current_mods) {
                    if (g_stop.load()) break;
                    Snapshot cur = snapshot_mod(mod);
                    Snapshot prev;
                    auto pi = g_prev_snapshots.find(mod);
                    if (pi != g_prev_snapshots.end()) prev = pi->second;
                    Diff diff = detect_changes(prev, cur, mod, true);
                    std::set<std::string> changed(diff.changed.begin(), diff.changed.end());
                    std::set<std::string> deleted(diff.deleted.begin(), diff.deleted.end());
                    if (!changed.empty() || !deleted.empty()) {
                        g_prev_snapshots[mod] = cur;
                        auto& slot = g_pending[mod];
                        slot.first.insert(changed.begin(), changed.end());
                        slot.second.insert(deleted.begin(), deleted.end());
                        g_last_change_ts = p5::epoch_now();
                        long long total_pending = 0;
                        for (const auto& [mm, vals] : g_pending) {
                            total_pending +=
                                static_cast<long long>(vals.first.size() + vals.second.size());
                        }
                        json flat = json::array();
                        for (const auto& [mm, vals] : g_pending) {
                            size_t n = 0;
                            for (const auto& r : vals.first) {
                                if (n++ >= 10) break;
                                flat.push_back(mm + ":" + r);
                            }
                            n = 0;
                            for (const auto& r : vals.second) {
                                if (n++ >= 10) break;
                                flat.push_back(mm + ":" + r + "(deleted)");
                            }
                        }
                        while (flat.size() > 20) flat.erase(flat.end() - 1);
                        {
                            std::lock_guard<std::mutex> lk(g_state_mu);
                            g_state["pending_count"] = total_pending;
                            g_state["pending_files"] = flat;
                            g_state["error"] = "";
                        }
                        json shown = json::array();
                        size_t n = 0;
                        for (const auto& r : changed) {
                            if (n++ >= 3) break;
                            shown.push_back(r);
                        }
                        rt_log("detected " + std::to_string(changed.size()) + " changed + " +
                                   std::to_string(deleted.size()) + " deleted in " + mod + ": " +
                                   p5::py_list_repr(shown),
                               "info", mod);
                        {
                            std::lock_guard<std::mutex> lk(g_state_mu);
                            g_state["stats"]["local_changes"] =
                                g_state["stats"]["local_changes"].get<long long>() +
                                static_cast<long long>(changed.size() + deleted.size());
                        }
                    } else {
                        g_prev_snapshots[mod] = cur;
                    }
                }

                // debounce fire (565-602)
                if (!g_pending.empty() && g_last_change_ts &&
                    (p5::epoch_now() - g_last_change_ts) >= debounce) {
                    if (is_cloud_busy()) {
                        if (wait_stop(0.5)) break;
                        continue;
                    }
                    decltype(g_pending) pending_copy = g_pending;
                    g_pending.clear();
                    {
                        std::lock_guard<std::mutex> lk(g_state_mu);
                        g_state["pending_count"] = 0;
                        g_state["pending_files"] = json::array();
                    }
                    for (const auto& [mod, vals] : pending_copy) {
                        std::set<std::string> changed = vals.first;
                        std::set<std::string> deleted = vals.second;
                        if (changed.empty() && deleted.empty()) continue;
                        if (!delete_extra) deleted.clear();
                        if (provider_id.empty() || mod.empty()) continue;
                        rt_log("auto-sync " + direction + " " + mod + " " +
                                   std::to_string(changed.size() + deleted.size()) +
                                   " files (changed " + std::to_string(changed.size()) +
                                   " deleted " + std::to_string(deleted.size()) + ")",
                               "info", mod);
                        try {
                            json res =
                                execute_sync(provider_id, mod, direction, changed, deleted,
                                             delete_extra);
                            long long total =
                                res.contains("total") ? res["total"].get<long long>() : 0;
                            {
                                std::lock_guard<std::mutex> lk(g_state_mu);
                                g_state["last_sync"] = p5::iso_now_local();
                                g_state["last_sync_result"] = res;
                                g_state["stats"]["sync_success"] =
                                    g_state["stats"]["sync_success"].get<long long>() + 1;
                            }
                            rt_log("auto-sync " + mod + " done +" + std::to_string(total),
                                   "info", mod);
                        } catch (const std::exception& e) {
                            {
                                std::lock_guard<std::mutex> lk(g_state_mu);
                                g_state["stats"]["sync_failed"] =
                                    g_state["stats"]["sync_failed"].get<long long>() + 1;
                                g_state["error"] = exc_str(e);
                            }
                            rt_log("auto-sync " + mod + " failed: " + exc_str(e), "error", mod);
                        }
                    }
                    g_last_change_ts = 0;
                }

                // remote poll (604-628)
                double now = p5::epoch_now();
                if ((direction == "download" || direction == "sync") &&
                    (now - g_remote_last_poll) >= remote_poll_interval) {
                    g_remote_last_poll = now;
                    if (!is_cloud_busy()) {
                        for (const auto& mod : current_mods) {
                            if (g_stop.load()) break;
                            rt_log("polling remote for " + mod, "info", mod);
                            auto res = poll_remote_and_sync(provider_id, mod, direction);
                            long long total =
                                (res && res->contains("total") && (*res)["total"].is_number())
                                    ? (*res)["total"].get<long long>()
                                    : 0;
                            if (total > 0) {
                                {
                                    std::lock_guard<std::mutex> lk(g_state_mu);
                                    g_state["last_sync"] = p5::iso_now_local();
                                    g_state["last_sync_result"] = *res;
                                    g_state["stats"]["remote_changes"] =
                                        g_state["stats"]["remote_changes"].get<long long>() +
                                        total;
                                }
                                rt_log("remote auto-download " + mod + " +" +
                                           std::to_string(total),
                                       "info", mod);
                                g_prev_snapshots[mod] = snapshot_mod(mod);
                            }
                            if (wait_stop(0.2)) break;
                        }
                    }
                    {
                        std::lock_guard<std::mutex> lk(g_state_mu);
                        g_state["next_remote_poll"] = static_cast<long long>(
                            std::floor(g_remote_last_poll + remote_poll_interval));
                    }
                }

                if (wait_stop(poll_interval)) break;
            } catch (const std::exception& e) {
                rt_log("watcher loop error: " + exc_str(e), "error");
                wait_stop(2.0);
            } catch (...) {
                rt_log("watcher loop error: unknown", "error");
                wait_stop(2.0);
            }
        }
        rt_log("realtime watcher stopped", "info");
    } catch (...) {
        // Never let an exception escape the thread.
    }
    {
        std::lock_guard<std::mutex> lk(g_state_mu);
        g_state["running"] = false;
        g_state["enabled"] = false;
    }
    g_alive = false;
    {
        std::lock_guard<std::mutex> lk(g_done_mu);
    }
    g_done_cv.notify_all();
}

}  // namespace

std::string rt_config_path() { return config_path(); }

json default_config() { return make_default_config(); }

json rt_get_config() {
    std::lock_guard<std::mutex> lk(g_cfg_mu);
    return load_config();
}

json rt_update_config(const json& patch) {
    if (!patch.is_object()) cloud::raise_value_error("config patch must be dict");
    std::lock_guard<std::mutex> lk(g_cfg_mu);
    json cfg = load_config();

    // rt_update_config (100-141) — fixed key tuple order.
    if (patch.contains("enabled")) cfg["enabled"] = p5::py_truthy(patch["enabled"]);
    if (patch.contains("provider_id")) cfg["provider_id"] = patch["provider_id"];
    if (patch.contains("mod_name")) cfg["mod_name"] = patch["mod_name"];
    if (patch.contains("mods")) {
        const json& v = patch["mods"];
        if (v.is_null()) {
            cfg["mods"] = json::array();
        } else if (v.is_array()) {
            json out = json::array();
            for (const auto& x : v) {
                std::string s = x.is_string() ? x.get<std::string>() : sa_core::py_str(x);
                if (!p4::strip(s).empty()) out.push_back(s);
            }
            cfg["mods"] = out;
        } else if (v.is_string() && !p4::strip(v.get<std::string>()).empty()) {
            cfg["mods"] = json::array({p4::strip(v.get<std::string>())});
        } else {
            cfg["mods"] = json::array();
        }
    }
    if (patch.contains("direction")) {
        std::string d = sp::lower(patch["direction"].is_string()
                                      ? patch["direction"].get<std::string>()
                                      : sa_core::py_str(patch["direction"]));
        if (d == "upload" || d == "download" || d == "sync") cfg["direction"] = d;
    }
    for (const char* k : {"debounce_ms", "poll_interval_ms", "remote_poll_interval_ms"}) {
        if (patch.contains(k)) {
            auto iv = p4::json_int(patch[k]);
            if (iv) cfg[k] = *iv;  // except Exception: pass
        }
    }
    if (patch.contains("delete_extra")) cfg["delete_extra"] = p5::py_truthy(patch["delete_extra"]);
    if (patch.contains("auto_start")) cfg["auto_start"] = p5::py_truthy(patch["auto_start"]);
    if (patch.contains("watch_all_mods"))
        cfg["watch_all_mods"] = p5::py_truthy(patch["watch_all_mods"]);
    if (p5::py_truthy(cfg["watch_all_mods"])) {
        cfg["mods"] = json::array();
        cfg["mod_name"] = "";
    }
    cfg["debounce_ms"] = clamp_ms(cfg["debounce_ms"], 300, 15000);
    cfg["poll_interval_ms"] = clamp_ms(cfg["poll_interval_ms"], 500, 10000);
    cfg["remote_poll_interval_ms"] = clamp_ms(cfg["remote_poll_interval_ms"], 5000, 300000);
    save_config(cfg);
    return cfg;
}

json rt_get_status() {
    json cfg = rt_get_config();
    json st;
    {
        std::lock_guard<std::mutex> lk(g_state_mu);
        st = g_state;
        json ev = json::array();
        for (size_t i = 0; i < std::min<size_t>(50, st["events"].size()); ++i)
            ev.push_back(st["events"][i]);
        st["events"] = ev;
    }
    st["config"] = cfg;
    st["cloud_sync"] = cloud::sync_status();
    return st;
}

bool ambig_content_changed(const std::string& mod_name, const std::string& rel) {
    // _ambig_content_changed (253-277)
    std::string sha;
    try {
        std::string path = join_rel(cloud::get_mod_dir(mod_name), rel);
        if (!spath::is_file(path) || spath::file_size(path) > 20LL * 1024 * 1024) return false;
        auto b = spath::read_bytes(path);
        if (!b.has_value()) return true;  // 读不到就保守按有变化处理
        sha = sa_core::sha1_hex(*b);
    } catch (...) {
        return true;
    }
    std::lock_guard<std::mutex> lk(g_ambig_mu);
    auto key = std::make_pair(mod_name, rel);
    auto it = g_ambig_sha.find(key);
    // Python: prev = dict.get(key); dict[key] = sha; return prev is not None
    // and prev != sha. The old value MUST be captured BEFORE the overwrite —
    // comparing it->second AFTER `g_ambig_sha[key] = sha` reads the new value
    // back (same map slot) and made this always return false, silently
    // killing the same-second equal-size detection this guard exists for.
    const bool had_prev = it != g_ambig_sha.end();
    const std::string prev_sha = had_prev ? it->second : std::string();
    g_ambig_sha[key] = sha;
    return had_prev && prev_sha != sha;
}

void clear_ambig_cache() {
    std::lock_guard<std::mutex> lk(g_ambig_mu);
    g_ambig_sha.clear();
}

Diff detect_changes(const Snapshot& prev, const Snapshot& cur, const std::string& mod_name,
                    bool with_ambig) {
    // _detect_changes (279-311)
    Diff d;
    std::set<std::string> added, modified, deleted;
    for (const auto& [k, cv] : cur) {
        auto pv = prev.find(k);
        if (pv == prev.end()) {
            added.insert(k);
            continue;
        }
        long long ps = pv->second.first, pm = pv->second.second;
        long long cs = cv.first, cm = cv.second;
        if (ps != cs || std::llabs(pm - cm) > 1) {
            modified.insert(k);
        } else if (with_ambig && !mod_name.empty() && ambig_content_changed(mod_name, k)) {
            modified.insert(k);
        }
    }
    for (const auto& [k, pv] : prev) {
        if (!cur.count(k)) deleted.insert(k);
    }
    auto filter = [](std::set<std::string>& s) {
        for (auto it = s.begin(); it != s.end();) {
            if (!valid_rel(*it)) it = s.erase(it);
            else ++it;
        }
    };
    filter(added);
    filter(modified);
    filter(deleted);
    std::set<std::string> changed = added;
    changed.insert(modified.begin(), modified.end());
    d.added.assign(added.begin(), added.end());
    d.modified.assign(modified.begin(), modified.end());
    d.deleted.assign(deleted.begin(), deleted.end());
    d.changed.assign(changed.begin(), changed.end());
    return d;
}

bool wait_thread_done(int timeout_ms) {
    if (!g_alive.load()) return true;
    std::unique_lock<std::mutex> lk(g_done_mu);
    return g_done_cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                              [] { return !g_alive.load(); });
}

json rt_start() {
    json cfg = rt_get_config();
    if (!p5::py_truthy(cfg.contains("provider_id") ? cfg["provider_id"] : json(nullptr))) {
        cloud::raise_value_error("provider_id required to start realtime sync");
    }
    auto mods = resolve_watch_mods(cfg);
    if (mods.empty()) {
        cloud::raise_value_error("no mods to watch (select mod or enable watch_all)");
    }
    // Serialize the whole lifecycle decision so a second concurrent start
    // cannot slip past the g_alive check before the first watcher sets it.
    std::lock_guard<std::mutex> life(g_life_mu);
    bool alive = false, draining = false;
    {
        std::lock_guard<std::mutex> lk(g_state_mu);
        alive = p5::py_truthy(g_state["running"]) && g_alive.load();
        draining = g_stop.load();
    }
    if (alive && !draining) {
        {
            std::lock_guard<std::mutex> lk(g_state_mu);
            g_state["enabled"] = true;
        }
        return rt_get_status();
    }
    if (alive && draining) {
        // 662-668: rt_stop's 2s join expired while the old thread was stuck
        // mid-sync — wait for it, else the watcher would silently die.
        if (!wait_thread_done(5000)) {
            throw ApiError("RuntimeError", "上一次实时同步停止尚未完成，请稍后重试");
        }
    }
    {
        std::lock_guard<std::mutex> lk(g_state_mu);
        g_state["running"] = true;
        g_state["enabled"] = true;
        g_state["error"] = "";
        g_state["provider_id"] = cfg.contains("provider_id") ? cfg["provider_id"] : json("");
        g_state["direction"] =
            cfg.contains("direction") ? cfg["direction"] : json("upload");
        g_state["watching_mods"] = mods;
    }
    rt_update_config(json{{"enabled", true}});
    g_stop = false;
    // Publish aliveness BEFORE detaching: the new watcher owns the flag from
    // here on, so the next start sees a live thread and does not spawn a second.
    g_alive = true;
    g_watcher_starts.fetch_add(1);
    try {
        std::thread(watcher_loop).detach();
    } catch (const std::system_error& e) {
        // Thread construction failed (resource exhaustion): no watcher owns
        // g_alive, so leaving it true would make every later rt_start observe
        // alive && draining and fail forever. Roll the published state back.
        g_alive = false;
        g_watcher_starts.fetch_sub(1);
        {
            std::lock_guard<std::mutex> lk(g_state_mu);
            g_state["running"] = false;
            g_state["enabled"] = false;
            g_state["error"] = exc_str(e);
        }
        rt_update_config(json{{"enabled", false}});
        throw ApiError("RuntimeError", "实时同步线程创建失败: " + exc_str(e));
    }
    rt_log("realtime sync enabled provider=" +
               sa_core::py_str(cfg.contains("provider_id") ? cfg["provider_id"] : json("")) +
               " mods=" + p5::py_list_repr(json(mods)) +
               " dir=" + sa_core::py_str(cfg.contains("direction") ? cfg["direction"]
                                                                   : json("upload")),
           "info");
    return rt_get_status();
}

json rt_stop() {
    std::lock_guard<std::mutex> life(g_life_mu);
    rt_update_config(json{{"enabled", false}});
    g_stop = true;
    wake_sleepers();
    {
        std::lock_guard<std::mutex> lk(g_state_mu);
        g_state["enabled"] = false;
        g_state["error"] = "";
    }
    wait_thread_done(2000);  // join(timeout=2.0) — no error on timeout
    rt_log("realtime sync disabled", "info");
    return rt_get_status();
}

void rt_auto_start() {
    try {
        json cfg = rt_get_config();
        bool enabled = p5::py_truthy(cfg.contains("enabled") ? cfg["enabled"] : json(nullptr));
        bool auto_start =
            p5::py_truthy(cfg.contains("auto_start") ? cfg["auto_start"] : json(nullptr));
        if (enabled && auto_start) {
            // 704-710: delayed daemon thread (STATE warm-up grace).
            std::thread([] {
                std::this_thread::sleep_for(std::chrono::seconds(3));
                try {
                    rt_start();
                } catch (const std::exception& e) {
                    rt_log("auto_start failed: " + exc_str(e), "error");
                } catch (...) {
                    rt_log("auto_start failed: unknown", "error");
                }
            }).detach();
        }
    } catch (...) {
    }
}

int watcher_starts_for_test() { return g_watcher_starts.load(); }

}  // namespace realtime
}  // namespace sa
