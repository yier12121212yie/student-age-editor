#include "server/state.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>

#include "sa_core/env_store.h"
#include "sa_core/paths.h"
#include "sa_core/steam_paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/perf.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace sa {
namespace {

namespace fs = std::filesystem;

std::string g_editor_root_override;
// 回调只允许在启动期 build_router() 里写入一次、此后只读（无锁）。若未来
// 需要运行期重挂，必须先引入同步，否则与 httpd 工作线程构成数据竞争。
std::function<void()> g_mod_cfgs_invalidator;
std::function<void()> g_preview_invalidator;

std::string env_or_empty(const char* name) {
    // UTF-8-safe on Windows (see sa_core::paths::getenv_utf8): env roots may
    // contain non-ASCII and must not be ANSI-mojibake'd.
    return sa_core::paths::getenv_utf8(name);
}

// user_mods_dir() is the exported sa::user_mods_dir below; the anon-namespace
// forward is gone so init_state's fallback call resolves unambiguously.

// api.py:275-286 _env_workspace_root (utf-8-sig 容错读写走 sa_core::env_store)
std::string env_workspace_root() {
    json data = sa_core::env_store::read_editor_env(editor_root());
    std::string ws;
    auto it = data.find("workspace_root");
    if (it != data.end()) {
        if (it->is_string()) {
            ws = it->get<std::string>();
        } else if (!it->is_null()) {
            ws = sa_core::py_str(*it);
        }
    }
    if (!ws.empty() && sa_core::paths::is_dir(ws)) return ws;
    return {};
}

#ifndef _WIN32
// POSIX editor_root() fallbacks only — Windows keeps its historical exe-dir/cwd
// rule untouched. Mirrors backend/editor/core/paths.py app_data_dir().
std::string home_dir() { return env_or_empty("HOME"); }

// paths.py:36-46 _dir_writable: makedirs(exist_ok=True) then create+delete a
// probe file (an AppImage squashfs mount or a root-owned /opt fails here).
bool dir_writable(const std::string& d) {
    if (d.empty()) return false;
    sa_core::paths::create_dirs(d);  // makedirs(exist_ok=True); ignore result
    const std::string probe = sa_core::paths::join(d, ".write_probe_selftest");
    if (!sa_core::paths::write_bytes_simple(probe, "ok")) return false;
    return sa_core::paths::remove_file(probe);
}

// paths.py:49-56 platform_data_dir(). Note the two names differ on purpose:
// macOS uses "StudentAgeEditor", Linux uses "student-age-editor" (exact, per
// the Python source).
std::string platform_data_dir() {
#if defined(__APPLE__)
    std::string p = sa_core::paths::join(home_dir(), "Library");
    p = sa_core::paths::join(p, "Application Support");
    return sa_core::paths::join(p, "StudentAgeEditor");
#else
    std::string base = env_or_empty("XDG_DATA_HOME");
    if (base.empty()) {
        base = sa_core::paths::join(home_dir(), ".local");
        base = sa_core::paths::join(base, "share");
    }
    return sa_core::paths::join(base, "student-age-editor");
#endif
}
#endif  // !_WIN32

}  // namespace

// ---------------------------------------------------------------------------
// small helpers shared with the cfg services
// ---------------------------------------------------------------------------

std::string cfg_name_of(std::string rel) {
    rel = sa_core::str::replace_all(rel, "\\", "/");
    while (!rel.empty() && rel.back() == '/') rel.pop_back();  // rstrip("/")
    if (rel.size() >= 5 && rel.compare(rel.size() - 5, 5, ".json") == 0) {
        rel = rel.substr(0, rel.size() - 5);
    }
    return rel;
}

bool truthy(const json& v) {
    if (v.is_boolean()) return v.get<bool>();
    if (!v.is_null()) {
        std::string s = sa_core::str::trim(v.is_string() ? v.get<std::string>()
                                                          : sa_core::py_str(v));
        for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return s == "true";
    }
    return false;
}

// fs_tools._norm (api.py sandbox): backslashes to slashes, leading slashes
// stripped, "." segments collapsed, ".." escape rejected with the Python
// "path escapes sandbox: %r" message.
std::string norm_rel(const std::string& rel_path) {
    std::string p = sa_core::str::replace_all(rel_path, "\\", "/");
    size_t start = p.find_first_not_of('/');
    if (start == std::string::npos) {
        p.clear();
    } else {
        p = p.substr(start);
    }
    p = sa_core::str::trim(p);  // .strip() after the replace/lstrip chain
    if (p.empty() || p == ".") return {};

    // os.path.normpath on the slash form
    std::vector<std::string> stack;
    bool absolute = false;
    size_t pos = 0;
    while (pos < p.size()) {
        size_t slash = p.find('/', pos);
        std::string part = p.substr(pos, slash == std::string::npos ? std::string::npos
                                                                    : slash - pos);
        pos = slash == std::string::npos ? p.size() : slash + 1;
        if (part.empty() || part == ".") continue;
        if (part == "..") {
            if (!stack.empty() && stack.back() != "..") {
                stack.pop_back();
            } else if (!absolute) {
                stack.push_back("..");
            }
            continue;
        }
        if (part.find(':') != std::string::npos) {
            throw SandboxError("path escapes sandbox: " + sa_core::py_repr_str(rel_path));
        }
        stack.push_back(part);
    }
    std::string norm;
    for (const auto& s : stack) {
        if (!norm.empty()) norm += "/";
        norm += s;
    }
    if (norm == "." || norm.empty()) return {};
    if (norm.rfind("..", 0) == 0) {
        throw SandboxError("path escapes sandbox: " + sa_core::py_repr_str(rel_path));
    }
    return norm;
}

// ---------------------------------------------------------------------------
// EditorState singleton
// ---------------------------------------------------------------------------

EditorStateT& STATE() {
    static EditorStateT s;
    return s;
}

std::string editor_root() {
    std::string env = env_or_empty("EDITOR_DATA_ROOT");
    if (!env.empty()) return env;
    if (!g_editor_root_override.empty()) return g_editor_root_override;
    // app_data_dir() equivalent for a portable build: the executable directory.
#ifdef _WIN32
    wchar_t buf[4096];
    DWORD n = GetModuleFileNameW(nullptr, buf, 4096);
    if (n > 0 && n < 4096) {
        fs::path exe = fs::path(buf).parent_path();
        return sa_core::paths::path_to_utf8(exe);
    }
#else
    // paths.py:59-70 app_data_dir(): prefer the exe directory when writable so
    // data travels with an unpacked/portable install; otherwise fall back to
    // the platform user-data dir (read-only AppImage, root-owned /opt, ...).
    const std::string exe = sa_core::paths::exe_dir();
    if (!exe.empty() && dir_writable(exe)) return exe;
    const std::string pdata = platform_data_dir();
    if (!pdata.empty()) return pdata;
#endif
    return sa_core::paths::path_to_utf8(fs::current_path());
}

namespace detail {
// main.cpp points this at the executable directory when EDITOR_DATA_ROOT is
// unset (app_data_dir() portable-build rule in core/paths.py).
void set_editor_root(const std::string& root) { g_editor_root_override = root; }
}  // namespace detail

std::vector<std::string> workshop_mods_roots() {
    return sa_core::steam_paths::workshop_mods_roots(editor_root());
}

// steam_paths.user_mods_dir exposed for the P2 routes (workspace fallback,
// oobe suggested_workspace). api.py callers of _user_mods_dir().
std::string user_mods_dir() { return sa_core::steam_paths::user_mods_dir(); }

std::string cfg_dir() {
    std::lock_guard<std::mutex> lk(STATE().mu_);
    if (STATE().mod_root.empty()) return {};
    return sa_core::paths::join(sa_core::paths::join(STATE().mod_root, "Cfgs"), "zh-cn");
}

std::string cfg_path(const std::string& cfg_name) {
    std::string dir;
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        if (STATE().mod_root.empty()) throw SandboxError("no mod selected");
        dir = sa_core::paths::join(sa_core::paths::join(STATE().mod_root, "Cfgs"), "zh-cn");
    }
    std::string rel = norm_rel(cfg_name + ".json");
    return sa_core::paths::join(dir, rel);
}

std::string sandbox_root(const std::string& scope) {
    std::lock_guard<std::mutex> lk(STATE().mu_);
    if (scope == "workspace") {
        return STATE().workspace_root.empty() ? editor_root() : STATE().workspace_root;
    }
    if (!STATE().mod_root.empty()) return STATE().mod_root;
    if (!STATE().workspace_root.empty()) return STATE().workspace_root;
    return editor_root();
}

json mod_info(const std::string& name, const std::string& mod_dir) {
    std::string cfg = sa_core::paths::join(sa_core::paths::join(mod_dir, "Cfgs"), "zh-cn");
    json cfg_files = json::array();
    if (sa_core::paths::is_dir(cfg)) {
        bool ok = false;
        auto names = sa_core::paths::listdir_sorted(cfg, &ok);
        for (const auto& f : names) {
            if (f.size() >= 5 && f.compare(f.size() - 5, 5, ".json") == 0 &&
                f != "CustomKeyMap.json") {
                cfg_files.push_back(f.substr(0, f.size() - 5));
            }
        }
    }
    json manifest = json::object();
    std::string mpath = sa_core::paths::join(mod_dir, "manifest.json");
    if (sa_core::paths::is_file(mpath)) {
        auto raw = sa_core::paths::read_bytes(mpath);
        if (raw) {
            auto text = sa_core::decode_utf8_sig_strict(*raw);
            if (text) {
                json parsed = json::parse(*text, nullptr, false);
                if (!parsed.is_discarded() && parsed.is_object()) manifest = std::move(parsed);
            }
        }
    }
    json info;
    info["name"] = name;
    info["root"] = mod_dir;
    info["cfg_files"] = cfg_files;
    info["has_manifest"] = !manifest.empty();
    std::string title;
    if (manifest.contains("title") && manifest["title"].is_string()) {
        title = manifest["title"].get<std::string>();
    }
    info["manifest_title"] = title;
    return info;
}

json list_mods() {
    auto& st = STATE();
    long long now = sa_core::now_ms();
    {
        std::lock_guard<std::mutex> lk(st.mu_);
        if (st.mods_cache_valid && now - st.mods_ts_ms < 2000) return st.mods_cache;
    }
    std::vector<std::string> roots;
    {
        std::lock_guard<std::mutex> lk(st.mu_);
        if (!st.workspace_root.empty()) roots.push_back(st.workspace_root);
    }
    std::string er = editor_root();
    if (!er.empty() && sa_core::paths::is_dir(sa_core::paths::join(sa_core::paths::join(er, "Cfgs"),
                                                                   "zh-cn"))) {
        roots.push_back(er);
    }
    for (auto& r : workshop_mods_roots()) roots.push_back(r);

    json mods = json::array();
    std::vector<std::string> seen;
    for (const auto& base : roots) {
        if (base.empty() || !sa_core::paths::is_dir(base)) continue;
        std::string nb = sa_core::paths::path_key(base);
        if (std::find(seen.begin(), seen.end(), nb) != seen.end()) continue;
        seen.push_back(nb);
        bool ok = false;
        auto names = sa_core::paths::listdir_sorted(base, &ok);
        if (!ok) continue;  // root unreadable: skip, never fail the whole list
        for (const auto& name : names) {
            std::string mod_dir = sa_core::paths::join(base, name);
            if (!sa_core::paths::is_dir(mod_dir)) continue;
            std::string cfgd =
                sa_core::paths::join(sa_core::paths::join(mod_dir, "Cfgs"), "zh-cn");
            std::string manifest = sa_core::paths::join(mod_dir, "manifest.json");
            if (!sa_core::paths::is_dir(cfgd) && !sa_core::paths::is_file(manifest)) continue;
            mods.push_back(mod_info(name, mod_dir));
        }
    }
    {
        std::lock_guard<std::mutex> lk(st.mu_);
        st.mods_cache = mods;
        st.mods_cache_valid = true;
        st.mods_ts_ms = now;
    }
    return mods;
}

void invalidate_mods_cache() {
    auto& st = STATE();
    std::lock_guard<std::mutex> lk(st.mu_);
    st.mods_cache_valid = false;
    st.mods_ts_ms = 0;
    st.mods_cache = json::array();
}

json select_mod(const std::string& name, const std::string& root) {
    {
        auto& st = STATE();
        std::lock_guard<std::mutex> lk(st.mu_);
        st.mod_name = name;
        st.mod_root = root;
        st.aa_status = "idle";  // aa_index=None equivalent
    }
    invalidate_mods_cache();
    // api.py:255-263 — mod-cfgs and preview caches go stale with the mod;
    // _TABLE_CACHE deliberately does NOT (path-keyed entries miss naturally).
    if (g_mod_cfgs_invalidator) g_mod_cfgs_invalidator();
    if (g_preview_invalidator) g_preview_invalidator();
    return mod_info(name, root);
}

void set_mod_cfgs_invalidator(std::function<void()> fn) { g_mod_cfgs_invalidator = std::move(fn); }
void set_preview_invalidator(std::function<void()> fn) { g_preview_invalidator = std::move(fn); }

void init_state(const std::string& cli_workspace_root, const std::string& cli_mod_root,
                const std::string& cli_mod_name) {
    auto& st = STATE();
    {
        std::lock_guard<std::mutex> lk(st.mu_);
        if (!cli_workspace_root.empty()) st.workspace_root = cli_workspace_root;
        if (!cli_mod_root.empty()) st.mod_root = cli_mod_root;
        if (!cli_mod_name.empty()) st.mod_name = cli_mod_name;
        if (st.workspace_root.empty()) {
            st.workspace_root = env_workspace_root();
            if (st.workspace_root.empty()) st.workspace_root = user_mods_dir();
            // Python creates the workspace dir when falling back (api.py:293-297).
            sa_core::paths::create_dirs(st.workspace_root);
        }
    }
    if (st.mod_root.empty()) {
        json mods = list_mods();
        if (!mods.empty()) {
            std::lock_guard<std::mutex> lk(st.mu_);
            st.mod_root = mods[0].value("root", "");
            st.mod_name = mods[0].value("name", "");
        }
    }
    // STATE.base (BaseDataService) — P1 domain, intentionally absent here.
}

}  // namespace sa
