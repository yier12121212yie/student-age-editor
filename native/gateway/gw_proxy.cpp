// gateway/gw_proxy.cpp — see gw_proxy.h.
#include "gw_proxy.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <utility>

#include "sa_core/http_client.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"

namespace http = sa_core::http;

namespace gw {
namespace {

sa::Resp err_json(int status, const char* message) {
    return sa::Resp::Json(status, sa::json{{"error", message}});
}

// 带稳定 code 的错误信封：前端按 code 映射本地化文案，避免匹配英文 error。
sa::Resp err_code(int status, const char* message, const char* code) {
    return sa::Resp::Json(status,
                          sa::json{{"error", message}, {"code", code}});
}

bool under(std::string_view path, std::string_view pfx) {
    return path == pfx ||
           (path.size() > pfx.size() + 1 && path.compare(0, pfx.size(), pfx) == 0 &&
            path[pfx.size()] == '/');
}

// 解析请求体里的 "remember"（真值语义：bool true 或字符串 "true"）。
bool body_remember(const sa::json& body) {
    if (!body.is_object() || !body.contains("remember")) return false;
    const auto& v = body.at("remember");
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_string()) return sa_core::str::lower(v.get<std::string>()) == "true";
    return false;
}

// 签发一次登录/注册/刷新结果：内存 access 会话 + （可选）refresh token。
// remember=true 时 refresh token 走长期有效期（refresh_ttl_days）并落盘，
// 否则与 access 会话同寿且仅内存（关闭浏览器即失效）。g.refresh 为空
// （测试/未装配）时只签发 access 会话。
void issue_session_tokens(Gateway& g, const std::string& name, bool remember,
                          sa::json* out) {
    const long long access_ttl_s = g.cfg.session_ttl_hours * 3600LL;
    (*out)["token"] = g.sessions->issue(name);
    (*out)["name"] = name;
    (*out)["expires_in"] = access_ttl_s;
    if (!g.refresh) return;
    const long long session_ttl_ms = access_ttl_s * 1000LL;
    const long long refresh_ttl_ms =
        remember ? g.cfg.refresh_ttl_days * 86400LL * 1000LL : session_ttl_ms;
    (*out)["refresh_token"] = g.refresh->issue(name, refresh_ttl_ms, remember);
    (*out)["refresh_expires_in"] = refresh_ttl_ms / 1000;
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
        "/api/extensions/install_path",    // 扩展合并：同型本机路径安装
        "/api/resource_packs/import_path", // p3b_domain_tools_routes.cpp: 同型
        "/api/mod/import_files",           // mod_files_routes.cpp: files[] 本机路径
        "/api/mods/import_path",           // mods_routes.cpp: 模组 zip 本机路径导入
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
        bool remember = false;
        if (req.body.is_object()) {
            if (req.body.contains("name") && req.body.at("name").is_string())
                name = req.body.at("name").get<std::string>();
            if (req.body.contains("password") && req.body.at("password").is_string())
                password = req.body.at("password").get<std::string>();
            remember = body_remember(req.body);
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
        sa::json out;
        issue_session_tokens(g, a->name, remember, &out);
        return sa::Resp::Json(200, std::move(out));
    });

    // ---- POST /api/auth/refresh ------------------------------------------
    // 长期鉴权核心：拿 refresh token 换一对新令牌（旋转，旧的立即失效）。
    // 无需 Bearer —— access token 正是可能已过期的那个。
    r.post(R"(/api/auth/refresh)", [&g](const sa::Req& req) -> sa::Resp {
        std::string refresh_token;
        if (req.body.is_object() && req.body.contains("refresh_token") &&
            req.body.at("refresh_token").is_string())
            refresh_token = req.body.at("refresh_token").get<std::string>();
        if (refresh_token.empty() || !g.refresh)
            return err_code(401, "invalid refresh token", "invalid_refresh");
        // 账号在签发 refresh token 后被停用时，长期凭据必须立刻失效。
        std::string account;
        if (!g.refresh->check(refresh_token, &account))
            return err_code(401, "invalid refresh token", "invalid_refresh");
        const Account* acc = g.cfg.find_account(account);
        if (!acc || acc->disabled) {
            g.refresh->revoke(refresh_token);
            return err_code(403, "account disabled", "account_disabled");
        }
        const long long session_ttl_ms = g.cfg.session_ttl_hours * 3600LL * 1000LL;
        const long long remember_ttl_ms =
            g.cfg.refresh_ttl_days * 86400LL * 1000LL;
        std::string new_refresh;
        long long new_refresh_ttl_ms = session_ttl_ms;
        if (!g.refresh->refresh(refresh_token, remember_ttl_ms, session_ttl_ms,
                                &new_refresh, &account, &new_refresh_ttl_ms))
            return err_code(401, "invalid refresh token", "invalid_refresh");
        sa::json out;
        const long long access_ttl_s = g.cfg.session_ttl_hours * 3600LL;
        out["token"] = g.sessions->issue(account);
        out["name"] = account;
        out["expires_in"] = access_ttl_s;
        out["refresh_token"] = new_refresh;
        out["refresh_expires_in"] = new_refresh_ttl_ms / 1000;
        return sa::Resp::Json(200, std::move(out));
    });

    // ---- GET /api/auth/registration --------------------------------------
    // Public signup policy so the login screen can show/hide the signup form.
    // Never reveals the invite code, only whether one is required.
    r.get(R"(/api/auth/registration)", [&g](const sa::Req& req) -> sa::Resp {
        (void)req;
        const RegistrationCfg& reg = g.cfg.registration;
        sa::json out;
        out["enabled"] = reg.enabled;
        out["invite_required"] = !reg.invite_code.empty();
        out["min_password_length"] = reg.enabled ? reg.min_password_length : 0;
        return sa::Resp::Json(200, std::move(out));
    });

    // ---- POST /api/auth/register -----------------------------------------
    // Self-service signup: admin-gated by registration.enabled, optionally
    // invite-code gated, name/password validated, credential persisted to the
    // registered-accounts file, then a session is issued (auto-login).
    r.post(R"(/api/auth/register)", [&g](const sa::Req& req) -> sa::Resp {
        const RegistrationCfg& reg = g.cfg.registration;
        if (!reg.enabled) return err_code(403, "registration disabled",
                                          "registration_disabled");
        std::string name, password, invite;
        if (req.body.is_object()) {
            if (req.body.contains("name") && req.body.at("name").is_string())
                name = req.body.at("name").get<std::string>();
            if (req.body.contains("password") && req.body.at("password").is_string())
                password = req.body.at("password").get<std::string>();
            if (req.body.contains("invite_code") && req.body.at("invite_code").is_string())
                invite = req.body.at("invite_code").get<std::string>();
        }
        const bool remember = body_remember(req.body);
        // 限速复用登录限速器（固定键）：挡邀请码爆破与重复注册尝试，
        // 同时挡 PBKDF2 算力耗尽。成功即清零。
        static const char kRegKey[] = "__register__";
        if (!g.login_limiter.allow(kRegKey))
            return err_code(429, "too many attempts; retry later", "rate_limited");
        if (!valid_account_name(name)) {
            g.login_limiter.record_fail(kRegKey);
            return err_code(400, "invalid account name", "invalid_name");
        }
        if (static_cast<int>(password.size()) < reg.min_password_length) {
            g.login_limiter.record_fail(kRegKey);
            return err_code(400, "password too short", "weak_password");
        }
        if (!reg.invite_code.empty() &&
            !secure_equals(invite, reg.invite_code)) {
            g.login_limiter.record_fail(kRegKey);
            return err_code(403, "invalid invite code", "invalid_invite");
        }
        if (!g.accounts)
            return err_code(500, "registration unavailable", "server_error");
        Account created;
        {
            // 原子化「重名检查 + 上限检查 + 落盘 + 并入运行时 cfg」。
            std::lock_guard<std::mutex> lk(g.accounts_mu);
            if (g.cfg.find_account(name)) {
                g.login_limiter.record_fail(kRegKey);
                return err_code(409, "account already exists", "name_taken");
            }
            if (reg.max_accounts > 0 &&
                static_cast<int>(g.cfg.accounts.size()) >= reg.max_accounts) {
                g.login_limiter.record_fail(kRegKey);
                return err_code(403, "account limit reached", "account_limit");
            }
            std::string aerr;
            if (!g.accounts->add(name, password, &created, &aerr)) {
                g.login_limiter.record_fail(kRegKey);
                std::fprintf(stderr, "[gateway] register '%s' failed: %s\n",
                             name.c_str(), aerr.c_str());
                // 同名已存在（文件与内存竞态）也给 409，其余按服务端错误。
                if (aerr == "account already exists")
                    return err_code(409, "account already exists", "name_taken");
                return err_code(500, "registration failed", "server_error");
            }
            g.cfg.accounts.push_back(created);
        }
        // 工作区目录先建好（进程池启动时也会兜底创建）。
        sa_core::paths::create_dirs(created.dir);
        g.login_limiter.record_success(kRegKey);
        std::fprintf(stderr, "[gateway] registered account '%s'\n", name.c_str());
        sa::json out;
        issue_session_tokens(g, created.name, remember, &out);
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
    // 吊销 access 会话（Bearer）与 refresh token（body）。access 已过期时
    // 仍允许仅凭 refresh token 登出（否则“登出”会留下长期凭据继续有效）；
    // 二者都没有/都无效才 401。
    r.post(R"(/api/auth/logout)", [&g](const sa::Req& req) -> sa::Resp {
        std::string token, account;
        const bool bearer_ok = parse_bearer(req.authorization_header, &token) &&
                               bearer_account(g, req, &account, nullptr);
        std::string refresh_token;
        if (req.body.is_object() && req.body.contains("refresh_token") &&
            req.body.at("refresh_token").is_string())
            refresh_token = req.body.at("refresh_token").get<std::string>();
        bool refresh_revoked = false;
        if (g.refresh && !refresh_token.empty())
            refresh_revoked = g.refresh->revoke(refresh_token);
        if (bearer_ok) g.sessions->logout(token);
        if (!bearer_ok && !refresh_revoked)
            return err_json(401, "unauthorized");
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
