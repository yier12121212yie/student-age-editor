// server/services/static_routes.cpp — see static_routes.h.
#include "static_routes.h"

#include <string>
#include <unordered_map>

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
        {"webp", "image/webp"},                 {"ico", "image/x-icon"},
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

        const std::string full = sa_core::paths::join(root_abs, rel);
        // Defense in depth: even after rel_is_safe, the resolved absolute path
        // must still live under root (symlink/normalization surprises).
        if (sa_core::paths::path_key(full).compare(0, root_key.size(), root_key) != 0) {
            return Resp::Json(403, json{{"error", "static path escapes web root"}});
        }
        if (!sa_core::paths::is_file(full)) {
            return Resp::Json(404, json{{"error", "no such file: " + req.path}});
        }
        auto bytes = sa_core::paths::read_bytes(full);
        if (!bytes) {
            return Resp::Json(500, json{{"error", "failed to read static file"}});
        }

        Resp out = Resp::BytesTyped(200, std::move(*bytes),
                                    mime_map().count(ext_of(full))
                                        ? mime_map().at(ext_of(full))
                                        : "application/octet-stream");
        // index.html must always revalidate (so a redeploy is picked up on
        // refresh); hashed/minified bundles are safe to cache a while. The
        // transport emits `no-store` unless we set cache_control, so this is
        // the only place static content opts out of the fixed API default.
        out.cache_control = ext_of(full) == "html" ? "no-cache" : "public, max-age=3600";
        return out;
    });
}

}  // namespace sa
