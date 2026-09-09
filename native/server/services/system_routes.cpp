// server/services/system_routes.cpp — /api/ping /api/state /api/shutdown
// /api/perf. Ports api.py:742-782 plus the additive GET /api/perf endpoint
// (CONVENTIONS 7).
#include <cstdio>
#include <ctime>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "sa_core/version.h"

#include "sa_core/assets.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/utf8.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/perf.h"
#include "server/state.h"

namespace sa {
namespace {

// /api/state.schema_count = len(GAME_SCHEMA) (api.py:765; golden = 406).
// assets/schema.json is the wave-0b export of game_schema.GAME_SCHEMA, so the
// top-level key count is the contract. R1 unification: this used to carry the
// narrowest wave-0 candidate list (only official build/ layout); resolution is
// now sa_core::assets.
int schema_count() {
    static std::once_flag once;
    static int count = 0;
    std::call_once(once, [] {
        const std::string p = sa_core::assets::find_asset("schema.json");
        auto raw = p.empty() ? std::nullopt : sa_core::paths::read_bytes(p);
        if (raw) {
            auto text = sa_core::decode_utf8_sig_strict(*raw);
            if (!text) text = sa_core::decode_utf8_sig_replace(*raw);
            json parsed = text ? json::parse(*text, nullptr, false) : json{};
            if (!parsed.is_discarded() && parsed.is_object()) {
                count = static_cast<int>(parsed.size());
                return;
            }
        }
        std::fprintf(stderr, "[system] schema.json not found; schema_count=0\n");
    });
    return count;
}

json ping_state_body() {
    auto& st = STATE();
    std::lock_guard<std::mutex> lk(st.mu_);
    json state;
    // api.py:746-752 — field order and names verbatim.
    state["workspace_root"] = st.workspace_root;
    state["mod_root"] = st.mod_root;
    state["mod_name"] = st.mod_name;
    state["aa_status"] = st.aa_status;
    state["base_loaded_count"] = 0;  // BaseDataService is P1 domain
    return state;
}

}  // namespace

void register_system_routes(Router& r) {
    // GET /api/ping — api.py:742-752. cfg_patch: true is the S2 capability gate
    // the frontend uses to pick PATCH-style saves over full PUTs.
    r.get(R"(/api/ping)", [](const Req&) -> Resp {
        json body;
        body["ok"] = true;
        body["app"] = sa_core::app_name();
        body["cfg_patch"] = true;
        body["state"] = ping_state_body();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/state — api.py:754-766.
    r.get(R"(/api/state)", [](const Req&) -> Resp {
        auto& st = STATE();
        std::string ws, mod_root, mod_name, aa_status, aa_error;
        std::vector<std::string> aa_dirs;
        {
            std::lock_guard<std::mutex> lk(st.mu_);
            ws = st.workspace_root;
            mod_root = st.mod_root;
            mod_name = st.mod_name;
            aa_status = st.aa_status;
            aa_error = st.aa_error;
            aa_dirs = st.aa_dirs;
        }
        json dirs = json::array();
        for (const auto& d : aa_dirs) dirs.push_back(d);
        json body;
        body["workspace_root"] = ws;
        body["mod_root"] = mod_root;
        body["mod_name"] = mod_name;
        body["mods"] = list_mods();
        body["aa_status"] = aa_status;
        body["aa_dirs"] = std::move(dirs);
        body["aa_error"] = aa_error;
        json base_loaded = json::array();  // P1 domain: stays empty
        body["base_loaded"] = std::move(base_loaded);
        body["schema_count"] = schema_count();
        return Resp::Json(200, std::move(body));
    });

    // POST /api/shutdown — api.py:777-782. The 200 body is written first;
    // httpd's connection loop then tears the process down (CONVENTIONS 2).
    r.post(R"(/api/shutdown)", [](const Req&) -> Resp {
        json body;
        body["ok"] = true;
        request_shutdown();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/perf — additive (no Python counterpart; golden-exempt).
    r.get(R"(/api/perf)", [](const Req&) -> Resp {
        json counters = json::object();
        for (const auto& [k, v] : sa::counters().snapshot()) counters[k] = v;
        json debug = json::object();
        debug["stack_bytes"] = cfg_store::debug_stack_bytes();
        debug["table_cache_entries"] = static_cast<long long>(table_cache_size());
        json body;
        body["counters"] = std::move(counters);
        body["debug"] = std::move(debug);
        return Resp::Json(200, std::move(body));
    });
}

}  // namespace sa
