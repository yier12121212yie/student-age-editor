// native/tui/p8_api.h — the TUI's outbound client for the native backend HTTP API.
//
// Thin wrapper over sa_core::http (WinHTTP) targeting exactly the endpoints the
// wave-1/wave-2 backend registers (CONVENTIONS 5, system/mods/cfg/bugfix routes).
// Every response-shape is turned into view-model data by static, side-effect-free
// parsers so the parsing half is unit-testable without a live server.
#pragma once

#include <string>
#include <vector>

#include "p8_model.h"

namespace p8 {

// Outcome of a PUT /api/cfg save, interpreted per CONVENTIONS 5.4/2.1.
struct SaveResult {
    enum class Kind { Ok, ConflictRows, ConflictTable, LossySource, Error } kind = Kind::Error;
    long long mtime_ns = 0;         // fresh mtime after a successful write
    std::string message;            // human text for the status line
    Json data;                      // table-level conflict carries disk data
};

// Outcome of POST /api/validate (the `v` overlay on the browse page).
struct ValidateResult {
    bool ok = false;
    std::vector<Issue> issues;
    long long errors = 0, warns = 0, infos = 0;
};

// Outcome of POST /api/cloud/sync, folded into counters for the status line.
// The route answers either the folder shape ({"results":[{rel,ok,action,error}],
// "total","dry_run","direction"}) or the single-file shape; InterpretSync
// accepts both.
struct CloudSyncSummary {
    bool dry_run = false;
    std::string direction;
    long long total = 0;
    long long uploaded = 0, downloaded = 0, skipped = 0, failed = 0;
    std::string message;  // "dry_run"/"message" passthrough or an HTTP error
};

class BackendApi {
public:
    explicit BackendApi(std::string base_url) : base_(std::move(base_url)) {}
    const std::string& base_url() const { return base_; }

    // ---- pure request/response transforms (unit-tested) -----------------
    static std::string JoinUrl(const std::string& base, const std::string& path);
    static std::vector<ModEntry> ParseMods(const Json& body);
    static std::vector<std::string> ParseTables(const Json& body);
    // GET /api/cfg/<name>?keys=1 -> (rows, mtime, exists).
    static void ParseTable(const Json& body, std::vector<TableRow>& rows, long long& mtime_ns,
                           bool& exists);
    static std::vector<BugEntry> ParseBugs(const Json& body);
    // GET /api/search/talk response -> hits.
    static std::vector<SearchHit> ParseSearch(const Json& body);
    // POST /api/validate response -> {issues, counts}.
    static void ParseValidate(const Json& body, ValidateResult& out);
    static SaveResult InterpretSave(int http_status, const Json& body);
    static std::vector<PluginEntry> ParsePlugins(const Json& body);
    static std::vector<CloudProvider> ParseProviders(const Json& body);
    // GET /api/cloud/local_files -> {entries:[{name,type,size,mtime}]}
    static std::vector<CloudFile> ParseLocalFiles(const Json& body);
    // GET /api/cloud/list -> {objects:[{name,path,is_dir,size,mtime,sha1}]}
    static std::vector<CloudFile> ParseRemoteObjects(const Json& body);
    // POST /api/cloud/sync -> counters (folder or single-file shape).
    static CloudSyncSummary InterpretSync(const Json& body);
    // GET /api/ai/settings -> {"settings":{...permissionMode...}}.
    static std::string ParsePermissionMode(const Json& body);

    // ---- transport (never throws; fills *err on failure) ----------------
    bool Ping(std::string* err);
    std::vector<ModEntry> ListMods(std::string* err);
    bool SelectMod(const std::string& name, std::string* err);
    std::vector<std::string> ListTables(std::string* err);
    bool LoadTable(const std::string& name, Table& out, std::string* err);
    SaveResult SaveTable(const std::string& name, const Json& body, std::string* err);
    std::vector<BugEntry> ScanBugs(std::string* err);
    // Fix all currently scanned bugs (POST /api/bugfix/fix, empty body).
    bool FixAllBugs(long long* fixed, std::string* err);
    // GET /api/search/talk?q=<kw> — the Ctrl-K global search.
    std::vector<SearchHit> SearchTalk(const std::string& q, std::string* err);
    // POST /api/validate {cfg, data} — the `v` overlay on the browse page.
    bool ValidateTable(const std::string& cfg, const Json& data, ValidateResult* out,
                       std::string* err);
    // ---- plugins (declarative: list/install/uninstall/reload) -----------
    std::vector<PluginEntry> ListPlugins(std::string* err);
    // POST /api/plugins/install_path {path, filename}. The local path form is
    // deliberate: it is the same call the desktop frontend makes and it dodges
    // the base64 body-size ceiling entirely.
    bool InstallPlugin(const std::string& zip_path, std::string* id_out, std::string* err);
    bool UninstallPlugin(const std::string& id, std::string* err);
    bool ReloadPlugins(std::vector<PluginEntry>* out, std::string* err);
    // ---- cloud ----------------------------------------------------------
    std::vector<CloudProvider> ListCloudProviders(std::string* err);
    std::vector<CloudFile> CloudLocalFiles(const std::string& mod, std::string* err);
    std::vector<CloudFile> CloudRemoteFiles(const std::string& provider_id,
                                            const std::string& mod, std::string* err);
    bool CloudTest(const std::string& provider_id, std::string* err);
    // POST /api/cloud/sync. `full` selects the whole-mod folder mode; otherwise
    // `rel_paths` must be non-empty (single-file / selected-files mode).
    CloudSyncSummary CloudSync(const std::string& provider_id, const std::string& direction,
                               const std::string& mod, bool dry_run, bool delete_extra,
                               bool full, std::string* err);
    // ---- ai settings ----------------------------------------------------
    // GET /api/ai/settings -> permission mode ("confirm" on any failure).
    std::string LoadPermissionMode(std::string* err);
    bool SavePermissionMode(const std::string& mode, std::string* err);
    // POST /api/shutdown — best-effort; used to reap a backend we spawned.
    void Shutdown();

private:
    Json Call(const std::string& method, const std::string& path, const Json* body,
              int* status, std::string* err);

    std::string base_;
};

}  // namespace p8
