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
#include <fstream>
#include <functional>
#include <string>
#include <thread>

#include "server/android_bundled.h"
#include "server/api_router.h"
#include "server/httpd.h"
#include "server/run.h"
#include "server/services/plugin_service.h"
#include "server/state.h"
#include "sa_core/paths.h"

namespace {

std::atomic<bool> g_signal_quit{false};

struct Options {
    int port = -1;  // -1 == flag missing; 0 == auto
    std::string write_port_file;
    std::string workspace_root;
    std::string mod_root;
    std::string mod_name;
    bool show_help = false;
};

void print_usage(const char* argv0) {
    std::fprintf(stderr,
                 "Usage: %s --port N [--write-port FILE] "
                 "[--workspace-root DIR] [--mod-root DIR] [--mod-name NAME]\n",
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

}  // namespace

namespace sa {

int run_server(const ServerConfig& cfg) {
    // --- Android/embedded injections; no-ops on desktop (W4-4) -------------
    // BEFORE init_state(): state.cpp resolves EDITOR_DATA_ROOT lazily but the
    // env-first rule of server/__init__.py only holds if we set it early.
    env_setdefault("EDITOR_DATA_ROOT", cfg.data_root);
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
    if (cfg.extra_routes) cfg.extra_routes(router);  // atelier graft point
    sa::Httpd httpd(&router);
    std::string bind_err;
    if (!httpd.bind_to("127.0.0.1", cfg.port, &bind_err)) {
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
    std::fprintf(stdout, "API server listening on 127.0.0.1:%d\n", httpd.port());
    std::fflush(stdout);

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    while (!g_signal_quit.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    httpd.stop();
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
    cfg.extra_routes = extra_routes;
    return run_server(cfg);
}

}  // namespace sa
