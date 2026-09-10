// sa_core/http_client implementation — see http_client.h for the contract.
//
// Windows: WinHTTP (schannel TLS, no third-party dependency). Everything else:
// compile-time stub returning Error::Other ("wave-P9 待接 libcurl") so the
// wave-2 sources link everywhere without dragging a TLS stack in.
#include "sa_core/http_client.h"

#include <algorithm>
#include <cmath>
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
#else   // POSIX (W4-3 class-B port): dlopen the system libcurl + iconv-free
        // stdlib. No link-time dependency: we resolve the handful of curl_easy_*
        // / curl_slist_* symbols at runtime. <cmath> for the read-idle timeout.
#include <dlfcn.h>
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
//
// W4-3 class-B port. The WinHTTP branch above is byte-for-byte untouched.
//
// We drive the system libcurl through dlopen()/dlsym() with a hand-written
// minimal declaration surface (see the constant block). libcurl is present on
// every mainstream Linux distro and macOS (in the shared-cache), so this adds
// ZERO build/link dependencies — no <curl/curl.h> include, no -lcurl, nothing
// in CMakeLists. On a stripped image without libcurl the dlopen fails and we
// fall back to an Error::Other in the same phrasing style as the old stub.
//
// Android (bionic) is deliberately NOT handled here: its HTTP path ships in
// the W4-4 JNI wave (java.net.HttpURLConnection / OkHttp bridge). Keeping the
// stub under __ANDROID__ makes that boundary explicit and stops the POSIX curl
// code from compiling against bionic's absent libcurl.
#if defined(__ANDROID__)

namespace {
Response stub_fail() {
    Response r;
    r.error = Response::Error::Other;
    r.error_message = "outbound HTTP on Android: 见 W4-4 JNI 方案";
    return r;
}
}  // namespace

Response request(const Request&) { return stub_fail(); }
Response request_stream(const Request&, const ChunkHandler&) { return stub_fail(); }

#else   // !_WIN32 && !__ANDROID__ : real libcurl-backed transport -----------

namespace {

// --- hand-written libcurl surface ------------------------------------------
// Only the symbols and enum values the transport actually touches. The numeric
// values were derived from curl's public headers and are ABI-frozen (curl
// guarantees they never change across versions); verified against curl 8.5.0
// (Ubuntu 24.04 libcurl.so.4.8.0) and master.
using CurlHandle = void;        // CURL*
using CurlSList = void;         // struct curl_slist*
using CurlCode = int;           // CURLcode
using CurlInfo = int;           // CURLINFO (values fit in int)

// CURLOPT_* (CURLOPTTYPE_LONG == raw value, OBJECT/CBPOINT/SLISTPOINT +10000,
// FUNCTIONPOINT +20000, OFF_T +30000).
enum : int {
    kOptWriteData = 10001,        // WRITEDATA   (CBPOINT+1)
    kOptUrl = 10002,              // URL         (STRINGPOINT+2)
    kOptPostFields = 10015,       // POSTFIELDS  (OBJECTPOINT+15)
    kOptUserAgent = 10018,        // USERAGENT   (STRINGPOINT+18)
    kOptLowSpeedLimit = 19,       // LOW_SPEED_LIMIT (LONG+19)
    kOptLowSpeedTime = 20,        // LOW_SPEED_TIME  (LONG+20)
    kOptHttpHeader = 10023,       // HTTPHEADER  (SLISTPOINT+23)
    kOptHeaderData = 10029,       // HEADERDATA  (CBPOINT+29)
    kOptCustomRequest = 10036,    // CUSTOMREQUEST (STRINGPOINT+36)
    kOptPost = 47,                // POST        (LONG+47)
    kOptFollowLocation = 52,      // FOLLOWLOCATION (LONG+52)
    kOptPostFieldSize = 60,       // POSTFIELDSIZE (LONG+60)
    kOptSslVerifyPeer = 64,       // SSL_VERIFYPEER (LONG+64)
    kOptMaxRedirs = 68,           // MAXREDIRS   (LONG+68)
    kOptHeaderFunction = 20079,   // HEADERFUNCTION (FUNCTIONPOINT+79)
    kOptNosignal = 99,            // NOSIGNAL    (LONG+99)
    kOptWriteFunction = 20011,    // WRITEFUNCTION (FUNCTIONPOINT+11)
    kOptConnectTimeoutMs = 156,   // CONNECTTIMEOUT_MS (LONG+156)
};
// CURLINFO_RESPONSE_CODE = CURLINFO_LONG(0x200000) + 2.
enum : int { kInfoResponseCode = 2097154 };

// CURLcode subset we phrase into Response::Error (values ABI-frozen).
enum : int {
    kCurOk = 0,
    kCurUnsupportedProto = 1,
    kCurUrlMalformat = 3,
    kCurCantResolveProxy = 5,
    kCurCantResolveHost = 6,
    kCurCantConnect = 7,
    kCurPartialFile = 18,
    kCurWriteError = 23,
    kCurTimeout = 28,
    kCurSslConnect = 35,
    kCurBadFunctionArg = 43,
    kCurTooManyRedirs = 47,
    kCurSendError = 55,
    kCurRecvError = 56,
    kCurSslCertProblem = 58,
    kCurSslCipher = 59,
    kCurPeerVerify = 60,
    kCurUseSslFailed = 64,
    kCurSslCacertBadfile = 77,
    kCurSslIssuerError = 83,
    kCurSslPinnedPubkey = 90,
    kCurSslInvalidCertStatus = 91,
    kCurSslClientCert = 98,
};

// Callback signatures exactly as libcurl invokes them (matches the C ABI).
using WriteFn = size_t (*)(char* ptr, size_t size, size_t nmemb, void* userdata);
using HeaderFn = size_t (*)(char* ptr, size_t size, size_t nmemb, void* userdata);

// The resolved entry points. Declared variadic where curl's own prototype is
// variadic (setopt/getinfo); the fixed args use the SAME width curl expects
// (option/info as int-sized enum) and every variable arg is cast to the exact
// promoted type (long for numeric options, pointer otherwise) — a wrong-width
// vararg on x86-64 would silently mis-set an option, hence the discipline.
using FnEasyInit = CurlHandle* (*)(void);
using FnEasyCleanup = void (*)(CurlHandle*);
using FnEasySetopt = CurlCode (*)(CurlHandle*, int option, ...);
using FnEasyPerform = CurlCode (*)(CurlHandle*);
using FnEasyGetinfo = CurlCode (*)(CurlHandle*, int info, ...);
using FnStrError = const char* (*)(CurlCode);
using FnSlistAppend = CurlSList* (*)(CurlSList*, const char*);
using FnSlistFreeAll = void (*)(CurlSList*);

struct CurlApi {
    FnEasyInit init = nullptr;
    FnEasyCleanup cleanup = nullptr;
    FnEasySetopt setopt = nullptr;
    FnEasyPerform perform = nullptr;
    FnEasyGetinfo getinfo = nullptr;
    FnStrError strerror_fn = nullptr;
    FnSlistAppend slist_append = nullptr;
    FnSlistFreeAll slist_free_all = nullptr;
    bool ok = false;
    std::string why;   // populated when ok == false
};

// Load libcurl once per process (C++11 magic statics => thread-safe). Returns
// a reference; `.ok` false means dlopen/dlsym failed and callers surface a
// transport error rather than crashing.
const CurlApi& curl_api() {
    static const CurlApi api = [] {
        CurlApi a;
        void* h = nullptr;
        // Linux SONAME first (most specific), then macOS in-cache path, then
        // generic fallbacks. RTLD_NOW resolves eagerly so a missing symbol
        // surfaces at load time, not mid-request.
        static const char* kCandidates[] = {
            "libcurl.so.4", "libcurl.so",
            "/usr/lib/libcurl.4.dylib", "libcurl.4.dylib", "libcurl.dylib",
        };
        for (const char* cand : kCandidates) {
            h = ::dlopen(cand, RTLD_NOW | RTLD_LOCAL);
            if (h) break;
        }
        if (!h) {
            a.ok = false;
            a.why = "libcurl.so.4 / libcurl.dylib 不可用（dlopen 失败）";
            return a;
        }
        a.init = reinterpret_cast<FnEasyInit>(::dlsym(h, "curl_easy_init"));
        a.cleanup = reinterpret_cast<FnEasyCleanup>(::dlsym(h, "curl_easy_cleanup"));
        a.setopt = reinterpret_cast<FnEasySetopt>(::dlsym(h, "curl_easy_setopt"));
        a.perform = reinterpret_cast<FnEasyPerform>(::dlsym(h, "curl_easy_perform"));
        a.getinfo = reinterpret_cast<FnEasyGetinfo>(::dlsym(h, "curl_easy_getinfo"));
        a.strerror_fn = reinterpret_cast<FnStrError>(::dlsym(h, "curl_easy_strerror"));
        a.slist_append = reinterpret_cast<FnSlistAppend>(::dlsym(h, "curl_slist_append"));
        a.slist_free_all = reinterpret_cast<FnSlistFreeAll>(::dlsym(h, "curl_slist_free_all"));
        if (!a.init || !a.cleanup || !a.setopt || !a.perform || !a.getinfo ||
            !a.slist_append || !a.slist_free_all) {
            a.ok = false;
            a.why = "libcurl 缺少必要的 curl_easy_*/curl_slist_* 符号";
            return a;
        }
        a.ok = true;
        return a;
    }();
    return api;
}

Response fail(Response::Error kind, const std::string& msg) {
    Response r;
    r.error = kind;
    r.error_message = msg;
    return r;
}

// Map a CURLcode to the transport error category. Deliberately mirrors the
// WinHTTP switch above: DNS/unreachable/reset => Connection, the certificate
// and handshake family => Tls, code 28 (CONNECTTIMEOUT_MS or LOW_SPEED stall)
// => Timeout, protocol/URL reject => BadInput, everything else => Other.
Response error_for_curl(CurlCode code) {
    Response::Error kind = Response::Error::Other;
    switch (code) {
        case kCurTimeout:
            kind = Response::Error::Timeout;
            break;
        case kCurCantResolveProxy:
        case kCurCantResolveHost:
        case kCurCantConnect:
        case kCurSendError:
        case kCurRecvError:
        case kCurPartialFile:      // server closed mid-body: a connection abort
            kind = Response::Error::Connection;
            break;
        case kCurSslConnect:
        case kCurSslCertProblem:
        case kCurSslCipher:
        case kCurPeerVerify:
        case kCurUseSslFailed:
        case kCurSslCacertBadfile:
        case kCurSslIssuerError:
        case kCurSslPinnedPubkey:
        case kCurSslInvalidCertStatus:
        case kCurSslClientCert:
            kind = Response::Error::Tls;
            break;
        case kCurUnsupportedProto:
        case kCurUrlMalformat:
        case kCurBadFunctionArg:
            kind = Response::Error::BadInput;
            break;
        default:
            kind = Response::Error::Other;
            break;
    }
    const CurlApi& a = curl_api();
    const char* desc = (a.strerror_fn && code >= 0) ? a.strerror_fn(code) : "unknown";
    char buf[256];
    std::snprintf(buf, sizeof(buf), "%s: libcurl error %d: %s", "perform", code,
                  desc ? desc : "unknown");
    return fail(kind, buf);
}

// Shared write/header context so the callbacks can accumulate into a Response
// and honour an early-abort request from the chunk handler.
struct Ctx {
    Response* resp = nullptr;
    const ChunkHandler* on_chunk = nullptr;
    bool aborted = false;
};

size_t write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* c = static_cast<Ctx*>(userdata);
    const size_t n = size * nmemb;
    if (!c->resp) return n;
    c->resp->body.append(ptr, n);
    if (c->on_chunk && !(*c->on_chunk)(std::string_view(ptr, n))) {
        c->aborted = true;
        return 0;   // signals CURLE_WRITE_ERROR; we translate it back below
    }
    return n;
}

size_t header_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* c = static_cast<Ctx*>(userdata);
    const size_t n = size * nmemb;
    if (!c->resp) return n;
    std::string line(ptr, n);
    // Strip trailing CRLF/LF.
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
    if (line.rfind("HTTP/", 0) == 0) {
        // A (re)status line: drop prior headers so the FINAL response's headers
        // win — matches WinHTTP's WINHTTP_QUERY_RAW_HEADERS_CRLF on the resolved
        // (post-redirect) request handle.
        c->resp->headers.clear();
        return n;
    }
    const size_t colon = line.find(':');
    if (colon == std::string::npos) return n;   // blank / non-header line
    std::string name = line.substr(0, colon);
    size_t vs = colon + 1;
    while (vs < line.size() && (line[vs] == ' ' || line[vs] == '\t')) vs++;
    c->resp->headers.emplace_back(std::move(name), line.substr(vs));
    return n;
}

// RAII wrapper for the easy handle + header slist (both freed on every exit).
struct HandleGuard {
    const CurlApi& api;
    CurlHandle* h = nullptr;
    CurlSList* slist = nullptr;
    explicit HandleGuard(const CurlApi& a) : api(a) {}
    ~HandleGuard() {
        if (slist) api.slist_free_all(slist);
        if (h) api.cleanup(h);
    }
    HandleGuard(const HandleGuard&) = delete;
};

Response do_request(const Request& req, const ChunkHandler* on_chunk) {
    Url u;
    if (!parse_url(req.url, &u)) {
        return fail(Response::Error::BadInput, "unsupported or malformed URL: " + req.url);
    }
    const CurlApi& api = curl_api();
    if (!api.ok) {
        return fail(Response::Error::Other,
                    "outbound HTTP on non-Windows: " + api.why);
    }
    HandleGuard g(api);
    g.h = api.init();
    if (!g.h) return fail(Response::Error::Other, "curl_easy_init failed");

    Response resp;
    Ctx ctx;
    ctx.resp = &resp;
    ctx.on_chunk = on_chunk;

    // Rebuild the full URL deterministically from the parsed pieces. parse_url
    // already rejected anything that is not http(s), so curl always gets a
    // well-formed absolute URL. IPv6 literals (which parse_url stores without
    // brackets) are re-wrapped here. The default port for the scheme is omitted
    // so the wire Host header stays canonical — matching WinHTTP, which is told
    // host + port separately and does not append :80/:443 to Host.
    const int default_port = u.https ? 443 : 80;
    const bool v6 = u.host.find(':') != std::string::npos;
    std::string full = u.https ? "https://" : "http://";
    full += v6 ? ("[" + u.host + "]") : u.host;
    if (u.port != default_port) full += ":" + std::to_string(u.port);
    full += u.path;
    if (!u.query.empty()) { full += "?"; full += u.query; }

    api.setopt(g.h, kOptUrl, full.c_str());
    api.setopt(g.h, kOptUserAgent, "student-age-editor");
    // No implicit Accept-Encoding/cookies beyond the header list below. NOSIGNAL
    // keeps the DNS/connect timeout signal-free so the transport is safe under
    // the httpd thread model (64 concurrent slots).
    api.setopt(g.h, kOptNosignal, 1L);
    // System default CA (schannel on WinHTTP here; OpenSSL/LibreSSL default
    // trust store on curl). Leave verification ON — the endpoints are real.
    api.setopt(g.h, kOptSslVerifyPeer, 1L);

    // Redirect policy ALWAYS, like WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS /
    // urllib. -1 == unbounded, matching WinHTTP's follow-all; a loop is broken
    // by the server, not by a client cap.
    api.setopt(g.h, kOptFollowLocation, 1L);
    api.setopt(g.h, kOptMaxRedirs, -1L);

    // Timeouts: WinHTTP gives resolve/connect/send/receive each the per-op
    // budget `timeout_seconds` (max(0.5, t)). Connect+resolve map cleanly to
    // CONNECTTIMEOUT_MS. There is no single per-recv knob in the easy API, so we
    // approximate the receive budget with a LOW_SPEED stall trip: if throughput
    // stays below 1 B/s for >= t seconds the transfer is aborted with CURLE_
    // OPERATION_TIMEDOUT (=> Timeout). This preserves long-lived SSE streams
    // (which keep delivering bytes) while rejecting a wedged read after ~t —
    // and, unlike a total CURLOPT_TIMEOUT, does NOT cap total stream duration
    // (matching WinHTTP, which only times a single stalled op).
    const double tsec = std::max(0.5, req.timeout_seconds);
    api.setopt(g.h, kOptConnectTimeoutMs, static_cast<long>(std::llround(tsec * 1000.0)));
    api.setopt(g.h, kOptLowSpeedLimit, 1L);
    // LOW_SPEED_TIME is whole seconds; a 0 value would DISABLE the stall trip,
    // so floor it at 1s. Consequence: a sub-second read timeout cannot be
    // expressed precisely (connect is still ms-precise). Documented divergence.
    api.setopt(g.h, kOptLowSpeedTime,
               static_cast<long>(std::max<long>(1, std::llround(tsec))));

    // Method + body. CUSTOMREQUEST fixes the verb token verbatim (WebDAV needs
    // PROPFIND/MKCOL); POSTFIELDS attaches the body for any verb. Body is only
    // attached when non-empty (so GET/HEAD/DELETE-without-body stay bodyless).
    const std::string method = req.method.empty() ? "GET" : req.method;
    api.setopt(g.h, kOptCustomRequest, method.c_str());
    if (!req.body.empty()) {
        api.setopt(g.h, kOptPostFields, req.body.data());
        api.setopt(g.h, kOptPostFieldSize, static_cast<long>(req.body.size()));
    } else if (method == "POST") {
        // Mirror WinHTTP: a POST always carries a (possibly empty) body and a
        // Content-Length: 0.
        api.setopt(g.h, kOptPost, 1L);
        api.setopt(g.h, kOptPostFields, "");
        api.setopt(g.h, kOptPostFieldSize, 0L);
    }

    // Headers, in order, plus the WinHTTP default Accept when none was given.
    bool has_accept = false;
    for (const auto& [k, v] : req.headers) {
        if (lower_ascii(k) == "accept") has_accept = true;
        // A header with an EMPTY value must be sent as "Name:" (curl treats a
        // trailing ';' or empty value specially — build "Name: " here).
        std::string hv = k + ": " + v;
        CurlSList* appended = api.slist_append(g.slist, hv.c_str());
        if (appended) g.slist = appended;
    }
    if (!has_accept) {
        CurlSList* appended = api.slist_append(g.slist, "Accept: */*");
        if (appended) g.slist = appended;
    }
    if (g.slist) api.setopt(g.h, kOptHttpHeader, g.slist);

    // Callbacks: status + headers are parsed before the first body chunk fires
    // (curl invokes HEADERFUNCTION for the response headers, then WRITEFUNCTION
    // for body bytes) — matches the WinHTTP ordering and the header contract.
    api.setopt(g.h, kOptWriteFunction, reinterpret_cast<void*>(&write_cb));
    api.setopt(g.h, kOptWriteData, &ctx);
    api.setopt(g.h, kOptHeaderFunction, reinterpret_cast<void*>(&header_cb));
    api.setopt(g.h, kOptHeaderData, &ctx);

    CurlCode code = api.perform(g.h);
    if (code == kCurWriteError && ctx.aborted) {
        // Early abort requested by on_chunk: deliver the partial body + parsed
        // status/headers with Error::None (contract: "partial body is still
        // delivered; Error stays None").
        code = kCurOk;
    }
    if (code != kCurOk) {
        return error_for_curl(code);
    }

    long status = 0;
    api.getinfo(g.h, kInfoResponseCode, &status);
    resp.status = static_cast<int>(status);
    resp.error = Response::Error::None;
    return resp;
}

}  // namespace

Response request(const Request& req) { return do_request(req, nullptr); }

Response request_stream(const Request& req, const ChunkHandler& on_chunk) {
    return do_request(req, &on_chunk);
}

#endif  // __ANDROID__ / POSIX curl

#endif  // _WIN32

}  // namespace http
}  // namespace sa_core
