// backend: native HTTP server for the StudentAge editor.
//
// Wave-0 scaffold. Implements the minimum slice of the Python backend's HTTP
// contract needed to bootstrap the C++ port and to drive the black-box contract
// tests:
//   * GET  /api/ping     -> 200, byte-for-byte identical body + headers to the
//                            Python server (see sa_core::py_dumps).
//   * POST /api/shutdown -> 200 {"ok": true}, then clean process exit.
//   * anything else      -> 404 {"error": "no route: <METHOD> <PATH>"}.
//
// CLI (mirrors backend/editor/server/__init__.py main()):
//   backend --port N [--write-port <file>]
// plus wave-0 state-injection hooks used only to prove JSON parity against the
// live Python values (aa_status / base_loaded_count are fixed idle defaults):
//   [--workspace-root <s>] [--mod-root <s>] [--mod-name <s>]
//
// Binding is restricted to 127.0.0.1 (loopback only), matching the Python host.
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>

#include "httplib.h"

#include <nlohmann/json.hpp>

#include "sa_core/json_wire.h"
#include "sa_core/version.h"

namespace {

std::atomic<bool> g_shutdown_requested{false};

struct Options {
    int port = -1;
    std::string write_port_file;
    // Runtime state values reported under ping.state. In later waves these come
    // from real workspace/mod scanning; for wave 0 they are injected / defaulted.
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
    if (out.port < 1 || out.port > 65535) {
        err = "--port must be in 1..65535";
        return false;
    }
    return true;
}

// Assemble the /api/ping body. Field order + spacing must match Python's
// build_router().ping() exactly (see api.py ~L742).
std::string build_ping_body(const Options& o) {
    nlohmann::ordered_json j;
    j["ok"] = true;
    j["app"] = sa_core::app_name();
    j["cfg_patch"] = true;  // S2 capability gate (verbatim from the Python side).

    nlohmann::ordered_json state;
    state["workspace_root"] = o.workspace_root;
    state["mod_root"] = o.mod_root;
    state["mod_name"] = o.mod_name;
    state["aa_status"] = "idle";  // wave-0 fixed default; real scanning later.
    state["base_loaded_count"] = 0;
    j["state"] = state;

    return sa_core::py_dumps(j);
}

// Apply the deterministic response headers the Python httpd._respond() emits on
// every JSON response (Cache-Control / CORS). Registered as the post-routing
// handler so it covers success AND error responses uniformly, regardless of
// which handler produced the body.
//
// Content-Type is NOT set here: httplib's Response::set_header APPENDS (the
// header map is a multimap), and every handler already calls
// res.set_content(body, "application/json; charset=utf-8"), which sets the
// single canonical Content-Type. Re-setting it here would emit a duplicate.
void set_contract_headers(httplib::Response& res) {
    res.set_header("Cache-Control", "no-store");
    res.set_header("Access-Control-Allow-Origin", "http://127.0.0.1");
    res.set_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    res.set_header("Access-Control-Allow-Headers", "Content-Type");
}

extern "C" void on_signal(int) {
    // Async-signal-safe enough for a scaffold: request a clean shutdown and let
    // httplib's own stop() do the socket teardown from a safer context.
    g_shutdown_requested.store(true);
}

}  // namespace

int main(int argc, char** argv) {
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

    const std::string host = "127.0.0.1";  // loopback only, per contract.

    httplib::Server server;
    // Keep-alive is enabled by default on the server side (HTTP/1.1).

    const std::string ping_body = build_ping_body(opts);

    server.Get("/api/ping",
               [&ping_body](const httplib::Request&, httplib::Response& res) {
                   res.status = 200;
                   res.set_content(ping_body, "application/json; charset=utf-8");
               });

    server.Post("/api/shutdown",
                [&server](const httplib::Request&, httplib::Response& res) {
                    // Respond first, then request shutdown. httplib writes this
                    // response on the connection thread while the listener stops,
                    // so the {"ok": true} body is actually delivered (the Python
                    // server races os._exit() here and often drops it).
                    res.status = 200;
                    res.set_content(sa_core::py_dumps(nlohmann::ordered_json{{"ok", true}}),
                                    "application/json; charset=utf-8");
                    g_shutdown_requested.store(true);
                    server.stop();
                });

    // Uniform headers for every response (including the 404/500 handled below).
    server.set_post_routing_handler(
        [](const httplib::Request&, httplib::Response& res) { set_contract_headers(res); });

    // 404 / other >=400: emit the api.py error envelope. cpp-httplib routes
    // unmatched paths AND wrong methods here with status 404, matching Python's
    // "no route: <METHOD> <PATH>".
    server.set_error_handler([](const httplib::Request& req, httplib::Response& res) {
        std::string msg;
        if (res.status == 404) {
            msg = "no route: " + req.method + " " + req.path;
        } else {
            msg = "http error " + std::to_string(res.status);
        }
        res.set_content(sa_core::error_json(msg), "application/json; charset=utf-8");
    });

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    if (!server.bind_to_port(host, opts.port)) {
        std::fprintf(stderr, "error: cannot bind %s:%d\n", host.c_str(), opts.port);
        return 1;
    }

    if (!opts.write_port_file.empty()) {
        std::ofstream pf(opts.write_port_file, std::ios::binary | std::ios::trunc);
        if (pf) {
            pf << opts.port;  // no trailing newline, mirroring Python on_ready().
            pf.flush();
        } else {
            std::fprintf(stderr, "cannot write port file: %s\n",
                         opts.write_port_file.c_str());
        }
    }

    std::fprintf(stdout, "API server listening on %s:%d (sa_core %s)\n", host.c_str(),
                 opts.port, sa_core::version());
    std::fflush(stdout);

    // Blocks until stop() is called (via /api/shutdown) or the listening socket
    // is torn down. SIGINT/SIGTERM set g_shutdown_requested; poll it from here
    // because stop() must run outside the (blocked) accept call to unblock it.
    // We run the accept loop on this thread; a watchdog thread performs stop().
    std::atomic<bool> loop_done{false};
    std::thread watchdog([&] {
        while (!g_shutdown_requested.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        server.stop();
        loop_done.store(true);
    });

    server.listen_after_bind();  // returns after stop()
    if (watchdog.joinable()) {
        watchdog.join();
    }

    std::fprintf(stdout, "API server stopped\n");
    std::fflush(stdout);
    return 0;  // clean exit for both /api/shutdown and Ctrl-C.
}
