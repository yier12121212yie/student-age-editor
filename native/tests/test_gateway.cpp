// tests/test_gateway.cpp — [gateway] suite for backend_gateway (网页版计划 M2).
//
// The whole file is `#ifndef _WIN32`: on Windows it compiles to an empty
// translation unit, so build.cmd's shared sa_tests binary is byte-for-byte
// unaffected (it links no sa_gateway and defines none of these symbols). On
// POSIX (WSL/Linux) it exercises the gateway's platform-neutral logic
// in-process — config parse/validate, password hashing + --hash-password
// format, session issue/verify/expiry/logout, the reverse-proxy ban table
// (every method+path combination), the AI model whitelist + per-UTC-day quota
// (temp dir), and policy_json — plus a real end-to-end [integration] case that
// boots a per-account backend and drives it through the proxy.
//
// The [integration] case only runs when EDITOR_GATEWAY_BACKEND_EXE points at a
// built `backend` binary; otherwise it SKIPs so a plain `[gateway]` run stays
// fast and dependency-free.
#include <catch_amalgamated.hpp>

#ifndef _WIN32

#include <sys/stat.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>

#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/sha256.h"
#include "sa_core/util.h"

#include "gateway/gw_config.h"
#include "gateway/gw_pool.h"
#include "gateway/gw_proxy.h"
#include "gateway/gw_sessions.h"
#include "gateway/gw_usage.h"
#include "server/httpd.h"

namespace fs = std::filesystem;
using namespace std::chrono_literals;

namespace {

std::filesystem::path tmp_root(const std::string& tag) {
    static std::atomic<int> n{0};
    auto p = fs::temp_directory_path() /
             ("gwtest_" + tag + "_" + std::to_string(++n) + "_" +
              std::to_string(sa_core::now_ms()));
    std::error_code ec;
    fs::remove_all(p, ec);
    fs::create_directories(p);
    return p;
}

// Build a Config with one or more accounts (password default "pw").
gw::Config base_config(const std::string& pw = "pw") {
    gw::Config cfg;
    cfg.user_data_root = "/tmp/gwtest_root";
    cfg.listen_port = 8770;
    cfg.session_ttl_hours = 24;
    cfg.instance_max = 4;
    cfg.idle_minutes = 30;
    cfg.state_dir = "/tmp/gwtest_root/.gateway";
    gw::Account a;
    a.name = "alice";
    a.salt = gw::random_salt_hex();
    a.password_sha256 = gw::password_hash(a.salt, pw);
    a.dir = "/tmp/gwtest_root/alice";
    cfg.accounts.push_back(a);
    return cfg;
}

struct RouteHarness {
    gw::Gateway g;
    sa::Router router;
    explicit RouteHarness(gw::Config cfg) {
        g.cfg = std::move(cfg);
        g.sessions = std::make_unique<gw::Sessions>(g.cfg.session_ttl_hours * 3600LL * 1000LL);
        g.usage = std::make_unique<gw::UsageStore>("/tmp/unused_usage.json",
                                                   g.cfg.ai.daily_limit);
        g.relay = gw::resolve_relay(g.cfg);
        gw::register_gateway_routes(router, g);
    }
    sa::Resp call(const std::string& method, const std::string& path, sa::json body = nullptr,
                  const std::string& bearer = "", const std::string& raw_body = "") {
        sa::Req req;
        req.method = method;
        req.path = path;
        req.body = std::move(body);
        req.authorization_header = bearer;
        req.raw_body = raw_body;
        return router.dispatch(req);
    }
};

std::string body_of(const sa::Resp& r) {
    return r.is_bytes ? r.bytes : sa_core::py_dumps(r.json_payload);
}

}  // namespace

// ---------------------------------------------------------------------------
// Config parse + validation.

TEST_CASE("gateway config: minimal valid parses", "[gateway]") {
    sa::json j;
    j["user_data_root"] = "/srv/data";
    j["listen_port"] = 9000;
    j["session_ttl_hours"] = 12;
    j["instance"] = {{"max", 3}, {"idle_minutes", 15}};
    sa::json acc = sa::json::array();
    gw::Account a;
    a.salt = gw::random_salt_hex();
    a.password_sha256 = gw::password_hash(a.salt, "secret");
    acc.push_back({{"name", "bob"}, {"salt", a.salt}, {"password_sha256", a.password_sha256}});
    j["accounts"] = acc;

    gw::Config cfg;
    std::string err;
    REQUIRE(gw::parse_config(j, &cfg, &err));
    CHECK(cfg.listen_port == 9000);
    CHECK(cfg.session_ttl_hours == 12);
    CHECK(cfg.instance_max == 3);
    CHECK(cfg.idle_minutes == 15);
    CHECK(cfg.state_dir == "/srv/data/.gateway");  // defaulted
    REQUIRE(cfg.accounts.size() == 1);
    CHECK(cfg.accounts[0].dir == "/srv/data/bob");  // defaulted under root
    CHECK(cfg.accounts[0].password_sha256 == a.password_sha256);
}

TEST_CASE("gateway config: validation failures", "[gateway]") {
    auto fail = [](sa::json j, const std::string& needle) {
        gw::Config cfg;
        std::string err;
        CHECK_FALSE(gw::parse_config(j, &cfg, &err));
        CAPTURE(err);
        CHECK(err.find(needle) != std::string::npos);
    };
    sa::json ok;
    ok["user_data_root"] = "/srv/data";
    sa::json acc = sa::json::array();
    acc.push_back({{"name", "a"}, {"salt", std::string(32, '0')},
                   {"password_sha256", std::string(64, '0')}});
    ok["accounts"] = acc;

    sa::json no_root = ok;
    no_root.erase("user_data_root");
    fail(no_root, "user_data_root");

    sa::json rel = ok;
    rel["user_data_root"] = "relative/path";
    fail(rel, "absolute");

    sa::json empty_acc = ok;
    empty_acc["accounts"] = sa::json::array();
    fail(empty_acc, "empty");

    sa::json bad_salt = ok;
    bad_salt["accounts"][0]["salt"] = "XYZ";
    fail(bad_salt, "salt");

    sa::json bad_hash = ok;
    bad_hash["accounts"][0]["password_sha256"] = "tooshort";
    fail(bad_hash, "password_sha256");

    sa::json dup = ok;
    dup["accounts"].push_back(dup["accounts"][0]);
    fail(dup, "duplicate");

    sa::json bad_port = ok;
    bad_port["listen_port"] = 70000;
    fail(bad_port, "listen_port");

    sa::json zero_max = ok;
    zero_max["instance"] = {{"max", 0}};
    fail(zero_max, "instance.max");
}

TEST_CASE("gateway config: web_root missing is a warning not an error", "[gateway]") {
    sa::json j;
    j["user_data_root"] = "/srv/data";
    j["web_root"] = "/nonexistent/web/root/xyz";
    sa::json acc = sa::json::array();
    acc.push_back({{"name", "a"}, {"salt", std::string(32, '0')},
                   {"password_sha256", std::string(64, '0')}});
    j["accounts"] = acc;
    gw::Config cfg;
    std::string err;
    REQUIRE(gw::parse_config(j, &cfg, &err));
    CHECK_FALSE(cfg.warnings.empty());
}

// ---------------------------------------------------------------------------
// Password hashing + --hash-password output format.

TEST_CASE("gateway password hash: format + verify", "[gateway]") {
    // sha256(salt_hex ++ password), salt used verbatim as ASCII.
    std::string salt = std::string(32, 'a');
    std::string expected = sa_core::sha256_hex(salt + "hunter2");
    CHECK(gw::password_hash(salt, "hunter2") == expected);

    std::string line = gw::hash_password_line("hunter2");
    auto colon = line.find(':');
    REQUIRE(colon != std::string::npos);
    std::string s = line.substr(0, colon), h = line.substr(colon + 1);
    CHECK(gw::is_hex_lower(s, 32));
    CHECK(gw::is_hex_lower(h, 64));
    // 安全批次 A：mint 产出 v2（PBKDF2-HMAC-SHA256）行，verify 走 password_hash_v2
    // 同迭代数；v1 路径仍由上面的 password_hash 断言覆盖。
    CHECK(gw::password_hash_v2(s, "hunter2", gw::kKdfIterationsDefault) == h);
    // random salt differs across calls.
    CHECK(gw::hash_password_line("hunter2") != line);
}

TEST_CASE("gateway secure_equals: length + content", "[gateway]") {
    CHECK(gw::secure_equals("abc", "abc"));
    CHECK_FALSE(gw::secure_equals("abc", "abd"));
    CHECK_FALSE(gw::secure_equals("abc", "abcd"));
    CHECK(gw::secure_equals("", ""));
}

// ---------------------------------------------------------------------------
// Sessions.

TEST_CASE("gateway sessions: issue/verify/logout", "[gateway]") {
    gw::Sessions s(60 * 1000);
    std::string tok = s.issue("alice");
    CHECK(gw::is_hex_lower(tok, 64));  // 256-bit -> 64 hex
    gw::Sessions::Info info;
    REQUIRE(s.check(tok, &info));
    CHECK(info.name == "alice");
    CHECK(s.logout(tok));
    CHECK_FALSE(s.check(tok, &info));   // gone
    CHECK_FALSE(s.logout(tok));         // double logout
    // Unknown token.
    CHECK_FALSE(s.check(std::string(64, 'f'), &info));
}

TEST_CASE("gateway sessions: expiry", "[gateway]") {
    gw::Sessions s(20);  // 20ms ttl
    std::string tok = s.issue("bob");
    std::this_thread::sleep_for(35ms);
    gw::Sessions::Info info;
    CHECK_FALSE(s.check(tok, &info));
    CHECK(s.size() == 0);  // expired entry dropped on access
}

TEST_CASE("gateway parse_bearer", "[gateway]") {
    std::string t;
    CHECK(gw::parse_bearer("Bearer abc", &t));
    CHECK(t == "abc");
    CHECK(gw::parse_bearer("bearer  x  ", &t));  // scheme case-insensitive + trim
    CHECK(t == "x");
    CHECK_FALSE(gw::parse_bearer("", &t));
    CHECK_FALSE(gw::parse_bearer("Basic abc", &t));
    CHECK_FALSE(gw::parse_bearer("Bearer", &t));
    CHECK_FALSE(gw::parse_bearer("Bearer   ", &t));  // empty token
}

// ---------------------------------------------------------------------------
// Ban table (method + path exact).

TEST_CASE("gateway ban table", "[gateway]") {
    // Banned (any method).
    CHECK(gw::endpoint_banned("POST", "/api/shutdown"));
    CHECK(gw::endpoint_banned("GET", "/api/shutdown"));
    CHECK(gw::endpoint_banned("GET", "/api/plugins/service/pid/thing"));
    CHECK(gw::endpoint_banned("POST", "/api/plugins/agent/exec"));
    CHECK(gw::endpoint_banned("GET", "/api/plugins/agent/tools"));
    CHECK(gw::endpoint_banned("POST", "/api/tts/synthesize"));
    CHECK(gw::endpoint_banned("PUT", "/api/tts/settings"));
    CHECK(gw::endpoint_banned("GET", "/api/oobe/status"));
    CHECK(gw::endpoint_banned("POST", "/api/oobe/setup"));
    CHECK(gw::endpoint_banned("POST", "/api/ai/image/generate"));
    CHECK(gw::endpoint_banned("POST", "/api/ai/image/edit"));
    CHECK(gw::endpoint_banned("GET", "/api/ai/settings"));
    CHECK(gw::endpoint_banned("PUT", "/api/ai/settings"));

    // POST /api/workspace banned; GET /api/workspace/status allowed.
    CHECK(gw::endpoint_banned("POST", "/api/workspace"));
    CHECK(gw::endpoint_banned("POST", "/api/workspace/set"));
    CHECK_FALSE(gw::endpoint_banned("GET", "/api/workspace/status"));
    CHECK_FALSE(gw::endpoint_banned("GET", "/api/workspace"));

    // Allowed (must NOT over-match on the '/' boundary).
    CHECK_FALSE(gw::endpoint_banned("GET", "/api/ttswatch"));   // not under /api/tts
    CHECK_FALSE(gw::endpoint_banned("GET", "/api/state"));
    CHECK_FALSE(gw::endpoint_banned("GET", "/api/cfg/SomeCfg"));
    CHECK_FALSE(gw::endpoint_banned("GET", "/api/mods"));
    CHECK_FALSE(gw::endpoint_banned("POST", "/api/plugins/list"));
    // Gateway-owned endpoints never reach the proxy, so the proxy never bans:
    CHECK_FALSE(gw::endpoint_banned("POST", "/api/auth/login"));
    CHECK_FALSE(gw::endpoint_banned("GET", "/api/ai/policy"));
    CHECK_FALSE(gw::endpoint_banned("POST", "/api/ai/relay/chat"));
}

// ---------------------------------------------------------------------------
// Model whitelist.

TEST_CASE("gateway model whitelist", "[gateway]") {
    std::vector<std::string> empty;
    CHECK(gw::model_allowed(empty, "anything"));
    CHECK(gw::model_allowed(empty, ""));
    std::vector<std::string> wl{"gpt-a", "claude-b"};
    CHECK(gw::model_allowed(wl, "gpt-a"));
    CHECK(gw::model_allowed(wl, "claude-b"));
    CHECK_FALSE(gw::model_allowed(wl, "gpt-z"));
    CHECK(gw::model_allowed(wl, ""));  // empty -> admin default, allowed
}

// ---------------------------------------------------------------------------
// Usage / quota (temp dir).

TEST_CASE("gateway usage quota", "[gateway]") {
    auto dir = tmp_root("usage");
    std::string file = (dir / "usage.json").string();
    long long limit = 3;
    std::string day = gw::UsageStore::utc_date_key();

    gw::UsageStore u(file, limit);
    CHECK(u.count_today("alice") == 0);
    CHECK_FALSE(u.over_limit("alice"));
    for (long long i = 0; i < limit; ++i) {
        u.record("alice");
        CHECK(u.count_today("alice") == i + 1);
    }
    CHECK(u.over_limit("alice"));            // 3 >= 3
    CHECK(u.count_today("bob") == 0);        // per-account isolation
    CHECK_FALSE(u.over_limit("bob"));

    // A fresh store reads the same file (persistence across restarts).
    gw::UsageStore u2(file, limit);
    CHECK(u2.count_today("alice") == limit);
    CHECK(u2.over_limit("alice"));

    // daily_limit <= 0 == unlimited, never charges.
    gw::UsageStore unlim(file, 0);
    unlim.record("alice");
    CHECK_FALSE(unlim.over_limit("alice"));

    // date key format (YYYY-MM-DD).
    CHECK(day.size() == 10);
    CHECK(day[4] == '-');
    CHECK(day[7] == '-');
    fs::remove_all(dir);
}

TEST_CASE("gateway usage: corrupt file treated as empty", "[gateway]") {
    auto dir = tmp_root("usage_bad");
    std::string file = (dir / "usage.json").string();
    { std::ofstream f(file); f << "not json{{{"; }
    gw::UsageStore u(file, 5);
    CHECK(u.count_today("x") == 0);
    u.record("x");
    CHECK(u.count_today("x") == 1);  // rewrite recovered it
    fs::remove_all(dir);
}

// ---------------------------------------------------------------------------
// policy_json via resolve_relay (gateway parameter combination).

TEST_CASE("gateway policy: relay off + own-key allowed + tts denied", "[gateway]") {
    gw::Config cfg = base_config();
    cfg.ai.enabled = false;
    cfg.ai.api_key = "sk-admin";
    cfg.ai.provider = "openai_compatible";
    cfg.ai.base_url = "https://api.example/v1";
    cfg.ai.model = "gpt-x";
    cfg.ai.models = {"gpt-x", "gpt-y"};
    cfg.ai.daily_limit = 100;
    auto s = gw::resolve_relay(cfg);
    CHECK_FALSE(s.usable);  // admin disabled kills usability even with a key
    sa::json p = sa::ai_relay::policy_json(s, true, false, cfg.ai.models, cfg.ai.daily_limit);
    CHECK(p["relay_available"] == false);
    CHECK(p["own_key_allowed"] == true);
    CHECK(p["tts_image_available"] == false);
    CHECK(p["stream"] == false);
    CHECK(p["models"].size() == 2);
    CHECK(p["limits"]["daily"] == 100);
}

TEST_CASE("gateway policy: relay on", "[gateway]") {
    gw::Config cfg = base_config();
    cfg.ai.enabled = true;
    cfg.ai.api_key = "sk-admin";
    cfg.ai.provider = "openai_compatible";
    cfg.ai.model = "gpt-x";
    auto s = gw::resolve_relay(cfg);
    CHECK(s.usable);
    sa::json p = sa::ai_relay::policy_json(s, true, false, {}, 0);
    CHECK(p["relay_available"] == true);
    CHECK(p["provider"] == "openai_compatible");
    CHECK(p["model"] == "gpt-x");
    CHECK(p["limits"]["daily"] == 0);
}

// ---------------------------------------------------------------------------
// Endpoints end-to-end through the Router (in-process, no real backend).

TEST_CASE("gateway routes: login/whoami/logout", "[gateway]") {
    RouteHarness h(base_config("pw"));
    // unknown account and wrong password both -> 401 "invalid credentials".
    auto r1 = h.call("POST", "/api/auth/login",
                     sa::json{{"name", "ghost"}, {"password", "pw"}});
    CHECK(r1.status == 401);
    CHECK(sa_core::py_dumps(r1.json_payload).find("invalid credentials") != std::string::npos);

    auto r2 = h.call("POST", "/api/auth/login",
                     sa::json{{"name", "alice"}, {"password", "wrong"}});
    CHECK(r2.status == 401);

    auto ok = h.call("POST", "/api/auth/login",
                     sa::json{{"name", "alice"}, {"password", "pw"}});
    REQUIRE(ok.status == 200);
    std::string tok = ok.json_payload.at("token").get<std::string>();
    CHECK(ok.json_payload.at("name") == "alice");
    CHECK(ok.json_payload.at("expires_in") == 24 * 3600);

    // whoami with the bearer.
    auto w = h.call("GET", "/api/auth/whoami", nullptr, "Bearer " + tok);
    REQUIRE(w.status == 200);
    CHECK(w.json_payload.at("name") == "alice");
    // whoami without bearer.
    CHECK(h.call("GET", "/api/auth/whoami").status == 401);

    // logout, then old token no longer works.
    auto lo = h.call("POST", "/api/auth/logout", nullptr, "Bearer " + tok);
    REQUIRE(lo.status == 200);
    CHECK(lo.json_payload.at("ok") == true);
    CHECK(h.call("GET", "/api/auth/whoami", nullptr, "Bearer " + tok).status == 401);
}

TEST_CASE("gateway routes: disabled account -> 403", "[gateway]") {
    gw::Config cfg = base_config("pw");
    cfg.accounts[0].disabled = true;
    RouteHarness h(std::move(cfg));
    auto r = h.call("POST", "/api/auth/login", sa::json{{"name", "alice"}, {"password", "pw"}});
    CHECK(r.status == 403);
}

TEST_CASE("gateway routes: proxy gate (auth, ban, oversized body)", "[gateway]") {
    RouteHarness h(base_config("pw"));
    std::string tok = h.call("POST", "/api/auth/login",
                             sa::json{{"name", "alice"}, {"password", "pw"}})
                          .json_payload.at("token")
                          .get<std::string>();

    // No bearer on a non-auth/non-ai endpoint -> 401 unauthorized.
    auto noauth = h.call("GET", "/api/cfg/SomeCfg");
    CHECK(noauth.status == 401);
    CHECK(sa_core::py_dumps(noauth.json_payload).find("unauthorized") != std::string::npos);

    // Banned path with valid bearer -> 403 (pool is null here; ban fires first).
    auto banned = h.call("POST", "/api/tts/synthesize", sa::json{{"x", 1}}, "Bearer " + tok);
    CHECK(banned.status == 403);
    CHECK(sa_core::py_dumps(banned.json_payload).find("endpoint disabled in hosted mode") !=
          std::string::npos);

    // Body too large for proxy: POST/PUT with a non-null parsed body but an
    // empty raw_body (httpd dropped >8MiB) -> 413.
    sa::Req big;
    big.method = "POST";
    big.path = "/api/cfg/Big";
    big.body = sa::json{{"k", "v"}};  // parsed, but raw_body was dropped
    big.authorization_header = "Bearer " + tok;
    // raw_body empty by default.
    auto r = h.router.dispatch(big);
    CHECK(r.status == 413);
    CHECK(sa_core::py_dumps(r.json_payload).find("body too large for proxy") != std::string::npos);

    // Proxy with a live session but no pool instance -> 502 backend unavailable.
    auto p502 = h.call("GET", "/api/cfg/SomeCfg", nullptr, "Bearer " + tok);
    CHECK(p502.status == 502);
    CHECK(sa_core::py_dumps(p502.json_payload).find("backend unavailable") != std::string::npos);
}

TEST_CASE("gateway routes: relay chat guards (no network)", "[gateway]") {
    gw::Config cfg = base_config("pw");
    cfg.ai.enabled = true;
    cfg.ai.api_key = "sk-admin";
    cfg.ai.provider = "openai_compatible";
    cfg.ai.models = {"gpt-allow"};
    cfg.ai.daily_limit = 1;
    auto dir = tmp_root("relay");
    RouteHarness h(std::move(cfg));
    h.g.usage = std::make_unique<gw::UsageStore>((dir / "usage.json").string(),
                                                 h.g.cfg.ai.daily_limit);
    std::string tok = h.call("POST", "/api/auth/login",
                             sa::json{{"name", "alice"}, {"password", "pw"}})
                          .json_payload.at("token")
                          .get<std::string>();

    // model not on whitelist -> 400 (checked before any upstream call).
    auto bad = h.call("POST", "/api/ai/relay/chat", sa::json{{"model", "gpt-deny"}},
                      "Bearer " + tok);
    CHECK(bad.status == 400);
    CHECK(sa_core::py_dumps(bad.json_payload).find("model not allowed") != std::string::npos);

    // no bearer -> 401.
    CHECK(h.call("POST", "/api/ai/relay/chat", sa::json{{"model", "gpt-allow"}}).status == 401);

    // Quota is checked before the upstream call; a whitelisted model would
    // reach relay_chat (network), so we only assert the 429 branch by priming
    // the counter past the limit and sending an EMPTY model (which passes the
    // whitelist) so the quota check trips first.
    h.g.usage->record("alice");  // 1 of limit 1 -> over
    auto over = h.call("POST", "/api/ai/relay/chat", sa::json{{"model", ""}}, "Bearer " + tok);
    CHECK(over.status == 429);
    CHECK(sa_core::py_dumps(over.json_payload).find("daily quota exceeded") != std::string::npos);
    fs::remove_all(dir);
}

TEST_CASE("gateway routes: relay not configured -> 503", "[gateway]") {
    RouteHarness h(base_config("pw"));  // ai_relay absent -> disabled
    std::string tok = h.call("POST", "/api/auth/login",
                             sa::json{{"name", "alice"}, {"password", "pw"}})
                          .json_payload.at("token")
                          .get<std::string>();
    auto r = h.call("POST", "/api/ai/relay/chat", sa::json{{"model", "x"}}, "Bearer " + tok);
    CHECK(r.status == 503);
}

// ---------------------------------------------------------------------------
// Integration: real per-account backend through the proxy. Skipped unless
// EDITOR_GATEWAY_BACKEND_EXE points at a built binary.

TEST_CASE("gateway pool: real backend proxy + per-account isolation",
          "[gateway][posix][integration]") {
    std::string exe = sa_core::paths::getenv_utf8("EDITOR_GATEWAY_BACKEND_EXE");
    if (exe.empty() || !sa_core::paths::is_file(exe)) {
        SKIP("set EDITOR_GATEWAY_BACKEND_EXE to a built backend binary to run");
    }
    auto root = tmp_root("pool");
    std::string udroot = root.string();
    std::string state = (root / ".gateway").string();
    fs::create_directories(sa_core::paths::to_path(state));

    auto mk_hash = [](const std::string& pw, std::string& salt) {
        salt = gw::random_salt_hex();
        return gw::password_hash(salt, pw);
    };
    gw::Config cfg;
    cfg.user_data_root = udroot;
    cfg.state_dir = state;
    cfg.session_ttl_hours = 1;
    cfg.instance_max = 4;
    cfg.idle_minutes = 30;
    for (const char* name : {"alice", "bob"}) {
        gw::Account a;
        a.name = name;
        a.dir = (root / name).string();
        fs::create_directories(sa_core::paths::to_path(a.dir));
        std::string salt;
        a.password_sha256 = mk_hash("pw", salt);
        a.salt = salt;
        cfg.accounts.push_back(a);
    }

    gw::Gateway g;
    g.cfg = cfg;
    g.sessions = std::make_unique<gw::Sessions>(cfg.session_ttl_hours * 3600LL * 1000LL);
    g.usage = std::make_unique<gw::UsageStore>((root / "usage.json").string(), 0);
    g.relay = gw::resolve_relay(cfg);
    gw::InstancePool::Options po;
    po.state_dir = state;
    po.backend_exe = exe;
    po.max_instances = cfg.instance_max;
    po.idle_minutes = cfg.idle_minutes;
    po.account_dir = [&cfg](const std::string& n) {
        const gw::Account* a = cfg.find_account(n);
        return a ? a->dir : "";
    };
    g.pool = std::make_unique<gw::InstancePool>(std::move(po));

    sa::Router router;
    gw::register_gateway_routes(router, g);
    sa::Httpd httpd(&router);
    std::string berr;
    REQUIRE(httpd.bind_to("127.0.0.1", 0, &berr));
    httpd.start();
    const int gport = httpd.port();

    auto login = [&](const std::string& name, const std::string& pw) -> sa_core::http::Response {
        sa_core::http::Request r;
        r.method = "POST";
        r.url = "http://127.0.0.1:" + std::to_string(gport) + "/api/auth/login";
        r.body = sa_core::py_dumps(sa::json{{"name", name}, {"password", pw}});
        r.headers.emplace_back("Content-Type", "application/json");
        r.bypass_proxy = true;
        r.timeout_seconds = 15;
        return sa_core::http::request(r);
    };
    auto get = [&](const std::string& path, const std::string& tok) -> sa_core::http::Response {
        sa_core::http::Request r;
        r.method = "GET";
        r.url = "http://127.0.0.1:" + std::to_string(gport) + path;
        if (!tok.empty()) r.headers.emplace_back("Authorization", "Bearer " + tok);
        r.bypass_proxy = true;
        r.timeout_seconds = 60;  // first call lazily boots the backend
        return sa_core::http::request(r);
    };

    // Bad password -> 401.
    CHECK(login("alice", "nope").status == 401);
    auto lr = login("alice", "pw");
    REQUIRE(lr.status == 200);
    std::string atok = sa::json::parse(lr.body).at("token").get<std::string>();

    // Proxy GET /api/ping through alice's lazily-started instance.
    auto ping = get("/api/ping", atok);
    CHECK(ping.status == 200);
    CHECK(ping.transport_ok());

    // GET /api/state -> workspace_root must be alice's account dir.
    auto st = get("/api/state", atok);
    REQUIRE(st.status == 200);
    sa::json stj = sa::json::parse(st.body);
    // Backend reports its resolved workspace_root; compare normalized.
    CHECK(fs::path(stj.value("workspace_root", std::string())).lexically_normal().string() ==
          fs::path(cfg.find_account("alice")->dir).lexically_normal().string());

    // No token -> 401.
    CHECK(get("/api/state", "").status == 401);
    // Banned endpoint (with a valid token) -> 403.
    CHECK(get("/api/tts/synthesize", atok).status == 403);

    // Isolation: alice creates a mod dir under her workspace via /api/mods? We
    // instead assert per-account routing by confirming bob gets his own
    // (different) workspace_root through the same proxy path.
    auto blr = login("bob", "pw");
    REQUIRE(blr.status == 200);
    std::string btok = sa::json::parse(blr.body).at("token").get<std::string>();
    auto bst = get("/api/state", btok);
    REQUIRE(bst.status == 200);
    std::string bws = sa::json::parse(bst.body).value("workspace_root", std::string());
    CHECK(fs::path(bws).lexically_normal().string() ==
          fs::path(cfg.find_account("bob")->dir).lexically_normal().string());
    CHECK(bws != stj.value("workspace_root", std::string()));
    CHECK(g.pool->live_count() == 2);  // two distinct instances

    // logout -> old token dead on the proxy.
    {
        sa_core::http::Request r;
        r.method = "POST";
        r.url = "http://127.0.0.1:" + std::to_string(gport) + "/api/auth/logout";
        r.headers.emplace_back("Authorization", "Bearer " + atok);
        r.bypass_proxy = true;
        auto lo = sa_core::http::request(r);
        CHECK(lo.status == 200);
    }
    CHECK(get("/api/state", atok).status == 401);

    httpd.stop();
    g.pool->shutdown_all();
    CHECK(g.pool->live_count() == 0);
    std::error_code ec;
    fs::remove_all(root, ec);
}

#endif  // !_WIN32
