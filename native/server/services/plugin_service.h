// server/services/plugin_service.h — PLUGIN_SPEC §4 HTTP-service-plugin
// infrastructure: discovery primitives shared with plugins_routes, the
// `service` manifest declaration (loopback URL whitelist), the plugin.json
// self-description cache, and the <url>/<subpath> proxy.
//
// Cache model ("刷新驱动、读缓存零网络"): the cache is written ONLY by
// refresh_all / refresh_one — triggered by run.cpp at startup,
// POST /api/plugins/reload, and install/uninstall. Every GET endpoint reads
// the cache without touching the network, so a dead service can never stall a
// poll and no background thread races the test-suite temp roots. The proxy
// deliberately bypasses the cache: it re-reads the manifest, so a running
// service works even before any refresh happened.
//
// Lifecycle (§4): the backend never starts or kills the plugin's process; it
// only talks HTTP to <service.url> on loopback.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "server/httpd.h"

namespace sa {
namespace plugin_service {

using json = nlohmann::ordered_json;

// --- discovery primitives (moved here so plugins_routes and the service
// fetcher share ONE implementation of the §1 rules) ------------------------

struct Found {
    std::string pid;
    json manifest;
};

// EDITOR_PLUGINS_ROOT or <editor_root>/plugins, best-effort mkdir (§1).
std::string plugins_root();
// manifest.json, utf-8-sig; nullopt when absent / not an object (§1: the whole
// plugin is ignored).
std::optional<json> read_manifest(const std::string& dir);
// _safe_pid: rejects separators, drive colons and any ".." — runs before a pid
// is ever joined onto the root.
bool safe_pid(const std::string& pid);
// §1 scan: sub-directories of plugins_root(), name-sorted, "__pycache__"
// excluded, broken manifests dropped.
std::vector<Found> scan_plugins();

// --- the "service" declaration --------------------------------------------

struct Decl {
    std::string url;           // canonical base, no trailing slash, explicit port
    std::string name;          // manifest service.name ("" when absent)
    std::string reject_reason; // non-empty == declaration unusable (never throws)
};

// §4 URL whitelist: scheme http only, host 127.0.0.1/localhost only, explicit
// port 1..65535, optional path prefix (no "..", no query). The whitelist is
// what keeps the proxy from becoming an SSRF/scan primitive.
Decl from_manifest(const json& manifest);

// --- self-description cache ----------------------------------------------

// Re-scan + fetch <url>/plugin.json for every service plugin, replacing the
// whole cache. budget_ms caps the TOTAL time spent on the wire; a plugin whose
// fetch would blow the budget is cached with an error telling the operator to
// reload, so a row of dead services can never stall boot/reload unboundedly.
void refresh_all(int budget_ms = 4000);
// Refresh a single plugin (install/uninstall path). Erases the cache entry
// when the directory/manifest is gone.
void refresh_one(const std::string& pid, int timeout_ms = 1500);

// Cached plugin.json object; null when the plugin has no cache entry (no
// service declared, never refreshed, or refresh failed).
json describe(const std::string& pid);
// "" for a healthy (or absent/not-yet-refreshed) service.
std::string error_of(const std::string& pid);
// Entry supplement for /api/plugins rows: {ok, url, name, checked} when the
// manifest declares a service, null otherwise. checked=false means the cache
// has no verdict for THIS url yet (never refreshed, or url changed since).
json service_status(const std::string& pid, const json& manifest);

// --- aggregates over the cached self-descriptions -------------------------

// Every service plugin's plugin.json "agent_tools" array elements (objects
// with a non-empty string "name"), plugin_id injected, pid order.
json agent_tools();
struct ToolOwner {
    std::string pid;
    std::string url;   // canonical service base (recorded at refresh time)
    std::string path;  // declared "path" or "/agent/exec"
};
// Which plugin owns tool `name` (first pid wins — names are global for the AI
// panel, matching the retired in-process engine's single namespace).
std::optional<ToolOwner> owner_of_tool(const std::string& name);

// POST {"name","args"} to the owning service's tool endpoint (§5: agent tool
// contributions are executed THROUGH the §4 service proxy). body is forwarded
// verbatim (an empty body is replaced by {"name": <name>}); the upstream
// response passes through untouched. 404 {"error":"unknown plugin tool: ..."}
// when no cached description owns the name (one bounded inline refresh is
// attempted before giving up).
Resp exec_tool(const std::string& name, const std::string& raw_body);

// --- proxy ----------------------------------------------------------------

// Forward `<method> <base>/<subpath>?<raw_query>` to the plugin's service,
// body verbatim, 10s budget, response status/body/Content-Type passed through
// (Resp::BytesTyped). subpath is the percent-DECODED remainder of req.path; it
// is re-quoted before joining. Errors:
//   400 invalid plugin id / invalid service url / illegal subpath or query
//   404 plugin not found
//   502 {"error":"plugin service unavailable"} on any transport failure,
//      and on an upstream body over 32 MiB (memory guard).
Resp proxy(const std::string& pid, const std::string& method, const std::string& subpath,
           const std::string& raw_query, const std::string& body);

// Drop every cache entry (tests).
void reset_for_test();

}  // namespace plugin_service
}  // namespace sa
