// server/run: the reusable process entry — sa::run_server() / sa::server_main().
//
// Moved out of main.cpp (wave-2 preparation) so atelier harnesses can boot the
// exact production server (same CLI, init_state, transport, shutdown hooks) and
// graft their own routes via `extra_routes` before build_router() is rewired by
// the orchestrator. main.cpp's main() simply delegates here.
//
// W4-4: the argv-only body was split into run_server(ServerConfig) so the
// Android JNI channel can pass the same boot parameters without a command
// line. Everything Android-specific (env setdefaults, bundled-zip extraction)
// is skipped when its config fields are empty — the desktop path therefore
// executes exactly the same statement sequence as before the split.
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <random>
#include <string>
#include <thread>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <sys/stat.h>
#endif

#include "server/android_bundled.h"
#include "server/api_router.h"
#include "server/httpd.h"
#include "server/jobs.h"
#include "server/run.h"
#include "server/services/cloud_sync.h"
#include "server/services/file_transfer.h"
#include "server/services/plugin_service.h"
#include "server/services/static_routes.h"
#include "server/state.h"
#include "sa_core/paths.h"

#include <vector>

namespace {

std::atomic<bool> g_signal_quit{false};

struct Options {
    int port = -1;  // -1 == flag missing; 0 == auto
    std::string write_port_file;
    std::string workspace_root;
    std::string mod_root;
    std::string mod_name;
    // Web tiers (网页版计划 M1.1): all optional, everything stays desktop-default
    // when absent.
    std::string host;
    std::string web_root;
    std::vector<std::string> trusted_origins;
    bool cloud_public_only = false;  // --cloud-public-only（安全批次 A）
    // 安全批次 B：后端进程令牌。
    bool auth_token_enabled = true;  // --no-auth-token 关闭（应急逃生口）
    std::string auth_token;          // --auth-token HEX（gw_pool fork 注入）
    long long max_body_bytes = 0;    // --max-body N（0 = 默认 256 MiB）
    bool show_help = false;
};

void print_usage(const char* argv0) {
    std::fprintf(stderr,
                 "Usage: %s --port N [--write-port FILE] "
                 "[--workspace-root DIR] [--mod-root DIR] [--mod-name NAME]\n"
                 "       [--host ADDR] [--web-root DIR] [--trusted-origin ORIGIN]...\n"
                 "       [--auth-token HEX] [--no-auth-token] [--max-body BYTES]\n"
                 "       [--cloud-public-only]\n",
                 argv0);
}

bool parse_args(int argc, char** argv, Options& out, std::string& err) {
    auto need_value = [&](int& i, const std::string& flag) -> std::string {
        if (i + 1 >= argc) {
            err = "missing value for " + flag;
            return std::string{};
        }
        return std::string(argv[++i]);
    };
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--port") {
            std::string v = need_value(i, a);
            if (!err.empty()) return false;
            try {
                out.port = std::stoi(v);
            } catch (...) {
                err = "invalid --port value: " + v;
                return false;
            }
        } else if (a == "--write-port") {
            out.write_port_file = need_value(i, a);
            if (!err.empty()) return false;
        } else if (a == "--workspace-root") {
            out.workspace_root = need_value(i, a);
            if (!err.empty()) return false;
        } else if (a == "--mod-root") {
            out.mod_root = need_value(i, a);
            if (!err.empty()) return false;
        } else if (a == "--mod-name") {
            out.mod_name = need_value(i, a);
            if (!err.empty()) return false;
        } else if (a == "--host") {
            out.host = need_value(i, a);
            if (!err.empty()) return false;
        } else if (a == "--web-root") {
            out.web_root = need_value(i, a);
            if (!err.empty()) return false;
        } else if (a == "--trusted-origin") {
            // repeatable: browser origins allowed to drive the server tier
            std::string v = need_value(i, a);
            if (!err.empty()) return false;
            out.trusted_origins.push_back(std::move(v));
        } else if (a == "--cloud-public-only") {
            // 托管模式 SSRF 护栏（安全批次 A）：云同步出站 URL 强校验公网。
            out.cloud_public_only = true;
        } else if (a == "--auth-token") {
            // 安全批次 B：进程令牌内存注入（gw_pool fork 后端时使用）。
            out.auth_token = need_value(i, a);
            if (!err.empty()) return false;
        } else if (a == "--no-auth-token") {
            // 应急逃生口：X-Backend-Token 强制校验关闭（回到无令牌行为）。
            out.auth_token_enabled = false;
        } else if (a == "--max-body") {
            // 安全批次 B：请求体上限（字节）。网关 fork 传 32 MiB。
            std::string v = need_value(i, a);
            if (!err.empty()) return false;
            try {
                out.max_body_bytes = std::stoll(v);
            } catch (...) {
                err = "invalid --max-body value: " + v;
                return false;
            }
            if (out.max_body_bytes <= 0) {
                err = "--max-body must be a positive byte count: " + v;
                return false;
            }
        } else if (a == "--help" || a == "-h") {
            out.show_help = true;
        } else {
            err = "unknown argument: " + a;
            return false;
        }
    }
    if (out.show_help) return true;
    if (out.port < 0) {
        err = "--port must be in 0..65535";
        return false;
    }
    if (out.port > 65535) {
        err = "--port must be in 0..65535";
        return false;
    }
    return true;
}

extern "C" void on_signal(int) { g_signal_quit.store(true); }

// os.environ.setdefault (server/__init__.py:23-26): a pre-set variable always
// wins. The desktop path never calls this (config fields stay empty).
void env_setdefault(const char* name, const std::string& value) {
    if (value.empty()) return;
    // setdefault semantics + UTF-8-safe storage (Windows env roots may be CJK).
    sa_core::paths::setenv_utf8(name, value, /*overwrite=*/false);
}

// ---------------------------------------------------------------------------
// 安全批次 B：后端进程令牌（X-Backend-Token）。
// ---------------------------------------------------------------------------

// 128-bit 随机 hex 令牌。每次调用新建 RNG；MinGW random_device 的退化由
// 时间/计数熵混合兜住。
std::string random_token_hex() {
    static std::atomic<unsigned long long> counter{0};
    static const char* hexd = "0123456789abcdef";
    std::mt19937_64 rng(
        std::random_device{}() ^
        static_cast<unsigned long long>(
            std::chrono::steady_clock::now().time_since_epoch().count()) ^
        counter.fetch_add(0x9E3779B97F4A7C15ull));
    std::string out;
    out.reserve(32);
    for (int i = 0; i < 32; ++i) out += hexd[(rng() >> ((i % 16) * 4)) & 0xF];
    return out;
}

// 确保工作区根/.backend_token 存在并返回令牌；失败返回空串（调用方降级为
// 不启用，兼容旧包/只读 FS）。fixed 非空时幂等写入该值（gw_pool fork 注入
// 的令牌也要落盘，供同工作区 CLI/TUI 读取）。POSIX 上 0600；Windows 用户
// 目录默认 ACL 已等价。
std::string ensure_backend_token(const std::string& root, const std::string& fixed) {
    namespace fs = std::filesystem;
    if (root.empty()) return {};
    std::error_code ec;
    fs::create_directories(sa_core::paths::to_path(root), ec);
    const std::string path = sa_core::paths::join(root, ".backend_token");
    auto write_0600 = [&](const std::string& value) -> bool {
        std::ofstream f(path, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f << value;
        f.flush();
        if (!f) return false;
#ifndef _WIN32
        ::chmod(path.c_str(), 0600);
#endif
        return true;
    };
    if (!fixed.empty()) {
        return write_0600(fixed) ? fixed : std::string{};
    }
    {
        std::ifstream in(path, std::ios::binary);
        if (in) {
            std::string t((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            while (!t.empty() &&
                   (t.back() == '\n' || t.back() == '\r' || t.back() == ' ' || t.back() == '\t'))
                t.pop_back();
            // 合法存量令牌（>= 64-bit 熵的 hex/任意 >=16 字符）原样沿用；
            // 空文件/残缺内容重新生成。
            if (t.size() >= 16 && t.size() <= 128) return t;
        }
    }
    std::string t = random_token_hex();
    return write_0600(t) ? t : std::string{};
}

}  // namespace

namespace sa {

int run_server(const ServerConfig& cfg) {
    // --- Android/embedded injections; no-ops on desktop (W4-4) -------------
    // BEFORE init_state(): state.cpp resolves EDITOR_DATA_ROOT lazily but the
    // env-first rule of server/__init__.py only holds if we set it early.
    env_setdefault("EDITOR_DATA_ROOT", cfg.data_root);
    // 托管模式 SSRF 护栏（安全批次 A）：在任何同步路径有机会跑之前挂上。
    sa::cloud::set_public_only(cfg.cloud_public_only);
    if (!cfg.data_root.empty()) {
        env_setdefault("EDITOR_PLUGINS_ROOT",
                       sa_core::paths::join(cfg.data_root, "plugins"));
    }
    env_setdefault("EDITOR_PACKS_ROOT", cfg.packs_root);
    // Silent-failure semantics live inside extract_bundled (Python's
    // `except Exception: pass` around the whole thing).
    extract_bundled(cfg.bundled_zip, cfg.packs_root);

    // Workspace / mod resolution per CONVENTIONS 11: CLI injection wins, then
    // editor_env.json, then the default user mods dir; auto-select first mod.
    sa::init_state(cfg.workspace_root, cfg.mod_root, cfg.mod_name);

    // PLUGIN_SPEC §4: fetch every service plugin's self-description once at
    // boot so the first request sees a populated cache. Synchronous with a 4s
    // total budget (per-service 1.5s cap inside): dead loopback services fail
    // fast (connection refused), and anything past the budget is left to
    // POST /api/plugins/reload rather than delaying the listen line.
    try {
        sa::plugin_service::refresh_all(4000);
    } catch (...) {
        // A broken plugins root must not stop the server from starting.
    }

    sa::Router router = sa::build_router();
    // 长任务结果查询（性能 P1）：wrap_async_job 包裹的端点 202 后在这里取回。
    // 404 信封与其它路由一致；令牌校验在传输层（/api/jobs 不豁免）。
    router.get(R"(^/api/jobs/(?P<id>[0-9a-f]{32})$)", [](const Req& req) -> Resp {
        Resp out;
        if (!sa::jobs::fetch(req.params.at("id"), &out)) {
            return Resp::Json(404, json{{"error", "no such job: " + req.params.at("id")}});
        }
        return out;
    });
    if (cfg.extra_routes) cfg.extra_routes(router);  // atelier graft point
    // Static web hosting is registered LAST: its catch-all GET only ever sees
    // requests that no API route matched (网页版计划 M1.2).
    if (!cfg.web_root.empty()) sa::register_static_routes(router, cfg.web_root);
    // 性能 P1：后台长任务池（4 worker）。在 httpd.start() 之前起，stop 与
    // httpd 对称。
    sa::jobs::start(4);
    // 模块 A：预热对象生命周期回收调度线程（60s 扫描，尽力而为）。
    sa::file_transfer::start_background();
    sa::Httpd httpd(&router);
    sa::CorsConfig cors;
    cors.trusted_origins = cfg.trusted_origins;
    httpd.set_cors(cors);  // empty list == the desktop default tier unchanged
    // 安全批次 B：后端进程令牌。落盘位置 = editor_root()（桌面发行版=可执行
    // 文件目录、Android=EDITOR_DATA_ROOT/data），与前端/CLI/TUI 的读取规则
    // 一致：三端都能按同一规则算出路径（桌面 exe 同目录、Android
    // getApplicationSupportDirectory()/data）。不用工作区根——工作区随用户
    // 切换，令牌应跟安装走。令牌文件不可用时降级为不启用（stderr 告警）。
    if (cfg.auth_token_enabled) {
        std::string auth_token = ensure_backend_token(sa::editor_root(), cfg.auth_token);
        if (!auth_token.empty()) {
            httpd.set_auth_token(std::move(auth_token));
        } else {
            std::fprintf(stderr,
                         "warning: .backend_token unavailable (editor root not writable), "
                         "X-Backend-Token enforcement DISABLED\n");
        }
    }
    if (cfg.max_body_bytes > 0) httpd.set_max_body_bytes(cfg.max_body_bytes);
    const std::string bind_host = cfg.host.empty() ? "127.0.0.1" : cfg.host;
    if (bind_host != "127.0.0.1" && bind_host != "localhost" && bind_host != "::1") {
        // Server mode: never expose the process-killer over a public socket.
        sa::detail::set_shutdown_disabled(true);
    }
    std::string bind_err;
    if (!httpd.bind_to(bind_host, cfg.port, &bind_err)) {
        std::fprintf(stderr, "error: %s\n", bind_err.c_str());
        return 1;
    }

    // Python fires on_ready(port) right after the bind (httpd.py run_server);
    // the JNI channel hands the actual port back through this hook. The
    // desktop --write-port block below stays exactly where it always was.
    if (cfg.on_ready) cfg.on_ready(httpd.port());

    if (!cfg.write_port_file.empty()) {
        std::ofstream pf(cfg.write_port_file, std::ios::binary | std::ios::trunc);
        if (pf) {
            pf << httpd.port();  // no trailing newline, like Python on_ready()
            pf.flush();
        } else {
            std::fprintf(stderr, "cannot write port file: %s\n",
                         cfg.write_port_file.c_str());
        }
    }

    httpd.start();
    // CONVENTIONS 11 keeps this exact ready line for human debugging (run_dev
    // polls /api/ping instead of parsing it).
    std::fprintf(stdout, "API server listening on %s:%d\n", bind_host.c_str(), httpd.port());
    std::fflush(stdout);

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    while (!g_signal_quit.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    httpd.stop();
    sa::file_transfer::stop_background();
    sa::jobs::stop();
    std::fprintf(stdout, "API server stopped\n");
    std::fflush(stdout);
    return 0;
}

void request_exit() { g_signal_quit.store(true); }

int server_main(int argc, char** argv,
                const std::function<void(Router&)>& extra_routes) {
    Options opts;
    std::string err;
    if (!parse_args(argc, argv, opts, err)) {
        std::fprintf(stderr, "error: %s\n", err.c_str());
        print_usage(argv[0]);
        return 2;
    }
    if (opts.show_help) {
        print_usage(argv[0]);
        return 0;
    }

    ServerConfig cfg;
    cfg.port = opts.port;
    cfg.write_port_file = opts.write_port_file;
    cfg.workspace_root = opts.workspace_root;
    cfg.mod_root = opts.mod_root;
    cfg.mod_name = opts.mod_name;
    cfg.host = opts.host;
    cfg.web_root = opts.web_root;
    cfg.trusted_origins = opts.trusted_origins;
    cfg.cloud_public_only = opts.cloud_public_only;
    cfg.auth_token_enabled = opts.auth_token_enabled;
    cfg.auth_token = opts.auth_token;
    cfg.max_body_bytes = opts.max_body_bytes;
    cfg.extra_routes = extra_routes;
    return run_server(cfg);
}

}  // namespace sa
