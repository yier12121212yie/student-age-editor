// server/state: EditorState minimal (port of api.py:151-330 + CONVENTIONS 11).
//
// Wave-1 scope: workspace/mod selection, cfg path resolution with sandbox
// normalization, list_mods with the 2s TTL (A15), select_mod's five-part
// invalidation (NOT clearing _TABLE_CACHE! api.py:248-264).
//
// P2 (landed): steam library / workshop discovery via sa_core::steam_paths,
// user_mods_dir = LocalLow game Mods. Still a wave-1+ seam:
//   * STATE.base (BaseDataService)        -> P1 domain, base_loaded stays []
#pragma once

#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {

using json = nlohmann::ordered_json;

// api.py SandboxError analogue: fs_tools._norm / _cfg_path refusals. Handlers
// catch it and answer 400 {"error": str(e), ...} (CONVENTIONS 4).
struct SandboxError : std::runtime_error {
    explicit SandboxError(const std::string& msg) : std::runtime_error(msg) {}
};

// api.py:310-316 _cfg_name
std::string cfg_name_of(std::string rel);

// api.py:327-330 _truthy: only real True / "true" (case/space-tolerant).
// Strings "false"/"0" are FALSE, the number 1 is FALSE.
bool truthy(const json& v);

// fs_tools._norm: reject absolute paths / drive letters / ".." escapes.
// Returns the normalized relative path (possibly "").
std::string norm_rel(const std::string& rel_path);

struct EditorStateT {
    // Guarded by mu_ (Python: STATE._lock + GIL).
    std::string workspace_root;
    std::string mod_root;   // absolute
    std::string mod_name;
    std::string aa_status = "idle";  // P2: stays idle until aa scan lands
    std::vector<std::string> aa_dirs;
    std::string aa_error;

    // A15: list_mods 2s TTL
    bool mods_cache_valid = false;
    long long mods_ts_ms = 0;
    json mods_cache = json::array();

    std::mutex mu_;
};

EditorStateT& STATE();

// Startup workspace resolution (CONVENTIONS 11):
//   CLI --workspace-root wins; else editor_env.json's workspace_root (if it
//   exists); else steam_paths.user_mods_dir() (LocalLow game Mods). Creates
//   the directory when falling back. Auto-selects the first mod
//   when nothing is selected yet (api.py:298-302).
void init_state(const std::string& cli_workspace_root, const std::string& cli_mod_root,
                const std::string& cli_mod_name);

// Data/cache root (api.py:95-107 _editor_root): EDITOR_DATA_ROOT env wins,
// else the executable's directory.
std::string editor_root();

namespace detail {
// main.cpp / tests: override the fallback editor root (portable-build rule of
// core/paths.py: exe directory). Only used when EDITOR_DATA_ROOT is unset.
void set_editor_root(const std::string& root);
}  // namespace detail

// Workshop mod roots (P2): core/steam_paths.py workshop_mods_roots — the
// editor_env.json "workshop_root" override plus one
// <library>/steamapps/workshop/content/1991040 per discovered Steam library.
// EDITOR_DISABLE_STEAM_DETECT=1 suppresses the library scan (contract
// isolation; mirrors the golden recorder's in-process steam_paths patch).
std::vector<std::string> workshop_mods_roots();

// steam_paths.user_mods_dir (P2): %USERPROFILE%\AppData\LocalLow\PakyiGame\
// StudentAge\Mods on Windows (Proton/XDG fallbacks elsewhere). Not affected
// by the detection switch — the value is pure path math, never a probe.
std::string user_mods_dir();

// <STATE.mod_root>/Cfgs/zh-cn or "" when no mod is selected.
std::string cfg_dir();

// api.py:319-324 _cfg_path: cfg_dir + _norm(name + ".json").
// Throws SandboxError("no mod selected") when no mod is active.
std::string cfg_path(const std::string& cfg_name);

// api.py:266-269 sandbox_root(scope).
std::string sandbox_root(const std::string& scope);

// One <mod> entry of /api/mods (api.py:220-246 _mod_info).
json mod_info(const std::string& name, const std::string& mod_dir);

// api.py:172-213 list_mods (TTL-cached; multi-root scan; unreadable root skipped).
json list_mods();

// A15: force a rescan after create/select/set_workspace.
void invalidate_mods_cache();

// api.py:248-264 select_mod: set mod, aa reset, invalidate mods + mod-cfgs +
// preview caches — deliberately NOT _TABLE_CACHE. Returns _mod_info.
json select_mod(const std::string& name, const std::string& root);

// Wiring for the five-part select_mod invalidation without a hard dependency on
// cfg_cache (which itself needs STATE): cfg_cache registers its invalidator.
void set_mod_cfgs_invalidator(std::function<void()> fn);
void set_preview_invalidator(std::function<void()> fn);

}  // namespace sa
