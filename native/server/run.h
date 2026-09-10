// server/run: the reusable process entry — sa::run_server(ServerConfig) plus
// the sa::server_main(argc, argv) CLI wrapper on top of it (declared in
// server/api_router.h; the signature is wave-2 atelier/wip-harness contract
// and must not move).
//
// W4-4 extracted the config struct out of the argv-only flow so the Android
// channel (native/android/jni_bridge.cpp, no argv) boots the IDENTICAL
// production server. Desktop (Windows) callers leave data_root / packs_root /
// bundled_zip empty — every Android-only step is a no-op then, which is what
// keeps backend.exe byte-for-byte unchanged in behaviour.
//
// Python truth source: editor/server/__init__.py:14-29 start_server() —
// env setdefaults happen BEFORE any module reads them, the bundled zip is
// extracted next, then the router is built and the socket bound.
#pragma once

#include <functional>
#include <string>

#include "server/httpd.h"

namespace sa {

struct ServerConfig {
    int port = 0;                    // 0 == auto-pick (CONVENTIONS 2)
    std::string write_port_file;     // --write-port FILE: actual port, no newline
    std::string workspace_root;      // CLI injection into init_state
    std::string mod_root;
    std::string mod_name;

    // Android/embedded distribution injection (server/__init__.py:22-27).
    // setdefault semantics throughout: a pre-set env var always wins.
    std::string data_root;           // -> EDITOR_DATA_ROOT + EDITOR_PLUGINS_ROOT=<data_root>/plugins
    std::string packs_root;          // -> EDITOR_PACKS_ROOT
    std::string bundled_zip;         // -> extract_bundled() into <packs_root>/bundled

    std::function<void(int port)> on_ready;     // fired once the socket is bound (Python on_ready)
    std::function<void(Router&)> extra_routes;  // atelier graft point (was server_main's 2nd arg)
};

// Blocking. Order fixed to mirror server_main's proven sequence (and Python):
// env setdefaults -> extract_bundled -> init_state -> build_router(+extra)
// -> bind 127.0.0.1 -> on_ready -> write_port file -> start -> ready line ->
// wait for SIGINT/SIGTERM or request_exit() -> stop. Returns the process exit
// code (1 == bind failure). Never throws.
int run_server(const ServerConfig& cfg);

// Ask the current run_server() wait loop to exit (graceful; the JNI stop()
// and any embedder use this; harmless before/after run_server).
void request_exit();

}  // namespace sa
