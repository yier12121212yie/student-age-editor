// tests/test_mcp_routes.cpp — HTTP MCP（网页版计划 M2）：
//   * POST /api/mcp 的 JSON-RPC 生命周期（initialize / ping /
//     notifications/initialized / tools/list / tools/call）；
//   * `?readonly=1` 只暴露 9 个只读工具并拦截写工具；
//   * 传输层鉴权：Authorization: Bearer <token> 与 X-Backend-Token 等价可用，
//     缺失/错误一律 403。
#include <catch_amalgamated.hpp>

#include <cstring>
#include <filesystem>
#include <string>

#include "httplib.h"
#include "test_support.h"

#include "sa_core/json_wire.h"
#include "server/api_router.h"
#include "server/httpd.h"
#include "server/state.h"

using sa::json;

namespace {

json mcp_call(sa::Router& r, const json& msg, const std::string& raw_query = "") {
    std::map<std::string, std::string> query;
    if (!raw_query.empty()) {
        size_t pos = 0;
        while (pos <= raw_query.size()) {
            size_t amp = raw_query.find('&', pos);
            std::string pair =
                raw_query.substr(pos, amp == std::string::npos ? std::string::npos : amp - pos);
            size_t eq = pair.find('=');
            query[pair.substr(0, eq)] = eq == std::string::npos ? "" : pair.substr(eq + 1);
            if (amp == std::string::npos) break;
            pos = amp + 1;
        }
    }
    return sat::call_router(r, "POST", "/api/mcp", query, msg, raw_query).json_payload;
}

// 传输层夹具：真端口 + 进程令牌，验证 Bearer 头等价于 X-Backend-Token。
struct AuthFixture {
    std::string root;
    sa::Router router;
    sa::Httpd server;
    std::string base;
    explicit AuthFixture(const std::string& token) : root(sat::make_temp_dir("mcp_auth").string()),
                                                     router(sa::build_router()),
                                                     server(&router) {
        server.set_auth_token(token);
        std::string err;
        REQUIRE(server.bind_to("127.0.0.1", 0, &err));
        server.start();
        base = "http://127.0.0.1:" + std::to_string(server.port());
    }
    ~AuthFixture() { server.stop(); }
};

}  // namespace

TEST_CASE("mcp: initialize advertises the 2025-03-26 protocol and a session header",
          "[mcp]") {
    sat::CfgFixture fx("mcp_init");
    sa::Resp resp = sat::call_router(fx.router(), "POST", "/api/mcp", {},
                                     json{{"jsonrpc", "2.0"}, {"id", 1}, {"method", "initialize"}});
    CHECK(resp.status == 200);
    bool has_session = false;
    for (const auto& kv : resp.headers)
        if (kv.first == "Mcp-Session-Id" && !kv.second.empty()) has_session = true;
    CHECK(has_session);
    const json& j = resp.json_payload;
    CHECK(j["jsonrpc"] == "2.0");
    CHECK(j["id"] == 1);
    CHECK(j["result"]["protocolVersion"] == "2025-03-26");
    CHECK(j["result"]["serverInfo"]["name"] == "student-age-editor-bridge");
    CHECK(j["result"]["capabilities"].contains("tools"));
}

TEST_CASE("mcp: ping returns an empty result object", "[mcp]") {
    sat::CfgFixture fx("mcp_ping");
    json j = mcp_call(fx.router(), json{{"jsonrpc", "2.0"}, {"id", "p"}, {"method", "ping"}});
    CHECK(j["id"] == "p");
    CHECK(j["result"].is_object());
    CHECK(j["result"].empty());
}

TEST_CASE("mcp: notifications/initialized is accepted with no body", "[mcp]") {
    sat::CfgFixture fx("mcp_notify");
    sa::Resp resp = sat::call_router(
        fx.router(), "POST", "/api/mcp", {},
        json{{"jsonrpc", "2.0"}, {"method", "notifications/initialized"}});
    CHECK(resp.status == 202);
    CHECK(resp.bytes.empty());
}

TEST_CASE("mcp: tools/list exposes 13 tools, ?readonly=1 trims to the 9 read-only ones",
          "[mcp]") {
    sat::CfgFixture fx("mcp_tools");
    json all = mcp_call(fx.router(), json{{"jsonrpc", "2.0"}, {"id", 1}, {"method", "tools/list"}});
    const json& tools = all["result"]["tools"];
    REQUIRE(tools.size() == 13);
    CHECK(tools[0]["name"] == "list_domains");
    CHECK(tools[12]["name"] == "set_talk_stage");
    bool has_update = false;
    for (const auto& t : tools)
        if (t["name"] == "update_domain_item") has_update = true;
    CHECK(has_update);

    json ro = mcp_call(fx.router(), json{{"jsonrpc", "2.0"}, {"id", 2}, {"method", "tools/list"}},
                       "readonly=1");
    const json& ro_tools = ro["result"]["tools"];
    REQUIRE(ro_tools.size() == 9);
    for (const auto& t : ro_tools) {
        const std::string n = t["name"].get<std::string>();
        CHECK(n != "update_domain_item");
        CHECK(n != "create_domain_item");
        CHECK(n != "delete_domain_item");
        CHECK(n != "set_talk_stage");
    }
}

TEST_CASE("mcp: tools/call list_domains returns the domain catalogue as text content",
          "[mcp]") {
    sat::CfgFixture fx("mcp_list_domains");
    json j = mcp_call(fx.router(), json{{"jsonrpc", "2.0"},
                                        {"id", 1},
                                        {"method", "tools/call"},
                                        {"params", {{"name", "list_domains"}, {"arguments", json::object()}}}});
    CHECK(j["result"]["isError"] == false);
    const std::string text = j["result"]["content"][0]["text"].get<std::string>();
    json payload = json::parse(text, nullptr, false);
    REQUIRE_FALSE(payload.is_discarded());
    CHECK(payload["domains"].is_array());
    CHECK(payload["domains"].size() > 0);
}

TEST_CASE("mcp: unknown tool is a JSON-RPC error, missing args are a tool error", "[mcp]") {
    sat::CfgFixture fx("mcp_errors");
    json unknown = mcp_call(fx.router(),
                            json{{"jsonrpc", "2.0"},
                                 {"id", 1},
                                 {"method", "tools/call"},
                                 {"params", {{"name", "no_such_tool"}, {"arguments", json::object()}}}});
    CHECK(unknown["error"]["code"] == -32602);
    CHECK(unknown["error"]["message"].get<std::string>().find("Unknown tool") != std::string::npos);

    json missing = mcp_call(fx.router(),
                            json{{"jsonrpc", "2.0"},
                                 {"id", 2},
                                 {"method", "tools/call"},
                                 {"params", {{"name", "get_domain_item"}, {"arguments", json::object()}}}});
    CHECK(missing.contains("result"));
    CHECK(missing["result"]["isError"] == true);
    const std::string msg = missing["result"]["content"][0]["text"].get<std::string>();
    // 顺序守卫：桥 _require(a, "domain", "cfg", "id") 先报 domain；若实现写成
    // 嵌套实参，MSVC 右→左求值会先报 "id"，这里就会失败。
    CHECK(msg.find("domain") != std::string::npos);
}

TEST_CASE("mcp: readonly mode rejects write tools with a JSON-RPC error", "[mcp]") {
    sat::CfgFixture fx("mcp_readonly");
    json j = mcp_call(fx.router(),
                      json{{"jsonrpc", "2.0"},
                           {"id", 1},
                           {"method", "tools/call"},
                           {"params", {{"name", "delete_domain_item"},
                                       {"arguments", {{"domain", "story"}, {"cfg", "EvtCfg"}, {"id", "1"}}}}}},
                      "readonly=1");
    CHECK(j["error"]["code"] == -32602);
    CHECK(j["error"]["message"].get<std::string>().find("只读") != std::string::npos);
}

TEST_CASE("mcp: batch requests are answered as an array, responses echo no id-less items",
          "[mcp]") {
    sat::CfgFixture fx("mcp_batch");
    json batch = json::array();
    batch.push_back(json{{"jsonrpc", "2.0"}, {"id", 1}, {"method", "ping"}});
    batch.push_back(json{{"jsonrpc", "2.0"}, {"method", "notifications/initialized"}});
    batch.push_back(json{{"jsonrpc", "2.0"}, {"id", 2}, {"method", "nope"}});
    json out = mcp_call(fx.router(), batch);
    REQUIRE(out.is_array());
    REQUIRE(out.size() == 2);  // 通知不产生响应
    CHECK(out[0]["id"] == 1);
    CHECK(out[1]["error"]["code"] == -32601);
}

TEST_CASE("mcp: GET /api/mcp reports health metadata", "[mcp]") {
    sat::CfgFixture fx("mcp_get");
    sa::Resp resp = sat::call_router(fx.router(), "GET", "/api/mcp");
    CHECK(resp.status == 200);
    CHECK(resp.json_payload["status"] == "ok");
    CHECK(resp.json_payload["protocolVersion"] == "2025-03-26");
    CHECK(resp.json_payload["tools"] == 13);

    sa::Resp sse = sat::call_router(fx.router(), "GET", "/api/mcp", {{"sse", "1"}});
    CHECK(sse.status == 200);
    CHECK(sse.content_type == "text/event-stream");
    CHECK(sse.bytes.find("data: /api/mcp") != std::string::npos);
}

TEST_CASE("mcp: Authorization Bearer is accepted by the transport like X-Backend-Token",
          "[mcp][auth]") {
    AuthFixture fx("secret-token-123");
    httplib::Client cli(fx.base);
    const std::string body =
        sa_core::py_dumps(json{{"jsonrpc", "2.0"}, {"id", 1}, {"method", "tools/list"}});

    {
        // 无令牌 -> 403，且不进入路由。
        auto res = cli.Post("/api/mcp", body, "application/json");
        REQUIRE(res);
        CHECK(res->status == 403);
    }
    {
        httplib::Headers h{{"Authorization", "Bearer secret-token-123"}};
        auto res = cli.Post("/api/mcp", h, body, "application/json");
        REQUIRE(res);
        CHECK(res->status == 200);
        CHECK(res->get_header_value("Mcp-Session-Id").size() > 0);
    }
    {
        httplib::Headers h{{"X-Backend-Token", "secret-token-123"}};
        auto res = cli.Post("/api/mcp", h, body, "application/json");
        REQUIRE(res);
        CHECK(res->status == 200);
    }
    {
        // scheme 大小写不敏感（RFC 7235）。
        httplib::Headers h{{"Authorization", "bearer secret-token-123"}};
        auto res = cli.Post("/api/mcp", h, body, "application/json");
        REQUIRE(res);
        CHECK(res->status == 200);
    }
    {
        httplib::Headers h{{"Authorization", "Bearer wrong-token"}};
        auto res = cli.Post("/api/mcp", h, body, "application/json");
        REQUIRE(res);
        CHECK(res->status == 403);
    }
    {
        // GET 也走同一道门。
        auto res = cli.Get("/api/mcp");
        REQUIRE(res);
        CHECK(res->status == 403);
    }
}
