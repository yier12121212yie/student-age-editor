// tests/test_mcp_bridge.cpp — C2：网页版 stdio MCP 桥接。
//
// 覆盖：本机默认可用的 policy、托管模式 deny-by-default + 命令白名单，
// 以及一次真实的 start → SSE 读取 → stop 往返（用系统 shell 的 echo 造一条
// JSON-RPC 响应，不依赖任何外部 MCP 服务器）。
#include <catch_amalgamated.hpp>

#include <fstream>
#include <string>

#include "sa_core/paths.h"
#include "server/httpd.h"
#include "server/services/mcp_bridge.h"
#include "test_support.h"

namespace {

struct EnvRestore {
    std::string key;
    std::string saved;
    bool had = false;
    EnvRestore(std::string k, std::string v) : key(std::move(k)) {
        saved = sa_core::paths::getenv_utf8(key.c_str());
        had = !saved.empty();
        sa_core::paths::setenv_utf8(key.c_str(), v, true);
    }
    ~EnvRestore() { sa_core::paths::setenv_utf8(key.c_str(), had ? saved : "", true); }
    EnvRestore(const EnvRestore&) = delete;
    EnvRestore& operator=(const EnvRestore&) = delete;
};

struct Collect : sa::StreamEmitter {
    std::string body;
    int status = 0;
    bool start(int s, std::string,
               std::vector<std::pair<std::string, std::string>>) override {
        status = s;
        return true;
    }
    bool write(std::string_view c) override {
        body.append(c.data(), c.size());
        return true;
    }
};

}  // namespace

TEST_CASE("mcp bridge: local backend is available without an allowlist", "[mcp][bridge]") {
    EnvRestore hosted("EDITOR_HOSTED", "");
    EnvRestore allow("EDITOR_MCP_STDIO_ALLOW", "");
    sat::CfgFixture fx("mcp_bridge_policy");
    auto r = sat::call_router(fx.router(), "GET", "/api/mcp/stdio/policy");
    REQUIRE(r.status == 200);
    CHECK(r.json_payload["available"] == true);
    CHECK(r.json_payload["hosted"] == false);
}

TEST_CASE("mcp bridge: hosted mode is deny-by-default + allowlist", "[mcp][bridge]") {
    EnvRestore hosted("EDITOR_HOSTED", "1");
    EnvRestore allow("EDITOR_MCP_STDIO_ALLOW", "");
    sat::CfgFixture fx("mcp_bridge_hosted");

    auto pol = sat::call_router(fx.router(), "GET", "/api/mcp/stdio/policy");
    REQUIRE(pol.status == 200);
    CHECK(pol.json_payload["available"] == false);
    CHECK(pol.json_payload["hosted"] == true);

    auto start = sat::call_router(
        fx.router(), "POST", "/api/mcp/stdio/start", {},
        sa::json{{"command", "cmd"}, {"args", sa::json::array()}});
    CHECK(start.status == 403);

    // 管理员开启白名单后：白名单内命令通过策略关，名单外仍 403。
    sa_core::paths::setenv_utf8("EDITOR_MCP_STDIO_ALLOW", "sh,cmd", true);
    auto pol2 = sat::call_router(fx.router(), "GET", "/api/mcp/stdio/policy");
    CHECK(pol2.json_payload["available"] == true);
    auto denied = sat::call_router(fx.router(), "POST", "/api/mcp/stdio/start", {},
                                   sa::json{{"command", "/usr/bin/evil"}});
    CHECK(denied.status == 403);
}

TEST_CASE("mcp bridge: start -> stream -> stop round-trip", "[mcp][bridge]") {
    EnvRestore hosted("EDITOR_HOSTED", "");
    EnvRestore allow("EDITOR_MCP_STDIO_ALLOW", "");
    sat::CfgFixture fx("mcp_bridge_run");
    // 通过「打印一个文件」造响应：shell 的内联引号在 Windows 的命令行转义
    // （cmd.exe 不认 \"）下不可靠，type/cat 一个 UTF-8 文件最稳。
    const std::string resp_line =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const std::string resp_path =
        sa_core::paths::path_to_utf8(fx.root() / "mcp_resp.json");
    {
        std::ofstream f(sa_core::paths::to_path(resp_path), std::ios::binary);
        f << resp_line << "\n";
    }
#ifdef _WIN32
    // 覆盖 Windows 上最常见的包装写法 `cmd /c <命令>`（与桌面端 MCP 配置
    // 一致）：程序名不强制加引号，cmd 才能正确识别 /c 后面的命令。
    const std::string command = "cmd";
    const sa::json args = sa::json::array({"/c", "type " + resp_path});
#else
    const std::string command = "cat";
    const sa::json args = sa::json::array({resp_path});
#endif
    auto start = sat::call_router(
        fx.router(), "POST", "/api/mcp/stdio/start", {},
        sa::json{{"command", command}, {"args", args}});
    REQUIRE(start.status == 200);
    const std::string sid = start.json_payload.value("session_id", std::string());
    REQUIRE(sid.size() == 32);

    sa::Req sreq;
    sreq.method = "GET";
    sreq.path = "/api/mcp/stdio/stream";
    sreq.query["session_id"] = sid;
    auto resp = fx.router().dispatch(sreq);
    REQUIRE(resp.body_stream);
    Collect c;
    CHECK(resp.body_stream(c));
    CHECK(c.status == 200);
    INFO("body: " << c.body);
    CHECK(std::filesystem::exists(sa_core::paths::to_path(resp_path)));
    CHECK(c.body.find("\"id\":1") != std::string::npos);

    auto stop = sat::call_router(fx.router(), "POST", "/api/mcp/stdio/stop", {},
                                 sa::json{{"session_id", sid}});
    CHECK(stop.status == 200);
    // 幂等：重复 stop 仍是 200。
    CHECK(sat::call_router(fx.router(), "POST", "/api/mcp/stdio/stop", {},
                           sa::json{{"session_id", sid}})
              .status == 200);
    sa::mcp_bridge::shutdown_all_for_test();
}
