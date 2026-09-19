// sa_core/http_client: the outbound HTTP client (wave-2 P4, official core file).
//
// Why this lives in sa_core: every networking service (TTS providers, OpenAI
// Images, GitHub update checks — wave 2 P4), the cloud/WebDAV sync services
// (wave 3 P5) and the §4 plugin-service fetches/proxy need one shared outbound
// client. Windows builds use **WinHTTP** (winhttp.dll, in-box on every
// supported Windows): TLS rides on schannel, so the dependency footprint stays
// zero-new-third-party. Non-Windows builds dlopen the system libcurl at
// runtime (no link-time import, keeping the same zero-new-dependency rule).
//
// Wave-3 (P5) reuse notes:
//   * `request()` is the buffered model — mirrors Python
//     `urllib.request.urlopen(req, timeout=t).read()`; TTS/image/update all
//     consume it that way (the DashScope SSE path reads the whole body first,
//     exactly like tts_service.py:443 `resp.read()`; it then splits `data:`
//     lines itself).
//   * `request_stream()` adds a per-chunk callback for callers that must
//     react to bytes incrementally (progress, early abort). `on_chunk` runs on
//     the calling thread before `request_stream` returns; status + headers are
//     already parsed when the first chunk fires and again in the returned
//     Response. Returning false from the callback aborts the read (the
//     partial body is still delivered; Error stays None).
//   * Redirects: policy ALWAYS when the OS supports the option (urllib
//     follows them too). Cookies: none per session. Proxy: the system/IE
//     configuration (WINHTTP_ACCESS_TYPE_DEFAULT_PROXY) — note Python's
//     urllib honours http(s)_proxy *environment variables* instead; for the
//     loopback mock endpoints used in tests this distinction is invisible.
//   * HTTP status >= 400 is NOT an error here: the Response carries the status
//     and the readable body so callers can reproduce Python's
//     `except HTTPError as e: "HTTP %s: %s" % (e.code, _extract_error(e.read()))`
//     envelope. Only transport-level failures set `Response::error`.
#pragma once

#include <functional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace sa_core {
namespace http {

// A URL split into request components (WinHttpCrackUrl wrapper; exposed for
// tests and for callers that must build requests from host/port literals).
struct Url {
    bool https = false;
    std::string host;   // puny/IDN not handled (same as urllib's default for
                        // the API hosts we talk to — all ASCII)
    int port = 0;       // 0 == scheme default (443/80)
    std::string path;   // "" normalizes to "/" on the wire
    std::string query;  // without the leading '?'
    bool valid = false;
};

bool parse_url(std::string_view url, Url* out);

// Percent-encode a single query/path component with Python
// `urllib.parse.quote(s)` defaults (safe="/" — everything outside
// [A-Za-z0-9._~-/] gets %XX, UTF-8 bytes separately).
std::string quote_component(std::string_view s);

struct Request {
    std::string method = "GET";              // "GET"/"POST"/"PUT"/"DELETE"/...
    std::string url;                         // absolute http(s) URL
    // Sent in order; do NOT add Content-Length yourself for `request()` with a
    // body — the transport sets it from `body.size()`.
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body;                        // raw bytes (empty = no body)
    // Per-operation timeout in seconds (mirrors socket-level urlopen timeout:
    // resolve/connect/send/receive each get this budget, not the total).
    double timeout_seconds = 30.0;
    // Skip the system/IE proxy configuration (WinHTTP NO_PROXY session, curl
    // PROXY=""). Loopback callers must set it: under WINHTTP_ACCESS_TYPE_
    // DEFAULT_PROXY a corporate proxy swallows requests to 127.0.0.1, which
    // would make every PLUGIN_SPEC §4 service plugin look dead.
    bool bypass_proxy = false;
    // 3xx handling. Default true keeps urllib/WinHTTP parity; the §4 service
    // fetches/proxy set false, because following a redirect to a non-loopback
    // host is exactly the escape its 127.0.0.1-only URL whitelist forbids.
    bool follow_redirects = true;
};

struct Response {
    enum class Error {
        None,       // an HTTP response was received (status may be >= 400!)
        Timeout,    // socket-level timeout (Python: URLError reason socket.timeout)
        Connection, // refused/unreachable/DNS (Python: URLError)
        Tls,        // certificate/handshake failure (Python: SSLError under URLError)
        BadInput,   // malformed URL, unsupported scheme
        Other,      // everything else (incl. the non-Windows stub)
    };

    int status = 0;              // HTTP status; 0 when Error != None
    std::string body;            // response bytes (may be empty)
    std::vector<std::pair<std::string, std::string>> headers;  // name as sent
    Error error = Error::None;
    std::string error_message;   // human-readable transport error (UTF-8)

    bool transport_ok() const { return error == Error::None; }
    // Case-insensitive header lookup (first match wins, like .get() on the
    // urllib message).
    std::string header(std::string_view name) const;
};

// Buffered request: read the entire response, then return. Never throws.
Response request(const Request& req);

using ChunkHandler = std::function<bool(std::string_view chunk)>;
// Streaming request: `on_chunk` fires for each received block before the
// call returns. The full body is still accumulated in the returned Response
// (callers that want to abort early return false from the callback).
Response request_stream(const Request& req, const ChunkHandler& on_chunk);

// Small helpers shared by the networking services (kept here so wave-3 has
// them without re-deriving):
std::string bytes_to_hex(std::string_view data);
// Strict hex decode (even length, [0-9a-fA-F]*); nullopt otherwise — the
// contract MiniMax's `output_format=hex` path needs before base64 fallback.
bool hex_to_bytes(std::string_view hex, std::string* out);

// RFC4648 base64. `decode` follows Python `base64.b64decode(s, validate=False)`
// semantics: strip everything outside the b64 alphabet, then require the
// remainder length % 4 == 0 (binascii.Error otherwise) and accept any '='
// padding position the length implies. nullopt on failure.
std::string b64_encode(std::string_view data);
bool b64_decode(std::string_view text, std::string* out);

}  // namespace http
}  // namespace sa_core
