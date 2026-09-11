// tests/test_httpd.cpp — transport contract (port of the httpd.py behaviours in
// CONVENTIONS 2): routing, origin checks, Content-Length validation, _raw body,
// query last-value, bytes 直发, 503 slot ceiling (B13), OPTIONS 204 (B12),
// header set. Black-box where practical (real loopback socket + httplib client);
// in-process dispatch where a client library cannot express the case
// (malformed Content-Length framing).
#include <catch_amalgamated.hpp>

#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

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
#include "sa_core/json_wire.h"
#include "sa_core/utf8.h"
#include "server/api_router.h"
#include "server/httpd.h"

namespace {

// ---------------------------------------------------------------------------
// raw test socket helpers (only for cases a client library cannot express)
// ---------------------------------------------------------------------------
#ifdef _WIN32
using test_socket_t = SOCKET;
inline bool sock_valid(test_socket_t s) { return s != INVALID_SOCKET; }
inline void close_test_socket(test_socket_t s) { closesocket(s); }
#else
using test_socket_t = int;
inline bool sock_valid(test_socket_t s) { return s >= 0; }
inline void close_test_socket(test_socket_t s) { ::close(s); }
#endif

inline test_socket_t make_test_socket(int port) {
#ifdef _WIN32
    test_socket_t s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
#else
    test_socket_t s = ::socket(AF_INET, SOCK_STREAM, 0);
#endif
    if (!sock_valid(s)) return s;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<unsigned short>(port));
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        close_test_socket(s);
#ifdef _WIN32
        return INVALID_SOCKET;
#else
        return -1;
#endif
    }
    return s;
}

inline void send_all_test(test_socket_t s, const char* data, size_t len) {
    size_t off = 0;
    while (off < len) {
        int n = static_cast<int>(::send(s, data + off, static_cast<unsigned>(len - off), 0));
        if (n <= 0) return;
        off += static_cast<size_t>(n);
    }
}

// Read one full HTTP response (head + Content-Length body) from a raw socket.
inline std::string read_http_response(test_socket_t s) {
    std::string resp;
    char buf[2048];
    for (int rounds = 0; rounds < 50; ++rounds) {
        int n = static_cast<int>(::recv(s, buf, sizeof(buf), 0));
        if (n <= 0) break;
        resp.append(buf, static_cast<size_t>(n));
        size_t pos = resp.find("\r\n\r\n");
        if (pos == std::string::npos) continue;
        long long want = -1;
        size_t start = 0;
        while (start < pos) {
            size_t nl = resp.find("\r\n", start);
            if (nl == std::string::npos || nl > pos) break;
            std::string line = resp.substr(start, nl - start);
            start = nl + 2;
            std::string lower;
            for (char c : line) {
                lower.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
            }
            if (lower.rfind("content-length:", 0) == 0) {
                want = atoll(lower.c_str() + strlen("content-length:"));
            }
        }
        if (want >= 0 && resp.size() >= pos + 4 + static_cast<size_t>(want)) break;
    }
    return resp;
}

// ---------------------------------------------------------------------------
// fixture: real transport on a loopback port, route bus from build_router()
// ---------------------------------------------------------------------------
struct ServerFixture {
    sa::Router router;
    sa::Httpd server;
    std::string base;
    ServerFixture() : router(sa::build_router()), server(&router) {
        std::string err;
        REQUIRE(server.bind_to("127.0.0.1", 0, &err));
        server.start();
        base = "http://127.0.0.1:" + std::to_string(server.port());
    }
    ~ServerFixture() { server.stop(); }
};

}  // namespace

TEST_CASE("router: named groups, 404 envelope, exception -> 500", "[httpd][router]") {
    sa::Router r;
    r.get(R"(/api/cfg/(?P<name>[^/]+))", [](const sa::Req& req) {
        sa::json body;
        body["name"] = req.params.at("name");
        return sa::Resp::Json(200, body);
    });
    sa::Req req;
    req.method = "GET";
    req.path = "/api/cfg/EvtCfg";
    auto res = r.dispatch(req);
    CHECK(res.status == 200);
    CHECK(res.json_payload["name"] == "EvtCfg");

    sa::Req miss;
    miss.method = "GET";
    miss.path = "/api/nope";
    auto m = r.dispatch(miss);
    CHECK(m.status == 404);
    CHECK(m.json_payload["error"] == "no route: GET /api/nope");

    sa::Req boom;
    boom.method = "GET";
    boom.path = "/api/cfg/Boom";
    sa::Router r2;
    r2.get(R"(/api/cfg/(?P<name>[^/]+))",
           [](const sa::Req&) -> sa::Resp { throw sa::ApiError("KeyError", "'x'"); });
    auto b = r2.dispatch(boom);
    CHECK(b.status == 500);
    // httpd.py:70-72: {"error": "<Type>: <message>"}
    CHECK(b.json_payload["error"] == "KeyError: 'x'");

    // registration order decides when both patterns match
    sa::Router r3;
    r3.get(R"(/api/x/(?P<name>.+))",
           [](const sa::Req&) { return sa::Resp::Json(200, sa::json{{"hit", "first"}}); });
    r3.get(R"(/api/x/(?P<name>[0-9]+))",
           [](const sa::Req&) { return sa::Resp::Json(200, sa::json{{"hit", "second"}}); });
    sa::Req q;
    q.method = "GET";
    q.path = "/api/x/42";
    CHECK(r3.dispatch(q).json_payload["hit"] == "first");
}

TEST_CASE("pattern conversion handles Python named groups", "[httpd]") {
    std::vector<std::string> names;
    auto conv = sa::py_pattern_to_std(R"(/api/cfg/(?P<name>[^/]+)/sub/(?P<tail>.*))", &names);
    CHECK(names.size() == 2);
    CHECK(names[0] == "name");
    CHECK(names[1] == "tail");
    std::regex rx(conv);
    CHECK(std::regex_match("/api/cfg/Evt/sub/a/b", rx));
}

TEST_CASE("GET /api/ping over the wire: status + headers + body", "[httpd][contract]") {
    ServerFixture fx;
    httplib::Client cli(fx.base);
    auto res = cli.Get("/api/ping");
    REQUIRE(res);
    CHECK(res->status == 200);
    CHECK(res->get_header_value("Content-Type") == "application/json; charset=utf-8");
    CHECK(res->get_header_value("Cache-Control") == "no-store");
    CHECK(res->get_header_value("Access-Control-Allow-Origin") == "http://127.0.0.1");
    CHECK(res->get_header_value("Access-Control-Allow-Methods") ==
          "GET, POST, PUT, DELETE, OPTIONS");
    CHECK(res->get_header_value("Access-Control-Allow-Headers") == "Content-Type");
    CHECK(res->get_header_value("Content-Length") == std::to_string(res->body.size()));
    // httpd.py emits no Server/Date headers; the raw transport matches.
    CHECK(res->get_header_value("Server").empty());
    auto j = sa::json::parse(res->body);
    CHECK(j["ok"] == true);
    CHECK(j["app"] == "student-age-editor");
    CHECK(j["cfg_patch"] == true);
    CHECK(j["state"]["aa_status"] == "idle");
}

TEST_CASE("404 envelope over the wire is JSON, not HTML", "[httpd][contract]") {
    ServerFixture fx;
    httplib::Client cli(fx.base);
    auto res = cli.Get("/api/nope");
    REQUIRE(res);
    CHECK(res->status == 404);
    auto j = sa::json::parse(res->body);
    CHECK(j["error"] == "no route: GET /api/nope");
}

TEST_CASE("origin/host validation (httpd.py:76-115)", "[httpd][B12]") {
    ServerFixture fx;
    httplib::Client cli(fx.base);
    {
        httplib::Headers h{{"Host", "evil.example.com"}};
        auto res = cli.Get("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 403);
        CHECK(sa::json::parse(res->body)["error"] == "forbidden host");
    }
    {
        httplib::Headers h{{"Origin", "https://evil.example.com"}};
        auto res = cli.Get("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 403);
        CHECK(sa::json::parse(res->body)["error"] == "forbidden origin");
    }
    {
        httplib::Headers h{{"Origin", "http://127.0.0.1:51234"}};
        auto res = cli.Get("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 200);
    }
    {
        // Host with port (IPv4 loopback) and localhost both pass
        httplib::Headers h{{"Host", "localhost:8765"}};
        auto res = cli.Get("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 200);
    }
    {
        // IPv6 bracketed host form (httpd.py:76-86 _host_without_port)
        httplib::Headers h{{"Host", "[::1]:8765"}};
        auto res = cli.Get("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 200);
    }
    {
        // OPTIONS preflight shares the same check (B12) but passes -> 204
        httplib::Headers h{{"Origin", "http://localhost:3000"}};
        auto res = cli.Options("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 204);
        CHECK(res->body.empty());
        CHECK(res->get_header_value("Access-Control-Allow-Methods") ==
              "GET, POST, PUT, DELETE, OPTIONS");
        CHECK(res->get_header_value("Content-Length") == "0");
    }
    {
        httplib::Headers h{{"Origin", "https://evil.example.com"}};
        auto res = cli.Options("/api/ping", h);
        REQUIRE(res);
        CHECK(res->status == 403);  // B12: preflight is validated too
    }
}

TEST_CASE("invalid Content-Length -> 400 JSON envelope (httpd.py:135-139)", "[httpd]") {
    ServerFixture fx;
    auto sock = make_test_socket(fx.server.port());
    REQUIRE(sock_valid(sock));
    const char* req =
        "PUT /api/cfg/x HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        "Content-Length: not-a-number\r\n\r\n{}";
    send_all_test(sock, req, strlen(req));
    std::string resp = read_http_response(sock);
    close_test_socket(sock);
    REQUIRE(!resp.empty());
    CHECK(resp.find("HTTP/1.1 400") != std::string::npos);
    CHECK(resp.find("invalid Content-Length") != std::string::npos);
}

TEST_CASE("oversized Content-Length -> 413 before the body is buffered", "[httpd]") {
    ServerFixture fx;
    auto sock = make_test_socket(fx.server.port());
    REQUIRE(sock_valid(sock));
    // Advertise far more than the cap while sending no body at all: the server
    // must refuse from the header alone (it used to try to buffer the whole
    // declared size in memory).
    const char* req =
        "PUT /api/cfg/x HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        "Content-Length: 999999999999\r\n\r\n";
    send_all_test(sock, req, strlen(req));
    std::string resp = read_http_response(sock);
    close_test_socket(sock);
    REQUIRE(!resp.empty());
    CHECK(resp.find("HTTP/1.1 413") != std::string::npos);
    CHECK(resp.find("request body too large") != std::string::npos);
}

TEST_CASE("body JSON parse failure arrives as {\"_raw\": text}", "[httpd]") {
    ServerFixture fx;
    fx.router.put(R"(/api/echo)", [](const sa::Req& req) {
        sa::json body;
        body["got_raw"] = req.body.contains("_raw");
        body["raw_text"] = req.body.contains("_raw") ? req.body.at("_raw") : sa::json();
        return sa::Resp::Json(200, body);
    });
    httplib::Client cli(fx.base);
    auto res = cli.Put("/api/echo", "this is {not json", "application/json");
    REQUIRE(res);
    auto j = sa::json::parse(res->body);
    CHECK(j["got_raw"] == true);
    CHECK(j["raw_text"] == "this is {not json");
}

TEST_CASE("query: last value wins, blanks dropped, path unquoted", "[httpd][query]") {
    ServerFixture fx;
    fx.router.get(R"(/api/echoq)", [](const sa::Req& req) {
        sa::json body = sa::json::object();
        for (const auto& [k, v] : req.query) body[k] = v;
        body["_path"] = req.path;
        return sa::Resp::Json(200, body);
    });
    httplib::Client cli(fx.base);
    auto res = cli.Get("/api/echoq?a=1&a=2&b=&c=%E6%97%A7");
    REQUIRE(res);
    auto j = sa::json::parse(res->body);
    CHECK(j["a"] == "2");           // {k: v[-1]} semantics (httpd.py:134)
    CHECK_FALSE(j.contains("b"));   // parse_qs drops blank values
    CHECK(j["c"] == "旧");         // percent-decoded UTF-8
    CHECK(j["_path"] == "/api/echoq");
}

TEST_CASE("bytes 直发: handler bytes payload goes out verbatim", "[httpd][S1]") {
    ServerFixture fx;
    std::string payload = "{\"cfg\": \"X\", \"data\": {\"k\": \"值\"}}";
    fx.router.get(R"(/api/raw)", [&payload](const sa::Req&) {
        return sa::Resp::Bytes(200, payload);
    });
    httplib::Client cli(fx.base);
    auto res = cli.Get("/api/raw");
    REQUIRE(res);
    CHECK(res->body == payload);  // no re-serialization: byte-for-byte
}

TEST_CASE("503 bare response when the 64-slot pool is saturated (B13)", "[httpd][B13]") {
    ServerFixture fx;
    std::atomic<bool> hold{true};
    std::atomic<int> arrived{0};
    fx.router.get(R"(/api/slow)", [&hold, &arrived](const sa::Req&) {
        arrived.fetch_add(1);
        while (hold.load()) std::this_thread::sleep_for(std::chrono::milliseconds(5));
        return sa::Resp::Json(200, sa::json{{"ok", true}});
    });
    std::vector<std::thread> threads;
    std::atomic<int> got503{0};
    std::atomic<int> done{0};
    const int kConc = 70;  // > 64 slots
    for (int i = 0; i < kConc; ++i) {
        threads.emplace_back([&]() {
            httplib::Client cli(fx.base);
            cli.set_read_timeout(30, 0);
            auto res = cli.Get("/api/slow");
            if (!res || res->status == 503) got503.fetch_add(1);
            done.fetch_add(1);
        });
    }
    while (arrived.load() < 64 && done.load() < kConc) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    CHECK(got503.load() >= kConc - 64);  // everyone over the ceiling got 503
    hold.store(false);
    for (auto& t : threads) t.join();
    CHECK(done.load() == kConc);
}

TEST_CASE("keep-alive: two requests reuse one connection", "[httpd][keepalive]") {
    ServerFixture fx;
    fx.router.get(R"(/api/ka)",
                  [](const sa::Req&) { return sa::Resp::Json(200, sa::json{{"ok", true}}); });
    httplib::Client cli(fx.base);
    auto r1 = cli.Get("/api/ka");
    auto r2 = cli.Get("/api/ka");
    REQUIRE(r1);
    REQUIRE(r2);
    CHECK(r1->status == 200);
    CHECK(r2->status == 200);
}

TEST_CASE("destructor drains a parked keep-alive connection without hanging",
          "[httpd][keepalive][shutdown]") {
    // A connected-but-idle client holds serve_connection inside recv() with a
    // 65s timeout. Before the fix the destructor's 2s drain expired and the
    // detached thread went on to dereference the destroyed Router (UAF). The
    // destructor must now shutdown() the socket, wake the thread, and return
    // promptly (well under the 65s idle timeout).
    bool connected = false;
    test_socket_t s = INVALID_SOCKET;
#ifndef _WIN32
    s = -1;
#endif
    auto t0 = std::chrono::steady_clock::now();
    {
        auto router = std::make_unique<sa::Router>(sa::build_router());
        auto server = std::make_unique<sa::Httpd>(router.get());
        std::string err;
        REQUIRE(server->bind_to("127.0.0.1", 0, &err));
        server->start();
        s = make_test_socket(server->port());
        REQUIRE(sock_valid(s));
        connected = true;
        // Complete one request, then sit idle on the still-open connection.
        const char* req = "GET /api/ping HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
        send_all_test(s, req, strlen(req));
        std::string resp = read_http_response(s);
        CHECK(resp.find("200") != std::string::npos);
        t0 = std::chrono::steady_clock::now();
        // server (then router) destroyed here: this is what used to UAF/hang.
    }
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                       std::chrono::steady_clock::now() - t0)
                       .count();
    CHECK(elapsed < 5000);
    if (connected) close_test_socket(s);
}

TEST_CASE("destructor waits for an in-flight slow handler (no UAF)",
          "[httpd][keepalive][shutdown]") {
    // A handler may legitimately run for minutes (ai_image/tts use 300s outbound
    // timeouts), so ~Httpd must not return -- and must not free Impl or the
    // caller's Router -- while such a handler is still executing on its detached
    // thread. The pre-fix code gave up after a fixed ~60s guard, which is not
    // waitable in a unit test; a 2s handler still catches any regression to a
    // shorter bounded guard and, under ASan, any early-free UAF.
    auto router = std::make_unique<sa::Router>(sa::build_router());
    std::atomic<bool> entered{false};
    std::atomic<bool> release{false};
    std::atomic<bool> handler_done{false};
    router->get(R"(/api/block)", [&](const sa::Req&) {
        entered.store(true);
        while (!release.load()) std::this_thread::sleep_for(std::chrono::milliseconds(5));
        handler_done.store(true);
        return sa::Resp::Json(200, sa::json{{"ok", true}});
    });
    auto server = std::make_unique<sa::Httpd>(router.get());
    std::string err;
    REQUIRE(server->bind_to("127.0.0.1", 0, &err));
    server->start();
    const int port = server->port();

    std::thread client([&]() {
        httplib::Client cli("127.0.0.1", port);
        cli.set_read_timeout(10, 0);
        cli.Get("/api/block");  // status ignored: the socket is woken mid-flight
    });
    for (int i = 0; i < 400 && !entered.load(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    REQUIRE(entered.load());

    // Destroy server (then the Router) while the handler is mid-flight.
    auto t0 = std::chrono::steady_clock::now();
    std::thread destroyer([&]() {
        server.reset();
        router.reset();
    });
    // The destructor must still be blocked at 500ms: the handler is not released.
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    CHECK_FALSE(handler_done.load());
    release.store(true);
    destroyer.join();
    client.join();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                       std::chrono::steady_clock::now() - t0)
                       .count();
    CHECK(handler_done.load());
    CHECK(elapsed >= 500);
}

TEST_CASE("shutdown route answers 200 {ok:true} and requests process exit",
          "[httpd][shutdown]") {
    // The _Exit(0) itself is exercised end-to-end by the python smoke driver;
    // here we assert the response contract plus the flag hand-off.
    sa::Router r = sa::build_router();
    auto res = sa::sa_test::dispatch_in_proc(r, "POST", "/api/shutdown", {}, sa::json{{"x", 1}});
    CHECK(res.status == 200);
    CHECK(res.json_payload["ok"] == true);
    CHECK(sa::shutdown_requested());
    sa::detail::clear_shutdown_for_test();
}
