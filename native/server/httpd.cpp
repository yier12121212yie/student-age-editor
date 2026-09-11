#include "server/httpd.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <set>
#include <thread>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
using sa_socket_t = SOCKET;
#define SA_INVALID_SOCKET INVALID_SOCKET
#define SA_ERRNO ((int)WSAGetLastError())
#define SA_EINTR WSAEINTR
#define sa_close closesocket
#define sa_shutdown(s) ::shutdown((s), SD_BOTH)
#else
#include <arpa/inet.h>
#include <cerrno>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
using sa_socket_t = int;
#define SA_INVALID_SOCKET (-1)
#define SA_ERRNO errno
#define SA_EINTR EINTR
#define sa_close ::close
#define sa_shutdown(s) ::shutdown((s), SHUT_RDWR)
#endif

namespace sa {
namespace {

// ---------------------------------------------------------------------------
// percent-decoding / query parsing (urllib.parse equivalents, httpd.py:132-134)
// ---------------------------------------------------------------------------

int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// urllib.parse.unquote / unquote_plus: decode %XX byte runs, then UTF-8 decode
// with errors="replace" (the CPython default for both functions). Undecodable
// % sequences pass through literally.
std::string unquote(std::string_view s, bool plus_to_space) {
    std::string bytes;
    bytes.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        if (s[i] == '%' && i + 2 < s.size()) {
            int hi = hexval(s[i + 1]);
            int lo = hexval(s[i + 2]);
            if (hi >= 0 && lo >= 0) {
                bytes.push_back(static_cast<char>(hi * 16 + lo));
                i += 3;
                continue;
            }
        }
        if (s[i] == '+' && plus_to_space) {
            bytes.push_back(' ');
        } else {
            bytes.push_back(s[i]);
        }
        ++i;
    }
    // Replace-decode so invalid UTF-8 in a URL can never throw.
    return sa_core::decode_utf8_sig_replace(bytes);
}

// httpd.py:134 `{k: v[-1] for k, v in parse_qs(parsed.query).items()}`:
// parse_qs drops '='-less tokens and blank values (keep_blank_values=False),
// and we keep the LAST occurrence of a repeated key.
std::map<std::string, std::string> parse_query_last(std::string_view query) {
    std::map<std::string, std::string> out;
    size_t pos = 0;
    while (pos <= query.size()) {
        size_t amp = query.find('&', pos);
        std::string_view pair = query.substr(
            pos, amp == std::string_view::npos ? std::string_view::npos : amp - pos);
        if (!pair.empty()) {
            size_t eq = pair.find('=');
            if (eq != std::string_view::npos) {
                std::string key = unquote(pair.substr(0, eq), true);
                std::string value = unquote(pair.substr(eq + 1), true);
                if (!value.empty()) out[key] = value;
            }
        }
        if (amp == std::string_view::npos) break;
        pos = amp + 1;
    }
    return out;
}

// ---------------------------------------------------------------------------
// socket helpers
// ---------------------------------------------------------------------------

bool send_all(sa_socket_t sock, const char* data, size_t len) {
    size_t off = 0;
    while (off < len) {
        int n = ::send(sock, data + off, static_cast<int>(len - off), 0);
        if (n == 0) return false;
        if (n < 0) {
            if (SA_ERRNO == SA_EINTR) continue;
            return false;
        }
        off += static_cast<size_t>(n);
    }
    return true;
}

// Buffered line/exact reader over the connection socket.
class LineReader {
  public:
    explicit LineReader(sa_socket_t sock) : sock_(sock) {}

    bool next_line(std::string& out) {
        out.clear();
        for (;;) {
            for (size_t i = 0; i < buf_.size(); ++i) {
                if (buf_[i] == '\n') {
                    out.assign(buf_.data(), i);
                    buf_.erase(buf_.begin(), buf_.begin() + i + 1);
                    if (!out.empty() && out.back() == '\r') out.pop_back();
                    return true;
                }
            }
            if (!fill()) {
                out.assign(buf_.begin(), buf_.end());
                buf_.clear();
                if (!out.empty() && out.back() == '\r') out.pop_back();
                return !out.empty();
            }
        }
    }

    bool read_exact(std::string& out, size_t want) {
        out.clear();
        while (out.size() < want) {
            size_t avail = std::min(buf_.size(), want - out.size());
            if (avail) {
                out.append(buf_.data(), avail);
                buf_.erase(buf_.begin(), buf_.begin() + avail);
                continue;
            }
            char chunk[65536];
            size_t space = std::min(sizeof(chunk), want - out.size());
            int n = ::recv(sock_, chunk, static_cast<int>(space), 0);
            if (n < 0) {
                if (SA_ERRNO == SA_EINTR) continue;
                return false;
            }
            if (n == 0) return false;
            out.append(chunk, static_cast<size_t>(n));
        }
        return true;
    }

  private:
    bool fill() {
        for (;;) {
            char chunk[8192];
            int n = ::recv(sock_, chunk, sizeof(chunk), 0);
            if (n > 0) {
                buf_.insert(buf_.end(), chunk, chunk + n);
                return true;
            }
            if (n < 0 && SA_ERRNO == SA_EINTR) continue;
            return false;  // EOF or timeout (SO_RCVTIMEO == httpd.py:94 timeout=65)
        }
    }

    sa_socket_t sock_;
    std::vector<char> buf_;
};

void set_recv_timeout(sa_socket_t sock, int ms) {
#ifdef _WIN32
    DWORD v = static_cast<DWORD>(ms);
    ::setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&v), sizeof(v));
#else
    timeval tv{ms / 1000, static_cast<suseconds_t>((ms % 1000) * 1000)};
    ::setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
#endif
}

#ifdef _WIN32
struct WsaInit {
    WsaInit() {
        WSADATA d;
        WSAStartup(MAKEWORD(2, 2), &d);
    }
    ~WsaInit() { WSACleanup(); }
};
#endif

// ---------------------------------------------------------------------------
// httpd.py:76-115 host/origin validation
// ---------------------------------------------------------------------------

std::string strip_lower(std::string v) {
    for (auto& c : v) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    size_t b = v.find_first_not_of(" \t\r\n\f\v");
    if (b == std::string::npos) return {};
    size_t e = v.find_last_not_of(" \t\r\n\f\v");
    return v.substr(b, e - b + 1);
}

std::string host_without_port(std::string value) {
    std::string v = strip_lower(std::move(value));
    if (!v.empty() && v[0] == '[') {
        size_t end = v.find(']');
        return end > 0 ? v.substr(1, end - 1) : v;
    }
    size_t colon = v.rfind(':');
    return colon == std::string::npos ? v : v.substr(0, colon);
}

bool loopback_host(const std::string& host) {
    return host == "127.0.0.1" || host == "localhost" || host == "::1";
}

bool check_origin(const Req& req, std::string* reason) {
    if (!loopback_host(host_without_port(req.host_header))) {
        *reason = "forbidden host";
        return false;
    }
    if (!req.origin_header.empty()) {
        std::string oh = sa_core::origin_hostname(req.origin_header).value_or("");
        if (!loopback_host(oh)) {
            *reason = "forbidden origin";
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// response writing (httpd.py:155-176 / 192-211, CONVENTIONS 2 header table)
// ---------------------------------------------------------------------------

const char* reason_phrase(int status) {
    switch (status) {
        case 200: return "OK";
        case 204: return "No Content";
        case 400: return "Bad Request";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 409: return "Conflict";
        case 410: return "Gone";
        case 422: return "Unprocessable Entity";
        case 500: return "Internal Server Error";
        case 503: return "Service Unavailable";
        default: return "Unknown";
    }
}

bool write_response(sa_socket_t sock, int status, const std::string& body, bool close_after) {
    std::string head = "HTTP/1.1 ";
    head += std::to_string(status);
    head += ' ';
    head += reason_phrase(status);
    head += "\r\n";
    head += "Content-Type: application/json; charset=utf-8\r\n";
    head += "Content-Length: " + std::to_string(body.size()) + "\r\n";
    head += "Cache-Control: no-store\r\n";
    head += "Access-Control-Allow-Origin: http://127.0.0.1\r\n";
    head += "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n";
    head += "Access-Control-Allow-Headers: Content-Type\r\n";
    if (close_after) head += "Connection: close\r\n";
    head += "\r\n";
    if (!send_all(sock, head.data(), head.size())) return false;
    if (!body.empty() && !send_all(sock, body.data(), body.size())) return false;
    return true;
}

bool write_options_response(sa_socket_t sock, bool close_after) {
    std::string head = "HTTP/1.1 204 No Content\r\n";
    head += "Content-Type: application/json; charset=utf-8\r\n";
    head += "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n";
    head += "Access-Control-Allow-Headers: Content-Type\r\n";
    head += "Content-Length: 0\r\n";
    head += "Cache-Control: no-store\r\n";
    head += "Access-Control-Allow-Origin: http://127.0.0.1\r\n";
    if (close_after) head += "Connection: close\r\n";
    head += "\r\n";
    return send_all(sock, head.data(), head.size());
}

std::string error_body(const std::string& message) {
    return sa_core::error_json(message);
}

// httpd.py:157-165: bytes payloads go out verbatim; dict payloads go through
// json.dumps(ensure_ascii=False) and a serialization failure becomes
// 500 {"error":"non-serializable response"}.
void serialize_payload(int& status, const Resp& r, std::string& body) {
    if (r.is_bytes) {
        body = r.bytes;
        return;
    }
    try {
        body = sa_core::py_dumps(r.json_payload);
    } catch (const std::exception&) {
        status = 500;
        body = error_body("non-serializable response");
    }
}

// ---------------------------------------------------------------------------
// per-connection loop (httpd.py:_ApiRequestHandler)
// ---------------------------------------------------------------------------

constexpr int kKeepAliveIdleMs = 65000;

// Cap the request body buffered in memory. The transport reads the whole body
// up front, so without a bound a local client (or a DNS-rebinding page past the
// Host check) can send Content-Length: 9e18 and drive the process into
// bad_alloc. 256 MiB leaves ample room for the base64 plugin/resource-pack
// installs (their own limits are 100 MB decoded).
constexpr long long kMaxBodyBytes = 256ll * 1024 * 1024;

void serve_connection(sa_socket_t sock, const Router& router, const std::atomic<bool>& quit_flag) {
    set_recv_timeout(sock, kKeepAliveIdleMs);
    LineReader reader(sock);
    for (;;) {
        if (quit_flag.load()) break;

        std::string line;
        if (!reader.next_line(line)) break;  // EOF / idle timeout / dropped
        size_t sp1 = line.find(' ');
        size_t sp2 = sp1 == std::string::npos ? std::string::npos : line.find(' ', sp1 + 1);
        if (sp1 == std::string::npos || sp2 == std::string::npos) break;  // malformed

        Req req;
        bool close_after = false;
        bool responded = false;  // B11 flag (httpd.py:69-72, 121-129)
        try {
            req.method = line.substr(0, sp1);
            std::string target = line.substr(sp1 + 1, sp2 - sp1 - 1);
            std::string version = line.substr(sp2 + 1);

            bool have_length_header = false;
            std::string content_length;
            bool headers_ok = true;
            for (;;) {
                std::string h;
                if (!reader.next_line(h)) {
                    headers_ok = false;
                    break;
                }
                if (h.empty()) break;
                size_t colon = h.find(':');
                if (colon == std::string::npos) continue;
                std::string name = strip_lower(h.substr(0, colon));
                std::string value = h.substr(colon + 1);
                size_t vb = value.find_first_not_of(" \t");
                value = vb == std::string::npos ? std::string{} : value.substr(vb);
                while (!value.empty() && (value.back() == ' ' || value.back() == '\t')) value.pop_back();
                if (name == "host" && req.host_header.empty()) {
                    req.host_header = value;
                } else if (name == "origin" && req.origin_header.empty()) {
                    req.origin_header = value;
                } else if (name == "content-length" && !have_length_header) {
                    have_length_header = true;  // first wins (.headers.get)
                    content_length = value;
                } else if (name == "connection") {
                    if (strip_lower(value).find("close") != std::string::npos) close_after = true;
                }
            }
            if (version == "HTTP/1.0") close_after = true;
            if (!headers_ok) break;

            size_t qpos = target.find('?');
            std::string raw_path = qpos == std::string::npos ? target : target.substr(0, qpos);
            req.path = unquote(raw_path, false);
            if (qpos != std::string::npos) req.query = parse_query_last(target.substr(qpos + 1));

            if (req.method == "OPTIONS") {
                // do_OPTIONS: no Content-Length parse, no body (httpd.py:192-211).
                std::string reason;
                if (!check_origin(req, &reason)) {
                    responded = true;
                    json env{{"error", reason}};
                    if (!write_response(sock, 403, sa_core::py_dumps(env), true)) break;
                } else {
                    responded = true;
                    if (!write_options_response(sock, close_after)) break;
                }
            } else {
                std::optional<long long> length;
                if (!have_length_header || content_length.empty()) {
                    length = 0;  // int(headers.get(...) or 0)
                } else {
                    length = sa_core::py_int(content_length);
                }
                if (!length.has_value()) {
                    // httpd.py:137-139 (before the origin check, before the body read)
                    responded = true;
                    json env{{"error", "invalid Content-Length"}};
                    write_response(sock, 400, sa_core::py_dumps(env), true);
                    break;
                }
                std::string body_raw;
                long long want = *length < 0 ? 0 : *length;  // length = max(0, length)
                if (want > kMaxBodyBytes) {
                    // Refuse before reading: the body is buffered whole in memory.
                    responded = true;
                    json env{{"error", "request body too large"}};
                    write_response(sock, 413, sa_core::py_dumps(env), true);
                    break;
                }
                if (want > 0 && !reader.read_exact(body_raw, static_cast<size_t>(want))) {
                    break;  // truncated body: connection is no longer framed
                }
                if (!body_raw.empty()) {
                    // httpd.py:143-147: strict decode + json.loads; failure -> {"_raw":...}
                    auto strict = sa_core::decode_utf8_sig_strict(body_raw);
                    if (strict) {
                        json parsed = json::parse(*strict, nullptr, false);
                        if (parsed.is_discarded()) {
                            req.body =
                                json{{"_raw", sa_core::decode_utf8_sig_replace(body_raw)}};
                        } else {
                            req.body = std::move(parsed);
                        }
                    } else {
                        req.body = json{{"_raw", sa_core::decode_utf8_sig_replace(body_raw)}};
                    }
                }

                std::string reason;
                Resp resp;
                if (!check_origin(req, &reason)) {
                    resp = Resp::Json(403, json{{"error", reason}});
                } else {
                    resp = router.dispatch(req);
                }
                responded = true;
                int status = resp.status;
                std::string body;
                serialize_payload(status, resp, body);  // may downgrade to 500
                if (!write_response(sock, status, body, close_after)) break;
            }
        } catch (const std::exception&) {
            // httpd.py:121-129: fallback 500 ONLY when nothing was written (B11).
            if (!responded) {
                write_response(sock, 500, error_body("internal server error"), true);
            }
            break;
        }
        if (close_after) break;
    }
    // The owning thread closes the socket (see the Release guard in the accept
    // loop) so close + deregister can be fenced together under conn_mu.
}

}  // namespace

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

std::string py_pattern_to_std(const std::string& pattern,
                              std::vector<std::string>* names_out) {
    std::string out;
    size_t i = 0;
    while (i < pattern.size()) {
        if (pattern.compare(i, 4, "(?P<") == 0) {
            size_t end = pattern.find('>', i + 4);
            if (end != std::string::npos) {
                if (names_out) names_out->push_back(pattern.substr(i + 4, end - (i + 4)));
                out += '(';
                i = end + 1;
                continue;
            }
        }
        out += pattern[i++];
    }
    return out;
}

void Router::add(const std::string& method, const std::string& pattern, Handler fn) {
    Entry e;
    e.method = method;
    std::vector<std::string> names;
    e.rx = std::regex(py_pattern_to_std(pattern, &names), std::regex::ECMAScript);
    e.group_names = std::move(names);
    e.fn = std::move(fn);
    entries_.push_back(std::move(e));
}

Resp Router::dispatch(Req& req) const {
    for (const auto& e : entries_) {
        if (e.method != req.method) continue;
        std::smatch m;
        if (!std::regex_match(req.path, m, e.rx)) continue;
        for (size_t i = 0; i < e.group_names.size(); ++i) {
            req.params[e.group_names[i]] = m[i + 1].matched ? m[i + 1].str() : std::string();
        }
        try {
            return e.fn(req);
        } catch (const ApiError& err) {
            // httpd.py:70-72: {"error": "<Type>: <message>"}
            return Resp::Json(500, json{{"error", err.what()}});
        } catch (const json::exception& err) {
            return Resp::Json(500, json{{"error", std::string("ValueError: ") + err.what()}});
        } catch (const std::exception& err) {
            return Resp::Json(500, json{{"error", std::string("RuntimeError: ") + err.what()}});
        }
    }
    return Resp::Json(404, json{{"error", "no route: " + req.method + " " + req.path}});
}

// ---------------------------------------------------------------------------
// Httpd (listen/accept/slots)
// ---------------------------------------------------------------------------

std::atomic<bool> g_shutdown_after{false};

struct Httpd::Impl {
    Router* router;
    sa_socket_t listen_sock = SA_INVALID_SOCKET;
    std::atomic<bool> quit{false};
    std::atomic<int> slots{0};
    std::thread accept_thread;
    int bound_port = -1;

    // Live-connection registry. serve_connection runs on a detached thread and
    // holds references into this Impl (quit) and into the caller-owned Router,
    // so ~Httpd must not return while any of them is still running. wake_conns()
    // unblocks a thread parked in recv(); the drain waits on `slots` (the
    // thread-finished counter) rather than the registry size, because on Windows
    // wake_conns() closes the socket and drops it from the registry while the
    // owning thread may still be executing serve_connection's tail.
    std::mutex conn_mu;
    std::condition_variable conn_cv;
    std::set<sa_socket_t> conns;

    static constexpr int kMaxSlots = 64;  // B13 (httpd.py:221)

    explicit Impl(Router* r) : router(r) {}

    void register_conn(sa_socket_t s) {
        std::lock_guard<std::mutex> lk(conn_mu);
        conns.insert(s);
    }

    // Owner-side close + deregister, fenced under conn_mu. On Windows wake_conns
    // may have already closed+erased the socket, in which case erase() is empty
    // and this is deliberately a no-op (no double close on a recycled handle).
    void close_conn(sa_socket_t s) {
        std::lock_guard<std::mutex> lk(conn_mu);
        if (conns.erase(s)) sa_close(s);
    }

    // Interrupt every thread parked in recv().
    //   * POSIX: shutdown() makes recv() return without releasing the fd.
    //     close() would NOT interrupt the parked syscall, and freeing the fd
    //     number early lets accept() recycle it under the blocked thread.
    //   * Windows/Winsock: closesocket() is what unblocks a blocked recv();
    //     shutdown() does not reliably do so. The entry is removed here so the
    //     owning thread's later close_conn() is a no-op.
    void wake_conns() {
        std::lock_guard<std::mutex> lk(conn_mu);
        for (auto it = conns.begin(); it != conns.end();) {
#ifdef _WIN32
            sa_socket_t s = *it;
            it = conns.erase(it);
            sa_close(s);
#else
            sa_shutdown(*it);
            ++it;
#endif
        }
    }

    // Block until every detached connection thread has finished using Impl and
    // Router (all slots released). Keeps waking parked recv()ers so a keep-alive
    // idle connection (65s) never stretches the drain past the guard.
    void drain_conns() {
        for (int spin = 0; spin < 6000 && slots.load() > 0; ++spin) {  // <= ~60s guard
            wake_conns();
            std::unique_lock<std::mutex> lk(conn_mu);
            conn_cv.wait_for(lk, std::chrono::milliseconds(10),
                             [this] { return slots.load() == 0; });
        }
    }

    bool try_acquire() {
        int cur = slots.load(std::memory_order_relaxed);
        while (cur < kMaxSlots) {
            if (slots.compare_exchange_weak(cur, cur + 1)) return true;
        }
        return false;
    }

    void accept_loop() {
        for (;;) {
#ifdef _WIN32
            sa_socket_t conn = ::accept(listen_sock, nullptr, nullptr);
            if (conn == SA_INVALID_SOCKET) break;  // closed listen socket or fatal
#else
            // POSIX cannot stop a blocking accept() by closing the fd (unlike
            // Winsock's closesocket, which returns WSAENOTSOCK to a thread
            // parked in accept -- verified live on this code path). The loop
            // therefore polls the listen socket with a short timeout and owns
            // its fd: quit is re-checked at least every 100 ms, and the fd is
            // closed here -- after accept() has definitely returned -- so it
            // never re-enters the fd-reuse pool while a parked accept() still
            // references it (which would make a later bind()/listen() hand its
            // new fd number to this loop and let it steal accepted sockets).
            sa_socket_t conn = SA_INVALID_SOCKET;
            for (;;) {
                if (quit.load()) break;
                struct pollfd pfd;
                pfd.fd = listen_sock;
                pfd.events = POLLIN;
                pfd.revents = 0;
                int pr = ::poll(&pfd, 1, 100);
                if (pr < 0) {
                    if (SA_ERRNO == SA_EINTR) continue;
                    break;  // dead listen socket or fatal
                }
                if (pr == 0) continue;  // idle: loop and re-check quit
                conn = ::accept(listen_sock, nullptr, nullptr);
                if (conn == SA_INVALID_SOCKET) {
                    int e = SA_ERRNO;
                    if (e == SA_EINTR || e == ECONNABORTED || e == EAGAIN ||
                        e == EWOULDBLOCK)
                        continue;
                    break;  // listen socket gone or fatal
                }
                break;  // accepted
            }
            if (conn == SA_INVALID_SOCKET) {
                if (listen_sock != SA_INVALID_SOCKET) {
                    ::close(listen_sock);
                    listen_sock = SA_INVALID_SOCKET;
                }
                break;
            }
#endif
            if (!try_acquire()) {
                // httpd.py:224-231: bare 503, Content-Length: 0, Connection: close.
                static const char k503[] =
                    "HTTP/1.1 503 Service Unavailable\r\n"
                    "Content-Length: 0\r\nConnection: close\r\n\r\n";
                send_all(conn, k503, sizeof(k503) - 1);
                sa_close(conn);
                continue;
            }
            register_conn(conn);
            std::thread([this, conn]() {
                struct Release {
                    Impl* impl;
                    sa_socket_t sock;
                    std::atomic<int>& s;
                    ~Release() {
                        impl->close_conn(sock);  // fenced close + deregister
                        // Publish "thread finished" while holding conn_mu: the
                        // drain waits on s, so it must not observe 0 and free
                        // Impl until this destructor is done touching it.
                        std::lock_guard<std::mutex> lk(impl->conn_mu);
                        s.fetch_sub(1);
                        impl->conn_cv.notify_all();
                    }
                } release{this, conn, slots};
                serve_connection(conn, *router, quit);
                if (g_shutdown_after.exchange(false)) {
                    // api.py:777-782 /api/shutdown semantics: respond first, then
                    // the process dies (Python: os._exit(0) on a daemon thread).
                    stop();
                    std::_Exit(0);
                }
            }).detach();
        }
    }

    void stop() {
        quit.store(true);
        // Wake every connection thread parked in recv() so it observes quit and
        // exits (platform-specific: closesocket on Windows, shutdown on POSIX).
        wake_conns();
#ifdef _WIN32
        if (listen_sock != SA_INVALID_SOCKET) {
            ::closesocket(listen_sock);
            listen_sock = SA_INVALID_SOCKET;
        }
#else
        // closesocket() interrupts a blocked accept() on Winsock; POSIX close()
        // does neither -- the parked accept keeps the file description alive
        // (observed as wchan=inet_csk_accept surviving stop()) and the fd
        // number would be recycled into unrelated sockets. accept_loop() owns
        // the close on POSIX; see the comment there. If the loop never started
        // or already exited, close directly so the fd is not leaked.
        if (!accept_thread.joinable() && listen_sock != SA_INVALID_SOCKET) {
            ::close(listen_sock);
            listen_sock = SA_INVALID_SOCKET;
        }
#endif
    }
};

Httpd::Httpd(Router* router) : impl_(new Impl(router)) {}

Httpd::~Httpd() {
    impl_->stop();
    if (impl_->accept_thread.joinable()) impl_->accept_thread.join();
    // The per-connection threads are detached (daemon-thread semantics), so the
    // Router they reference must outlive them: block until every one has closed
    // its socket. stop() already shutdown() the registered sockets, so a
    // keep-alive idle thread returns from recv() immediately instead of waiting
    // out its 65s timeout -- without this the threads would dereference the
    // destroyed Impl/Router (use-after-free on /api/shutdown and in tests).
    impl_->drain_conns();
}

bool Httpd::bind_to(const std::string& host, int port, std::string* err) {
#ifdef _WIN32
    static WsaInit wsa;
#endif
    sa_socket_t s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == SA_INVALID_SOCKET) {
        if (err) *err = "socket() failed";
        return false;
    }
    int one = 1;
    ::setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&one), sizeof(one));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<unsigned short>(port));
    if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // CONVENTIONS 2: loopback only
    }
    if (::bind(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        if (err) *err = "bind " + host + ":" + std::to_string(port) + " failed (err " +
                        std::to_string(SA_ERRNO) + ")";
        sa_close(s);
        return false;
    }
    if (::listen(s, 128) != 0) {
        if (err) *err = "listen failed";
        sa_close(s);
        return false;
    }
    sockaddr_in actual{};
    socklen_t len = sizeof(actual);
    impl_->bound_port =
        (::getsockname(s, reinterpret_cast<sockaddr*>(&actual), &len) == 0)
            ? ntohs(actual.sin_port)
            : port;
    impl_->listen_sock = s;
    return true;
}

int Httpd::port() const { return impl_->bound_port; }

void Httpd::start() {
    impl_->accept_thread = std::thread([this] { impl_->accept_loop(); });
}

void Httpd::stop() { impl_->stop(); }

int Httpd::active_connections() const { return impl_->slots.load(); }

void request_shutdown() { g_shutdown_after.store(true); }

bool shutdown_requested() { return g_shutdown_after.load(); }

namespace detail {
void clear_shutdown_for_test() { g_shutdown_after.store(false); }
}  // namespace detail

}  // namespace sa
