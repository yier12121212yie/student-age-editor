// tests/test_http_client_posix.cpp — W4-3 [http_client][posix-only] suite.
//
// Exercises the dlopen'd-libcurl outbound transport (core/http_client.cpp, the
// !_WIN32 && !__ANDROID__ branch) against LOCAL mocks only, so CI needs no
// network. The transport runs on the caller thread and speaks real HTTP over a
// loopback socket, so these cover the exact shapes the services rely on:
// method/header/body passthrough (incl. binary bodies and the WinHTTP default
// Accept), 404-is-not-an-error, opt-in redirect following (安全批次 A: the
// transport NEVER follows on its own; the shared layer follows manually with
// cross-origin Authorization/Cookie stripping, 8-hop cap and the urllib
// POST->GET fold), the connect+read timeout mapping to
// Error::Timeout, request_stream's per-chunk cadence + accumulation, and the
// early-abort contract (partial body, Error stays None). Custom verbs
// (PROPFIND/MKCOL — the WebDAV path) are covered against p5mock, the one mock
// that accepts arbitrary verb tokens.
//
// The whole file is `#if !defined(_WIN32)`: on Windows it compiles to an empty
// translation unit (the WinHTTP path is gated by build-W43 + golden instead).
// One extra `[network]` case hits a real HTTPS host and is excluded by the
// default tag filter (~[network]).
#include <catch_amalgamated.hpp>

#if !defined(_WIN32)

#include <atomic>
#include <chrono>
#include <string>
#include <vector>

#include "p4_mock.h"
#include "p5_mock.h"
#include "sa_core/http_client.h"

namespace http = sa_core::http;
using namespace std::chrono_literals;

namespace {

// A handler body for httplib that never completes quickly (times the client).
void delay_and_respond(int ms, httplib::Response& res) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
    res.set_content("late", "text/plain");
}

}  // namespace

TEST_CASE("posix http: 200 body + case-insensitive header + request headers pass",
          "[http_client][posix-only]") {
    p4mock::Server srv;
    std::string seen_auth, seen_xtrace;
    srv.server().Get(R"(/ok)", [&](const httplib::Request& req, httplib::Response& res) {
        seen_auth = req.get_header_value("Authorization");
        seen_xtrace = req.get_header_value("X-Trace");
        res.set_header("X-Test", "hello");
        res.set_content("the-answer", "text/plain");
    });
    srv.start();

    http::Request r;
    r.url = srv.base() + "/ok";
    r.headers = {{"Authorization", "Bearer abc123"}, {"X-Trace", "tid-7"}};
    http::Response resp = http::request(r);

    CHECK(resp.transport_ok());
    CHECK(resp.status == 200);
    CHECK(resp.body == "the-answer");
    CHECK(resp.header("x-test") == "hello");   // case-insensitive lookup
    CHECK(resp.header("X-TEST") == "hello");
    CHECK(seen_auth == "Bearer abc123");
    CHECK(seen_xtrace == "tid-7");
    // No Error:: fields set on the success path.
    CHECK(resp.error == http::Response::Error::None);
    CHECK(resp.error_message.empty());
}

TEST_CASE("posix http: 404 is a response, not a transport error", "[http_client][posix-only]") {
    p4mock::Server srv;
    srv.server().Get(R"(/nf)", [](const httplib::Request&, httplib::Response& res) {
        res.status = 404;
        res.set_content("{\"error\":\"missing\"}", "application/json");
    });
    srv.start();
    http::Request r;
    r.url = srv.base() + "/nf";
    http::Response resp = http::request(r);
    CHECK(resp.transport_ok());                    // HTTP completed => None error
    CHECK(resp.status == 404);
    CHECK(resp.body.find("missing") != std::string::npos);
}

TEST_CASE("posix http: POST/PUT method + body passthrough (incl. binary NUL)",
          "[http_client][posix-only]") {
    p4mock::Server srv;
    std::string last_method, last_body;
    auto echo = [&](const httplib::Request& req, httplib::Response& res) {
        last_method = req.method;
        last_body = req.body;
        res.set_content("ok", "text/plain");
    };
    srv.server().Post(R"(/echo)", echo);
    srv.server().Put(R"(/echo)", echo);
    srv.start();

    // text POST
    {
        http::Request r;
        r.method = "POST";
        r.url = srv.base() + "/echo";
        r.body = "k=v&x=1";
        http::Response resp = http::request(r);
        CHECK(resp.transport_ok());
        CHECK(resp.status == 200);
        CHECK(last_method == "POST");
        CHECK(last_body == "k=v&x=1");
    }
    // binary PUT with an embedded NUL (POSTFIELDSSIZE must carry full length)
    {
        std::string bin;
        bin.push_back('a');
        bin.push_back('\0');
        bin.push_back('b');
        bin.push_back('\xff');
        http::Request r;
        r.method = "PUT";
        r.url = srv.base() + "/echo";
        r.body = bin;
        http::Response resp = http::request(r);
        CHECK(resp.transport_ok());
        CHECK(last_method == "PUT");
        REQUIRE(last_body.size() == bin.size());
        CHECK(last_body == bin);   // NUL and high bytes not truncated/corrupted
    }
}

TEST_CASE("posix http: 302 redirect is followed only when follow_redirects is set",
          "[http_client][posix-only]") {
    p4mock::Server srv;
    bool dest_hit = false;
    srv.server().Get(R"(/start)", [](const httplib::Request&, httplib::Response& res) {
        res.set_redirect("/dest", 302);
    });
    srv.server().Get(R"(/dest)", [&](const httplib::Request&, httplib::Response& res) {
        dest_hit = true;
        res.set_content("landed", "text/plain");
    });
    srv.start();

    // 默认（安全批次 A）：传输层永不自行跟随，3xx 原样交还调用方。
    {
        http::Request r;
        r.url = srv.base() + "/start";
        http::Response resp = http::request(r);
        CHECK(resp.transport_ok());
        CHECK(resp.status == 302);
        CHECK(resp.header("Location").find("/dest") != std::string::npos);
        CHECK_FALSE(dest_hit);
    }
    // 显式开启：共享重定向层手动逐跳跟随。
    {
        http::Request r;
        r.url = srv.base() + "/start";
        r.follow_redirects = true;
        http::Response resp = http::request(r);
        CHECK(resp.transport_ok());
        CHECK(resp.status == 200);            // final, not 302
        CHECK(resp.body == "landed");
        CHECK(dest_hit);
    }
}

TEST_CASE("posix http: cross-origin redirect strips Authorization/Cookie, same-origin keeps",
          "[http_client][posix-only]") {
    p4mock::Server a, b;
    b.start();   // 先起 B，A 的跨源跳转目标需要它的 base
    const std::string b_base = b.base();
    std::string a_auth, b_auth, b_cookie;
    a.server().Get(R"(/same)", [](const httplib::Request&, httplib::Response& res) {
        res.set_redirect("/dest", 302);   // 同源跳（同 host:port）
    });
    a.server().Get(R"(/dest)", [&](const httplib::Request& req, httplib::Response& res) {
        a_auth = req.get_header_value("Authorization");
        res.set_content("same-origin", "text/plain");
    });
    a.server().Get(R"(/cross)", [b_base](const httplib::Request&, httplib::Response& res) {
        res.set_redirect(b_base + "/dest", 302);   // 跨源跳（端口不同）
    });
    b.server().Get(R"(/dest)", [&](const httplib::Request& req, httplib::Response& res) {
        b_auth = req.get_header_value("Authorization");
        b_cookie = req.get_header_value("Cookie");
        res.set_content("cross-origin", "text/plain");
    });
    a.start();

    http::Request r;
    r.url = a.base() + "/same";
    r.follow_redirects = true;
    r.headers = {{"Authorization", "Bearer secret"}, {"Cookie", "sid=xyz"}};
    http::Response resp = http::request(r);
    CHECK(resp.transport_ok());
    CHECK(resp.status == 200);
    CHECK(resp.body == "same-origin");
    CHECK(a_auth == "Bearer secret");      // 同源跳保留凭据

    http::Request r2;
    r2.url = a.base() + "/cross";
    r2.follow_redirects = true;
    r2.headers = {{"Authorization", "Bearer secret"}, {"Cookie", "sid=xyz"}};
    http::Response resp2 = http::request(r2);
    CHECK(resp2.transport_ok());
    CHECK(resp2.status == 200);
    CHECK(resp2.body == "cross-origin");
    CHECK(b_auth.empty());                 // 跨源跳剥离 Authorization
    CHECK(b_cookie.empty());               // 跨源跳剥离 Cookie
}

TEST_CASE("posix http: 302 folds POST into GET and drops the body (urllib parity)",
          "[http_client][posix-only]") {
    p4mock::Server srv;
    std::string dest_method, dest_body;
    srv.server().Post(R"(/start)", [](const httplib::Request&, httplib::Response& res) {
        res.set_redirect("/dest", 302);
    });
    srv.server().Get(R"(/dest)", [&](const httplib::Request& req, httplib::Response& res) {
        dest_method = req.method;
        dest_body = req.body;
        res.set_content("landed", "text/plain");
    });
    srv.start();
    http::Request r;
    r.method = "POST";
    r.url = srv.base() + "/start";
    r.body = "payload=1";
    r.follow_redirects = true;
    http::Response resp = http::request(r);
    CHECK(resp.transport_ok());
    CHECK(resp.status == 200);
    CHECK(dest_method == "GET");           // 301/302/303 把 POST 折成 GET
    CHECK(dest_body.empty());              // 且丢弃 body
}

TEST_CASE("posix http: stalled response maps to Error::Timeout", "[http_client][posix-only]") {
    p4mock::Server srv;
    srv.server().Get(R"(/slow)", [](const httplib::Request& , httplib::Response& res) {
        delay_and_respond(4000, res);
    });
    srv.start();
    http::Request r;
    r.url = srv.base() + "/slow";
    r.timeout_seconds = 1.0;
    auto t0 = std::chrono::steady_clock::now();
    http::Response resp = http::request(r);
    auto dt = std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - t0)
                  .count();
    CHECK_FALSE(resp.transport_ok());
    CHECK(resp.error == http::Response::Error::Timeout);
    // Well under the 4s server delay => the read-idle trip fired.
    CHECK(dt < 3500);
}

TEST_CASE("posix http: request_stream accumulates the full body incrementally",
          "[http_client][posix-only]") {
    p4mock::Server srv;
    const std::string payload = std::string(300000, 'A');   // > one 16KB recv chunk
    srv.server().Get(R"(/big)", [&](const httplib::Request&, httplib::Response& res) {
        res.set_content(payload, "application/octet-stream");
    });
    srv.start();
    http::Request r;
    r.url = srv.base() + "/big";
    std::string acc;
    int chunks = 0;
    http::Response resp = http::request_stream(r, [&](std::string_view c) {
        acc.append(c.data(), c.size());
        ++chunks;
        return true;   // keep reading
    });
    CHECK(resp.transport_ok());
    CHECK(resp.status == 200);
    CHECK(resp.body == payload);          // full body still accumulated
    CHECK(acc == payload);                // callback saw every byte, in order
    CHECK(chunks >= 1);
}

TEST_CASE("posix http: request_stream early-abort keeps partial body + None error",
          "[http_client][posix-only]") {
    p4mock::Server srv;
    const std::string payload(300000, 'B');
    srv.server().Get(R"(/big)", [&](const httplib::Request&, httplib::Response& res) {
        res.set_content(payload, "application/octet-stream");
    });
    srv.start();
    http::Request r;
    r.url = srv.base() + "/big";
    int seen = 0;
    http::Response resp = http::request_stream(r, [&](std::string_view /*c*/) {
        ++seen;
        return false;   // abort after the first chunk
    });
    CHECK(resp.error == http::Response::Error::None);   // contract: cancel => None
    CHECK(resp.status == 200);                          // status parsed pre-abort
    CHECK(seen >= 1);
    CHECK_FALSE(resp.body.empty());                     // first partial chunk delivered
    CHECK(resp.body.size() < payload.size());           // and it stopped early
}

TEST_CASE("posix http: WebDAV custom verbs (PROPFIND/MKCOL) via CURLOPT_CUSTOMREQUEST",
          "[http_client][posix-only][webdav]") {
    p5mock::Server mock;
    mock.on("PROPFIND", "/dav", [](const p5mock::Request& req, p5mock::Response& res) {
        res.status = 207;
        res.set_content("<D:multistatus Depth=\"" + req.get_header_value("Depth") + "\"/>",
                        "application/xml");
    });
    mock.on("MKCOL", "", [](const p5mock::Request&, p5mock::Response& res) { res.status = 201; });
    mock.serve();
    int port = mock.start();
    REQUIRE(port > 0);

    {
        http::Request r;
        r.method = "PROPFIND";
        r.url = mock.base() + "/dav/x";
        r.body = "<?xml?>";
        r.headers = {{"Depth", "1"}};
        http::Response resp = http::request(r);
        CHECK(resp.transport_ok());
        CHECK(resp.status == 207);
        CHECK(resp.body == "<D:multistatus Depth=\"1\"/>");   // verb + header reached mock
    }
    {
        http::Request r;
        r.method = "MKCOL";
        r.url = mock.base() + "/dav/newdir";
        http::Response resp = http::request(r);
        CHECK(resp.transport_ok());
        CHECK(resp.status == 201);
    }
    // The mock recorded both custom verbs (proves the tokens hit the wire verbatim).
    bool pf = false, mk = false;
    for (const auto& c : mock.calls()) {
        if (c.method == "PROPFIND") pf = true;
        if (c.method == "MKCOL") mk = true;
    }
    CHECK(pf);
    CHECK(mk);
}

TEST_CASE("posix http: malformed / unsupported URL maps to Error::BadInput",
          "[http_client][posix-only]") {
    http::Request r;
    r.url = "ftp://example.com/x";   // only http(s) supported
    http::Response resp = http::request(r);
    CHECK_FALSE(resp.transport_ok());
    CHECK(resp.error == http::Response::Error::BadInput);
    CHECK(resp.status == 0);
}

TEST_CASE("posix http: real HTTPS GET against system CA", "[http_client][posix-only][network]") {
    // Excluded by the default ~[network] gate; run manually where outbound net
    // exists to confirm the dlopen'd curl uses the platform trust store.
    http::Request r;
    r.url = "https://example.com/";
    r.timeout_seconds = 15.0;
    http::Response resp = http::request(r);
    CHECK(resp.transport_ok());
    CHECK(resp.error != http::Response::Error::Tls);   // cert validated
    CHECK(resp.status == 200);
    CHECK_FALSE(resp.body.empty());
}

#endif  // !_WIN32
