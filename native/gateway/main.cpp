// gateway/main: backend_gateway — the online hosting gateway (网页版计划 M2).
//
//   backend_gateway --config <gateway.json> [--port N] [--host ADDR]
//                   [--write-port FILE]
//   backend_gateway --hash-password [PLAIN]
//
// `--hash-password` prints one `salt:hash` line (admin tool to mint account
// entries) and exits 0; with no inline password it reads one line from stdin.
// Otherwise it boots a single-workspace HTTP gateway: it owns auth + AI relay,
// hosts the web build, and reverse-proxies every other /api/* to a lazily
// forked per-account `backend` instance (gw_pool). See README for topology.
//
// POSIX-only: the whole target is gated by `if(UNIX)` in native/CMakeLists.txt.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <csignal>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <thread>

#include "sa_core/paths.h"
#include "server/httpd.h"
#include "server/services/static_routes.h"

#include "gw_config.h"
#include "gw_pool.h"
#include "gw_proxy.h"
#include "gw_refresh.h"
#include "gw_sessions.h"
#include "gw_usage.h"

namespace {

std::atomic<bool> g_quit{false};
void on_signal(int) { g_quit.store(true); }

void print_usage(const char* a0) {
    std::fprintf(stderr,
                 "Usage: %s --config <gateway.json> [--port N] [--host ADDR] "
                 "[--write-port FILE]\n"
                 "       %s --hash-password [PLAIN]\n",
                 a0, a0);
}

struct Args {
    std::string config;
    std::string host;            // "" -> from config default / 0.0.0.0
    int port = -1;               // -1 -> config listen_port
    std::string write_port;
    bool hash_password = false;
    bool has_positional_pw = false;
    std::string positional_pw;
    bool show_help = false;
};

bool parse_args(int argc, char** argv, Args* a) {
    for (int i = 1; i < argc; ++i) {
        std::string s = argv[i];
        auto need = [&](std::string& dst) -> bool {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "error: missing value for %s\n", s.c_str());
                return false;
            }
            dst = argv[++i];
            return true;
        };
        if (s == "--config") {
            if (!need(a->config)) return false;
        } else if (s == "--port") {
            std::string v;
            if (!need(v)) return false;
            try {
                a->port = std::stoi(v);
            } catch (...) {
                std::fprintf(stderr, "error: invalid --port: %s\n", v.c_str());
                return false;
            }
        } else if (s == "--host") {
            if (!need(a->host)) return false;
        } else if (s == "--write-port") {
            if (!need(a->write_port)) return false;
        } else if (s == "--hash-password") {
            a->hash_password = true;
            // Optional inline value: consume it only if the next token does
            // not look like another flag (mirrors the [PLAIN] optional arg).
            if (i + 1 < argc && std::string(argv[i + 1]).rfind("--", 0) != 0)
                a->positional_pw = argv[++i], a->has_positional_pw = true;
        } else if (s == "--help" || s == "-h") {
            a->show_help = true;
        } else {
            std::fprintf(stderr, "error: unknown argument: %s\n", s.c_str());
            return false;
        }
    }
    return true;
}

int do_hash_password(const Args& a) {
    std::string pw;
    if (a.has_positional_pw) {
        pw = a.positional_pw;
    } else {
        // Read a single line from stdin (no trailing newline).
        if (!std::getline(std::cin, pw)) {
            std::fprintf(stderr, "error: empty stdin for --hash-password\n");
            return 2;
        }
    }
    // v2（安全批次 A）：PBKDF2-HMAC-SHA256 + 随机盐。除了 salt:hash 行，
    // 再附上可直接粘贴进 gateway.json accounts[] 的 kdf 字段，避免管理员
    // 手抄出 kdf_version 缺失导致账号回落 v1 校验。
    const gw::PasswordMint m = gw::mint_password(pw);
    std::printf("%s:%s\n", m.salt.c_str(), m.hash.c_str());
    std::printf("gateway.json account fields:\n"
                "  \"salt\": \"%s\",\n"
                "  \"password_sha256\": \"%s\",\n"
                "  \"kdf_version\": %d,\n"
                "  \"kdf_iterations\": %d\n",
                m.salt.c_str(), m.hash.c_str(), m.kdf_version, m.iterations);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    Args a;
    if (!parse_args(argc, argv, &a)) {
        print_usage(argv[0]);
        return 2;
    }
    if (a.show_help) {
        print_usage(argv[0]);
        return 0;
    }
    if (a.hash_password) return do_hash_password(a);
    if (a.config.empty()) {
        std::fprintf(stderr, "error: --config is required\n");
        print_usage(argv[0]);
        return 2;
    }

    // --- config + validation ------------------------------------------------
    gw::Config cfg;
    std::string cerr_str;
    if (!gw::load_config(a.config, &cfg, &cerr_str)) {
        std::fprintf(stderr, "error: %s\n", cerr_str.c_str());
        return 2;  // accounts empty / bad root / malformed config all land here
    }
    for (const auto& w : cfg.warnings) std::fprintf(stderr, "warning: %s\n", w.c_str());

    // Create the data root + state dir first: registered accounts load from
    // <state_dir>/accounts.json and their workspaces are created below.
    if (!sa_core::paths::create_dirs(cfg.user_data_root)) {
        std::fprintf(stderr, "error: cannot create user_data_root: %s\n",
                     cfg.user_data_root.c_str());
        return 1;
    }
    if (!sa_core::paths::create_dirs(cfg.state_dir)) {
        std::fprintf(stderr, "error: cannot create state_dir: %s\n", cfg.state_dir.c_str());
        return 1;
    }

    // --- assemble the gateway runtime --------------------------------------
    gw::Gateway g;
    g.cfg = cfg;
    // 并入自助注册账号；管理员在 gateway.json 声明的同名账号优先。
    g.accounts = std::make_unique<gw::RegisteredAccounts>(g.cfg.accounts_file,
                                                          g.cfg.user_data_root);
    g.accounts->merge_into(&g.cfg);
    if (g.accounts->count() > 0) {
        std::fprintf(stdout, "loaded %zu self-registered account(s) from %s\n",
                     g.accounts->count(), g.cfg.accounts_file.c_str());
    }
    g.sessions = std::make_unique<gw::Sessions>(g.cfg.session_ttl_hours * 3600LL * 1000LL);
    // 长期鉴权（记住我）：refresh token 落盘，网关重启后仍可免登。
    g.refresh = std::make_unique<gw::RefreshTokens>(g.cfg.refresh_file);
    g.usage = std::make_unique<gw::UsageStore>(
        sa_core::paths::join(g.cfg.state_dir, "usage.json"), g.cfg.ai.daily_limit);
    g.relay = gw::resolve_relay(g.cfg);

    // Create every account workspace (gateway.json + registered).
    for (const auto& acct : g.cfg.accounts) {
        if (!sa_core::paths::create_dirs(acct.dir)) {
            std::fprintf(stderr, "error: cannot create account workspace: %s\n",
                         acct.dir.c_str());
            return 1;
        }
    }

    const std::string backend_exe = gw::InstancePool::resolve_backend_exe();
    if (backend_exe.empty()) {
        std::fprintf(stderr,
                     "warning: no `backend` binary found next to the gateway and "
                     "EDITOR_GATEWAY_BACKEND_EXE unset; proxy requests will 502\n");
    }
    gw::InstancePool::Options po;
    po.state_dir = g.cfg.state_dir;
    po.backend_exe = backend_exe;
    po.max_instances = g.cfg.instance_max;
    po.idle_minutes = g.cfg.idle_minutes;
    // SSRF 护栏透传（安全批次 A）：cloud_public_only 默认 true，管理员可
    // 在 gateway.json 显式关闭（纯内网自托管场景）。
    po.cloud_public_only = g.cfg.cloud_public_only;
    // 人物图片资源扩展（服务器端「2 种安装方式」）透传给每个 backend 实例。
    po.portrait_dir = g.cfg.portraits.dir;
    po.portrait_base_url = g.cfg.portraits.base_url;
    // 背景图片资源扩展（与人物图片扩展同构）透传给每个 backend 实例。
    po.background_dir = g.cfg.backgrounds.dir;
    po.background_base_url = g.cfg.backgrounds.base_url;
    // 上传/请求体上限：网关自身与每个实例用同一个配置值。
    po.max_body_bytes = g.cfg.max_body_bytes;
    // 读 g.cfg（而非启动时的局部副本）：自助注册会在运行时追加账号。
    po.account_dir = [&g](const std::string& name) -> std::string {
        const gw::Account* acc = g.cfg.find_account(name);
        return acc ? acc->dir : "";
    };
    g.pool = std::make_unique<gw::InstancePool>(std::move(po));

    sa::Router router;
    gw::register_gateway_routes(router, g);
    // Static web hosting is registered LAST so any /api route wins (run.cpp
    // parity). Missing/empty web_root -> skip (already warned by config).
    bool host_static = !cfg.web_root.empty() && sa_core::paths::is_dir(cfg.web_root);
    if (host_static) sa::register_static_routes(router, cfg.web_root);
    if (!cfg.web_root.empty() && !host_static) {
        std::fprintf(stderr, "warning: web_root missing, static hosting skipped: %s\n",
                     cfg.web_root.c_str());
    }

    sa::Httpd httpd(&router);
    sa::CorsConfig cors;
    cors.trusted_origins = cfg.trusted_origins;
    httpd.set_cors(cors);
    httpd.set_max_slots(256);  // gateway fans out; lift the default 64 slot cap
    // 大体积上传：网关必须能收下整个 body 并原样转发给实例，所以 body 上限与
    // raw_body 保留上限都用 gateway.json 的 max_body_bytes。
    httpd.set_max_body_bytes(g.cfg.max_body_bytes);
    httpd.set_raw_body_keep_max(g.cfg.max_body_bytes);

    // 默认只绑环回（安全批次 A）：面向外网部署必须显式 --host 0.0.0.0
    // （或管理员在配置里声明），避免「顺手起个网关」把托管面直接暴露公网。
    const std::string host = a.host.empty() ? std::string("127.0.0.1") : a.host;
    const int port = a.port >= 0 ? a.port : cfg.listen_port;
    std::string berr;
    if (!httpd.bind_to(host, port, &berr)) {
        std::fprintf(stderr, "error: bind %s:%d failed: %s\n", host.c_str(), port,
                     berr.c_str());
        return 1;
    }
    if (!a.write_port.empty()) {
        std::ofstream pf(a.write_port, std::ios::binary | std::ios::trunc);
        if (pf) pf << httpd.port();
    }

    httpd.start();
    std::fprintf(stdout, "backend_gateway listening on %s:%d (accounts=%zu, web_root=%s, "
                         "relay=%s)\n",
                 host.c_str(), httpd.port(), g.cfg.accounts.size(),
                 host_static ? cfg.web_root.c_str() : "<none>",
                 g.relay.usable ? "on" : "off");
    std::fflush(stdout);

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    // Reaper: idle instance + expired session sweep every 60s.
    std::atomic<bool> reaper_quit{false};
    std::thread reaper([&] {
        while (!reaper_quit.load()) {
            for (int i = 0; i < 60 && !reaper_quit.load(); ++i)
                std::this_thread::sleep_for(std::chrono::seconds(1));
            if (reaper_quit.load()) break;
            g.sessions->prune_expired();
            if (g.refresh) g.refresh->prune_expired();
            if (g.pool) g.pool->reap_idle();
        }
    });

    while (!g_quit.load()) std::this_thread::sleep_for(std::chrono::milliseconds(100));

    reaper_quit.store(true);
    reaper.join();
    httpd.stop();
    if (g.pool) g.pool->shutdown_all();
    std::fprintf(stdout, "backend_gateway stopped\n");
    std::fflush(stdout);
    return 0;
}
