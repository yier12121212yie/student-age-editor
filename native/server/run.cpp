// server/run: the reusable process entry — sa::server_main().
//
// Moved out of main.cpp (wave-2 preparation) so atelier harnesses can boot the
// exact production server (same CLI, init_state, transport, shutdown hooks) and
// graft their own routes via `extra_routes` before build_router() is rewired by
// the orchestrator. main.cpp's main() simply delegates here.
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <fstream>
#include <functional>
#include <string>
#include <thread>

#include "server/api_router.h"
#include "server/httpd.h"
#include "server/state.h"

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
        err = "--port is required";
        return false;
    }
    if (out.port > 65535) {
        err = "--port must be in 0..65535";
        return false;
    }
    return true;
}

extern "C" void on_signal(int) { g_signal_quit.store(true); }

}  // namespace

namespace sa {

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

    // Workspace / mod resolution per CONVENTIONS 11: CLI injection wins, then
    // editor_env.json, then the default user mods dir; auto-select first mod.
    sa::init_state(opts.workspace_root, opts.mod_root, opts.mod_name);

    sa::Router router = sa::build_router();
    if (extra_routes) extra_routes(router);  // atelier graft point
    sa::Httpd httpd(&router);
    std::string bind_err;
    if (!httpd.bind_to("127.0.0.1", opts.port, &bind_err)) {
        std::fprintf(stderr, "error: %s\n", bind_err.c_str());
        return 1;
    }

    if (!opts.write_port_file.empty()) {
        std::ofstream pf(opts.write_port_file, std::ios::binary | std::ios::trunc);
        if (pf) {
            pf << httpd.port();  // no trailing newline, like Python on_ready()
            pf.flush();
        } else {
            std::fprintf(stderr, "cannot write port file: %s\n",
                         opts.write_port_file.c_str());
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

}  // namespace sa
