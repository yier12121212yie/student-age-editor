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
#include <csignal>
#include <cerrno>
#include <netinet/in.h>
#include <netinet/tcp.h>
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

// Set by /api/shutdown (request_shutdown) and consumed by the owning connection
// thread, which exits the process after the response is flushed. Declared here
// so serve_connection can force a prompt close instead of parking in keep-alive.
std::atomic<bool> g_shutdown_after{false};

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

// Request/response over loopback pays a Nagle + delayed-ACK stall on the
// response write on some platform stacks; every response here is a single
// flush, so Nagle never helps. Best effort — failure is non-fatal.
void enable_nodelay(sa_socket_t sock) {
    int one = 1;
    ::setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&one),
                 sizeof(one));
}

bool send_all(sa_socket_t sock, const char* data, size_t len) {
#ifdef _WIN32
    constexpr int kSendFlags = 0;
#elif defined(__APPLE__)
    constexpr int kSendFlags = 0;  // SIGPIPE ignored process-wide at bind time
#else
    constexpr int kSendFlags = MSG_NOSIGNAL;  // belt-and-braces with the SIGPIPE ignore
#endif
    size_t off = 0;
    while (off < len) {
        int n = ::send(sock, data + off, static_cast<int>(len - off), kSendFlags);
        if (n == 0) return false;
        if (n < 0) {
            if (SA_ERRNO == SA_EINTR) continue;
            return false;
        }
        off += static_cast<size_t>(n);
    }
    return true;
}

// Upper bound on the buffered request head (request line + headers). fill()
// refuses to buffer past it, so a client streaming a never-terminated header
// line cannot drive the process into bad_alloc (the body has its own cap:
// kMaxBodyBytes below). Headers beyond this are answered with 431.
constexpr size_t kMaxHeadBytes = 1024 * 1024;

// Buffered line/exact reader over the connection socket.
class LineReader {
  public:
    explicit LineReader(sa_socket_t sock) : sock_(sock) {}

    bool next_line(std::string& out) {
        out.clear();
        for (;;) {
            for (size_t i = start_; i < buf_.size(); ++i) {
                if (buf_[i] == '\n') {
                    out.assign(buf_.data() + start_, i - start_);
                    start_ = i + 1;
                    compact();
                    if (!out.empty() && out.back() == '\r') out.pop_back();
                    return true;
                }
            }
            if (!fill()) {
                if (overflow_) {
                    buf_.clear();
                    start_ = 0;
                    out.clear();
                    return false;
                }
                out.assign(buf_.data() + start_, buf_.size() - start_);
                buf_.clear();
                start_ = 0;
                if (!out.empty() && out.back() == '\r') out.pop_back();
                return !out.empty();
            }
        }
    }

    bool overflowed() const { return overflow_; }

    bool read_exact(std::string& out, size_t want) {
        out.clear();
        while (out.size() < want) {
            size_t avail = std::min(buf_.size() - start_, want - out.size());
            if (avail) {
                out.append(buf_.data() + start_, avail);
                start_ += avail;
                compact();
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
    // Drop the consumed prefix so buf_ stays O(live bytes). Only worth an erase
    // once the dead prefix is large; keeps per-line costs amortized O(1).
    void compact() {
        if (start_ >= 8192) {
            buf_.erase(buf_.begin(), buf_.begin() + static_cast<long>(start_));
            start_ = 0;
        }
    }

    bool fill() {
        for (;;) {
            if (buf_.size() - start_ >= kMaxHeadBytes) {
                overflow_ = true;
                return false;
            }
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
    size_t start_ = 0;  // consumed prefix of buf_ (avoid O(n^2) erase per line)
    bool overflow_ = false;
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

// 阶段 1c 收紧（有记录的安全偏差，Python 只比主机名不比端口）：Origin 存在时，
// 其 authority 必须与 Host 精确相等（主机+端口）。只比主机名的话，本机任意
// 其它端口上的页面（比如 http://localhost:3000 的某开发服务）都能对 loopback
// API 发"简单请求"（form/text/plain 不触发 CORS preflight）直接执行写操作——
// loopback 不隔离不同应用，端口才是边界。桌面/移动/CLI 客户端不送 Origin，
// 不受影响。
std::string origin_authority(std::string_view origin) {
    size_t pos = origin.find("://");
    if (pos == std::string_view::npos) return {};
    std::string_view rest = origin.substr(pos + 3);
    size_t end = rest.find_first_of("/?#");
    if (end != std::string_view::npos) rest = rest.substr(0, end);
    size_t at = rest.rfind('@');  // userinfo，同 origin_hostname 的容错方向
    if (at != std::string_view::npos) rest = rest.substr(at + 1);
    return strip_lower(std::string(rest));
}

// 默认端口归一：本服务只跑明文 HTTP，":80" 显式写出与省略等价。
std::string trim_default_port(std::string authority) {
    if (authority.size() > 3 &&
        authority.compare(authority.size() - 3, 3, ":80") == 0) {
        authority.resize(authority.size() - 3);
    }
    return authority;
}

// Server tier (网页版计划 M1.2): a browser request must send an Origin whose
// normalized authority is one of the admin-declared trusted origins; the
// Host==Origin equality of the default tier is deliberately not required (the
// trusted list is the stronger statement — a rebinding page carries its own
// host name as Origin and fails the membership test). Non-browser requests
// without an Origin pass, exactly as CLI traffic always has.
bool check_origin_trusted(const Req& req, const CorsConfig* cors, std::string* reason) {
    if (req.origin_header.empty()) return true;
    std::string oa = trim_default_port(origin_authority(req.origin_header));
    if (oa.empty()) {
        *reason = "forbidden origin";
        return false;
    }
    for (const auto& t : cors->trusted_origins) {
        if (trim_default_port(origin_authority(t)) == oa) return true;
    }
    *reason = "forbidden origin";
    return false;
}

bool check_origin(const Req& req, const CorsConfig* cors, std::string* reason) {
    if (cors && cors->server_mode()) return check_origin_trusted(req, cors, reason);
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
        if (trim_default_port(origin_authority(req.origin_header)) !=
            trim_default_port(strip_lower(req.host_header))) {
            *reason = "origin/host mismatch";
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// response writing (httpd.py:155-176 / 192-211, CONVENTIONS 2 header table)
// ---------------------------------------------------------------------------

// Per-request CORS wire facts (网页版计划 M1.2). All-default == the desktop
// tier: the fixed `http://127.0.0.1` ACAO line and the fixed Allow-Headers —
// byte-for-byte what every golden pins. In server mode a request whose Origin
// passed check_origin echoes that exact Origin back; every other response in
// server mode carries no ACAO at all (no Origin => no browser consumer).
struct CorsWire {
    bool server_mode = false;
    std::string echo_origin;  // non-empty == emit this exact ACAO value

    static CorsWire for_request(const CorsConfig* cors, const Req& req, bool origin_ok) {
        CorsWire w;
        if (!cors || !cors->server_mode()) return w;
        w.server_mode = true;
        if (origin_ok && !req.origin_header.empty() && req.origin_header.size() <= 128) {
            bool safe = true;
            for (unsigned char c : req.origin_header) {
                if (c <= 0x20 || c == 0x7F) safe = false;
            }
            if (safe) w.echo_origin = req.origin_header;
        }
        return w;
    }
};

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
        case 413: return "Content Too Large";
        case 431: return "Request Header Fields Too Large";
        case 500: return "Internal Server Error";
        case 503: return "Service Unavailable";
        default: return "Unknown";
    }
}

// `content_type` empty == the fixed Python-compatible header; non-empty is a
// verbatim hand-through (PLUGIN_SPEC §4 service proxy of a non-JSON upstream).
// A hand-through value containing a control character would let an upstream
// inject headers into THIS server's response, so it is discarded (default
// header) rather than truncated.
// Header-value sanity shared by content_type passthrough and the server-tier
// Origin echo: reject CR/LF/NUL and other control bytes (header injection) and
// DEL, but ALLOW the space 0x20 so legitimate values like
// "text/html; charset=utf-8" and "public, max-age=3600" are not silently
// downgraded. (The pre-web transport used `c <= 0x20`, which wrongly rejected
// the space; every value that reached it was space-free JSON/§4-proxy types so
// the difference was never observed. Default-tier bytes are unchanged.)
bool safe_header_value(const std::string& v) {
    if (v.size() > 128) return false;
    for (unsigned char c : v) {
        if (c < 0x20 || c == 0x7F) return false;
    }
    return true;
}

// Appends the tier-dependent CORS header lines. Default tier reproduces the
// fixed CONVENTIONS 2 block byte-for-byte.
void append_cors_headers(std::string& head, const CorsWire& cors) {
    if (!cors.server_mode) {
        head += "Access-Control-Allow-Origin: http://127.0.0.1\r\n";
        head += "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n";
        head += "Access-Control-Allow-Headers: Content-Type\r\n";
        return;
    }
    if (!cors.echo_origin.empty() && safe_header_value(cors.echo_origin)) {
        head += "Access-Control-Allow-Origin: " + cors.echo_origin + "\r\n";
    }
    head += "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n";
    head += "Access-Control-Allow-Headers: Content-Type, Authorization\r\n";
}

bool write_response(sa_socket_t sock, int status, const std::string& body, bool close_after,
                    const std::string& content_type = {},
                    const std::string& cache_control = {}, const CorsWire& cors = {}) {
    const char* ct = "application/json; charset=utf-8";
    if (!content_type.empty()) {
        if (safe_header_value(content_type)) ct = content_type.c_str();
    }
    std::string head = "HTTP/1.1 ";
    head += std::to_string(status);
    head += ' ';
    head += reason_phrase(status);
    head += "\r\n";
    head += "Content-Type: ";
    head += ct;
    head += "\r\n";
    head += "Content-Length: " + std::to_string(body.size()) + "\r\n";
    if (cache_control.empty() || !safe_header_value(cache_control)) {
        head += "Cache-Control: no-store\r\n";
    } else {
        head += "Cache-Control: " + cache_control + "\r\n";
    }
    append_cors_headers(head, cors);
    if (close_after) head += "Connection: close\r\n";
    head += "\r\n";
    if (!send_all(sock, head.data(), head.size())) return false;
    if (!body.empty() && !send_all(sock, body.data(), body.size())) return false;
    return true;
}

bool write_options_response(sa_socket_t sock, bool close_after, const CorsWire& cors = {}) {
    std::string head = "HTTP/1.1 204 No Content\r\n";
    head += "Content-Type: application/json; charset=utf-8\r\n";
    append_cors_headers(head, cors);
    head += "Content-Length: 0\r\n";
    head += "Cache-Control: no-store\r\n";
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
void serialize_payload(int& status, Resp& r, std::string& body) {
    if (r.is_bytes) {
        body = std::move(r.bytes);  // 性能 P2：bytes 直发路径不再整块拷贝（40MB 缓存命中）
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

// keep-alive 空闲 65s -> 15s（性能 P1）：httpd.py:94 的 65s 是给浏览器的宽
// 限；桌面/网关客户端都是主动连断，65s 的空闲槽位在 max_slots 内积压僵尸
// keep-alive。长任务（AI/TTS/云同步）已改走 async job 轮询，不再有「响应前
// 被掐断」的窗口。
constexpr int kKeepAliveIdleMs = 15000;

// Cap the request body buffered in memory. The transport reads the whole body
// up front, so without a bound a local client (or a DNS-rebinding page past the
// Host check) can send Content-Length: 9e18 and drive the process into
// bad_alloc. 256 MiB leaves ample room for the base64 plugin/resource-pack
// installs (their own limits are 100 MB decoded). 安全批次 B：可经
// --max-body 覆盖（网关 fork 传 32 MiB）。
constexpr long long kDefaultMaxBodyBytes = 256ll * 1024 * 1024;

// Ceiling for keeping a second, wire-fidelity copy of the body in Req::raw_body
// (the §4 service proxy replays it byte-for-byte). Anything above this is a
// bulk upload (base64 plugin/resource-pack installs reach 100 MB decoded) that
// no forwarding route ever consumes, and copying it would double the peak.
constexpr size_t kRawBodyKeepMax = 8ull * 1024 * 1024;

// 安全批次 B：后端进程令牌（X-Backend-Token）。启用后（require_token 非空）
// 除豁免外的 /api/* 一律要求等值令牌。豁免：
//   * /api/ping        —— 启动探活；客户端在读取 .backend_token 之前就要能
//                         确认端口归属（它不泄露任何数据）。
//   * 非 /api/* 路径   —— 静态资源（web_root 托管）：浏览器 <img>/<script>
//                         无法携带自定义头。
//   * OPTIONS          —— CORS preflight 不能携带自定义头（在更早的分支处理）。
bool token_exempt(const std::string& path) {
    return path == "/api/ping" || path.rfind("/api/", 0) != 0;
}

// 常数时间比较：长度不等直接 false（长度本身不构成泄露）；逐字节 XOR 折叠。
bool token_ok(const std::string& require, const Req& req) {
    if (token_exempt(req.path)) return true;
    if (req.backend_token_header.size() != require.size()) return false;
    unsigned char diff = 0;
    for (size_t i = 0; i < require.size(); ++i) {
        diff |= static_cast<unsigned char>(require[i]) ^
                static_cast<unsigned char>(req.backend_token_header[i]);
    }
    return diff == 0;
}

void serve_connection(sa_socket_t sock, const Router& router, const std::atomic<bool>& quit_flag,
                      const CorsConfig* cors, const std::string* require_token,
                      long long max_body_bytes, long long raw_body_keep_max) {
    set_recv_timeout(sock, kKeepAliveIdleMs);
    LineReader reader(sock);
    // Errors raised before the origin verdict still need the tier's header
    // block (no ACAO echo, but the server-tier Allow-Headers set).
    CorsWire wire_pre;
    wire_pre.server_mode = cors && cors->server_mode();
    for (;;) {
        if (quit_flag.load()) break;

        std::string line;
        if (!reader.next_line(line)) {
            if (reader.overflowed()) {
                // Head cap exceeded: answer 431 and drop (the connection framing
                // is unrecoverable without knowing where the headers end).
                json env{{"error", "request head too large"}};
                write_response(sock, 431, sa_core::py_dumps(env), true);
            }
            break;  // EOF / idle timeout / dropped / overflow
        }
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
                    if (reader.overflowed() && !responded) {
                        responded = true;
                        json env{{"error", "request head too large"}};
                        write_response(sock, 431, sa_core::py_dumps(env), true);
                    }
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
                } else if (name == "authorization" && req.authorization_header.empty()) {
                    req.authorization_header = value;
                } else if (name == "x-backend-token" && req.backend_token_header.empty()) {
                    req.backend_token_header = value;
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
            if (qpos != std::string::npos) {
                req.raw_query = target.substr(qpos + 1);
                req.query = parse_query_last(req.raw_query);
            }

            if (req.method == "OPTIONS") {
                // do_OPTIONS: no Content-Length parse, no body (httpd.py:192-211).
                std::string reason;
                if (!check_origin(req, cors, &reason)) {
                    responded = true;
                    json env{{"error", reason}};
                    if (!write_response(sock, 403, sa_core::py_dumps(env), true, {}, {},
                                        wire_pre))
                        break;
                } else {
                    responded = true;
                    if (!write_options_response(sock, close_after,
                                                CorsWire::for_request(cors, req, true)))
                        break;
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
                    write_response(sock, 400, sa_core::py_dumps(env), true, {}, {}, wire_pre);
                    break;
                }
                std::string body_raw;
                long long want = *length < 0 ? 0 : *length;  // length = max(0, length)
                if (want > max_body_bytes) {
                    // Refuse before reading: the body is buffered whole in memory.
                    responded = true;
                    json env{{"error", "request body too large"}};
                    write_response(sock, 413, sa_core::py_dumps(env), true, {}, {}, wire_pre);
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
                // 大体积上传：解析完再「移动」走 wire 字节（而非解析前复制），
                // 峰值少一份整包副本（自定义 max_body_bytes 时尤其要紧）。
                if (static_cast<long long>(body_raw.size()) <= raw_body_keep_max)
                    req.raw_body = std::move(body_raw);

                std::string reason;
                bool origin_ok = check_origin(req, cors, &reason);
                const CorsWire wire = CorsWire::for_request(cors, req, origin_ok);
                Resp resp;
                if (!origin_ok) {
                    resp = Resp::Json(403, json{{"error", reason}});
                } else if (require_token != nullptr && !token_ok(*require_token, req)) {
                    resp = Resp::Json(403, json{{"error", "forbidden: backend token required"}});
                } else {
                    resp = router.dispatch(req);
                }
                responded = true;
                int status = resp.status;
                std::string body;
                serialize_payload(status, resp, body);  // may downgrade to 500
                // /api/shutdown must not wait out the 65s keep-alive idle: force
                // Connection: close so this loop exits immediately and the owning
                // thread can _Exit(0) right after flushing the response.
                if (g_shutdown_after.load()) close_after = true;
                if (!write_response(sock, status, body, close_after, resp.content_type,
                                    resp.cache_control, wire))
                    break;
            }
        } catch (const std::exception&) {
            // httpd.py:121-129: fallback 500 ONLY when nothing was written (B11).
            if (!responded) {
                write_response(sock, 500, error_body("internal server error"), true, {}, {},
                               wire_pre);
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
    // 性能 P2：不含正则元字符的字面量 pattern 进入精确直达表（绝大多数路由）。
    if (pattern.find_first_of("^$.|()[]{}*+?\\") == std::string::npos) {
        std::string key = method;
        key += '\x1f';
        key += pattern;
        exact_.emplace(std::move(key), entries_.size());  // 首注册者优先
    }
    entries_.push_back(std::move(e));
}

Resp Router::dispatch(Req& req) const {
    // 性能 P2：精确路由 O(1) 直达；未命中再走有序正则回退（~190 条），首条
    // 命中的顺序语义完全保留。两条路径的异常语义逐字节一致（同一 catch 组）。
    std::string key;
    key.reserve(req.method.size() + 1 + req.path.size());
    key = req.method;
    key += '\x1f';
    key += req.path;
    auto hit = exact_.find(key);
    if (hit != exact_.end()) {
        const Entry& e = entries_[hit->second];
        try {
            return e.fn(req);
        } catch (const ApiError& err) {
            return Resp::Json(500, json{{"error", err.what()}});
        } catch (const json::exception& err) {
            return Resp::Json(500, json{{"error", std::string("ValueError: ") + err.what()}});
        } catch (const std::exception& err) {
            return Resp::Json(500, json{{"error", std::string("RuntimeError: ") + err.what()}});
        }
    }
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

    // B13 (httpd.py:221): 64 slots by default. The web tiers may raise it
    // (网页版计划 M1.2) — a value <=0 falls back to the default.
    int max_slots = 192;  // B13 默认 64 -> 192（性能 P1；网关/测试仍可覆盖）
    CorsConfig cors;      // set before start(); read-only afterwards
    std::string auth_token;               // 安全批次 B：空串 = 不启用
    long long max_body = kDefaultMaxBodyBytes;
    // Req::raw_body 保留上限（§4 代理重放 + 网关转发用）。可经
    // set_raw_body_keep_max 抬高（网关按 gateway.json 的 max_body_bytes 设置）。
    long long raw_body_keep = static_cast<long long>(kRawBodyKeepMax);

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
    // idle connection never stretches the drain. The wait is deliberately
    // unbounded: a handler may legitimately run for minutes (ai_image and tts
    // use 300s outbound timeouts), and a bounded guard that expires early would
    // let ~Httpd free Impl while the detached thread is still inside
    // serve_connection -- a use-after-free on Impl and the caller's Router.
    void drain_conns() {
        while (slots.load() > 0) {
            wake_conns();
            std::unique_lock<std::mutex> lk(conn_mu);
            conn_cv.wait_for(lk, std::chrono::milliseconds(10),
                             [this] { return slots.load() == 0; });
        }
    }

    bool try_acquire() {
        const int limit = max_slots > 0 ? max_slots : 64;
        int cur = slots.load(std::memory_order_relaxed);
        while (cur < limit) {
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
            enable_nodelay(conn);
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
                const std::string impl_auth_token = auth_token;        // 快照，线程安全读
                const long long impl_max_body = max_body;
                const long long impl_raw_keep = raw_body_keep;
                serve_connection(conn, *router, quit, &cors,
                                 impl_auth_token.empty() ? nullptr : &impl_auth_token,
                                 impl_max_body, impl_raw_keep);
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
#else
    // A client hanging up mid-response raises SIGPIPE on POSIX (Windows has no
    // such signal, so CI there never exposes this); ignoring it turns the next
    // send() into a plain EPIPE error that send_all already handles.
    ::signal(SIGPIPE, SIG_IGN);
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

void Httpd::set_cors(const CorsConfig& cors) { impl_->cors = cors; }

void Httpd::set_max_slots(int n) { impl_->max_slots = n; }

void Httpd::set_auth_token(std::string token) { impl_->auth_token = std::move(token); }

void Httpd::set_max_body_bytes(long long n) {
    if (n > 0) impl_->max_body = n;
}

void Httpd::set_raw_body_keep_max(long long n) {
    if (n > 0) impl_->raw_body_keep = n;
}

void Httpd::start() {
    impl_->accept_thread = std::thread([this] { impl_->accept_loop(); });
}

void Httpd::stop() { impl_->stop(); }

int Httpd::active_connections() const { return impl_->slots.load(); }

void request_shutdown() { g_shutdown_after.store(true); }

bool shutdown_requested() { return g_shutdown_after.load(); }

namespace detail {
void clear_shutdown_for_test() { g_shutdown_after.store(false); }

std::atomic<bool> g_shutdown_disabled{false};
void set_shutdown_disabled(bool disabled) { g_shutdown_disabled.store(disabled); }
bool shutdown_disabled() { return g_shutdown_disabled.load(); }
}  // namespace detail

}  // namespace sa
