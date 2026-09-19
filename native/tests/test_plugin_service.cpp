// [plugins] — PLUGIN_SPEC §4: HTTP service plugins (plugin_service.{h,cpp} +
// the /api/plugins/service + /agent routes in plugins_routes.cpp).
//
// A real loopback "plugin service" is faked with the [p5] suite's header-only
// mock (p5mock::Server — arbitrary verbs, recorded calls), driven through the
// REAL route bus exactly like test_plugins.cpp. The service side of the wire
// (WinHTTP, bypass_proxy, no redirects) is the production path, not a stub.
//
// Contract being pinned here (PLUGIN_SPEC §4 + PLUGIN_GUIDE §5):
//   * GET endpoints read the refresh cache and NEVER touch the network;
//   * refresh happens on reload / install / exec-miss, per-service 1.5s cap;
//   * the proxy forwards verb/subpath/query/body verbatim to <service.url> and
//     passes the upstream status/body/Content-Type back untouched;
//   * the service URL whitelist (http, 127.0.0.1/localhost, explicit port)
//     turns bad declarations into entry errors and 400s, never requests.
#include <map>
#include <string>
#include <vector>

#include <catch_amalgamated.hpp>

#include "p5_mock.h"
#include "plugin_service.h"
#include "plugins_routes.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "test_support.h"

namespace {

namespace cs = sa_core::paths;
namespace ps = sa::plugin_service;
using sa::json;

// Env var RAII (same shape as test_plugins.cpp's ScopedEnv).
struct ScopedEnv {
    std::string key;
    std::string saved;
    bool had;
    explicit ScopedEnv(const std::string& k, const std::string& v) : key(k) {
        const char* cur = std::getenv(k.c_str());
        had = cur != nullptr;
        saved = cur ? cur : "";
        set(v);
    }
    ~ScopedEnv() {
        if (had) set(saved);
#ifdef _WIN32
        else
            _putenv_s(key.c_str(), "");
#else
        else
            unsetenv(key.c_str());
#endif
    }
    void set(const std::string& v) {
#ifdef _WIN32
        _putenv_s(key.c_str(), v.c_str());
#else
        setenv(key.c_str(), v.c_str(), 1);
#endif
    }
    ScopedEnv(const ScopedEnv&) = delete;
    ScopedEnv& operator=(const ScopedEnv&) = delete;
};

// Full bus; the §4 cache starts empty per case (it is process-global).
struct ServiceFixture : sat::CfgFixture {
    ServiceFixture() : sat::CfgFixture("plugin_service") { ps::reset_for_test(); }
    sa::Resp call(const std::string& method, const std::string& path,
                  std::map<std::string, std::string> query = {},
                  const sa::json& body = sa::json(),
                  const std::string& raw_query = "") {
        return sat::call_router(router(), method, path, std::move(query), body, raw_query);
    }
};

std::string fixture_root() {
    static auto p = sat::make_temp_dir("plugin_service_env");
    return cs::path_to_utf8(p);
}

int g_seq = 0;
std::string fresh_root(const char* tag) {
    const std::string p = cs::join(fixture_root(), std::string(tag) + "_" + std::to_string(++g_seq));
    cs::create_dirs(p);
    return p;
}

void make_plugin(const std::string& root, const std::string& pid, const std::string& manifest) {
    const std::string dir = cs::join(root, pid);
    cs::create_dirs(dir);
    cs::write_bytes_simple(cs::join(dir, "manifest.json"), manifest);
}

std::string manifest_with_service(const std::string& url) {
    return json{{"id", "svc_demo"},
                {"name", "服务演示"},
                {"service", json{{"url", url}, {"name", "demo"}}}}
        .dump();
}

// A loopback fake of a §4 plugin service: /plugin.json serves `desc`, the
// wildcard responder records every call and answers 200 "ok" text/plain.
struct MockService {
    p5mock::Server srv;
    int port = 0;
    std::string desc = "{}";

    bool start() {
        srv.on("GET", "/plugin.json",
               [this](const p5mock::Request&, p5mock::Response& res) {
                   res.set_content(desc, "application/json");
               });
        srv.on("", "", [](const p5mock::Request&, p5mock::Response& res) {
            res.set_content("ok", "text/plain");
        });
        port = srv.start();
        return port != 0;
    }
    std::string url() const { return "http://127.0.0.1:" + std::to_string(port); }

    // Calls whose raw target starts with `prefix`.
    std::vector<p5mock::Call> calls(const std::string& prefix) {
        std::vector<p5mock::Call> out;
        for (const auto& c : srv.calls()) {
            if (c.target.compare(0, prefix.size(), prefix) == 0) out.push_back(c);
        }
        return out;
    }
    std::vector<p5mock::Call> calls() { return srv.calls(); }
};

// A port that currently refuses connections (bind, read the number, close).
int dead_port() {
    p5mock::Server s;
    const int p = s.start();
    s.stop();
    return p;
}

}  // namespace

// ---------------------------------------------------------------------------
// URL whitelist
// ---------------------------------------------------------------------------

TEST_CASE("plugin service url whitelist rejects non-loopback declarations", "[plugins]") {
    const std::string root = fresh_root("whitelist");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    make_plugin(root, "p_https", R"({"service":{"url":"https://127.0.0.1:39211"}})");
    make_plugin(root, "p_noport", R"({"service":{"url":"http://127.0.0.1"}})");
    make_plugin(root, "p_remote", R"({"service":{"url":"http://evil.example:39211"}})");
    make_plugin(root, "p_zero", R"({"service":{"url":"http://127.0.0.1:0"}})");
    make_plugin(root, "p_dotdot", R"({"service":{"url":"http://127.0.0.1:39211/../x"}})");
    make_plugin(root, "p_noobj", R"({"service":"http://127.0.0.1:39211"})");
    make_plugin(root, "p_nourl", R"({"service":{"name":"no url"}})");
    make_plugin(root, "p_ok_prefix", R"({"service":{"url":"http://127.0.0.1:39211/svc"}})");

    ServiceFixture fx;
    auto reload = fx.call("POST", "/api/plugins/reload");
    REQUIRE(reload.status == 200);
    std::map<std::string, json> by_id;
    for (const auto& e : reload.json_payload["plugins"]) by_id[e["id"].get<std::string>()] = e;

    for (const char* pid :
         {"p_https", "p_noport", "p_remote", "p_zero", "p_dotdot", "p_noobj", "p_nourl"}) {
        INFO(pid);
        const std::string err = by_id[pid].value("error", std::string());
        CHECK(sa_core::str::starts_with(err, "invalid service url: "));
        CHECK(by_id[pid]["service_status"]["checked"] == true);  // verdict needs no network
        CHECK(by_id[pid]["service_status"]["ok"] == false);
        // The proxy refuses bad declarations without touching the network.
        CHECK(fx.call("GET", std::string("/api/plugins/service/") + pid + "/echo").status == 400);
    }
    // A path prefix is allowed and kept in the canonical base; the fetch to
    // the (here dead) 39211 port fails like any unavailable service.
    CHECK(by_id["p_ok_prefix"]["error"] == "plugin service unavailable");
    CHECK(by_id["p_ok_prefix"]["service_status"]["url"] == "http://127.0.0.1:39211/svc");
}

// ---------------------------------------------------------------------------
// self-description fetch, cache semantics, aggregates
// ---------------------------------------------------------------------------

TEST_CASE("plugin service description feeds the aggregates; GETs never touch the network",
          "[plugins]") {
    const std::string root = fresh_root("desc");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    MockService svc;
    REQUIRE(svc.start());
    svc.desc = json{
        {"flow_cards", json::array({json{{"type_id", "svc_card"}, {"name", "服务卡"}}})},
        {"panels", json::array({json{{"panel_id", "pn"}, {"title", "动态面板"}}})},
        {"agent_tools",
         json::array({json{{"name", "get_weather"},
                           {"description", "查天气"},
                           {"parameters", json::object()},
                           {"confirm", true}}})},
    }.dump();
    make_plugin(root, "svc", manifest_with_service(svc.url()));
    // A declarative card on another plugin must come FIRST (manifest, then service).
    make_plugin(root, "pure", R"({"ui":{"flow_cards":[{"type_id":"plain"}]}})");

    ServiceFixture fx;
    // Before any refresh the aggregates are declarative-only and the mock was
    // never contacted.
    CHECK(fx.call("GET", "/api/plugins/ui/flow_cards").json_payload["flow_cards"].size() == 1);
    CHECK(svc.calls().empty());

    auto reload = fx.call("POST", "/api/plugins/reload");
    REQUIRE(reload.status == 200);
    REQUIRE(svc.calls("/plugin.json").size() == 1);  // exactly one description fetch

    // flow_cards: manifest cards first, service cards after, same whitelist.
    // (Bind the Resp to a named local before taking sub-object references —
    // chaining onto the temporary would dangle.)
    auto fc_resp = fx.call("GET", "/api/plugins/ui/flow_cards");
    const auto& cards = fc_resp.json_payload["flow_cards"];
    REQUIRE(cards.size() == 2);
    CHECK(cards[0]["type_id"] == "plain");
    CHECK(cards[0]["plugin_id"] == "pure");
    CHECK(cards[1]["type_id"] == "svc_card");
    CHECK(cards[1]["plugin_id"] == "svc");
    CHECK(cards[1]["name"] == "服务卡");

    // panels: passthrough + plugin_id.
    auto ui_resp = fx.call("GET", "/api/plugins/ui");
    const auto& panels = ui_resp.json_payload["panels"];
    REQUIRE(panels.size() == 1);
    CHECK(panels[0]["panel_id"] == "pn");
    CHECK(panels[0]["plugin_id"] == "svc");

    // agent tools: listed with plugin_id, path defaulted later at exec time.
    auto tools_resp = fx.call("GET", "/api/plugins/agent/tools");
    const auto& tools = tools_resp.json_payload["tools"];
    REQUIRE(tools.size() == 1);
    CHECK(tools[0]["name"] == "get_weather");
    CHECK(tools[0]["confirm"] == true);
    CHECK(tools[0]["plugin_id"] == "svc");

    // Reads stay off the wire: no /plugin.json hits beyond the reload's one.
    CHECK(svc.calls("/plugin.json").size() == 1);
    // A second reload re-fetches (synchronous sweep).
    fx.call("POST", "/api/plugins/reload");
    CHECK(svc.calls("/plugin.json").size() == 2);

    // The list rows carry the healthy verdict now.
    auto list = fx.call("GET", "/api/plugins");
    REQUIRE(list.json_payload["plugins"].size() == 2);
    CHECK(list.json_payload["plugins"][0]["error"] == "");  // pure declarative row
    CHECK(list.json_payload["plugins"][1]["error"] == "");
    CHECK(list.json_payload["plugins"][1]["service_status"] ==
          json{{"ok", true}, {"url", svc.url()}, {"name", "demo"}, {"checked", true}});
}

TEST_CASE("plugin service: dead service -> entry error, 502 proxy, other plugins unaffected",
          "[plugins]") {
    const std::string root = fresh_root("dead");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    const int port = dead_port();
    make_plugin(root, "gone", manifest_with_service("http://127.0.0.1:" + std::to_string(port)));
    make_plugin(root, "alive", R"({"id":"alive","name":"纯声明"})");

    ServiceFixture fx;
    auto reload = fx.call("POST", "/api/plugins/reload");
    REQUIRE(reload.status == 200);
    std::map<std::string, json> by_id;
    for (const auto& e : reload.json_payload["plugins"]) by_id[e["id"].get<std::string>()] = e;
    CHECK(by_id["gone"]["error"] == "plugin service unavailable");
    CHECK(by_id["gone"]["service_status"]["ok"] == false);
    CHECK(by_id["alive"]["error"] == "");

    // The proxy answers the spec's exact 502 envelope.
    auto proxied = fx.call("GET", "/api/plugins/service/gone/echo");
    CHECK(proxied.status == 502);
    CHECK(proxied.json_payload == json{{"error", "plugin service unavailable"}});
    // Uninstalling clears the verdict with the directory.
    CHECK(fx.call("DELETE", "/api/plugins/gone").status == 200);
    CHECK(ps::error_of("gone").empty());
}

TEST_CASE("plugin service: bad plugin.json shapes are reported per plugin", "[plugins]") {
    const std::string root = fresh_root("baddesc");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    MockService svc;
    REQUIRE(svc.start());
    make_plugin(root, "notobj", manifest_with_service(svc.url()));

    ServiceFixture fx;
    svc.desc = "[]";
    CHECK(fx.call("POST", "/api/plugins/reload").status == 200);
    CHECK(ps::error_of("notobj") == "bad plugin.json: not a JSON object");

    svc.desc = "{\"pad\":\"" + std::string(3 * 1024 * 1024, 'x') + "\"}";
    CHECK(fx.call("POST", "/api/plugins/reload").status == 200);
    CHECK(ps::error_of("notobj") == "bad plugin.json: too large");
}

// ---------------------------------------------------------------------------
// proxy fidelity
// ---------------------------------------------------------------------------

TEST_CASE("plugin service proxy: verbs, query, body and content-type pass through", "[plugins]") {
    const std::string root = fresh_root("proxy");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    MockService svc;
    REQUIRE(svc.start());
    make_plugin(root, "svc", manifest_with_service(svc.url()));
    make_plugin(root, "pure", R"({"id":"pure"})");  // no service declared

    ServiceFixture fx;
    REQUIRE(fx.call("POST", "/api/plugins/reload").status == 200);
    svc.srv.clear_calls();

    // GET with a repeated-key query: raw_query is replayed verbatim.
    auto g = fx.call("GET", "/api/plugins/service/svc/echo", {}, sa::json(), "a=1&a=2&b=x");
    CHECK(g.status == 200);  // wildcard "ok"
    REQUIRE(svc.calls("/echo").size() == 1);
    CHECK(svc.calls("/echo")[0].method == "GET");
    CHECK(svc.calls("/echo")[0].target == "/echo?a=1&a=2&b=x");
    REQUIRE(svc.calls("/echo")[0].headers.count("x-plugin-id") == 1);
    CHECK(svc.calls("/echo")[0].headers.at("x-plugin-id") == "svc");

    // Percent-decoded subpath is re-quoted on the way out (space -> %20).
    fx.call("GET", "/api/plugins/service/svc/my file", {}, sa::json());
    if (svc.calls("/my%20file").size() != 1) {
        for (const auto& c : svc.calls()) INFO("mock saw: " << c.method << " " << c.target);
    }
    REQUIRE(svc.calls("/my%20file").size() == 1);

    // POST body verbatim — including a body the transport could not parse as
    // JSON ({"_raw": text} marker -> the raw text is the body).
    fx.call("POST", "/api/plugins/service/svc/echo", {}, json{{"_raw", "not-json{"}});
    REQUIRE(svc.calls("/echo").size() == 2);
    CHECK(svc.calls("/echo")[1].method == "POST");
    CHECK(svc.calls("/echo")[1].body == "not-json{");

    // PUT with a JSON body: forwarded as the serialized JSON (semantically the
    // request body).
    fx.call("PUT", "/api/plugins/service/svc/items", {}, json{{"k", 1}});
    REQUIRE(svc.calls("/items").size() == 1);
    CHECK(svc.calls("/items")[0].method == "PUT");
    CHECK(svc.calls("/items")[0].body.find("\"k\": 1") != std::string::npos);

    // Upstream status and content-type come back untouched (bytes path).
    auto raw = fx.call("GET", "/api/plugins/service/svc/echo");
    CHECK(raw.is_bytes);
    CHECK(raw.bytes == "ok");
    CHECK(raw.content_type == "text/plain");

    // Refusals that never reach the wire.
    const size_t before = svc.calls().size();
    CHECK(fx.call("GET", "/api/plugins/service/svc/../etc/passwd").status == 400);
    CHECK(fx.call("GET", "/api/plugins/service/svc/a:b").status == 400);
    CHECK(fx.call("GET", "/api/plugins/service/ghost/echo").status == 404);
    CHECK(fx.call("GET", "/api/plugins/service/pure/echo").status == 400);
    CHECK(svc.calls().size() == before);
}

// ---------------------------------------------------------------------------
// agent tools
// ---------------------------------------------------------------------------

TEST_CASE("plugin service agent tools list and execute through the proxy", "[plugins]") {
    const std::string root = fresh_root("agent");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    MockService svc;
    REQUIRE(svc.start());
    svc.desc = json{
        {"agent_tools",
         json::array({
             json{{"name", "get_weather"},
                  {"description", "查天气"},
                  {"parameters", json::object()},
                  {"path", "/tools/weather"}},
             json{{"name", "shout"}},                          // default path /agent/exec
             json{{"name", "  "}},                             // blank name -> dropped
             json{{"description", "nameless"}},                // no name -> dropped
             json{{"name", "bad_path"}, {"path", "no-lead"}},  // invalid path -> default
         })},
    }.dump();
    make_plugin(root, "svc", manifest_with_service(svc.url()));

    ServiceFixture fx;
    // No reload yet: exec performs the bounded inline refresh itself (§4
    // cache-miss fallback) and still finds the tool.
    auto exec = fx.call("POST", "/api/plugins/agent/exec", {},
                        json{{"name", "get_weather"}, {"args", json{{"city", "杭州"}}}});
    CHECK(exec.status == 200);  // wildcard "ok" — the call DID reach the service
    CHECK(svc.calls("/plugin.json").size() == 1);  // the inline refresh
    REQUIRE(svc.calls("/tools/weather").size() == 1);
    CHECK(svc.calls("/tools/weather")[0].method == "POST");
    CHECK(svc.calls("/tools/weather")[0].body.find("get_weather") != std::string::npos);
    CHECK(svc.calls("/tools/weather")[0].body.find("杭州") != std::string::npos);

    // Now the normal path: listed after the refresh exec performed.
    auto tools_resp = fx.call("GET", "/api/plugins/agent/tools");
    const auto& tools = tools_resp.json_payload["tools"];
    REQUIRE(tools.size() == 3);
    CHECK(tools[0]["name"] == "get_weather");
    CHECK(tools[0]["plugin_id"] == "svc");
    CHECK(tools[1]["name"] == "shout");
    CHECK(tools[2]["name"] == "bad_path");

    // Default tool path is /agent/exec.
    fx.call("POST", "/api/plugins/agent/exec", {}, json{{"name", "shout"}});
    REQUIRE(svc.calls("/agent/exec").size() == 1);
    // Invalid declared path falls back to the default too.
    fx.call("POST", "/api/plugins/agent/exec", {}, json{{"name", "bad_path"}});
    REQUIRE(svc.calls("/agent/exec").size() == 2);
    // The exec body reaches the service as sent (JSON replay path).
    CHECK(svc.calls("/agent/exec")[1].body.find("bad_path") != std::string::npos);

    // Missing name / unknown tool.
    CHECK(fx.call("POST", "/api/plugins/agent/exec", {}, json{{"args", json::object()}}).status ==
          400);
    auto unknown = fx.call("POST", "/api/plugins/agent/exec", {}, json{{"name", "nope"}});
    CHECK(unknown.status == 404);
    CHECK(unknown.json_payload == json{{"error", "unknown plugin tool: nope"}});
}

// ---------------------------------------------------------------------------
// dynamic panel content
// ---------------------------------------------------------------------------

TEST_CASE("plugin service panel falls through to the service for dynamic content", "[plugins]") {
    const std::string root = fresh_root("panel");
    ScopedEnv env("EDITOR_PLUGINS_ROOT", root);
    MockService svc;
    REQUIRE(svc.start());
    make_plugin(root, "svc",
                json{{"service", json{{"url", svc.url()}}},
                     {"ui",
                      json{{"panels",
                            json::array({json{{"panel_id", "static"},
                                              {"title", "静态"},
                                              {"description", "说明"}}})}}}}
                    .dump());

    ServiceFixture fx;
    REQUIRE(fx.call("POST", "/api/plugins/reload").status == 200);

    // Declared panel: served from the manifest, the service is not contacted.
    auto declared = fx.call("GET", "/api/plugins/svc/panel/static");
    REQUIRE(declared.status == 200);
    CHECK(declared.json_payload["title"] == "静态");
    CHECK(svc.calls("/panel/").empty());

    // Undeclared panel: proxied; whatever the service answers passes through.
    auto live = fx.call("GET", "/api/plugins/svc/panel/live");
    REQUIRE(live.status == 200);
    CHECK(live.bytes == "ok");  // wildcard responder
    REQUIRE(svc.calls("/panel/live").size() == 1);

    // A non-service plugin's unknown panel stays the local 404 envelope.
    auto miss = fx.call("GET", "/api/plugins/ghost/panel/any");
    CHECK(miss.status == 404);
    CHECK(miss.json_payload == json{{"error", "panel not found"}});
}
