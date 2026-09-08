// sa_core/http_client implementation — see http_client.h for the contract.
//
// Windows: WinHTTP (schannel TLS, no third-party dependency). Everything else:
// compile-time stub returning Error::Other ("wave-P9 待接 libcurl") so the
// wave-2 sources link everywhere without dragging a TLS stack in.
#include "sa_core/http_client.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwctype>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>
#endif

namespace sa_core {
namespace http {
namespace {

int hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::string lower_ascii(std::string_view s) {
    std::string out(s);
    for (auto& c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

}  // namespace

bool parse_url(std::string_view url, Url* out) {
    out->valid = false;
    out->https = false;
    out->host.clear();
    out->port = 0;
    out->path.clear();
    out->query.clear();
    auto pos = url.find("://");
    if (pos == std::string_view::npos) return false;
    std::string scheme = lower_ascii(url.substr(0, pos));
    std::string_view rest = url.substr(pos + 3);
    if (scheme == "https") {
        out->https = true;
        out->port = 443;
    } else if (scheme == "http") {
        out->port = 80;
    } else {
        return false;  // only http(s) — every caller's need set
    }
    auto slash = rest.find('/');
    std::string_view authority = slash == std::string_view::npos ? rest : rest.substr(0, slash);
    std::string_view pathpart = slash == std::string_view::npos ? std::string_view()
                                                                : rest.substr(slash + 1);
    // strip userinfo (unused by our endpoints; never leak it)
    auto at = authority.rfind('@');
    if (at != std::string_view::npos) authority = authority.substr(at + 1);
    if (!authority.empty() && authority.front() == '[') {
        auto close = authority.find(']');
        if (close == std::string_view::npos) return false;
        out->host = std::string(authority.substr(1, close - 1));
        std::string_view tail = authority.substr(close + 1);
        if (!tail.empty()) {
            if (tail.front() != ':') return false;
            tail = tail.substr(1);
        }
        if (!tail.empty()) {
            int p = std::atoi(std::string(tail).c_str());
            if (p <= 0 || p > 65535) return false;
            out->port = p;
        }
    } else {
        auto colon = authority.find(':');
        out->host = std::string(colon == std::string_view::npos ? authority
                                                                : authority.substr(0, colon));
        if (colon != std::string_view::npos) {
            int p = std::atoi(std::string(authority.substr(colon + 1)).c_str());
            if (p <= 0 || p > 65535) return false;
            out->port = p;
        }
        if (out->host.empty()) return false;
    }
    auto q = pathpart.find('?');
    out->path = "/" + std::string(q == std::string_view::npos ? pathpart
                                                              : pathpart.substr(0, q));
    if (q != std::string_view::npos) out->query = std::string(pathpart.substr(q + 1));
    out->valid = true;
    return true;
}

std::string quote_component(std::string_view s) {
    static const char* hexd = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : s) {
        if (std::isalnum(c) || c == '.' || c == '-' || c == '_' || c == '~' || c == '/') {
            out += static_cast<char>(c);
        } else {
            out += '%';
            out += hexd[c >> 4];
            out += hexd[c & 0xF];
        }
    }
    return out;
}

std::string bytes_to_hex(std::string_view data) {
    static const char* hexd = "0123456789abcdef";
    std::string out;
    out.reserve(data.size() * 2);
    for (unsigned char c : data) {
        out += hexd[c >> 4];
        out += hexd[c & 0xF];
    }
    return out;
}

bool hex_to_bytes(std::string_view hex, std::string* out) {
    if (hex.size() % 2 != 0) return false;
    std::string res;
    res.reserve(hex.size() / 2);
    for (size_t i = 0; i < hex.size(); i += 2) {
        int hi = hex_val(hex[i]);
        int lo = hex_val(hex[i + 1]);
        if (hi < 0 || lo < 0) return false;
        res += static_cast<char>((hi << 4) | lo);
    }
    *out = std::move(res);
    return true;
}

std::string b64_encode(std::string_view data) {
    static const char* tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve(((data.size() + 2) / 3) * 4);
    size_t i = 0;
    while (i + 3 <= data.size()) {
        unsigned v = (static_cast<unsigned char>(data[i]) << 16) |
                     (static_cast<unsigned char>(data[i + 1]) << 8) |
                     static_cast<unsigned char>(data[i + 2]);
        out += tbl[(v >> 18) & 63];
        out += tbl[(v >> 12) & 63];
        out += tbl[(v >> 6) & 63];
        out += tbl[v & 63];
        i += 3;
    }
    size_t rem = data.size() - i;
    if (rem == 1) {
        unsigned v = static_cast<unsigned char>(data[i]) << 16;
        out += tbl[(v >> 18) & 63];
        out += tbl[(v >> 12) & 63];
        out += "==";
    } else if (rem == 2) {
        unsigned v = (static_cast<unsigned char>(data[i]) << 16) |
                     (static_cast<unsigned char>(data[i + 1]) << 8);
        out += tbl[(v >> 18) & 63];
        out += tbl[(v >> 12) & 63];
        out += tbl[(v >> 6) & 63];
        out += '=';
    }
    return out;
}

bool b64_decode(std::string_view text, std::string* out) {
    // Python `base64.b64decode(s, validate=False)` -> binascii.a2b_base64:
    // characters outside the alphabet are discarded before decoding; "="
    // terminates the data (trailing characters ignored). A remainder of one
    // data character (len % 4 == 1) is the classic binascii error -> failure.
    auto val_of = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return -1;
    };
    std::string clean;
    clean.reserve(text.size());
    for (char c : text) {
        if (val_of(c) >= 0) {
            clean += c;
        } else if (c == '=') {
            break;
        }
        // else: silently discarded (validate=False behaviour)
    }
    if (clean.size() % 4 == 1) return false;
    std::string res;
    res.reserve(clean.size() / 4 * 3);
    size_t i = 0;
    while (i + 4 <= clean.size()) {
        unsigned v = (static_cast<unsigned>(val_of(clean[i])) << 18) |
                     (static_cast<unsigned>(val_of(clean[i + 1])) << 12) |
                     (static_cast<unsigned>(val_of(clean[i + 2])) << 6) |
                     static_cast<unsigned>(val_of(clean[i + 3]));
        res += static_cast<char>((v >> 16) & 0xFF);
        res += static_cast<char>((v >> 8) & 0xFF);
        res += static_cast<char>(v & 0xFF);
        i += 4;
    }
    size_t rem = clean.size() - i;
    if (rem == 2) {
        unsigned v = (static_cast<unsigned>(val_of(clean[i])) << 18) |
                     (static_cast<unsigned>(val_of(clean[i + 1])) << 12);
        res += static_cast<char>((v >> 16) & 0xFF);
    } else if (rem == 3) {
        unsigned v = (static_cast<unsigned>(val_of(clean[i])) << 18) |
                     (static_cast<unsigned>(val_of(clean[i + 1])) << 12) |
                     (static_cast<unsigned>(val_of(clean[i + 2])) << 6);
        res += static_cast<char>((v >> 16) & 0xFF);
        res += static_cast<char>((v >> 8) & 0xFF);
    }
    *out = std::move(res);
    return true;
}

std::string Response::header(std::string_view name) const {
    std::string want = lower_ascii(name);
    for (const auto& [k, v] : headers) {
        if (lower_ascii(k) == want) return v;
    }
    return {};
}

#ifdef _WIN32
namespace {

// RAII wrappers ---------------------------------------------------------------
struct Session {
    HINTERNET h = nullptr;
    Session(const wchar_t* ua, DWORD access) { h = WinHttpOpen(ua, access, nullptr, nullptr, 0); }
    ~Session() {
        if (h) WinHttpCloseHandle(h);
    }
    Session(const Session&) = delete;
    explicit operator bool() const { return h != nullptr; }
};

struct Hdl {
    HINTERNET h = nullptr;
    Hdl() = default;
    explicit Hdl(HINTERNET x) : h(x) {}
    ~Hdl() {
        if (h) WinHttpCloseHandle(h);
    }
    Hdl(Hdl&& o) noexcept : h(o.h) { o.h = nullptr; }
    Hdl& operator=(Hdl&& o) noexcept {
        if (this != &o) {
            if (h) WinHttpCloseHandle(h);
            h = o.h;
            o.h = nullptr;
        }
        return *this;
    }
    Hdl(const Hdl&) = delete;
    explicit operator bool() const { return h != nullptr; }
};

std::wstring to_wide(std::string_view s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return w;
}

std::string to_utf8(std::wstring_view w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0,
                                nullptr, nullptr);
    std::string s(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr,
                        nullptr);
    return s;
}

Response fail(Response::Error kind, const std::string& msg) {
    Response r;
    r.error = kind;
    r.error_message = msg;
    return r;
}

// WinHTTP diagnostics: the 12002 timeout and the connection/TLS families map
// onto the Error enum the services phrase into their Chinese messages.
Response error_for_last_win32(const char* what) {
    DWORD code = GetLastError();
    Response::Error kind = Response::Error::Other;
    switch (code) {
        case 12002:  // ERROR_INTERNET_TIMEOUT (any phase)
            kind = Response::Error::Timeout;
            break;
        case 12007:  // server name could not be resolved (DNS)
        case 12029:  // cannot connect
        case 12030:  // connection terminated abnormally
        case 12161:  // min TLS version handshake
            kind = Response::Error::Connection;
            break;
        case 12175:  // ERROR_WINHTTP_SECURE_FAILURE (certificate/handshake)
            kind = Response::Error::Tls;
            break;
        default:
            kind = Response::Error::Other;
            break;
    }
    char buf[160];
    std::snprintf(buf, sizeof(buf), "%s: WinHTTP error %lu (0x%08lx)", what, code, code);
    return fail(kind, buf);
}

constexpr wchar_t kUserAgent[] = L"student-age-editor";

Response do_request(const Request& req, const ChunkHandler* on_chunk) {
    Url u;
    if (!parse_url(req.url, &u)) {
        return fail(Response::Error::BadInput, "unsupported or malformed URL: " + req.url);
    }
    Session session(kUserAgent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY);
    if (!session) return fail(Response::Error::Other, "WinHttpOpen failed");

    DWORD t_ms = static_cast<DWORD>(std::max<double>(0.5, req.timeout_seconds) * 1000.0);
    // resolve, connect, send, receive — per-operation budget like socket timeout
    if (!WinHttpSetTimeouts(session.h, static_cast<int>(t_ms), static_cast<int>(t_ms),
                            static_cast<int>(t_ms), static_cast<int>(t_ms))) {
        return error_for_last_win32("WinHttpSetTimeouts");
    }
    // Follow 3xx like urllib (best effort; option unsupported on older stacks)
    DWORD redir = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
    WinHttpSetOption(session.h, WINHTTP_OPTION_REDIRECT_POLICY, &redir, sizeof(redir));

    Hdl connect(WinHttpConnect(session.h, to_wide(u.host).c_str(),
                               static_cast<INTERNET_PORT>(u.port), 0));
    if (!connect) return error_for_last_win32("WinHttpConnect");

    std::wstring target = to_wide(u.path);
    if (!u.query.empty()) {
        target += L"?";
        target += to_wide(u.query);
    }
    std::string method = req.method.empty() ? "GET" : req.method;
    Hdl request_handle(WinHttpOpenRequest(
        connect.h, to_wide(method).c_str(), target.c_str(), nullptr, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, u.https ? WINHTTP_FLAG_SECURE : 0));
    if (!request_handle) return error_for_last_win32("WinHttpOpenRequest");

    std::wstring headers;
    bool has_accept = false;
    for (const auto& [k, v] : req.headers) {
        if (lower_ascii(k) == "accept") has_accept = true;
        headers += to_wide(k);
        headers += L": ";
        headers += to_wide(v);
        headers += L"\r\n";
    }
    if (!has_accept) headers += L"Accept: */*\r\n";

    // Content-Length is set by WinHttpSendRequest from the totals field.
    // WinHTTP only reads the buffer, so casting away const is safe here.
    void* body_ptr = req.body.empty()
                         ? nullptr
                         : const_cast<void*>(static_cast<const void*>(req.body.data()));
    DWORD body_size = static_cast<DWORD>(req.body.size());
    BOOL sent = WinHttpSendRequest(
        request_handle.h, headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers.c_str(),
        static_cast<DWORD>(headers.size()), body_ptr, body_size, body_size, 0);
    if (!sent) return error_for_last_win32("WinHttpSendRequest");
    if (!WinHttpReceiveResponse(request_handle.h, nullptr)) {
        return error_for_last_win32("WinHttpReceiveResponse");
    }

    Response resp;
    wchar_t status_buf[16] = {};
    DWORD status_size = sizeof(status_buf);
    if (!WinHttpQueryHeaders(request_handle.h, WINHTTP_QUERY_STATUS_CODE, nullptr, status_buf,
                             &status_size, nullptr)) {
        return error_for_last_win32("WinHttpQueryHeaders(status)");
    }
    resp.status = _wtoi(status_buf);

    wchar_t hdr_buf[16384] = {};
    DWORD hdr_size = sizeof(hdr_buf);
    if (WinHttpQueryHeaders(request_handle.h, WINHTTP_QUERY_RAW_HEADERS_CRLF, nullptr, hdr_buf,
                            &hdr_size, nullptr)) {
        std::string block = to_utf8(hdr_buf);
        size_t pos = 0;
        while (pos < block.size()) {
            size_t eol = block.find("\r\n", pos);
            std::string line =
                block.substr(pos, eol == std::string::npos ? std::string::npos : eol - pos);
            if (!line.empty()) {
                size_t colon = line.find(':');
                if (colon != std::string::npos) {
                    std::string name = line.substr(0, colon);
                    size_t vs = colon + 1;
                    while (vs < line.size() && (line[vs] == ' ' || line[vs] == '\t')) vs++;
                    resp.headers.emplace_back(std::move(name), line.substr(vs));
                }
            }
            if (eol == std::string::npos) break;
            pos = eol + 2;
        }
    }

    for (;;) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request_handle.h, &available)) {
            return error_for_last_win32("WinHttpQueryDataAvailable");
        }
        if (available == 0) break;
        std::string chunk(available, '\0');
        DWORD read = 0;
        if (!WinHttpReadData(request_handle.h, chunk.data(), available, &read)) {
            return error_for_last_win32("WinHttpReadData");
        }
        chunk.resize(read);
        resp.body += chunk;
        if (on_chunk && !(*on_chunk)(std::string_view(chunk))) break;  // early abort
        if (read == 0) break;
    }
    return resp;
}

}  // namespace

Response request(const Request& req) { return do_request(req, nullptr); }

Response request_stream(const Request& req, const ChunkHandler& on_chunk) {
    return do_request(req, &on_chunk);
}

#else  // !_WIN32 --------------------------------------------------------------

namespace {
Response stub_fail() {
    Response r;
    r.error = Response::Error::Other;
    r.error_message = "outbound HTTP on non-Windows: wave-P9 待接 libcurl";
    return r;
}
}  // namespace

Response request(const Request&) { return stub_fail(); }
Response request_stream(const Request&, const ChunkHandler&) { return stub_fail(); }

#endif  // _WIN32

}  // namespace http
}  // namespace sa_core
