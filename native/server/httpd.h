// server/httpd: HTTP transport contract (port of `server/httpd.py`).
//
// CONVENTIONS section 2 governs every decision here. The transport is the
// hand-written socket loop in httpd.cpp (Winsock2 / BSD sockets); the vendored
// cpp-httplib is only ever a *client* here (tests/), never this server's socket
// layer. It implements the *semantics* of the Python BaseHTTPRequestHandler:
//   * ordered (method, regex) fullmatch route table, first hit wins (ApiRouter);
//   * 404 envelope {"error":"no route: GET /x"} for anything unmatched;
//   * Host/Origin loopback validation (httpd.py:76-115, IPv6 brackets included);
//   * handler exceptions -> 500 {"error":"<Type>: <msg>"}; a response that was
//     already written is never re-written (B11) -- structurally guaranteed here
//     because handlers only return a Resp, and the transport writes exactly once;
//   * raw-bytes responses bypass serialization (40MB cache-hit fast path);
//   * 64 concurrent connections max, overflow answered with a bare
//     "HTTP/1.1 503 ... Content-Length: 0 / Connection: close" (B13);
//   * keep-alive idle 65s (httpd.py:94 timeout).
//
// Known deviations from Python are documented at the point of use and in the
// wave-1 delivery report (501-for-unknown-methods becomes 404 no-route).
#pragma once

#include <functional>
#include <map>
#include <memory>
#include <regex>
#include <string>
#include <unordered_map>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {

using json = nlohmann::ordered_json;

// One request as seen by handlers: everything Python's dispatch passes in
// (named groups as kwargs, `_query`, `_body`).
struct Req {
    std::string method;              // GET / POST / PUT / DELETE / OPTIONS
    std::string path;                // percent-decoded path, no query
    std::map<std::string, std::string> query;  // parse_qs semantics, last wins
    json body;                       // null=no body; {"_raw":text} on parse failure
    std::map<std::string, std::string> params;  // named regex groups ("kwargs")
    std::string host_header;         // raw Host header value
    std::string origin_header;       // raw Origin header value ("" if absent)
    std::string authorization_header;  // raw Authorization header ("" if absent);
                                       // the web gateway (plan M2) authenticates
                                       // Bearer sessions from route handlers,
                                       // which is why the transport keeps it.
    std::string backend_token_header;  // raw X-Backend-Token（安全批次 B 进程
                                       // 令牌；"" if absent）。传输层在
                                       // dispatch 前强制校验，路由层无感。
    // Wire-fidelity copies for forwarding services (PLUGIN_SPEC §4 proxy): the
    // parsed views above are lossy — `query` drops repeated keys, `body`
    // reformats JSON — so a proxy that must replay the request byte-for-byte
    // reads these instead.
    std::string raw_query;           // text after the first '?', as sent, no '?'
    // Populated only up to kRawBodyKeepMax (see httpd.cpp): copying every body
    // would double the peak memory of the 100 MB base64 plugin installs.
    std::string raw_body;
};

// Origin/CORS tier for the transport (网页版计划 M1.2). Empty `trusted_origins`
// == the desktop default: loopback-only Host/Origin checks with the fixed
// `Access-Control-Allow-Origin: http://127.0.0.1` header line — byte-for-byte
// the CONVENTIONS 2 wire (every golden depends on it). A non-empty list switches
// to the "server tier": browser requests (those carrying an Origin) must match
// one of the configured public origins exactly (scheme + host + port,
// case-insensitive, default port folded); requests WITHOUT an Origin (CLI, the
// gateway's local proxy hop, health checks) pass as they always did. The
// trusted list replaces the "port is the boundary" rule because the admin has
// explicitly declared which sites may drive this server, and dropping the
// origin==host equality keeps legitimate cross-port dev flows working — a
// DNS-rebinding page still fails: its Origin is the attacker's host name,
// which is by definition not on the list.
struct CorsConfig {
    std::vector<std::string> trusted_origins;  // e.g. "https://editor.example"

    bool server_mode() const { return !trusted_origins.empty(); }
};

// Handler result: JSON payload or pre-serialized bytes (bytes 直发, httpd.py:157-160).
struct Resp {
    int status = 200;
    json json_payload;               // used when !is_bytes
    std::string bytes;               // used when is_bytes
    bool is_bytes = false;
    // Empty keeps the transport's fixed `application/json; charset=utf-8`.
    // Set it only to hand through an upstream type (PLUGIN_SPEC §4 proxy).
    std::string content_type;
    // Empty keeps the transport's fixed `Cache-Control: no-store`. Only the
    // static web hosting route (网页版计划 M1.2) sets it — every JSON API
    // response stays no-store as the Python wire requires.
    std::string cache_control;

    Resp() = default;
    static Resp Json(int status, json payload) {
        Resp r;
        r.status = status;
        r.json_payload = std::move(payload);
        return r;
    }
    static Resp Bytes(int status, std::string data) {
        Resp r;
        r.status = status;
        r.bytes = std::move(data);
        r.is_bytes = true;
        return r;
    }
    // bytes 直发 with an explicit Content-Type.
    static Resp BytesTyped(int status, std::string data, std::string content_type) {
        Resp r = Bytes(status, std::move(data));
        r.content_type = std::move(content_type);
        return r;
    }
};

using Handler = std::function<Resp(const Req&)>;

// 长任务 opt-in 包装（性能 P1）：返回的 handler 在请求带 query `async=1` 时把
// 原调用交给后台任务池（server/jobs，4 worker），立即返回
// 202 {"job_id": ...}，结果经 GET /api/jobs/{id} 轮询；不带标记则同步执行
// （旧客户端零影响）。实现见 server/jobs.cpp。
Handler wrap_async_job(Handler fn);

// Thrown by handlers/services to surface a Python-style exception name in the
// 500 envelope: `raise ApiError("SandboxError", "no mod selected")` renders as
// {"error": "SandboxError: no mod selected"} (httpd.py:70-72).
struct ApiError : std::runtime_error {
    std::string type_name;
    ApiError(std::string type, const std::string& message)
        : std::runtime_error(type + ": " + message), type_name(std::move(type)) {}
};

class Router {
  public:
    // `pattern` uses Python-style named groups (?P<name>...) so service code
    // reads like api.py; they're rewritten to plain capture groups internally
    // and the names recorded in group order.
    void add(const std::string& method, const std::string& pattern, Handler fn);
    void get(const std::string& p, Handler fn) { add("GET", p, std::move(fn)); }
    void post(const std::string& p, Handler fn) { add("POST", p, std::move(fn)); }
    void put(const std::string& p, Handler fn) { add("PUT", p, std::move(fn)); }
    void del(const std::string& p, Handler fn) { add("DELETE", p, std::move(fn)); }
    void options(const std::string& p, Handler fn) { add("OPTIONS", p, std::move(fn)); }

    // Python ApiRouter.dispatch: fullmatch over the per-method bucket in
    // registration order; exception -> 500; miss -> 404 no-route envelope.
    Resp dispatch(Req& req) const;

    size_t route_count() const { return entries_.size(); }

  private:
    struct Entry {
        std::string method;
        std::regex rx;
        std::vector<std::string> group_names;
        Handler fn;
    };
    std::vector<Entry> entries_;
    // 精确路由直达表（性能 P2）：pattern 不含任何正则元字符时按
    // method+'\x1f'+path 索引到 entries_ 下标；dispatch 先查表 O(1)，未命中
    // 再走原有的有序正则全量回退（首条命中的顺序语义完全保留）。
    std::unordered_map<std::string, size_t> exact_;
};

// Convert a Python regex pattern to std::regex ECMAScript: rewrite
// (?P<name> -> (?<name>, capturing the names in order.
std::string py_pattern_to_std(const std::string& pattern,
                              std::vector<std::string>* names_out);

// The blocking HTTP server (run on its own thread by the caller).
class Httpd {
  public:
    explicit Httpd(Router* router);
    ~Httpd();

    // Bind 127.0.0.1:port (port 0 -> auto). Returns false + error on failure.
    // `host` may name any local address (网页版计划 M1.1 — run.cpp only passes
    // non-loopback values in explicit server mode; inet_pton failures still
    // fall back to loopback as CONVENTIONS 2 always demanded).
    bool bind_to(const std::string& host, int port, std::string* err);
    int port() const;

    // Origin/CORS tier; must be called before start() (plan M1.2).
    void set_cors(const CorsConfig& cors);

    // Connection-slot ceiling; default 192（性能 P1，原 64）。The gateway may
    // raise it.
    void set_max_slots(int n);

    // 安全批次 B：后端进程令牌。非空时，除豁免（/api/ping、OPTIONS、静态资源）
    // 外的 /api/* 请求必须带等值 X-Backend-Token 头，否则 403。空串（默认）
    // = 不启用。
    void set_auth_token(std::string token);

    // 安全批次 B：请求体上限（字节，覆盖 httpd 的 256 MiB 默认）。网关 fork
    // 传 32 MiB。必须在 start() 前调用。
    void set_max_body_bytes(long long n);

    // Req::raw_body（§4 服务代理逐字节重放 + 网关转发）的保留上限。默认 8 MiB；
    // 网关需转发大体积上传时按 max_body_bytes 抬高。必须在 start() 前调用。
    void set_raw_body_keep_max(long long n);

    void start();   // spawn accept loop thread; returns once listening
    void stop();    // stop accepting; existing connections drain/are killed at exit

    // Slot accounting (tests / /api/perf debug): current live connections.
    int active_connections() const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

namespace sa_test {
// In-process dispatch helper (tests only): mirrors Python's
// router.dispatch(...) MockClient path without touching a socket.
inline sa::Resp dispatch_in_proc(sa::Router& r, const std::string& method,
                                 const std::string& path,
                                 std::map<std::string, std::string> query, sa::json body) {
    sa::Req req;
    req.method = method;
    req.path = path;
    req.query = std::move(query);
    req.body = std::move(body);
    return r.dispatch(req);
}
}  // namespace sa_test

// Ask the process to exit after the shutdown response is flushed (api.py:777-782
// "先回响应再退出"; C++ uses std::_Exit once stop() has returned, mirroring
// Python daemon threads being killed by os._exit(0)).
void request_shutdown();
bool shutdown_requested();

namespace detail {
void clear_shutdown_for_test();  // the flag is consumed by a connection thread in prod

// Server-mode shutdown gate (网页版计划 M1.2): run.cpp sets this when the bind
// host is not loopback, and the /api/shutdown handler refuses to kill a
// public-facing server. Loopback/default never sets it (behaviour unchanged).
void set_shutdown_disabled(bool disabled);
bool shutdown_disabled();
}  // namespace detail

}  // namespace sa
