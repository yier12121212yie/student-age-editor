// gateway/gw_proxy: the gateway's own endpoints + the authenticated reverse
// proxy catch-all (网页版计划 M2.1/M2.3).
//
// Endpoint ownership (all registered BEFORE the /api/* proxy catch-all so the
// ordered Router picks them first):
//   POST /api/auth/login    — verify credentials, mint a Bearer session.
//   GET  /api/auth/whoami   — Bearer -> {name}.
//   POST /api/auth/logout   — Bearer -> drop the token.
//   GET  /api/ai/policy     — Bearer; supply policy from gateway.json ai_relay.
//   POST /api/ai/relay/chat — Bearer; whitelist + per-day quota; ai_relay relay.
//   <anything else /api/*>  — Bearer gate, then banned-path filter, then
//                             reverse proxy to the account's lazy backend.
#pragma once

#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "server/httpd.h"
#include "server/services/ai_relay_routes.h"

#include "gw_config.h"
#include "gw_sessions.h"
#include "gw_usage.h"

#ifndef _WIN32
#include "gw_pool.h"
#endif

namespace gw {

// 登录滑动窗口限速（安全批次 A）：按账号名计数，60 秒窗口内累计 10 次
// 失败 → 锁定 5 分钟；成功登录清零。仅内存态（重启即释放，够挡在线爆破；
// 离线爆破由 PBKDF2 成本墙挡）。线程安全。
struct LoginRateLimiter {
    // 允许发起本次校验吗？锁定中的账号返回 false（调用方直接 429）。
    bool allow(const std::string& name);
    // 记录一次失败；触发锁定后后续 allow() 返回 false。
    void record_fail(const std::string& name);
    // 成功登录：清空该账号计数。
    void record_success(const std::string& name);

   private:
    struct Entry {
        std::deque<long long> fails_ms;  // 窗口内失败时间戳（升序，滑出即弃）
        long long locked_until_ms = 0;
    };
    std::mutex mu_;
    std::map<std::string, Entry> by_name_;
};

// The assembled gateway runtime. Owned by main(), shared (by pointer) with the
// route handlers captured in the Router's std::function closures.
struct Gateway {
    Config cfg;
    std::unique_ptr<Sessions> sessions;
    std::unique_ptr<UsageStore> usage;
    sa::ai_relay::RelaySettings relay;  // resolved from cfg.ai (usable gated)
    LoginRateLimiter login_limiter;     // 登录滑动窗口限速（安全批次 A）
#ifndef _WIN32
    std::unique_ptr<InstancePool> pool;
#endif
    Gateway() = default;
    Gateway(const Gateway&) = delete;
    Gateway& operator=(const Gateway&) = delete;
};

// Register auth + ai self endpoints and the /api/* proxy catch-all. Static
// hosting (if web_root exists) is registered separately by main() AFTER this,
// mirroring run.cpp's "static last" ordering.
void register_gateway_routes(sa::Router& r, Gateway& gwctx);

// ---------------------------------------------------------------------------
// Pure, individually testable helpers (no I/O, no process):

// Hosted-mode endpoint ban list. `path` is the decoded request path. Returns
// true when the proxy must answer 403 (endpoint disabled). Method matters:
// POST /api/workspace is banned (would rewrite the account's workspace root)
// but GET /api/workspace/status is allowed.
bool endpoint_banned(const std::string& method, const std::string& path);

// Model whitelist enforcement: empty `models` == unrestricted (any model,
// including the empty/omitted one -> relay fills the admin default). When a
// whitelist is configured, a non-empty requested model must match exactly; an
// empty requested model is allowed (it resolves to the admin default).
bool model_allowed(const std::vector<std::string>& models, const std::string& requested);

// Validate stored credentials and run the constant-time hash compare. Returns
// the account on success, nullptr when name/password are wrong. Sets
// *disabled_true when the account exists, authenticated, but is disabled.
//
// KDF 版本化（安全批次 A）：v1 账号（legacy sha256）命中后透明升级到 v2
// PBKDF2 —— 只升级内存中的 Account（新哈希/迭代数就地写回 cfg），并把可
// 直接粘贴进 gateway.json 的 `salt:hash` 行填入 *upgraded_line（非空时），
// 由调用方落日志提醒管理员持久化。upgraded_line 可为 nullptr。
const Account* check_login(Config& cfg, const std::string& name,
                           const std::string& password, bool* disabled,
                           std::string* upgraded_line = nullptr);

// Build the gateway's RelaySettings from its own ai_relay config: reads via
// the shared ai_relay mapping, then forces usable=false when the section is
// disabled (so policy reports and relay both honour the admin kill-switch).
sa::ai_relay::RelaySettings resolve_relay(const Config& cfg);

}  // namespace gw
