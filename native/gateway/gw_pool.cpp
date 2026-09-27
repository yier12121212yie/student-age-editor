// gateway/gw_pool.cpp — see gw_pool.h. POSIX only (fork/exec/killpg); the
// whole gateway target is gated by `if(UNIX)` at the root CMake level, and
// the file is additionally wrapped so a stray Windows compile is inert.
#ifndef _WIN32

#include "gw_pool.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <optional>
#include <random>
#include <thread>
#include <vector>

#include "sa_core/http_client.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"

extern char** environ;

namespace fs = std::filesystem;
namespace http = sa_core::http;

namespace gw {
namespace {

constexpr auto kPortWait = std::chrono::seconds(10);
constexpr auto kPingWait = std::chrono::seconds(3);

void sleep_ms(int ms) {
    struct pollfd pfd{};
    ::poll(&pfd, 0, ms);  // ppoll-free sleep; ignores EINTR-ish re-poll
}

std::optional<int> read_port_file(const std::string& path) {
    auto raw = sa_core::paths::read_bytes(path);
    if (!raw) return std::nullopt;
    std::string s = sa_core::str::trim(*raw);
    if (s.empty() || s.size() > 5) return std::nullopt;
    for (char c : s)
        if (c < '0' || c > '9') return std::nullopt;
    int p = std::atoi(s.c_str());
    if (p <= 0 || p > 65535) return std::nullopt;
    return p;
}

bool ping_port(int port, double timeout_s) {
    http::Request req;
    req.method = "GET";
    req.url = "http://127.0.0.1:" + std::to_string(port) + "/api/ping";
    req.timeout_seconds = timeout_s;
    req.bypass_proxy = true;       // loopback must never hit a proxy env
    req.follow_redirects = false;
    http::Response res = http::request(req);
    return res.transport_ok() && res.status == 200;
}

// 安全批次 B：128-bit 随机 hex 令牌（gw_pool 生成后经 argv 内存注入 fork 的
// backend，不经命令行之外的持久化；backend 侧会把它写进账号工作区的
// .backend_token 供诊断）。
std::string random_hex_token() {
    static const char* hexd = "0123456789abcdef";
    std::mt19937_64 rng(
        std::random_device{}() ^
        static_cast<unsigned long long>(
            std::chrono::steady_clock::now().time_since_epoch().count()));
    std::string out;
    out.reserve(32);
    for (int i = 0; i < 32; ++i) out += hexd[(rng() >> ((i % 16) * 4)) & 0xF];
    return out;
}

}  // namespace

InstancePool::InstancePool(Options opts) : opts_(std::move(opts)) {}

InstancePool::~InstancePool() { shutdown_all(); }

std::string InstancePool::resolve_backend_exe() {
    std::string env = sa_core::paths::getenv_utf8("EDITOR_GATEWAY_BACKEND_EXE");
    if (!env.empty() && sa_core::paths::is_file(env)) return env;
    std::string dir = sa_core::paths::exe_dir();
    if (dir.empty()) return "";
    for (const char* name : {"backend", "backend.exe"}) {
        std::string p = sa_core::paths::join(dir, name);
        if (sa_core::paths::is_file(p)) return p;
    }
    return "";
}

bool InstancePool::alive_locked(Instance& in) {
    if (in.pid <= 0) return false;
    int status = 0;
    pid_t r = ::waitpid(in.pid, &status, WNOHANG);
    if (r == in.pid) {  // reaped: gone (normal or crashed — both recycle)
        in.pid = 0;
        in.port = 0;
        return false;
    }
    if (r < 0 && errno != EINTR) {
        in.pid = 0;
        in.port = 0;
        return false;
    }
    return true;  // r == 0: still running
}

void InstancePool::stop_locked(std::shared_ptr<Instance>& in, bool kill_hard) {
    if (in->pid > 0) {
        // setsid put the child in its own group whose pgid == pid; killpg
        // takes the (rare) grandchildren the backend may have spawned too.
        if (kill_hard) {
            ::killpg(in->pid, SIGKILL);
        } else {
            ::killpg(in->pid, SIGTERM);
            auto t0 = std::chrono::steady_clock::now();
            bool gone = false;
            while (std::chrono::steady_clock::now() - t0 < std::chrono::seconds(5)) {
                int status = 0;
                pid_t r = ::waitpid(in->pid, &status, WNOHANG);
                if (r == in->pid) {
                    gone = true;
                    break;
                }
                if (r < 0 && errno != EINTR) {
                    gone = true;
                    break;
                }
                sleep_ms(50);
            }
            if (!gone) {
                ::killpg(in->pid, SIGKILL);
                int status = 0;
                for (int i = 0; i < 40 && ::waitpid(in->pid, &status, WNOHANG) != in->pid;
                     ++i)
                    sleep_ms(50);
            }
        }
        if (kill_hard) {
            // Reap after SIGKILL without blocking forever on a D-state child.
            int status = 0;
            for (int i = 0; i < 40 && ::waitpid(in->pid, &status, WNOHANG) != in->pid; ++i)
                sleep_ms(50);
        }
        in->pid = 0;
    }
    in->port = 0;
    std::string pf = sa_core::paths::join(opts_.state_dir, in->name + ".port");
    std::error_code ec;
    fs::remove(sa_core::paths::to_path(pf), ec);
}

int InstancePool::start_locked(std::shared_ptr<Instance>& in, std::string* err) {
    if (opts_.backend_exe.empty() || !sa_core::paths::is_file(opts_.backend_exe)) {
        *err = "backend binary not found (set EDITOR_GATEWAY_BACKEND_EXE)";
        return 0;
    }
    const std::string acct = opts_.account_dir ? opts_.account_dir(in->name) : "";
    if (acct.empty()) {
        *err = "no account dir for " + in->name;
        return 0;
    }
    std::error_code ec;
    fs::create_directories(sa_core::paths::to_path(acct), ec);

    const std::string port_file = sa_core::paths::join(opts_.state_dir, in->name + ".port");
    fs::remove(sa_core::paths::to_path(port_file), ec);  // clear stale port
    const std::string log_file = sa_core::paths::join(opts_.state_dir, in->name + ".log");

    // Prepare EVERYTHING before fork(): the child between fork and exec may
    // only touch async-signal-safe calls (no malloc), so argv/envp/fd are all
    // built here in the parent.
    int logfd = ::open(log_file.c_str(), O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0600);
    if (logfd < 0) logfd = ::open("/dev/null", O_WRONLY | O_CLOEXEC);

    std::vector<std::string> argv = {opts_.backend_exe,
                                     "--port", "0",
                                     "--write-port", port_file,
                                     "--workspace-root", acct};
    // 安全批次 B：每个实例独立 128-bit 进程令牌；代理转发时携带
    // X-Backend-Token（gw_proxy）。backend 对除 /api/ping、静态资源外的
    // /api/* 强制等值校验。
    in->token = random_hex_token();
    argv.emplace_back("--auth-token");
    argv.emplace_back(in->token);
    // 托管模式 SSRF 护栏（安全批次 A）：云同步等出站请求只允许公网地址，
    // 阻断账号配置里塞私网/环回 URL 的内网横移（gw_config 默认开启）。
    if (opts_.cloud_public_only) argv.emplace_back("--cloud-public-only");
    // 性能 P1：请求体上限 32 MiB——网关可见的合法上传（base64 插件/资源包
    // 解码上限 100 MB 的场景不走网关直传）远小于桌面直连的 256 MiB 默认。
    argv.emplace_back("--max-body");
    argv.emplace_back("33554432");
    std::vector<char*> argvp;
    for (auto& s : argv) argvp.push_back(s.data());
    argvp.push_back(nullptr);

    std::vector<std::string> envv;
    for (char** e = environ; *e; ++e) envv.emplace_back(*e);
    auto put_env = [&](const std::string& kv) {
        std::string key = kv.substr(0, kv.find('='));
        for (auto& s : envv)
            if (s.size() > key.size() && s.compare(0, key.size(), key) == 0 &&
                s[key.size()] == '=') {
                s = kv;
                return;
            }
        envv.push_back(kv);
    };
    put_env("EDITOR_DATA_ROOT=" + acct);
    put_env("EDITOR_DISABLE_STEAM_DETECT=1");
    std::vector<char*> envp;
    for (auto& s : envv) envp.push_back(s.data());
    envp.push_back(nullptr);

    pid_t pid = ::fork();
    if (pid < 0) {
        if (logfd >= 0) ::close(logfd);
        *err = std::string("fork failed: ") + std::strerror(errno);
        return 0;
    }
    if (pid == 0) {
        // Child: new session/process group so killpg() cannot hit the
        // gateway; append logs; exec.
        ::setsid();
        if (logfd >= 0) {
            if (logfd != 1) ::dup2(logfd, 1);
            if (logfd != 2) ::dup2(logfd, 2);
        }
        if (logfd > 2) ::close(logfd);
        ::execv(argv.front().c_str(), argvp.data());
        _exit(127);
    }
    if (logfd >= 0) ::close(logfd);
    in->pid = pid;

    auto t0 = std::chrono::steady_clock::now();
    int port = 0;
    while (std::chrono::steady_clock::now() - t0 < kPortWait) {
        int status = 0;
        pid_t r = ::waitpid(pid, &status, WNOHANG);
        if (r == pid) {
            in->pid = 0;
            *err = "backend instance for '" + in->name + "' exited before binding";
            return 0;
        }
        if (auto p = read_port_file(port_file)) {
            port = *p;
            break;
        }
        sleep_ms(50);
    }
    if (port == 0) {
        *err = "backend instance for '" + in->name + "' did not write port file in 10s";
        return 0;
    }
    in->port = port;

    // Ready-check: /api/ping answers 200 once the instance is usable. A
    // connection refused in this window is normal (backlog not yet accepting).
    t0 = std::chrono::steady_clock::now();
    while (std::chrono::steady_clock::now() - t0 < kPingWait) {
        if (ping_port(port, 1.0)) return port;
        int status = 0;
        if (::waitpid(pid, &status, WNOHANG) == pid) {
            in->pid = 0;
            in->port = 0;
            *err = "backend instance for '" + in->name + "' died during startup";
            return 0;
        }
        sleep_ms(100);
    }
    *err = "backend instance for '" + in->name + "' port " + std::to_string(port) +
           " did not answer /api/ping";
    return 0;
}

// Eviction, done synchronously by the caller BEFORE it holds its own
// instance lock: mark the LRU idle victim detached + erase it from the map
// (so no new request routes to it), hand back the shared_ptr, and the caller
// then locks ONLY the victim's mutex to kill it. Because the caller never
// holds its own instance mutex here, no instance->instance cycle is possible
// (CONVENTIONS 6: pool mu is a leaf w.r.t. instance mu; kills happen with at
// most one instance mu held and never mu_ held across one).
std::shared_ptr<InstancePool::Instance> InstancePool::detach_lru_idle(
    const std::string& self_name) {
    std::lock_guard<std::mutex> lk(mu_);
    std::shared_ptr<Instance> victim;
    for (const auto& [name, in] : map_) {
        if (name == self_name || in->detached) continue;
        if (in->pid <= 0 || in->inflight.load() > 0) continue;
        if (!victim || in->last_seen_ms < victim->last_seen_ms) victim = in;
    }
    if (victim) {
        victim->detached = true;
        map_.erase(victim->name);
    }
    return victim;
}

// The actual kill of a detached victim: locks the victim's mutex (nothing
// else held) and re-adds it if it became busy meanwhile, else stops it.
void InstancePool::retire_detached(std::shared_ptr<Instance> in) {
    std::lock_guard<std::mutex> lk(in->mu);
    if (in->starting || in->inflight.load() > 0) {
        std::lock_guard<std::mutex> pk(mu_);  // instance -> pool (declared order)
        if (!map_.count(in->name)) {
            in->detached = false;
            map_[in->name] = in;
        }
        return;
    }
    stop_locked(in, /*kill_hard=*/false);
    // Dead already (stopped) or victim; entry is out of the map, next acquire
    // for this name creates a fresh instance.
}

int InstancePool::acquire(const std::string& name, std::string* err) {
    err->clear();
    while (true) {
        std::shared_ptr<Instance> in;
        bool need_slot = false;
        bool at_cap = false;
        {
            std::lock_guard<std::mutex> lk(mu_);
            auto it = map_.find(name);
            if (it == map_.end() || it->second->detached) {
                in = std::make_shared<Instance>();
                in->name = name;
                map_[name] = in;
            } else {
                in = it->second;
            }
            // Capacity is only a concern when we will fork a new process
            // (this instance is not currently live).
            need_slot = (in->pid == 0);
            if (need_slot) {
                int live = 0;
                for (const auto& [k, v] : map_)
                    if (!v->detached && v->pid > 0) ++live;
                at_cap = live >= opts_.max_instances;
            }
        }
        // Eviction happens with NO instance lock held (avoids instance->
        // instance deadlock). Retire the victim synchronously here.
        if (need_slot && at_cap) {
            if (auto victim = detach_lru_idle(name)) {
                retire_detached(victim);
            } else {
                std::fprintf(stderr,
                             "[gateway] instance cap %d reached but all are busy; "
                             "allowing temporary overrun for %s\n",
                             opts_.max_instances, name.c_str());
            }
        }

        std::unique_lock<std::mutex> lk(in->mu);
        if (in->detached) continue;  // reaper/evictor owns it now
        in->starting = true;
        struct Done {
            Instance* p;
            ~Done() { p->starting = false; }
        } done{in.get()};

        if (in->pid > 0) {
            if (alive_locked(*in) && ping_port(in->port, 2.0)) {
                in->last_seen_ms = sa_core::now_ms();
                in->inflight.fetch_add(1);
                return in->port;
            }
            std::fprintf(stderr, "[gateway] recycling dead backend instance for %s\n",
                         name.c_str());
            stop_locked(in, /*kill_hard=*/true);
            // pid now 0: loop so the next pass frees a slot if we're at cap.
            continue;
        }
        std::string start_err;
        int port = start_locked(in, &start_err);
        if (port == 0) {
            stop_locked(in, /*kill_hard=*/true);
            *err = start_err;
            return 0;
        }
        in->last_seen_ms = sa_core::now_ms();
        in->inflight.fetch_add(1);
        return port;
    }
}

void InstancePool::release(const std::string& name) {
    std::shared_ptr<Instance> in;
    {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = map_.find(name);
        if (it != map_.end()) in = it->second;
    }
    if (!in) return;
    std::lock_guard<std::mutex> lk(in->mu);
    int prev = in->inflight.fetch_sub(1);
    if (prev < 0) in->inflight.store(0);
    in->last_seen_ms = sa_core::now_ms();
}

int InstancePool::reap_idle() {
    int stopped = 0;
    std::vector<std::shared_ptr<Instance>> snapshot;
    {
        std::lock_guard<std::mutex> lk(mu_);
        for (const auto& [k, v] : map_)
            if (!v->detached) snapshot.push_back(v);
    }
    const long long cutoff =
        sa_core::now_ms() - static_cast<long long>(opts_.idle_minutes) * 60ll * 1000ll;
    for (auto& in : snapshot) {
        std::unique_lock<std::mutex> lk(in->mu);
        if (in->pid > 0) {
            bool dead = !alive_locked(*in);
            if (dead) {
                std::fprintf(stderr, "[gateway] backend instance for %s exited; reaped\n",
                             in->name.c_str());
                std::lock_guard<std::mutex> pk(mu_);
                auto it = map_.find(in->name);
                if (it != map_.end() && it->second == in) map_.erase(it);
                ++stopped;
                continue;
            }
            if (in->last_seen_ms < cutoff && in->inflight.load() == 0 && !in->starting) {
                std::fprintf(stderr, "[gateway] idling out backend instance for %s\n",
                             in->name.c_str());
                stop_locked(in, /*kill_hard=*/false);
                std::lock_guard<std::mutex> pk(mu_);
                auto it = map_.find(in->name);
                if (it != map_.end() && it->second == in) map_.erase(it);
                ++stopped;
            }
        } else {
            // pid==0 && idle: plain housekeeping of the dead record.
            std::lock_guard<std::mutex> pk(mu_);
            auto it = map_.find(in->name);
            if (it != map_.end() && it->second == in && in->inflight.load() == 0)
                map_.erase(it);
        }
    }
    return stopped;
}

void InstancePool::shutdown_all() {
    std::vector<std::shared_ptr<Instance>> all;
    {
        std::lock_guard<std::mutex> lk(mu_);
        for (auto& [k, v] : map_) {
            v->detached = true;
            all.push_back(v);
        }
        map_.clear();
    }
    for (auto& in : all) {
        std::unique_lock<std::mutex> lk(in->mu);
        stop_locked(in, /*kill_hard=*/true);
    }
}

int InstancePool::live_count() {
    std::lock_guard<std::mutex> lk(mu_);
    int n = 0;
    for (auto& [k, v] : map_)
        if (!v->detached && v->pid > 0) ++n;
    return n;
}

int InstancePool::peek_port(const std::string& name) {
    std::shared_ptr<Instance> in;
    {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = map_.find(name);
        if (it == map_.end() || it->second->detached) return 0;
        in = it->second;
    }
    std::lock_guard<std::mutex> slk(in->mu);  // instance -> nothing (pool mu released)
    return in->port;
}

std::string InstancePool::peek_token(const std::string& name) {
    std::shared_ptr<Instance> in;
    {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = map_.find(name);
        if (it == map_.end() || it->second->detached) return {};
        in = it->second;
    }
    std::lock_guard<std::mutex> slk(in->mu);
    return in->token;
}

}  // namespace gw

#endif  // !_WIN32
