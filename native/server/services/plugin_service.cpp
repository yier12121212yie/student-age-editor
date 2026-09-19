// server/services/plugin_service.cpp — see plugin_service.h (PLUGIN_SPEC §4).
//
// Outbound calls all use sa_core::http with bypass_proxy=true (a corporate
// proxy must never answer for a loopback service) and follow_redirects=false
// (a 3xx hop to a non-loopback host is exactly what the URL whitelist exists
// to prevent; a redirecting service simply shows up as an error row).
#include "plugin_service.h"

#include <algorithm>
#include <chrono>
#include <map>
#include <mutex>
#include <string_view>

#include "p3b_support.h"
#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/utf8.h"
#include "server/state.h"  // editor_root(): the default plugins root parent

namespace sa {
namespace plugin_service {
namespace {

namespace cs = sa_core::paths;
namespace http = sa_core::http;

using p3b::json_truthy;
using p3b::py_strip;

constexpr double kFetchTimeoutSeconds = 1.5;   // GET <url>/plugin.json
constexpr double kProxyTimeoutSeconds = 10.0;  // §4: 代理超时 10s
constexpr std::size_t kDescMaxBytes = 2ull * 1024 * 1024;
constexpr std::size_t kProxyRespMaxBytes = 32ull * 1024 * 1024;
constexpr std::size_t kSubpathMaxBytes = 256;

struct Entry {
    std::string url;    // canonical base the description was fetched from
    json desc;          // plugin.json object; null on failure
    std::string error;  // "" == healthy
};

std::mutex g_mu;
std::map<std::string, Entry> g_cache;  // pid -> entry; map order == pid order

std::string lower_ascii(std::string_view s) {
    std::string out(s);
    for (char& c : out) {
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    }
    return out;
}

}  // namespace

// ---------------------------------------------------------------------------
// discovery primitives (§1) — the single implementation shared with
// plugins_routes.cpp, which aliases them instead of keeping private copies
// ---------------------------------------------------------------------------

std::string plugins_root() {
    // plugin_system.plugins_root: EDITOR_PLUGINS_ROOT or <app_data>/plugins.
    // getenv_utf8: the override is a path and may contain CJK on Windows.
    std::string env = cs::getenv_utf8("EDITOR_PLUGINS_ROOT");
    std::string root = !env.empty() ? env : cs::join(sa::editor_root(), "plugins");
    cs::create_dirs(root);  // best-effort like Python
    return root;
}

std::optional<json> read_manifest(const std::string& dir) {
    auto raw = cs::read_bytes(cs::join(dir, "manifest.json"));
    if (!raw) return std::nullopt;
    auto text = sa_core::decode_utf8_sig_strict(*raw);  // utf-8-sig read
    if (!text) return std::nullopt;
    json parsed = json::parse(*text, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object()) return std::nullopt;
    return parsed;
}

// _safe_pid (plugin_system.py:93-96) — the guard every <pid> route runs first,
// before the id is ever joined onto the root.
bool safe_pid(const std::string& pid) {
    if (pid.empty()) return false;
    for (char c : pid) {
        if (c == '/' || c == '\\' || c == ':') return false;
    }
    return pid.find("..") == std::string::npos;
}

std::vector<Found> scan_plugins() {
    std::vector<Found> out;
    const std::string root = plugins_root();
    bool ok = false;
    const std::vector<std::string> names = cs::listdir_sorted(root, &ok);
    if (!ok) return out;
    for (const auto& pid : names) {
        if (pid == "__pycache__") continue;
        const std::string dir = cs::join(root, pid);
        if (!cs::is_dir(dir)) continue;  // plugins.json and stray files are not plugins
        auto manifest = read_manifest(dir);
        if (!manifest) continue;
        out.push_back(Found{pid, std::move(*manifest)});
    }
    return out;
}

// ---------------------------------------------------------------------------
// the "service" declaration (§4 URL whitelist)
// ---------------------------------------------------------------------------

Decl from_manifest(const json& manifest) {
    Decl d;
    if (!manifest.is_object() || !manifest.contains("service")) {
        d.reject_reason = "no service declared";
        return d;
    }
    const json& svc = manifest.at("service");
    if (!svc.is_object()) {
        d.reject_reason = "service is not an object";
        return d;
    }
    if (svc.contains("name") && svc.at("name").is_string()) {
        d.name = svc.at("name").get<std::string>();
    }
    std::string url;
    if (svc.contains("url") && svc.at("url").is_string()) {
        url = svc.at("url").get<std::string>();
    }
    if (url.empty()) {
        d.reject_reason = "url missing";
        return d;
    }
    http::Url u;
    if (!http::parse_url(url, &u)) {
        d.reject_reason = "unparsable url";
        return d;
    }
    if (u.https) {
        d.reject_reason = "https is not allowed (loopback only)";
        return d;
    }
    const std::string host = lower_ascii(u.host);
    if (host != "127.0.0.1" && host != "localhost") {
        d.reject_reason = "host must be 127.0.0.1 or localhost";
        return d;
    }
    // parse_url defaults to :80 when the authority has no ':', but the spec's
    // contract is an explicit port (the 39xxx convention) — require one.
    // parse_url succeeding implies "http://" is present; the guard keeps the
    // npos wraparound below unreachable even if that invariant ever changes.
    const size_t scheme_pos = url.find("://");
    if (scheme_pos == std::string::npos) {
        d.reject_reason = "unparsable url";
        return d;
    }
    const size_t scheme_end = scheme_pos + 3;
    const size_t auth_end = std::min(std::min(url.find('/', scheme_end), url.find('?', scheme_end)),
                                     url.size());
    std::string_view authority(url.data() + scheme_end, auth_end - scheme_end);
    const size_t at = authority.rfind('@');
    if (at != std::string_view::npos) authority = authority.substr(at + 1);
    if (authority.find(':') == std::string_view::npos) {
        d.reject_reason = "explicit port required";
        return d;
    }
    if (u.port <= 0 || u.port > 65535) {
        d.reject_reason = "port out of range";
        return d;
    }
    // u.path is the RAW text after the host ("//" for the root). Allow it as a
    // prefix, but never one that can walk off the service's own namespace.
    if (!u.query.empty()) {
        d.reject_reason = "query string not allowed in url";
        return d;
    }
    if (u.path.size() > 1) {
        if (u.path.find("..") != std::string::npos) {
            d.reject_reason = "path may not contain '..'";
            return d;
        }
        for (unsigned char c : u.path) {
            if (c <= 0x20 || c == 0x7F) {
                d.reject_reason = "path must be printable ASCII";
                return d;
            }
        }
    }
    d.url = "http://" + u.host + ":" + std::to_string(u.port);
    if (u.path.size() > 1) {
        d.url += u.path;  // already starts with '/'
        if (d.url.back() == '/') d.url.pop_back();
    }
    return d;
}

// ---------------------------------------------------------------------------
// self-description fetch + cache
// ---------------------------------------------------------------------------

namespace {

Entry fetch_entry(const Decl& d, double timeout_seconds) {
    Entry e;
    e.url = d.url;
    http::Request req;
    req.method = "GET";
    req.url = d.url + "/plugin.json";
    req.bypass_proxy = true;
    req.follow_redirects = false;
    req.timeout_seconds = timeout_seconds;
    const http::Response rs = http::request(req);
    if (!rs.transport_ok() || rs.status != 200) {
        e.error = "plugin service unavailable";
        return e;
    }
    if (rs.body.size() > kDescMaxBytes) {
        e.error = "bad plugin.json: too large";
        return e;
    }
    auto strict = sa_core::decode_utf8_sig_strict(rs.body);
    const std::string text = strict ? *strict : sa_core::decode_utf8_sig_replace(rs.body);
    json parsed = json::parse(text, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object()) {
        e.error = "bad plugin.json: not a JSON object";
        return e;
    }
    e.desc = std::move(parsed);
    return e;
}

// The one outbound sender behind proxy() and exec_tool(): 10s budget, verbatim
// body, upstream status/body/Content-Type passed through untouched.
Resp send_to_service(const std::string& base, const std::string& method,
                     const std::string& path_and_query, const std::string& body,
                     const std::string& pid) {
    http::Request req;
    req.method = method;
    req.url = base + path_and_query;
    req.bypass_proxy = true;
    req.follow_redirects = false;
    req.timeout_seconds = kProxyTimeoutSeconds;
    req.headers.emplace_back("Content-Type", "application/json");
    if (!pid.empty()) req.headers.emplace_back("X-Plugin-Id", pid);
    req.body = body;
    const http::Response rs = http::request(req);
    if (!rs.transport_ok()) {
        return Resp::Json(502, json{{"error", "plugin service unavailable"}});
    }
    if (rs.body.size() > kProxyRespMaxBytes) {
        return Resp::Json(502, json{{"error", "plugin service response too large"}});
    }
    return Resp::BytesTyped(rs.status, std::move(rs.body), rs.header("Content-Type"));
}

}  // namespace

void refresh_all(int budget_ms) {
    const auto t0 = std::chrono::steady_clock::now();
    std::map<std::string, Entry> next;
    for (const auto& f : scan_plugins()) {
        const Decl d = from_manifest(f.manifest);
        if (d.reject_reason == "no service declared") continue;  // pure declarative row
        Entry e;
        e.url = d.url;
        if (!d.reject_reason.empty()) {
            e.error = "invalid service url: " + d.reject_reason;
        } else {
            const double left_ms =
                static_cast<double>(budget_ms) -
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0)
                    .count();
            if (left_ms <= 0) {
                // Keep the row visible but honest: reload to finish the sweep.
                e.error = "refresh budget exhausted (POST /api/plugins/reload to retry)";
            } else {
                e = fetch_entry(d, std::min<double>(kFetchTimeoutSeconds, left_ms / 1000.0));
            }
        }
        next[f.pid] = std::move(e);
    }
    std::lock_guard<std::mutex> lk(g_mu);
    g_cache = std::move(next);
}

void refresh_one(const std::string& pid, int timeout_ms) {
    if (!safe_pid(pid)) return;
    auto manifest = read_manifest(cs::join(plugins_root(), pid));
    if (!manifest) {
        std::lock_guard<std::mutex> lk(g_mu);
        g_cache.erase(pid);
        return;
    }
    const Decl d = from_manifest(*manifest);
    if (d.reject_reason == "no service declared") {
        std::lock_guard<std::mutex> lk(g_mu);
        g_cache.erase(pid);
        return;
    }
    Entry e;
    e.url = d.url;
    if (!d.reject_reason.empty()) {
        e.error = "invalid service url: " + d.reject_reason;
    } else {
        e = fetch_entry(d, std::max(0.05, static_cast<double>(timeout_ms) / 1000.0));
    }
    std::lock_guard<std::mutex> lk(g_mu);
    g_cache[pid] = std::move(e);
}

json describe(const std::string& pid) {
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_cache.find(pid);
    if (it == g_cache.end() || it->second.desc.is_null()) return json();
    return it->second.desc;
}

std::string error_of(const std::string& pid) {
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_cache.find(pid);
    return it == g_cache.end() ? std::string() : it->second.error;
}

json service_status(const std::string& pid, const json& manifest) {
    const Decl d = from_manifest(manifest);
    if (d.reject_reason == "no service declared") return json();
    std::string raw_url;
    if (manifest.is_object() && manifest.contains("service") &&
        manifest.at("service").is_object() && manifest.at("service").contains("url") &&
        manifest.at("service").at("url").is_string()) {
        raw_url = manifest.at("service").at("url").get<std::string>();
    }
    json out = json::object();
    out["ok"] = false;
    out["url"] = d.url.empty() ? raw_url : d.url;
    out["name"] = d.name;
    out["checked"] = false;
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_cache.find(pid);
    if (it != g_cache.end() && it->second.url == d.url) {
        out["checked"] = true;
        out["ok"] = it->second.error.empty() && !it->second.desc.is_null();
    }
    return out;
}

json agent_tools() {
    json out = json::array();
    std::lock_guard<std::mutex> lk(g_mu);
    for (const auto& [pid, e] : g_cache) {
        if (e.desc.is_null()) continue;
        if (!e.desc.contains("agent_tools") || !e.desc.at("agent_tools").is_array()) continue;
        for (const auto& t : e.desc.at("agent_tools")) {
            if (!t.is_object()) continue;
            auto name = t.find("name");
            if (name == t.end() || !name->is_string() ||
                py_strip(name->get<std::string>()).empty()) {
                continue;
            }
            json tool = t;
            tool["plugin_id"] = pid;  // setdefault semantics, like the declarative reads
            if (t.contains("plugin_id") && json_truthy(t.at("plugin_id"))) {
                tool["plugin_id"] = t.at("plugin_id");
            }
            out.push_back(std::move(tool));
        }
    }
    return out;
}

std::optional<ToolOwner> owner_of_tool(const std::string& name) {
    std::lock_guard<std::mutex> lk(g_mu);
    for (const auto& [pid, e] : g_cache) {
        if (e.desc.is_null()) continue;  // failed/absent description owns nothing
        if (!e.desc.contains("agent_tools") || !e.desc.at("agent_tools").is_array()) continue;
        for (const auto& t : e.desc.at("agent_tools")) {
            if (!t.is_object()) continue;
            auto n = t.find("name");
            if (n == t.end() || !n->is_string() || n->get<std::string>() != name) continue;
            ToolOwner owner;
            owner.pid = pid;
            owner.url = e.url;
            owner.path = "/agent/exec";
            auto p = t.find("path");
            if (p != t.end() && p->is_string()) {
                const std::string path = p->get<std::string>();
                if (path.size() > 1 && path.front() == '/' &&
                    path.find("..") == std::string::npos) {
                    owner.path = path;
                }
            }
            return owner;
        }
    }
    return std::nullopt;
}

// ---------------------------------------------------------------------------
// proxy (§4)
// ---------------------------------------------------------------------------

Resp proxy(const std::string& pid, const std::string& method, const std::string& subpath,
           const std::string& raw_query, const std::string& body) {
    if (!safe_pid(pid)) return Resp::Json(400, json{{"error", "invalid plugin id"}});
    auto manifest = read_manifest(cs::join(plugins_root(), pid));
    if (!manifest) return Resp::Json(404, json{{"error", "plugin not found"}});
    const Decl d = from_manifest(*manifest);
    if (d.reject_reason == "no service declared") {
        return Resp::Json(400, json{{"error", "plugin does not declare a service"}});
    }
    if (!d.reject_reason.empty()) {
        return Resp::Json(400, json{{"error", "invalid service url: " + d.reject_reason}});
    }
    // subpath arrives percent-DECODED (req.path) and is re-quoted below; the
    // gate runs on the decoded text so "..", separators and control bytes can
    // never reach the upstream URL.
    if (subpath.empty() || subpath.front() == '/' || subpath.find("..") != std::string::npos ||
        subpath.find('?') != std::string::npos || subpath.find('#') != std::string::npos ||
        subpath.find('\\') != std::string::npos || subpath.find(':') != std::string::npos ||
        subpath.size() > kSubpathMaxBytes) {
        return Resp::Json(400, json{{"error", "illegal subpath"}});
    }
    for (unsigned char c : subpath) {
        // 0x20 is fine — the re-quote below percent-encodes everything outside
        // the URL-safe set, so only control bytes need the hard gate here.
        if (c < 0x20 || c == 0x7F) return Resp::Json(400, json{{"error", "illegal subpath"}});
    }
    // raw_query is replayed verbatim after '?'; keep it to printable ASCII so a
    // hostile query cannot smuggle whitespace/CR/LF into the outbound request.
    for (unsigned char c : raw_query) {
        if (c <= 0x20 || c == 0x7F) return Resp::Json(400, json{{"error", "illegal query"}});
    }
    std::string target = "/" + http::quote_component(subpath);
    if (!raw_query.empty()) target += "?" + raw_query;
    return send_to_service(d.url, method, target, body, pid);
}

Resp exec_tool(const std::string& name, const std::string& raw_body) {
    auto owner = owner_of_tool(name);
    if (!owner) {
        // The cache has no verdict (never refreshed, or the tool was added
        // after the last sweep): one bounded inline refresh, then re-lookup.
        refresh_all(2000);
        owner = owner_of_tool(name);
    }
    if (!owner) return Resp::Json(404, json{{"error", "unknown plugin tool: " + name}});
    std::string body = raw_body;
    if (body.empty()) body = sa_core::py_dumps(json{{"name", name}});
    return send_to_service(owner->url, "POST", owner->path, body, owner->pid);
}

void reset_for_test() {
    std::lock_guard<std::mutex> lk(g_mu);
    g_cache.clear();
}

}  // namespace plugin_service
}  // namespace sa
