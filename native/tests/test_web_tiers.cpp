// tests/test_web_tiers.cpp — 网页版计划 M1 transport/service tiers:
//   * server-tier CORS (trusted origins): Origin echo, untrusted reject,
//     no-Origin pass-through, and the untouched default tier (byte compat);
//   * static hosting route (index/asset/404/traversal + API precedence);
//   * /api/shutdown server-mode gate;
//   * ai_relay:: unit behaviour + mock-provider round-trips (SSRF wall,
//     stream forcing, provider header sets) and route wiring through
//     editor_ai settings.
#include <catch_amalgamated.hpp>

#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include "httplib.h"
#include "p4_mock.h"
#include "test_support.h"

#include "ai_relay_routes.h"  // services dir is on the include path
#include "env_store_ai.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "server/api_router.h"
#include "server/httpd.h"
#include "server/services/static_routes.h"
#include "server/state.h"

using sa::json;

namespace {

void putenv_portable(const char* k, const char* v) {
#ifdef _WIN32
    std::string s = std::string(k) + "=" + v;
    _putenv(s.c_str());
#else
    if (v[0] == '\0') ::unsetenv(k);
    else ::setenv(k, v, 1);
#endif
}

// Editor-root override scoped to a case (test_assets_routes pattern):
// EDITOR_DATA_ROOT must be empty for detail::set_editor_root to take effect.
struct EditorRootScope {
    std::string dir;
    explicit EditorRootScope(const std::string& d) : dir(d) {
        putenv_portable("EDITOR_DATA_ROOT", "");
        sa::detail::set_editor_root(d);
    }
    ~EditorRootScope() { sa::detail::set_editor_root(""); }
};

struct CorsFixture {
    sa::Router router;
    sa::Httpd server;
    std::string base;
    explicit CorsFixture(std::vector<std::string> trusted)
        : router(sa::build_router()), server(&router) {
        sa::CorsConfig cors;
        cors.trusted_origins = std::move(trusted);
        server.set_cors(cors);
        std::string err;
        REQUIRE(server.bind_to("127.0.0.1", 0, &err));
        server.start();
        base = "http://127.0.0.1:" + std::to_string(server.port());
    }
    ~CorsFixture() { server.stop(); }
};

// Minimal raw GET (httplib normalizes encoded dot-segments client-side, which
// is exactly the traffic a traversal probe sends — the socket must not).
struct RawResp {
    int status = 0;
    std::string headers;  // lower-cased "name: value\r\n" lines
    std::string body;
};

RawResp raw_get(const std::string& host, int port, const std::string& target,
                const std::string& extra_headers = "") {
    RawResp out;
    auto s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<unsigned short>(port));
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (::connect(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) return out;
    std::string req = "GET " + target + " HTTP/1.1\r\nHost: " + host + ":" +
                      std::to_string(port) + "\r\nConnection: close\r\n" + extra_headers +
                      "\r\n";
    ::send(s, req.data(), static_cast<int>(req.size()), 0);
    std::string all;
    for (;;) {
        char buf[4096];
#ifdef _WIN32
        int n = ::recv(s, buf, sizeof(buf), 0);
#else
        int n = static_cast<int>(::recv(s, buf, sizeof(buf), 0));
#endif
        if (n <= 0) break;
        all.append(buf, static_cast<size_t>(n));
    }
#ifdef _WIN32
    ::closesocket(s);
#else
    ::close(s);
#endif
    size_t sep = all.find("\r\n\r\n");
    if (sep == std::string::npos) return out;
    std::string head = all.substr(0, sep);
    out.body = all.substr(sep + 4);
    out.status = std::atoi(head.c_str() + strlen("HTTP/1.1 "));
    std::string lower;
    for (char c : head) lower.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
    out.headers = lower;
    return out;
}

struct StaticWebRoot {
    std::filesystem::path dir;
    explicit StaticWebRoot(const std::string& tag) : dir(sat::make_temp_dir(tag)) {
        auto write = [&](const std::string& name, const std::string& text) {
            std::ofstream(dir / std::filesystem::u8path(name), std::ios::binary) << text;
        };
        write("index.html", "<html>WEB</html>");
        write("main.dart.js", "//bundle");
        write("manifest.json", "{}");
        // Sits next to, not inside, web_root: a successful escape would read it.
        std::ofstream(dir.parent_path() / std::filesystem::u8path(dir.filename().string() +
                                                                  "_outside.txt")) =
            std::ofstream();  // touch only; content irrelevant
    }
    std::string path() const { return sa_core::paths::path_to_utf8(dir); }
};

struct StaticFixture {
    std::string root;
    sa::Router router;
    sa::Httpd server;
    std::string base;
    explicit StaticFixture(const std::string& web_root)
        : root(web_root), router(sa::build_router()), server(&router) {
        sa::register_static_routes(router, root);  // LAST, like run.cpp
        std::string err;
        REQUIRE(server.bind_to("127.0.0.1", 0, &err));
        server.start();
        base = "http://127.0.0.1:" + std::to_string(server.port());
    }
    ~StaticFixture() { server.stop(); }
};

int bound_port(const std::string& base) {
    size_t c = base.rfind(':');
    return std::atoi(base.c_str() + c + 1);
}

}  // namespace

// ---------------------------------------------------------------------------
// CORS tiers
// ---------------------------------------------------------------------------

TEST_CASE("default tier is untouched by the CorsConfig hook (empty list)", "[web][cors]") {
    CorsFixture fx{{}};
    httplib::Client cli(fx.base);
    auto res = cli.Get("/api/ping");
    REQUIRE(res);
    CHECK(res->status == 200);
    CHECK(res->get_header_value("Access-Control-Allow-Origin") == "http://127.0.0.1");
    CHECK(res->get_header_value("Access-Control-Allow-Headers") == "Content-Type");
    // The CONVENTIONS 2 order: Cache-Control before the ACA block.
    CHECK(res->get_header_value("Cache-Control") == "no-store");
}

TEST_CASE("server tier echoes trusted origins and rejects others", "[web][cors]") {
    CorsFixture fx{{"http://app.test"}};
    httplib::Client cli(fx.base);
    {
        httplib::Headers h{{"Origin", "http://app.test"}};
        auto res = cli.Get("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 200);
        CHECK(res->get_header_value("Access-Control-Allow-Origin") == "http://app.test");
        CHECK(res->get_header_value("Access-Control-Allow-Headers") ==
              "Content-Type, Authorization");
    }
    {
        httplib::Headers h{{"Origin", "http://evil.test"}};
        auto res = cli.Get("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 403);
        CHECK(json::parse(res->body)["error"] == "forbidden origin");
        // A rejected origin must never see an ACAO (it could read the 403).
        CHECK(res->get_header_value("Access-Control-Allow-Origin").empty());
    }
    {
        // Non-browser clients (CLI, the gateway proxy hop, curl) carry no
        // Origin and pass, as in the default tier.
        auto res = cli.Get("/api/ping");
        REQUIRE(res);
        CHECK(res->status == 200);
    }
    {
        // Host-independence is the deliberate server-tier deviation: a
        // rebinding page fails the LIST test, not a port equality test.
        httplib::Headers h{{"Host", "rebind.attacker.net"}, {"Origin", "http://app.test"}};
        auto res = cli.Get("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 200);
    }
    {
        httplib::Headers h{{"Host", "rebind.attacker.net"}, {"Origin", "http://rebind.attacker.net"}};
        auto res = cli.Get("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 403);
    }
}

TEST_CASE("server tier normalizes case/defaults/ports in the trusted match", "[web][cors]") {
    CorsFixture fx{{"HTTP://APP.TEST:80/"}};
    httplib::Client cli(fx.base);
    httplib::Headers h{{"Origin", "http://app.test"}};
    auto res = cli.Get("/api/ping", h);
    REQUIRE(res);
    CHECK(res->status == 200);
}

TEST_CASE("server tier OPTIONS preflight: 204 + echo + Authorization", "[web][cors]") {
    CorsFixture fx{{"http://app.test"}};
    httplib::Client cli(fx.base);
    httplib::Headers h{{"Origin", "http://app.test"}};
    httplib::Request req;
    req.method = "OPTIONS";
    req.path = "/api/cfg/EvtCfg";
    req.headers = h;
    auto res = cli.send(req);
    REQUIRE(res);
    CHECK(res->status == 204);
    CHECK(res->get_header_value("Access-Control-Allow-Origin") == "http://app.test");
    CHECK(res->get_header_value("Access-Control-Allow-Headers") ==
          "Content-Type, Authorization");
}

// ---------------------------------------------------------------------------
// /api/shutdown server-mode gate
// ---------------------------------------------------------------------------

TEST_CASE("shutdown route refuses when disabled, answers when enabled", "[web][shutdown]") {
    sa::Router r = sa::build_router();
    sa::detail::set_shutdown_disabled(true);
    struct Guard {
        ~Guard() { sa::detail::set_shutdown_disabled(false); }
    } guard;
    auto denied = sa::sa_test::dispatch_in_proc(r, "POST", "/api/shutdown", {}, json{});
    CHECK(denied.status == 403);
    CHECK(denied.json_payload["error"] == "shutdown disabled in server mode");
    CHECK(!sa::shutdown_requested());  // the flag must not be armed
    sa::detail::set_shutdown_disabled(false);
    auto ok = sa::sa_test::dispatch_in_proc(r, "POST", "/api/shutdown", {}, json{});
    CHECK(ok.status == 200);
    CHECK(ok.json_payload["ok"] == true);
    sa::detail::clear_shutdown_for_test();
}

// ---------------------------------------------------------------------------
// Static hosting
// ---------------------------------------------------------------------------

TEST_CASE("static hosting: index, assets, cache classes, 404s and API precedence",
          "[web][static]") {
    StaticWebRoot web("static");
    StaticFixture fx(web.path());

    httplib::Client cli(fx.base);
    {
        auto res = cli.Get("/");
        REQUIRE(res);
        CHECK(res->status == 200);
        CHECK(res->body == "<html>WEB</html>");
        CHECK(res->get_header_value("Content-Type") == "text/html; charset=utf-8");
        CHECK(res->get_header_value("Cache-Control") == "no-cache");
    }
    {
        auto res = cli.Get("/index.html");
        REQUIRE(res);
        CHECK(res->body == "<html>WEB</html>");
    }
    {
        auto res = cli.Get("/main.dart.js");
        REQUIRE(res);
        CHECK(res->status == 200);
        CHECK(res->get_header_value("Content-Type") == "text/javascript; charset=utf-8");
        CHECK(res->get_header_value("Cache-Control") == "public, max-age=3600");
    }
    {
        auto res = cli.Get("/missing.txt");
        REQUIRE(res);
        CHECK(res->status == 404);
        CHECK(json::parse(res->body)["error"].get<std::string>().rfind("no such file", 0) == 0);
    }
    {
        // Unknown /api/* keeps the transport's contract envelope, not the
        // asset-server 404.
        auto res = cli.Get("/api/nope");
        REQUIRE(res);
        CHECK(res->status == 404);
        CHECK(json::parse(res->body)["error"] == "no route: GET /api/nope");
    }
    {
        // A registered API route still wins over the catch-all.
        auto res = cli.Get("/api/ping");
        REQUIRE(res);
        CHECK(res->status == 200);
        CHECK(json::parse(res->body)["ok"] == true);
    }
    {
        // Encoded traversal: must not read the sibling file outside web_root.
        auto raw = raw_get("127.0.0.1", bound_port(fx.base),
                           "/%2e%2e/" + web.dir.filename().string() + "_outside.txt");
        CHECK(raw.status == 400);
        CHECK(raw.body.find("WEB") == std::string::npos);
    }
    {
        // Raw (unencoded) dot-dot in the request line.
        auto raw = raw_get("127.0.0.1", bound_port(fx.base), "/..%2Fescape.txt");
        CHECK(raw.status == 400);
    }
}

TEST_CASE("static hosting is absent unless registered (desktop default)", "[web][static]") {
    CorsFixture fx{{}};
    httplib::Client cli(fx.base);
    auto res = cli.Get("/");
    REQUIRE(res);
    CHECK(res->status == 404);
    CHECK(json::parse(res->body)["error"] == "no route: GET /");
}

// ---------------------------------------------------------------------------
// ai_relay: units + provider round-trips
// ---------------------------------------------------------------------------

TEST_CASE("relay settings: usable iff apiKey set, provider allowlist", "[web][ai]") {
    json empty = sa::env_store_ai::normalize_ai_settings(json::object());
    auto s0 = sa::ai_relay::read_settings_from_ai(empty);
    CHECK_FALSE(s0.usable);

    json conf;
    conf["provider"] = "anthropic";
    conf["apiKey"] = "sk-ant";
    conf["baseUrl"] = "";
    auto s1 = sa::ai_relay::read_settings_from_ai(conf);
    CHECK(s1.usable);
    CHECK(s1.provider == "anthropic");

    json junk;
    junk["provider"] = "bogus";  // not normalizable by read_settings: unusable path
    junk["apiKey"] = "k";
    auto s2 = sa::ai_relay::read_settings_from_ai(junk);
    CHECK_FALSE(s2.usable);
}

TEST_CASE("relay policy json shape (raw backend answers)", "[web][ai]") {
    json ai = sa::env_store_ai::normalize_ai_settings(json::object());
    auto s = sa::ai_relay::read_settings_from_ai(ai);
    auto p = sa::ai_relay::policy_json(s, true, true, {}, 0);
    CHECK(p["relay_available"] == false);
    CHECK(p["own_key_allowed"] == true);
    CHECK(p["tts_image_available"] == true);
    CHECK(p["stream"] == false);
    CHECK(p["models"].is_array());
    CHECK(p["limits"]["daily"] == 0);
}

TEST_CASE("relay round-trip: openai_compatible headers, stream forced, SSRF keys dropped",
          "[web][ai][mock]") {
    p4mock::Server srv;
    std::string last_auth, last_path, last_body;
    srv.server().Post(R"(/v1/chat/completions)", [&](const httplib::Request& req,
                                                     httplib::Response& res) {
        last_auth = req.get_header_value("Authorization");
        last_path = req.path;
        last_body = req.body;
        res.set_content(R"({"choices":[{"message":{"content":"hi"}}]})", "application/json");
    });
    REQUIRE(srv.start() > 0);

    sa::ai_relay::RelaySettings s;
    s.provider = "openai_compatible";
    s.base_url = srv.base() + "/v1";
    s.api_key = "sk-test";
    s.model = "default-model";
    s.usable = true;

    json body;
    body["messages"] = json::array({json{{"role", "user"}, {"content", "x"}}});
    body["stream"] = true;
    body["protocol"] = "anthropic";   // control keys the relay must ignore
    body["base_url"] = "http://127.0.0.2:9";  // SSRF attempt
    body["apiKey"] = "steal";
    auto resp = sa::ai_relay::relay_chat(s, body);
    CHECK(resp.status == 200);
    CHECK(resp.is_bytes);
    CHECK(resp.bytes.find("hi") != std::string::npos);
    CHECK(resp.content_type.find("application/json") != std::string::npos);

    CHECK(last_path == "/v1/chat/completions");
    CHECK(last_auth == "Bearer sk-test");
    auto fwd = json::parse(last_body);
    CHECK(fwd["stream"] == false);
    CHECK(fwd["model"] == "default-model");
    CHECK_FALSE(fwd.contains("protocol"));
    CHECK_FALSE(fwd.contains("base_url"));
    CHECK_FALSE(fwd.contains("apiKey"));
}

TEST_CASE("relay round-trip: anthropic path, header set, max_tokens default", "[web][ai][mock]") {
    p4mock::Server srv;
    std::string last_key, last_ver, last_body;
    srv.server().Post(R"(/v1/messages)", [&](const httplib::Request& req,
                                             httplib::Response& res) {
        last_key = req.get_header_value("x-api-key");
        last_ver = req.get_header_value("anthropic-version");
        last_body = req.body;
        res.set_content(R"({"content":[{"text":"ok"}]})", "application/json");
    });
    REQUIRE(srv.start() > 0);

    sa::ai_relay::RelaySettings s;
    s.provider = "anthropic";
    s.base_url = srv.base() + "/v1/";  // trailing slash must be normalized away
    s.api_key = "sk-ant";
    s.usable = true;
    json body;
    body["model"] = "claude-x";
    body["messages"] = json::array();
    auto resp = sa::ai_relay::relay_chat(s, body);
    CHECK(resp.status == 200);
    CHECK(last_key == "sk-ant");
    CHECK(last_ver == "2023-06-01");
    auto fwd = json::parse(last_body);
    CHECK(fwd["max_tokens"] == 8192);  // anthropic rejects without it
}

TEST_CASE("relay round-trip: openai_responses path + upstream error verbatim",
          "[web][ai][mock]") {
    p4mock::Server srv;
    std::string last_path;
    srv.server().Post(R"(/v1/responses)", [&](const httplib::Request& req,
                                              httplib::Response& res) {
        last_path = req.path;
        res.status = 429;
        res.set_content(R"({"error":{"message":"rate limited"}})", "application/json");
    });
    REQUIRE(srv.start() > 0);

    sa::ai_relay::RelaySettings s;
    s.provider = "openai_responses";
    s.base_url = srv.base() + "/v1";
    s.api_key = "sk";
    s.usable = true;
    json body;
    body["model"] = "gpt-x";
    body["input"] = json::array();
    auto resp = sa::ai_relay::relay_chat(s, body);
    CHECK(last_path == "/v1/responses");
    CHECK(resp.status == 429);  // pass-through, not swallowed into a 500
    CHECK(resp.bytes.find("rate limited") != std::string::npos);
}

TEST_CASE("relay transport failure -> 502 ai_upstream_unreachable", "[web][ai]") {
    sa::ai_relay::RelaySettings s;
    s.provider = "openai_compatible";
    s.base_url = "http://127.0.0.1:9";  // closed port
    s.api_key = "sk";
    s.usable = true;
    json body;
    body["messages"] = json::array();
    auto resp = sa::ai_relay::relay_chat(s, body);
    CHECK(resp.status == 502);
    CHECK(resp.json_payload["error"].get<std::string>().rfind("ai_upstream_unreachable", 0) == 0);
}

TEST_CASE("relay endpoints: policy + chat through the router (editor_ai config)",
          "[web][ai][mock][routes]") {
    auto root = sat::make_temp_dir("relay");
    EditorRootScope er(sa_core::paths::path_to_utf8(root));

    p4mock::Server srv;
    std::string last_auth;
    srv.server().Post(R"(/v1/chat/completions)", [&](const httplib::Request& req,
                                                     httplib::Response& res) {
        last_auth = req.get_header_value("Authorization");
        res.set_content(R"({"choices":[]})", "application/json");
    });
    REQUIRE(srv.start() > 0);

    json patch;
    patch["provider"] = "openai_compatible";
    patch["baseUrl"] = srv.base() + "/v1";
    patch["apiKey"] = "sk-route";
    patch["model"] = "m-route";
    sa::env_store_ai::write_ai_settings(sa::editor_root(), patch);

    sa::Router r = sa::build_router();
    auto pol = sa::sa_test::dispatch_in_proc(r, "GET", "/api/ai/policy", {}, json{});
    CHECK(pol.status == 200);
    CHECK(pol.json_payload["relay_available"] == true);
    CHECK(pol.json_payload["provider"] == "openai_compatible");
    CHECK(pol.json_payload["model"] == "m-route");

    json chat;
    chat["messages"] = json::array({json{{"role", "user"}, {"content", "y"}}});
    sa::Req req;
    req.method = "POST";
    req.path = "/api/ai/relay/chat";
    req.body = chat;
    auto resp = r.dispatch(req);
    CHECK(resp.status == 200);
    CHECK(last_auth == "Bearer sk-route");
}
