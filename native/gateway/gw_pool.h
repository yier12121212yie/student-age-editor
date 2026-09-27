// gateway/gw_pool: the lazy per-account backend instance pool (网页版计划 M2.2,
// POSIX-only).
//
// One `backend` process per account, fork/exec'd on the first proxied request
//   backend --port 0 --write-port <state_dir>/<name>.port
//                   --workspace-root <account dir>
// with EDITOR_DATA_ROOT=<account dir> and EDITOR_DISABLE_STEAM_DETECT=1 in the
// child environment, in its own session/process group (setsid) so the gateway
// can killpg the whole tree. Reuse requires both waitpid-alive AND a
// GET /api/ping round-trip; a dead instance is recycled transparently.
//
// Lock discipline (CONVENTIONS 6 spirit): pool mutex guards ONLY the map and
// the detached flag. An instance mutex serialises acquire/start/stop for that
// account. Order is always instance-mu -> pool-mu, and the pool mu is never
// held across a blocking call — eviction hands the kill to a short-lived
// detached thread that takes the victim's mu first.
//
// The whole header is POSIX: the gateway target is gated by `if(UNIX)` in
// native/CMakeLists.txt and never compiles for Windows.
#pragma once

#ifndef _WIN32

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <sys/types.h>

namespace gw {

class InstancePool {
  public:
    struct Options {
        std::string state_dir;   // port/log files live here
        // Absolute path of the `backend` binary. "" -> env
        // EDITOR_GATEWAY_BACKEND_EXE, else <gateway-exe-dir>/backend[.exe].
        std::string backend_exe;
        // Account name -> workspace dir (created if missing at start time).
        std::function<std::string(const std::string&)> account_dir;
        int max_instances = 8;
        int idle_minutes = 30;
        // 托管模式 SSRF 护栏（安全批次 A）：true 时给 fork 的 backend 传
        // --cloud-public-only（云同步出站 URL 强校验公网地址）。
        bool cloud_public_only = false;
    };

    explicit InstancePool(Options opts);
    ~InstancePool();

    // Ensure a live instance for the account and mark it busy (inflight++).
    // Returns the loopback port, or 0 with `*err` set. Caller MUST call
    // release(name) exactly once per successful acquire.
    int acquire(const std::string& name, std::string* err);
    void release(const std::string& name);

    // Reaper hook (60s ticker): reap zombies, stop instances idle longer than
    // idle_minutes. Returns how many were stopped.
    int reap_idle();

    // Stop everything (gateway shutdown path).
    void shutdown_all();

    // Live count + port for tests/telemetry (0 when absent).
    int live_count();
    int peek_port(const std::string& name);

    // 安全批次 B：该账号 backend 实例的进程令牌（X-Backend-Token）。实例不
    // 在池中/未启动时返回空串。在 acquire() 成功与 release() 之间调用（inflight
    // 引用保证实例不被逐出）。
    std::string peek_token(const std::string& name);

    // Default backend binary discovery (env EDITOR_GATEWAY_BACKEND_EXE,
    // else <exe_dir>/backend, else <exe_dir>/backend.exe; "" if none exist).
    static std::string resolve_backend_exe();

  private:
    struct Instance {
        std::mutex mu;             // serialise acquire/start/stop for this acct
        pid_t pid = 0;
        int port = 0;
        long long last_seen_ms = 0;
        std::atomic<int> inflight{0};
        bool starting = false;     // guarded by mu
        bool detached = false;     // guarded by pool mu
        std::string name;
        std::string token;         // 安全批次 B：start 时生成，经 --auth-token
                                   // 注入 fork 的 backend；代理转发时带
                                   // X-Backend-Token（guarded by mu，start 后只读）
    };

    // All *_locked helpers assume the caller holds inst->mu.
    bool alive_locked(Instance& in);          // waitpid WNOHANG check
    void stop_locked(std::shared_ptr<Instance>& in, bool kill_hard);
    int start_locked(std::shared_ptr<Instance>& in, std::string* err);

    // Capacity eviction (called synchronously with NO instance lock held):
    // detach the LRU idle victim from the map, then retire it. retire_detached
    // locks only the victim's mutex (instance -> pool order).
    std::shared_ptr<Instance> detach_lru_idle(const std::string& self_name);
    void retire_detached(std::shared_ptr<Instance> in);

    Options opts_;
    std::mutex mu_;  // guards map_ and detached flags ONLY
    std::map<std::string, std::shared_ptr<Instance>> map_;
};

}  // namespace gw

#endif  // !_WIN32
