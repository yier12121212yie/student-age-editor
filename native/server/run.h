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
#include <vector>

#include "server/httpd.h"

namespace sa {

struct ServerConfig {
    int port = 0;                    // 0 == auto-pick (CONVENTIONS 2)
    std::string write_port_file;     // --write-port FILE: actual port, no newline
    std::string workspace_root;      // CLI injection into init_state
    std::string mod_root;
    std::string mod_name;

    // Web tiers (网页版计划 M1.1). Every field defaults to the desktop wire:
    //   host empty            -> bind 127.0.0.1 exactly as before
    //   trusted_origins empty -> default origin tier (loopback+Origin==Host)
    //   web_root empty        -> no static hosting routes registered
    std::string host;                      // --host (server/browser access)
    std::vector<std::string> trusted_origins;  // repeatable --trusted-origin
    std::string web_root;                  // --web-root: serve this dir at /

    // 托管模式 SSRF 护栏（安全批次 A）：true 时云同步出站 URL 强校验公网
    // 地址（sa::cloud::set_public_only）。网关 fork 的 backend 默认带
    // --cloud-public-only；桌面端保持 false（局域网 NAS 是合法场景）。
    bool cloud_public_only = false;

    // 安全批次 B：后端进程令牌（X-Backend-Token）。enabled 时 run_server 确保
    // 工作区根/.backend_token 存在（128-bit hex，POSIX 0600），并对除
    // /api/ping、OPTIONS、静态资源外的 /api/* 强制等值校验。auth_token 非空
    // 时直接采用该值（网关 fork 经 argv 内存注入），并同步写文件供
    // CLI/TUI 读取。令牌文件不可写/工作区不可解析时降级为不启用（兼容旧包
    // 与只读 FS，stderr 有告警）。
    bool auth_token_enabled = true;
    std::string auth_token;  // 非空 = 指定令牌（gw_pool fork 用）

    // 安全批次 B / 性能 P1：请求体上限（字节）。0 == 桌面默认 256 MiB；
    // 网关 fork 传 32 MiB。
    long long max_body_bytes = 0;

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
