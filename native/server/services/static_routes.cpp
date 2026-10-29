// server/services/static_routes.cpp — see static_routes.h.
#include "static_routes.h"

#include <cctype>
#include <cstdio>
#include <string>
#include <unordered_map>
#include <utility>

#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "server/state.h"

namespace sa {
namespace {

// Extensions we hand out, mapped to Content-Type. The flutter web bundle only
// needs a handful; unknown extensions fall back to octet-stream (still served,
// browsers sniff image/font types from the leading bytes anyway).
const std::unordered_map<std::string, const char*>& mime_map() {
    static const std::unordered_map<std::string, const char*> m = {
        {"html", "text/html; charset=utf-8"},   {"htm", "text/html; charset=utf-8"},
        {"js", "text/javascript; charset=utf-8"}, {"mjs", "text/javascript; charset=utf-8"},
        {"css", "text/css; charset=utf-8"},     {"json", "application/json"},
        {"bin", "application/octet-stream"},    {"manifest", "text/cache-manifest"},
        {"wasm", "application/wasm"},           {"svg", "image/svg+xml"},
        {"png", "image/png"},                   {"jpg", "image/jpeg"},
        {"jpeg", "image/jpeg"},                 {"gif", "image/gif"},
        {"webp", "image/webp"},                 {"avif", "image/avif"},
        {"ico", "image/x-icon"},
        {"woff", "font/woff"},                  {"woff2", "font/woff2"},
        {"ttf", "font/ttf"},                    {"otf", "font/otf"},
        {"txt", "text/plain; charset=utf-8"},   {"xml", "application/xml"},
    };
    return m;
}

std::string ext_of(const std::string& p) {
    size_t slash = p.find_last_of("/\\");
    std::string base = slash == std::string::npos ? p : p.substr(slash + 1);
    size_t dot = base.find_last_of('.');
    if (dot == std::string::npos) return {};
    std::string e = base.substr(dot + 1);
    for (auto& c : e) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return e;
}

// Reject a relative path that would escape web_root. The transport already
// percent-decoded req.path, so ".." and absolute-ish shapes can appear here.
bool rel_is_safe(const std::string& rel) {
    if (rel.empty()) return false;
    if (rel.front() == '/' || rel.front() == '\\') return false;
    if (rel.find('\0') != std::string::npos) return false;
    // Windows drive prefix (C:) or any colon before the first separator.
    size_t sep = rel.find_first_of("/\\");
    if (rel.find(':') != std::string::npos && (sep == std::string::npos ||
                                               rel.find(':') < sep))
        return false;
    // Reject any "." / ".." path segment outright.
    size_t i = 0;
    while (i <= rel.size()) {
        size_t j = rel.find_first_of("/\\", i);
        if (j == std::string::npos) j = rel.size();
        std::string seg = rel.substr(i, j - i);
        if (seg == "..") return false;
        i = j + 1;
        if (j == rel.size()) break;
    }
    return true;
}

std::string lower_ascii(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

bool is_zero_q(const std::string& params) {
    // "br;q=0" / "gzip; q=0.000" mean "not acceptable".
    std::string p = lower_ascii(params);
    size_t q = p.find("q=");
    if (q == std::string::npos) return false;
    size_t i = q + 2;
    while (i < p.size() && (p[i] == ' ' || p[i] == '\t')) ++i;
    double value = 0.0;
    bool any = false;
    while (i < p.size() && ((p[i] >= '0' && p[i] <= '9') || p[i] == '.')) {
        any = true;
        i += 1;
    }
    if (!any) return false;
    try {
        value = std::stod(p.substr(q + 2, i - (q + 2)));
    } catch (...) {
        return false;
    }
    return value <= 0.0;
}

// Token match over a comma-separated Accept-Encoding header. "*" is accepted
// as a wildcard for both encodings (q=0 still opts out).
bool accepts_encoding(const std::string& header, const std::string& token) {
    if (header.empty()) return false;
    size_t i = 0;
    while (i <= header.size()) {
        size_t comma = header.find(',', i);
        if (comma == std::string::npos) comma = header.size();
        std::string item = header.substr(i, comma - i);
        size_t semi = item.find(';');
        std::string name = item.substr(0, semi);
        size_t b = name.find_first_not_of(" \t");
        size_t e = name.find_last_not_of(" \t");
        name = b == std::string::npos ? std::string{} : name.substr(b, e - b + 1);
        const std::string params = semi == std::string::npos ? "" : item.substr(semi + 1);
        const std::string lowered = lower_ascii(name);
        if ((lowered == token || lowered == "*") && !is_zero_q(params)) return true;
        i = comma + 1;
        if (comma == header.size()) break;
    }
    return false;
}

// Strong ETag for a static asset. Includes the encoding tag so a gzip/br
// variant can never satisfy an identity response's validator.
std::string make_etag(long long size, long long mtime_ns, const std::string& enc) {
    char buf[112];
    std::snprintf(buf, sizeof(buf), "\"%llx-%llx-%s\"",
                  static_cast<unsigned long long>(size),
                  static_cast<unsigned long long>(mtime_ns),
                  enc.empty() ? "id" : enc.c_str());
    return std::string(buf);
}

bool etag_matches(const std::string& if_none_match, const std::string& etag) {
    if (if_none_match.empty()) return false;
    if (if_none_match.find('*') != std::string::npos) return true;
    size_t i = 0;
    while (i <= if_none_match.size()) {
        size_t comma = if_none_match.find(',', i);
        if (comma == std::string::npos) comma = if_none_match.size();
        std::string item = if_none_match.substr(i, comma - i);
        size_t b = item.find_first_not_of(" \t");
        size_t e = item.find_last_not_of(" \t");
        item = b == std::string::npos ? std::string{} : item.substr(b, e - b + 1);
        if (item.rfind("W/", 0) == 0) item = item.substr(2);
        if (item == etag) return true;
        i = comma + 1;
        if (comma == if_none_match.size()) break;
    }
    return false;
}

bool has_suffix(const std::string& s, const char* suffix) {
    const size_t n = std::char_traits<char>::length(suffix);
    return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

bool starts_with(const std::string& s, const char* prefix) {
    return s.rfind(prefix, 0) == 0;
}

// Cache policy. Everything that is not content-addressed revalidates on every
// visit (a 304 is a couple hundred bytes); only hash-versioned fallback fonts
// are immutable. Icons are small and only change on a release, so a day is a
// good middle ground.
std::string cache_control_for(const std::string& rel) {
    if (starts_with(rel, "fallback_fonts/")) return "public, max-age=31536000, immutable";
    if (starts_with(rel, "icons/") || starts_with(rel, "favicon")) return "public, max-age=86400";
    return "no-cache";
}

}  // namespace

void register_static_routes(Router& r, const std::string& web_root) {
    // Absolute, separator-normalized root the sandbox is measured against.
    const std::string root_abs = sa_core::paths::abs_path(web_root);
    const std::string root_key = sa_core::paths::path_key(root_abs);

    r.get(R"(/.*)", [root_abs, root_key](const Req& req) -> Resp {
        // API contract first: a GET that reached us under /api/ is an unknown
        // route, and callers (selftest, golden) expect the transport's 404
        // envelope shape, not an asset-server 404.
        if (req.path == "/api" || sa_core::str::starts_with(req.path, "/api/")) {
            return Resp::Json(404, json{{"error", "no route: GET " + req.path}});
        }

        std::string rel = req.path;
        if (rel == "/" || rel.empty()) rel = "index.html";
        else rel = rel.substr(1);  // drop the leading '/'

        if (!rel_is_safe(rel)) {
            return Resp::Json(400, json{{"error", "invalid static path"}});
        }
        // Pre-compressed sidecars are an implementation detail: never serve
        // `main.dart.js.gz` as a first-class asset.
        if (has_suffix(rel, ".gz") || has_suffix(rel, ".br")) {
            return Resp::Json(404, json{{"error", "no such file: " + req.path}});
        }

        const std::string full = sa_core::paths::join(root_abs, rel);
        // Defense in depth: even after rel_is_safe, the resolved absolute path
        // must still live under root (symlink/normalization surprises).
        if (sa_core::paths::path_key(full).compare(0, root_key.size(), root_key) != 0) {
            return Resp::Json(403, json{{"error", "static path escapes web root"}});
        }
        if (!sa_core::paths::is_file(full)) {
            return Resp::Json(404, json{{"error", "no such file: " + req.path}});
        }

        // Content negotiation: brotli first (better ratio), gzip second, then
        // the identity bytes. Precompressed sidecars are produced by
        // build_release.py; an installation without them keeps working.
        std::string chosen = full;
        std::string encoding;
        if (accepts_encoding(req.accept_encoding_header, "br") &&
            sa_core::paths::is_file(full + ".br")) {
            chosen = full + ".br";
            encoding = "br";
        } else if ((accepts_encoding(req.accept_encoding_header, "gzip") ||
                    accepts_encoding(req.accept_encoding_header, "x-gzip")) &&
                   sa_core::paths::is_file(full + ".gz")) {
            chosen = full + ".gz";
            encoding = "gzip";
        }

        auto st = sa_core::paths::stat(chosen);
        if (!st) {
            return Resp::Json(500, json{{"error", "failed to stat static file"}});
        }
        const std::string cache_control = cache_control_for(rel);
        const std::string etag = make_etag(st->size, st->mtime_ns,
                                           encoding.empty() ? "id" : encoding);
        if (etag_matches(req.if_none_match_header, etag)) {
            Resp out = Resp::NotModified(etag, cache_control);
            out.headers.emplace_back("Vary", "Accept-Encoding");
            return out;
        }

        auto bytes = sa_core::paths::read_bytes(chosen);
        if (!bytes) {
            return Resp::Json(500, json{{"error", "failed to read static file"}});
        }

        const std::string ext = ext_of(rel);  // original extension, not .gz/.br
        Resp out = Resp::BytesTyped(200, std::move(*bytes),
                                    mime_map().count(ext) ? mime_map().at(ext)
                                                          : "application/octet-stream");
        // index.html / main.dart.js / canvaskit must revalidate (so a redeploy
        // is picked up on refresh and an engine upgrade cannot pair a stale
        // wasm with a new bundle). Hash-versioned fonts opt into long caching.
        out.cache_control = cache_control;
        out.etag = etag;
        out.headers.emplace_back("Vary", "Accept-Encoding");
        if (!encoding.empty()) out.headers.emplace_back("Content-Encoding", encoding);
        return out;
    });
}

}  // namespace sa
