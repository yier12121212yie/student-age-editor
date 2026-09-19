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
    // Wire-fidelity copies for forwarding services (PLUGIN_SPEC §4 proxy): the
    // parsed views above are lossy — `query` drops repeated keys, `body`
    // reformats JSON — so a proxy that must replay the request byte-for-byte
    // reads these instead.
    std::string raw_query;           // text after the first '?', as sent, no '?'
    // Populated only up to kRawBodyKeepMax (see httpd.cpp): copying every body
    // would double the peak memory of the 100 MB base64 plugin installs.
    std::string raw_body;
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
    bool bind_to(const std::string& host, int port, std::string* err);
    int port() const;

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
}

}  // namespace sa
