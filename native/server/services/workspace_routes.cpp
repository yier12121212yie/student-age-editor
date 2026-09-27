// wip/P2/workspace_routes.cpp — see workspace_routes.h.
//
// Semantics are a line-by-line port of api.py:768-775 (/api/workspace) and
// api.py:784-848 (/api/oobe/status|setup|complete) on top of cli/oobe.py's
// shared state layer. Where the brief and api.py disagree (workspace
// persistence), the deviation is documented inline and in the P2 delivery
// report per CONVENTIONS preamble ("以 Python 行为为准并回报差异").
#include "workspace_routes.h"

#include <algorithm>
#include <cctype>
#include <ctime>
#include <cstdio>
#include <exception>
#include <regex>
#include <string>

#include "sa_core/atomic_io.h"
#include "sa_core/env_store.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/steam_paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "server/cfg_cache.h"
#include "server/state.h"

namespace sa {
namespace {

namespace cs = sa_core::paths;
namespace esp = sa_core::steam_paths;
namespace es = sa_core::env_store;

// Python `bool(x)` over JSON values: null/false/0/""/[]/{} are falsy; every
// other value is truthy (a non-empty string "false" included — oobe/setup's
// mark_done is a raw bool() test, NOT _truthy).
bool py_truthy(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get_ref<const std::string&>().empty();
    if (v.is_array() || v.is_object()) return !v.empty();
    return true;
}

std::string env_get(const char* name) {
    // UTF-8-safe: USERPROFILE/HOME feed OOBE `~` expansion and are paths.
    return sa_core::paths::getenv_utf8(name);
}

// ---------------------------------------------------------------------------
// 阶段 1c 安全加固（workspace root 校验）。POST /api/workspace 与 POST
// /api/oobe/setup 可把沙箱根设成任意目录；配合 /api/tools/write(scope=
// workspace) 就构成"任意本地进程/任意 localhost 页面可在任意落点写文件"的
// 链（写进 Start Menu\Startup 即登录执行）。规则：显式 root 不得位于（或
// 反向包住）系统目录/ProgramData/用户启动项目录，不得是盘符/文件系统根。
// 普通工作目录（Documents\mods、%TEMP% 沙箱等）不受影响；env 缺失则跳过
// 对应比较。校验先于 is_dir/mkdir：既不探测系统目录，也不在系统目录下
// 建目录。Python 无此检查，属有记录的安全偏差。
std::string ws_key(const std::string& p) {
    std::string s = sa_core::str::replace_all(p, "\\", "/");
    while (s.size() > 1 && s.back() == '/') s.pop_back();
#ifdef _WIN32
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
#endif
    return s;
}

// child 位于 parent 内（或同一目录），按段边界比较；两者都必须是 ws_key 形式。
bool path_within(const std::string& child, const std::string& parent) {
    if (parent.empty()) return false;
    if (child == parent) return true;
    return child.size() > parent.size() &&
           child.compare(0, parent.size(), parent) == 0 && child[parent.size()] == '/';
}

// 允许返回空串；否则返回拒绝理由（直接进 400 的 error 字段）。
std::string workspace_root_reject(const std::string& raw) {
    std::string norm = ws_key(cs::abs_path(raw));
    if (norm.empty()) return {};
#ifdef _WIN32
    if (norm.size() == 2 && norm[1] == ':')
        return "workspace root must not be a drive root: " + raw;
    const char* env_names[] = {"SystemRoot", "windir", "ProgramFiles",
                               "ProgramFiles(x86)", "ProgramData"};
    for (const char* v : env_names) {
        std::string d = ws_key(env_get(v));
        if (!d.empty() && path_within(norm, d))
            return "workspace root must not be inside a system/program directory (" +
                   std::string(v) + ")";
    }
    // 用户 Start Menu（Startup 落点所在）："在内"与"包住它"两个方向都拒。
    std::string roaming = ws_key(env_get("APPDATA"));
    if (!roaming.empty()) {
        std::string start_menu = roaming + "/microsoft/windows/start menu";
        if (path_within(norm, start_menu) || path_within(start_menu, norm))
            return "workspace root must not contain or be inside the Windows Start Menu directory";
    }
    return {};
#else
    if (norm == "/")
        return "workspace root must not be the filesystem root: " + raw;
    static const char* sys_dirs[] = {"/etc", "/usr", "/var", "/bin", "/sbin",
                                     "/boot", "/dev", "/root", "/opt"};
    for (const char* d : sys_dirs) {
        if (path_within(norm, d))
            return "workspace root must not be inside a system directory: " + std::string(d);
    }
    std::string home = env_get("HOME");
    if (!home.empty()) {
        std::string autostart = ws_key(home + "/.config/autostart");
        if (path_within(norm, autostart) || path_within(autostart, norm))
            return "workspace root must not contain or be inside the desktop autostart directory";
    }
    return {};
#endif
}

// `(body.get(k) or "")` 语义（api.py:769 / 802-804）：缺失/null/JSON 假值
// （false/0/""/[]/{}）都归 ""；其余非字符串标量按 str(x) 取值（Python 在
// isdir/strip 处会对真数值抛 TypeError→500，路径病态输入按 mods_routes
// 波次 1 先例统一降级为 str 处理，记入报告偏差节）。
std::string body_str(const json& body, const char* key) {
    if (!body.is_object()) return {};
    auto it = body.find(key);
    if (it == body.end() || !py_truthy(*it)) return {};
    if (it->is_string()) return it->get<std::string>();
    return sa_core::py_str(*it);
}

// datetime.now().isoformat(timespec="seconds") — same helper mods_routes.cpp
// carries locally; duplicated here because that file is not mine to touch.
std::string now_iso_seconds() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    localtime_s(&tm, &t);
#else
    localtime_r(&t, &tm);
#endif
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d", tm.tm_year + 1900,
                  tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
    return buf;
}

// oobe.py ValueError analogue: caught -> 400 {"error": msg} in /api/oobe/setup.
struct OobeValueError : std::runtime_error {
    explicit OobeValueError(const std::string& m) : std::runtime_error(m) {}
};

// cli/oobe.py:_TITLE_RE — same screen /api/mods/create applies.
bool title_illegal(const std::string& title) {
    static const std::regex illegal(R"([\\/:*?"<>|\x00-\x1f])");
    return std::regex_search(title, illegal) || title == "." || title == "..";
}

// ntpath.expanduser("~") support for oobe_set_workspace; kept here (not in
// sa_core) so the core module's surface stays steam-only.
std::string esp_home() {
    std::string up = env_get("USERPROFILE");
    if (!up.empty()) return up;
    return env_get("HOME");
}

// oobe.mark_done / oobe.set_workspace share this tmp+replace merge (via
// env_store, which is sa_core::write_text_atomic — same durability class).
void mark_done(const json& extra) {
    json patch = json::object();
    patch["oobe_completed"] = true;
    patch["oobe_completed_at"] = now_iso_seconds();
    if (extra.is_object()) {
        for (auto it = extra.begin(); it != extra.end(); ++it) patch[it.key()] = it.value();
    }
    es::merge_editor_env(editor_root(), patch);
}

// oobe.set_workspace: expanduser + absolutize + normpath + mkdir -p, then
// persist workspace_root into editor_env.json; returns the saved path.
// ValueError("cannot create workspace %s: %s") on mkdir failure.
std::string oobe_set_workspace(const std::string& raw) {
    std::string p = raw;
    // Path.expanduser(): only a leading "~" segment.
    if (p == "~" || (p.size() > 1 && p[0] == '~' && (p[1] == '/' || p[1] == '\\'))) {
        p = cs::join(esp_home(), p.substr(1));
    }
    // Python: not absolute -> cwd / p; then os.path.normpath.
    std::string abs = cs::abs_path(p);
    // 阶段 1c：与 POST /api/workspace 同一护栏，先于 mkdir —— 拒绝在系统
    // 目录下创建并注册工作区。OobeValueError 走 setup 的 400 通道。
    std::string reject = workspace_root_reject(abs);
    if (!reject.empty()) throw OobeValueError(reject);
    if (!cs::create_dirs(abs)) {
        throw OobeValueError("cannot create workspace " + abs + ": directory not creatable");
    }
    es::merge_editor_env(editor_root(), json{{"workspace_root", abs}});
    return abs;
}

// oobe.create_mod (used by /api/oobe/setup when mod_title is given). Error
// strings keep the Python wording verbatim (错误 detail 中文逐字).
std::string oobe_create_mod(const std::string& title, const std::string& workspace,
                            const std::string& desc) {
    if (title.empty()) throw OobeValueError("模组名不能为空");
    if (title_illegal(title)) {
        throw OobeValueError("模组名含非法字符: " + sa_core::py_repr_str(title));
    }
    std::string mod_dir = cs::join(workspace, title);
    if (cs::exists(mod_dir)) throw OobeValueError("模组已存在: " + mod_dir);
    cs::create_dirs(cs::join(cs::join(mod_dir, "Cfgs"), "zh-cn"));
    json manifest;
    manifest["title"] = title;
    manifest["description"] = desc;
    manifest["version"] = "1.0.0";
    manifest["created_at"] = now_iso_seconds();
    // Path.write_text on Windows translates \n -> \r\n; wave-1 known deviation
    // 6 precedent: on-disk manifest bytes stay CRLF.
    std::string text = sa_core::py_dumps_indent(manifest);
    std::string crlf;
    crlf.reserve(text.size() + 32);
    for (char c : text) {
        if (c == '\n') crlf += "\r\n";
        else crlf += c;
    }
    cs::write_bytes_simple(cs::join(mod_dir, "manifest.json"), crlf);
    return mod_dir;
}

}  // namespace

// --------------------------------------------------------------------------
// GET /api/oobe/status payload (exported for tests)
// --------------------------------------------------------------------------

json oobe_status_payload() {
    json env = es::read_editor_env(editor_root());

    bool done = false;
    auto it_done = env.find("oobe_completed");
    if (it_done != env.end()) done = py_truthy(*it_done);

    // oobe.forced_by_env
    std::string raw = env_get("EDITOR_OOBE");
    std::string no = env_get("EDITOR_NO_OOBE");
    bool forced = false;
    if (!(raw.empty() && !no.empty())) {
        std::string r = sa_core::str::lower(sa_core::str::trim(raw));
        forced = (r == "1" || r == "true" || r == "yes" || r == "on");
    }

    // oobe.current_workspace: str(env.get("workspace_root") or "").strip()
    std::string ws_env;
    auto it_ws = env.find("workspace_root");
    if (it_ws != env.end() && py_truthy(*it_ws)) {
        ws_env = it_ws->is_string() ? it_ws->get<std::string>() : sa_core::py_str(*it_ws);
    }
    ws_env = sa_core::str::trim(ws_env);

    json snap;
    snap["done"] = done;
    snap["first_run"] = !done;
    snap["forced"] = forced;
    snap["disabled"] = !no.empty();  // bool(os.environ.get("EDITOR_NO_OOBE"))
    snap["workspace_root"] = ws_env;
    snap["suggested_workspace"] = user_mods_dir();
    // oobe.snapshot.mods_count: cli.utils.list_mods(None) — in the C++ port
    // STATE.list_mods() is the same scan (workspace + editor root + workshop).
    snap["mods_count"] = static_cast<long long>(list_mods().size());
    // Deviation: Python reports the source-checkout root here; the native
    // build reports its data/editor root instead. Contract-normalized to
    // <PATH> either way (normalize.py PATH_KEYS).
    snap["editor_root"] = editor_root();
    // api.py:796 server_workspace overlay (snap["workspace_root"] above keeps
    // the env value, NOT the live STATE value — like Python).
    {
        std::lock_guard<std::mutex> lk(STATE().mu_);
        snap["server_workspace"] = STATE().workspace_root;
    }
    return snap;
}

void register_workspace_routes(Router& r) {
    // POST /api/workspace — api.py:768-775.
    r.post(R"(/api/workspace)", [](const Req& req) -> Resp {
        std::string root = body_str(req.body, "root");
        if (!root.empty()) {
            std::string reject = workspace_root_reject(root);
            if (!reject.empty()) return Resp::Json(400, json{{"error", reject}});
        }
        if (!root.empty() && !cs::is_dir(root)) {
            return Resp::Json(400, json{{"error", "directory not found: " + root}});
        }
        std::string ws = root.empty() ? user_mods_dir() : root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            STATE().workspace_root = ws;
        }
        // A15: the root changed, the 2s mods cache must drop. NOTE: api.py
        // deliberately does NOT touch _MOD_CFGS_CACHE here (the mod selection
        // survives; its cfg dir path is mod-rooted, not workspace-rooted).
        invalidate_mods_cache();
        // P2 brief addition on top of api.py:768-775 — an explicitly chosen
        // workspace persists into editor_env.json (oobe.set_workspace
        // semantics) so a restart keeps it; the transient root="" fallback is
        // NOT persisted (Python: next start re-resolves from env anyway).
        // Flagged as a deliberate deviation in the P2 report.
        if (!root.empty()) {
            try {
                es::merge_editor_env(editor_root(), json{{"workspace_root", ws}});
            } catch (const std::exception& e) {
                std::fprintf(stderr, "[workspace] editor_env.json 持久化失败：%s\n", e.what());
            }
        }
        json body;
        body["workspace_root"] = ws;
        body["mods"] = list_mods();
        return Resp::Json(200, std::move(body));
    });

    // GET /api/oobe/status — api.py:785-797.
    r.get(R"(/api/oobe/status)", [](const Req&) -> Resp {
        // The Python handler wraps the import in try/except and falls back to
        // {"done": true, ..., "error": str(e)}; the native port cannot throw
        // here, so the fallback branch is structurally unreachable.
        return Resp::Json(200, oobe_status_payload());
    });

    // POST /api/oobe/setup — api.py:799-839 (oobe.set_workspace/create_mod/
    // mark_done chain; ai_settings/cloud_provider extras are wave-4-owned and
    // degrade to the Python silent-failure path).
    r.post(R"(/api/oobe/setup)", [](const Req& req) -> Resp {
        std::string ws = sa_core::str::trim(body_str(req.body, "workspace"));
        std::string title = sa_core::str::trim(body_str(req.body, "mod_title"));
        std::string desc = sa_core::str::trim(body_str(req.body, "mod_desc"));
        bool mark = true;
        if (req.body.is_object()) {
            auto it = req.body.find("mark_done");
            if (it != req.body.end()) mark = py_truthy(*it);
        }
        try {
            if (!ws.empty()) {
                std::string saved = oobe_set_workspace(ws);
                {
                    std::lock_guard<std::mutex> lk(STATE().mu_);
                    STATE().workspace_root = saved;
                }
                invalidate_mod_cfgs_cache();
                // api.py:810-814 does NOT invalidate the mods LIST cache here;
                // reproducing exactly (A15 TTL keeps its 2s stale window).
            }
            std::string mod_name;
            if (!title.empty()) {
                std::string target_ws;
                {
                    std::lock_guard<std::mutex> lk(STATE().mu_);
                    target_ws = STATE().workspace_root;
                }
                if (target_ws.empty()) target_ws = user_mods_dir();
                std::string mod_dir = oobe_create_mod(title, target_ws, desc);
                mod_name = cs::basename(mod_dir);
                select_mod(mod_name, mod_dir);
            } else if (ws.empty()) {
                json mods = list_mods();
                std::lock_guard<std::mutex> lk(STATE().mu_);
                if (!mods.empty() && STATE().mod_name.empty()) {
                    STATE().mod_name = mods[0].value("name", "");
                    STATE().mod_root = mods[0].value("root", "");
                }
            }
            // body.ai_settings / body.cloud_provider -> oobe._apply_extras:
            // AI (.editor_ai.json) and cloud (.editor_cloud.json) are wave-4
            // domains; Python swallows every failure of this step anyway.
            if (mark) {
                if (!ws.empty()) {
                    std::lock_guard<std::mutex> lk(STATE().mu_);
                    mark_done(json{{"workspace_root", STATE().workspace_root}});
                } else {
                    mark_done(json::object());
                }
            }
        } catch (const OobeValueError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        } catch (const sa_core::FsError& e) {
            // Python surfaces OSError as "OSError: <msg>" through the generic
            // except; keep the type name for the 500 envelope shape.
            return Resp::Json(500, json{{"error", std::string("OSError: ") + e.what()}});
        } catch (const std::exception& e) {
            return Resp::Json(500, json{{"error", std::string("RuntimeError: ") + e.what()}});
        }
        json body;
        body["ok"] = true;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            body["workspace_root"] = STATE().workspace_root;
            body["mod_name"] = STATE().mod_name;
        }
        body["mods"] = list_mods();
        return Resp::Json(200, std::move(body));
    });

    // POST /api/oobe/complete — api.py:841-848.
    r.post(R"(/api/oobe/complete)", [](const Req&) -> Resp {
        try {
            mark_done(json::object());
        } catch (const std::exception& e) {
            return Resp::Json(500, json{{"error", e.what()}});
        }
        json body;
        body["ok"] = true;
        return Resp::Json(200, std::move(body));
    });
}

}  // namespace sa
