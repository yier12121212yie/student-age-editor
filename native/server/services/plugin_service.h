// server/services/plugin_service.h — PLUGIN_SPEC §4 HTTP-service-plugin
// infrastructure: discovery primitives shared with plugins_routes, the
// `service` manifest declaration (loopback URL whitelist), the plugin.json
// self-description cache, and the <url>/<subpath> proxy.
//
// Cache model ("刷新驱动、读缓存零网络"): the cache is written ONLY by
// refresh_all / refresh_one — triggered by run.cpp at startup,
// POST /api/plugins/reload, install/uninstall, and (since P2) by exec_tool's
// cache-miss fallback, which runs the refresh on a detached background thread
// and answers the caller from the cache immediately. Every GET endpoint reads
// the cache without touching the network, so a dead service can never stall a
// poll. The proxy deliberately bypasses the cache: it re-reads the manifest,
// so a running service works even before any refresh happened.
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

// --- 扩展合并：插件启用态 -------------------------------------------------
// 资源包与插件合并为「扩展」后，插件不再是「常开」：启用列表持久化在
// <plugins_root>/plugins.json -> {"enabled":[ids]}。文件缺失 => 全部启用
// （默认启用，兼容既有「常开」语义与既有测试）；文件存在 => 只有列出的
// 插件启用。启用态只影响 UI 贡献聚合与 /api/extensions 列表，目录扫描、
// 服务代理与安装/卸载行为不变。
std::string plugins_state_path();
// 显式启用集；nullopt == 未写状态（默认全启用）。
std::optional<std::vector<std::string>> explicit_enabled_plugins();
bool is_plugin_enabled(const std::string& pid);
// 已发现插件 ∩ 启用集（默认全启用时即全部已发现插件），按 pid 排序。
std::vector<std::string> enabled_plugin_ids();
std::vector<std::string> enabled_plugin_dirs();
json set_enabled_plugins(const std::vector<std::string>& ids);
// 安装 => 默认启用（仅在状态文件已存在时落盘，否则默认启用即覆盖）。
void remember_installed_plugin(const std::string& pid);
void forget_plugin(const std::string& pid);

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
// when no cached description owns the name — since P2 the fallback refresh is
// a DETACHED background thread (fully exception-guarded; the caller gets the
// cached answer immediately, so a retry after it lands hits the tool).
Resp exec_tool(const std::string& name, const std::string& raw_body);

// Test hook: true while no background fallback refresh (exec_tool miss) is in
// flight; lets the suite wait out the detached thread instead of racing the
// next test case.
bool bg_refresh_idle_for_test();

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
