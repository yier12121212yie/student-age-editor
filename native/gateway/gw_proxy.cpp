// gateway/gw_proxy.cpp — see gw_proxy.h.
#include "gw_proxy.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <utility>

#include "sa_core/http_client.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"

namespace http = sa_core::http;

namespace gw {
namespace {

sa::Resp err_json(int status, const char* message) {
    return sa::Resp::Json(status, sa::json{{"error", message}});
}

bool under(std::string_view path, std::string_view pfx) {
    return path == pfx ||
           (path.size() > pfx.size() + 1 && path.compare(0, pfx.size(), pfx) == 0 &&
            path[pfx.size()] == '/');
}

// 登录限速参数（安全批次 A）：60 秒滑动窗口 10 次失败 → 锁 5 分钟。
constexpr long long kFailWindowMs = 60ll * 1000;
constexpr int kMaxFailsPerWindow = 10;
constexpr long long kLockoutMs = 5ll * 60 * 1000;

long long now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// Resolve bearer -> account. On failure returns false with the 401 to send.
bool bearer_account(Gateway& g, const sa::Req& req, std::string* account,
                    std::string* token_out) {
    std::string token;
    if (!parse_bearer(req.authorization_header, &token)) return false;
    Sessions::Info info;
    if (!g.sessions->check(token, &info)) return false;
    if (account) *account = info.name;
    if (token_out) *token_out = token;
    return true;
}

}  // namespace

// --------------------------------------------------------------------------
// Pure helpers.

bool LoginRateLimiter::allow(const std::string& name) {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = by_name_.find(name);
    if (it == by_name_.end()) return true;
    const long long now = now_ms();
    if (it->second.locked_until_ms > now) return false;
    // 窗口过期：失败计数随窗口滑出自然清零（锁定时间独立计时）。
    auto& f = it->second.fails_ms;
    while (!f.empty() && f.front() <= now - kFailWindowMs) f.pop_front();
    return true;
}

void LoginRateLimiter::record_fail(const std::string& name) {
    std::lock_guard<std::mutex> lk(mu_);
    Entry& e = by_name_[name];
    const long long now = now_ms();
    e.fails_ms.push_back(now);
    while (!e.fails_ms.empty() && e.fails_ms.front() <= now - kFailWindowMs)
        e.fails_ms.pop_front();
    if (static_cast<int>(e.fails_ms.size()) >= kMaxFailsPerWindow) {
        e.locked_until_ms = now + kLockoutMs;
        e.fails_ms.clear();  // 锁定期间不再累积，解锁后从零计数
        std::fprintf(stderr,
                     "[gateway] login rate limit: '%s' locked for 5 min "
                     "(%d failures in 60s)\n",
                     name.c_str(), kMaxFailsPerWindow);
    }
}

void LoginRateLimiter::record_success(const std::string& name) {
    std::lock_guard<std::mutex> lk(mu_);
    by_name_.erase(name);
}

bool endpoint_banned(const std::string& method, const std::string& path) {
    // Prefixes disabled in hosted mode (any method). Derived from the M2
    // brief + grep of ai_image.cpp/tts.cpp generation and settings routes:
    //   /api/shutdown         — never proxy a process-killer
    //   /api/plugins/service  — §4 plugin SSRF surface
    //   /api/plugins/agent    — arbitrary tool exec
    //   /api/tts              — all TTS (gen + settings): platform never pays
    //   /api/oobe             — OOBE rewrites workspace root
    //   /api/ai/image         — image generate/edit (ai_image.cpp)
    //   /api/ai/settings      — user's own AI key must never land on the box
    static const char* kPrefixes[] = {"/api/shutdown", "/api/plugins/service",
                                      "/api/plugins/agent", "/api/tts", "/api/oobe",
                                      "/api/ai/image", "/api/ai/settings"};
    for (const char* p : kPrefixes)
        if (under(path, p)) return true;
    // Workspace root is method-specific: only POST /api/workspace (and any
    // subpath) mutates the sandbox root; GET /api/workspace/status stays open.
    if (method == "POST" && under(path, "/api/workspace")) return true;
    // 全量导入端点（安全批次 A）：这些端点接受调用方提供的任意本机文件系统
    // 路径，托管模式下等于把宿主机任意文件读进账号沙箱（sandbox 逃逸/
    // 任意文件读取原语）。Web 通道的安全等价物是 *_upload（字节走 body）。
    static const char* kPathImportPrefixes[] = {
        "/api/plugins/install_path",       // plugins_routes.cpp: install_plugin_from_path
        "/api/resource_packs/import_path", // p3b_domain_tools_routes.cpp: 同型
        "/api/mod/import_files",           // mod_files_routes.cpp: files[] 本机路径
    };
    for (const char* p : kPathImportPrefixes)
        if (under(path, p)) return true;
    return false;
}

bool model_allowed(const std::vector<std::string>& models, const std::string& requested) {
    if (models.empty()) return true;              // unrestricted
    if (requested.empty()) return true;           // resolves to admin default
    for (const auto& m : models)
        if (m == requested) return true;
    return false;
}

const Account* check_login(Config& cfg, const std::string& name,
                           const std::string& password, bool* disabled,
                           std::string* upgraded_line) {
    if (disabled) *disabled = false;
    if (upgraded_line) upgraded_line->clear();
    const Account* a = cfg.find_account(name);
    if (!a) {
        // Burn comparable time even for an unknown account so a 401's latency
        // does not leak which usernames exist. v2 是现行主流成本（100k 轮
        // PBKDF2），用同量级 dummy 保证时序对齐。
        std::string dummy = password_hash_v2(
            "00000000000000000000000000000000", password, kKdfIterationsDefault);
        volatile bool r = secure_equals(dummy, std::string(64, '0'));
        (void)r;
        return nullptr;
    }
    if (!is_hex_lower(a->salt, 32) || !is_hex_lower(a->password_sha256, 64))
        return nullptr;
    bool ok = false;
    bool upgraded = false;
    if (a->kdf_version == kKdfVersion2) {
        int it = a->kdf_iterations > 0 ? a->kdf_iterations : kKdfIterationsDefault;
        ok = secure_equals(password_hash_v2(a->salt, password, it),
                           a->password_sha256);
    } else {
        // v1（legacy sha256(salt+pw)）：命中后透明升级到 v2 —— 只更新内存
        // 中的账号记录并回传新哈希行，gateway.json 的持久化由管理员完成。
        ok = secure_equals(password_hash(a->salt, password), a->password_sha256);
        if (ok) {
            Account* mutable_a = const_cast<Account*>(cfg.find_account(name));
            mutable_a->kdf_version = kKdfVersion2;
            mutable_a->kdf_iterations = kKdfIterationsDefault;
            mutable_a->password_sha256 =
                password_hash_v2(a->salt, password, kKdfIterationsDefault);
            upgraded = true;
            if (upgraded_line)
                *upgraded_line = a->salt + ":" + mutable_a->password_sha256;
        }
    }
    if (!ok) return nullptr;
    if (upgraded) {
        std::fprintf(stderr,
                     "[gateway] account '%s' password transparently upgraded to "
                     "PBKDF2 (v2, %d iterations). New line for gateway.json "
                     "(salt/password_sha256/kdf_version/kdf_iterations):\n  %s\n"
                     "  \"kdf_version\": 2, \"kdf_iterations\": %d\n",
                     name.c_str(), kKdfIterationsDefault, upgraded_line ? upgraded_line->c_str() : "",
                     kKdfIterationsDefault);
    }
    if (a->disabled) {
        if (disabled) *disabled = true;
        return nullptr;
    }
    return a;
}

sa::ai_relay::RelaySettings resolve_relay(const Config& cfg) {
    // Feed the shared ai_relay mapper the same key names the local backend's
    // env_store_ai produces (provider/baseUrl/apiKey/model).
    sa::json ai;
    ai["provider"] = cfg.ai.provider;
    ai["baseUrl"] = cfg.ai.base_url;
    ai["apiKey"] = cfg.ai.api_key;
    ai["model"] = cfg.ai.model;
    sa::ai_relay::RelaySettings s = sa::ai_relay::read_settings_from_ai(ai);
    if (!cfg.ai.enabled) s.usable = false;  // admin kill-switch wins
    return s;
}

// --------------------------------------------------------------------------
// Route registration.

void register_gateway_routes(sa::Router& r, Gateway& g) {
    // ---- POST /api/auth/login --------------------------------------------
    r.post(R"(/api/auth/login)", [&g](const sa::Req& req) -> sa::Resp {
        std::string name, password;
        if (req.body.is_object()) {
            if (req.body.contains("name") && req.body.at("name").is_string())
                name = req.body.at("name").get<std::string>();
            if (req.body.contains("password") && req.body.at("password").is_string())
                password = req.body.at("password").get<std::string>();
        }
        // 滑动窗口限速（安全批次 A）：锁定中的账号直接 429，不进入昂贵的
        // PBKDF2 校验（既挡在线爆破也挡 DoS 式的 KDF 算力耗尽）。
        if (!g.login_limiter.allow(name))
            return err_json(429, "too many failed logins; retry in 5 minutes");
        std::string upgraded_line;
        bool disabled = false;
        const Account* a = check_login(g.cfg, name, password, &disabled,
                                       &upgraded_line);
        if (!a) {
            g.login_limiter.record_fail(name);
            if (disabled) return err_json(403, "account disabled");
            return err_json(401, "invalid credentials");
        }
        g.login_limiter.record_success(name);
        std::string token = g.sessions->issue(a->name);
        sa::json out;
        out["token"] = token;
        out["name"] = a->name;
        out["expires_in"] = g.cfg.session_ttl_hours * 3600LL;
        return sa::Resp::Json(200, std::move(out));
    });

    // ---- GET /api/auth/whoami --------------------------------------------
    r.get(R"(/api/auth/whoami)", [&g](const sa::Req& req) -> sa::Resp {
        std::string account;
        if (!bearer_account(g, req, &account, nullptr))
            return err_json(401, "unauthorized");
        return sa::Resp::Json(200, sa::json{{"name", account}});
    });

    // ---- POST /api/auth/logout -------------------------------------------
    r.post(R"(/api/auth/logout)", [&g](const sa::Req& req) -> sa::Resp {
        std::string token;
        if (!parse_bearer(req.authorization_header, &token))
            return err_json(401, "unauthorized");
        std::string account;
        if (!bearer_account(g, req, &account, nullptr))
            return err_json(401, "unauthorized");
        g.sessions->logout(token);
        return sa::Resp::Json(200, sa::json{{"ok", true}});
    });

    // ---- GET /api/ai/policy ----------------------------------------------
    // Bearer-gated like every non-auth /api endpoint ("其它所有 /api/* 一律
    // 先过 Bearer 会话"): the login screen does not need it; the editor does.
    r.get(R"(/api/ai/policy)", [&g](const sa::Req& req) -> sa::Resp {
        std::string account;
        if (!bearer_account(g, req, &account, nullptr))
            return err_json(401, "unauthorized");
        return sa::Resp::Json(
            200, sa::ai_relay::policy_json(g.relay, /*own_key_allowed=*/true,
                                           /*tts_image_available=*/false, g.cfg.ai.models,
                                           g.cfg.ai.daily_limit));
    });

    // ---- POST /api/ai/relay/chat -----------------------------------------
    r.post(R"(/api/ai/relay/chat)", [&g](const sa::Req& req) -> sa::Resp {
        std::string account;
        if (!bearer_account(g, req, &account, nullptr))
            return err_json(401, "unauthorized");
        if (!g.relay.usable) return err_json(503, "ai relay not configured");
        std::string requested;
        if (req.body.is_object() && req.body.contains("model") &&
            req.body.at("model").is_string())
            requested = req.body.at("model").get<std::string>();
        if (!model_allowed(g.cfg.ai.models, requested))
            return err_json(400, "model not allowed");
        if (g.cfg.ai.daily_limit > 0 && g.usage && g.usage->over_limit(account))
            return err_json(429, "daily quota exceeded");
        sa::Resp up = sa::ai_relay::relay_chat(g.relay, req.body);
        // Charge the quota only for a completed round (a 4xx/5xx from the
        // provider or the SSRF guards did not deliver service).
        if (up.status >= 200 && up.status < 400 && g.usage) g.usage->record(account);
        return up;
    });

    // ---- reverse proxy catch-all for everything else under /api ----------
    auto proxy = [&g](const sa::Req& req) -> sa::Resp {
        std::string account;
        if (!bearer_account(g, req, &account, nullptr))
            return err_json(401, "unauthorized");
        if (endpoint_banned(req.method, req.path))
            return err_json(403, "endpoint disabled in hosted mode");
        // httpd keeps raw_body only up to 8 MiB. A POST/PUT that parsed a
        // non-empty body but whose raw bytes were dropped means the request
        // exceeded what the proxy can faithfully replay -> refuse it.
        const bool bodyful = (req.method == "POST" || req.method == "PUT");
        if (bodyful && req.raw_body.empty() && !req.body.is_null())
            return err_json(413, "body too large for proxy");
#ifndef _WIN32
        std::string perr;
        int port = g.pool ? g.pool->acquire(account, &perr) : 0;
        if (port == 0) {
            std::fprintf(stderr, "[gateway] proxy %s %s for %s -> no instance: %s\n",
                         req.method.c_str(), req.path.c_str(), account.c_str(),
                         perr.c_str());
            return err_json(502, "backend unavailable");
        }
        struct Release {
            InstancePool* p;
            std::string acct;
            ~Release() {
                if (p) p->release(acct);
            }
        } rel{g.pool.get(), account};

        http::Request hr;
        hr.method = req.method;
        hr.url = "http://127.0.0.1:" + std::to_string(port) + http::quote_component(req.path);
        if (!req.raw_query.empty()) hr.url += "?" + req.raw_query;
        hr.body = req.raw_body;
        hr.timeout_seconds = 300.0;
        hr.bypass_proxy = true;
        hr.follow_redirects = false;
        if (!req.raw_body.empty()) hr.headers.emplace_back("Content-Type", "application/json");
        // 安全批次 B：backend 实例启用进程令牌后，代理跳必须携带
        // X-Backend-Token（令牌只在网关与 fork 的 backend 之间流转）。
        {
            const std::string backend_token = g.pool->peek_token(account);
            if (!backend_token.empty())
                hr.headers.emplace_back("X-Backend-Token", backend_token);
        }
        // NOTE: the inbound Authorization header is intentionally NOT forwarded
        // (end-user credentials never reach the forked backend; the proxy hop
        // authenticates with the per-instance X-Backend-Token above).
        http::Response hs = http::request(hr);
        if (!hs.transport_ok()) {
            std::fprintf(stderr, "[gateway] proxy %s %s -> transport error: %s\n",
                         req.method.c_str(), req.path.c_str(), hs.error_message.c_str());
            return err_json(502, "backend unavailable");
        }
        std::string ct = hs.header("Content-Type");
        if (ct.empty()) ct = "application/json";
        return sa::Resp::BytesTyped(hs.status, std::move(hs.body), std::move(ct));
#else
        return err_json(502, "backend unavailable");  // gateway is POSIX-only
#endif
    };
    r.get(R"(/api(?:/.*)?)", proxy);
    r.post(R"(/api(?:/.*)?)", proxy);
    r.put(R"(/api(?:/.*)?)", proxy);
    r.del(R"(/api(?:/.*)?)", proxy);
}

}  // namespace gw
