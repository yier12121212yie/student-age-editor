// p7_cli_logic.h — the testable half of the native CLI (P7).
//
// Everything here is process-local and server-agnostic: argv -> Command,
// Command -> HTTP request specs (method/path/query/body), response -> text
// rendering, exit-code policy, and the pure helpers behind the client-side
// `mods add --path/--zip` import. main.cpp owns only the embedded-server
// bootstrap, the WinHTTP calls and stdout/stderr writes, so the whole command
// surface is unit-testable inside sa_tests without sockets.
//
// Contract notes (brief: "功能相似即可", but envelopes/JSON fields must match
// the C++ backend): --json prints the backend response bytes verbatim, and
// text mode renders the same fields the desktop frontend consumes.
#pragma once

#include <map>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa_cli {

using json = nlohmann::ordered_json;

// ---------------------------------------------------------------------------
// Command model (CLI11 output as plain data)
// ---------------------------------------------------------------------------

enum class Kind {
    ModsList,
    ModsCreate,     // == add <title> (create is the Python-name alias)
    ModsAddPath,    // copy an existing directory into the workspace + select
    ModsAddZip,     // extract a zip into the workspace + select
    ModsSelect,
    ModsRemove,
    CfgList,
    CfgGet,
    CfgSet,         // whole-table PUT
    CfgPatch,       // PUT with {patch:{set,remove}} (CONVENTIONS 5.4, no PATCH verb)
    CfgHistory,     // GET /api/history (+ --undo/--redo via the history ops)
    Validate,
    BugfixScan,
    BugfixFix,
    StoryExport,
    StoryImport,
    OobeStatus,
    OobeDone,
    OobeSetup,
    PluginList,     // GET  /api/plugins
    PluginInstall,  // POST /api/plugins/install_path (local zip, no base64)
    PluginUninstall,// DELETE /api/plugins/<pid>
    PluginReload,   // POST /api/plugins/reload
    PluginTools,    // GET  /api/plugins/agent/tools
    CloudProviders, // GET  /api/cloud/providers
    CloudAdd,       // POST /api/cloud/providers
    CloudUpdate,    // PUT  /api/cloud/providers/<pid>
    CloudRemove,    // DELETE /api/cloud/providers/<pid>
    CloudTest,      // POST /api/cloud/test
    CloudSync,      // POST /api/cloud/sync
    CloudStatus,    // GET  /api/cloud/status
    CloudDrivers,   // GET  /api/cloud/drivers
    CloudLocal,     // GET  /api/cloud/local_files
    CloudRemote,    // GET  /api/cloud/list
    AiSettings,     // GET  /api/ai/settings
    AiSet,          // PUT  /api/ai/settings
    EnvGet,         // local editor_env.json (no HTTP route exists)
    EnvSet,
    None,
};

struct GlobalFlags {
    std::string url;          // --url: talk to a running instance (no embed)
    std::string data_root;    // --data-root -> EDITOR_DATA_ROOT
    std::string workspace;    // --workspace -> init_state workspace_root
    std::string mod;          // --mod: explicit mod selection (Python parity)
    bool json = false;        // --json raw output
    double timeout = 30.0;    // --timeout seconds
};

// CLI-local selection persistence key inside editor_env.json. The desktop
// backend keeps the mod selection in process memory only; a one-shot CLI
// process must re-establish it every run, so `mods select` mirrors it here
// (unknown keys are ignored by oobe/workspace/env consumers).
inline constexpr const char* kCliSelectedModKey = "cli_selected_mod";

struct Command {
    Kind kind = Kind::None;

    // names / scalar payloads
    std::string cfg;           // cfg table name (get/set/patch/history/validate)
    std::string mod_name;      // mods select/remove / --name import override
    std::string title, desc;   // mods create/add
    std::string path, zip;     // mods add --path/--zip
    std::string root;          // mods select --root
    std::string id, field;     // cfg get record/field projection
    std::string prefix;        // cfg get ?prefix=
    std::string start_id, text, out, dual;  // story
    std::string evt_ids;       // story export, comma separated
    std::string env_key, env_value;         // env get/set

    json data;                 // cfg set body / validate --data / story --text file? no
    bool has_data = false;     // --data|--file supplied (cfg set, validate)
    json set_obj;              // cfg patch --set
    bool has_set = false;
    json remove_arr;           // cfg patch --remove
    bool has_remove = false;
    json if_match;             // cfg patch --if-match
    bool has_if_match = false;
    json opts;                 // story export --opts passthrough
    bool has_opts = false;
    json bugs;                 // bugfix fix --from-file (array or scan payload)
    bool has_bugs = false;

    // plugins ---------------------------------------------------------------
    std::string plugin_id;     // plugin uninstall/tools target
    std::string plugin_name;   // plugin install --name (filename for id fallback)

    // cloud -----------------------------------------------------------------
    std::string provider_id;   // cloud update/remove/test/sync/remote
    std::string provider_name; // cloud add/update --name
    std::string provider_type; // cloud add/update --type (webdav|local|openlist|...)
    std::string remote_root;   // cloud add/update --remote-root (default "mods" server-side)
    json provider_config;      // cloud add/update --config / --config-file
    bool has_provider_config = false;
    std::string direction;     // cloud sync --direction (upload|download|sync|...)
    std::string files_txt;     // cloud sync --files rel[,rel...]
    bool dry_run = false;      // cloud sync --dry-run
    bool delete_extra = false; // cloud sync --delete-extra
    bool folder = false;       // cloud sync --folder/--all (whole-mod sync)

    // ai / oobe extras ------------------------------------------------------
    json ai_settings;          // ai set --data / oobe setup --ai
    bool has_ai_settings = false;
    json cloud_provider;       // oobe setup --cloud-provider (client-side composed)
    bool has_cloud_provider = false;

    long long expect_mtime = 0;
    bool has_expect_mtime = false;
    int suffix = 3;            // cfg get ?suffix=
    long long limit = 20;      // text-view row cap

    bool keys = false, meta = false, force = false;
    bool write = false, append = false;
    bool strict = false;       // validate: exit 1 when errors present
    bool undo = false, redo = false;
    bool mark_done = true;     // oobe setup --no-mark-done
    bool json_value = false;   // env set: value is JSON
};

enum class ParseResult { Ok, Help, UsageError };

// argv (UTF-8, no program name) -> GlobalFlags + Command. On UsageError,
// `err_msg` carries a one-line explanation (exit code 2 per our policy, same
// as server_main's argument handling).
ParseResult parse_command_line(const std::vector<std::string>& args, GlobalFlags& g,
                               Command& c, std::string& err_msg);

// Human usage text (CLI11 help) for --help / usage errors.
std::string usage_text();

// ---------------------------------------------------------------------------
// Request planning (pure: Command -> HTTP specs)
// ---------------------------------------------------------------------------

struct HttpRequestSpec {
    std::string method;                                     // GET/POST/PUT
    std::string path;                                       // origin-form, un-encoded
    std::vector<std::pair<std::string, std::string>> query;
    json body;                                              // null -> send no body
};

// Full request line for sa_core::http. base_url has no trailing slash
// ("http://127.0.0.1:8765"). Path segments and query params are percent
// encoded with Python quote() semantics (segments keep no '/' of their own).
std::string build_url(const std::string& base_url, const HttpRequestSpec& spec);

// All HTTP steps of a command except the ones needing runtime data
// (validate-auto needs a prior GET, add --path/--zip need a prior /api/state).
// env commands plan to zero requests. May read --file/--set-file style inputs
// into the corresponding Command fields (hence the mutable reference). On
// precondition failure (missing data, unreadable file, bad shape) returns
// false + err_msg.
bool make_plan(Command& c, std::vector<HttpRequestSpec>& out, std::string& err_msg);

// validate with data already loaded (--data/--file): one POST. The auto mode
// planner emits [GET cfg] and main feeds the response back here.
HttpRequestSpec validate_post(const std::string& cfg_name, const json& data);

// cfg GET used to source data for `validate <name>`.
HttpRequestSpec cfg_get_request(const std::string& cfg_name);

// mods add --path/--zip finalize: select the freshly imported dir. The root
// form bypasses the name lookup — required because A15's 2s mods cache can
// still answer pre-import listings inside this very process.
HttpRequestSpec mod_select_request(const std::string& name, const std::string& root = "");

// POST /api/state reader for workspace resolution in --url mode.
HttpRequestSpec state_request();

// ---------------------------------------------------------------------------
// Output / exit policy
// ---------------------------------------------------------------------------

// status -> process exit code. 2xx: 0 (validate --strict with errors -> 1);
// any HTTP error response: 1; the caller maps transport failures to 3 and
// usage errors to 2 outside this function.
int compute_exit(int status, const json& body, const Command& c);

// One-line "error: ..." body for stderr from a Python-style envelope
// ({"error":..., "detail":..., "cfg":...}); falls back to the raw body.
std::string error_text(const json& body);

// Text (non --json) rendering of a 2xx response for the command. Plain lines,
// deliberately not the rich tables of the Python CLI (excluded per brief).
std::string format_text(const Command& c, const json& body);

// env get rendering: scalars via Python str(), containers via indent dump.
std::string env_value_text(const json& value);

// ---------------------------------------------------------------------------
// Pure helpers behind the local import steps
// ---------------------------------------------------------------------------

// True when `dir` would be recognized by list_mods (has Cfgs/zh-cn or manifest.json).
bool looks_like_mod_dir(const std::string& dir);

// Destination dir name for `mods add --path/--zip`: explicit override, else
// directory basename (path) / archive stem (zip). Returns "" when unusable.
std::string import_target_name(const std::string& src, bool is_zip,
                               const std::string& override_name);

// Zip entry screen mirroring the bundled-zip guard of CONVENTIONS 11
// (absolute paths, drive letters, ".." segments and NULs never escape the
// target dir; backslashes normalize to '/'). True = skip the entry.
bool zip_entry_reject(const std::string& entry);

// JSON string -> parse (lenient: also accepts a bare object where an array is
// documented, per command). On failure returns false + err_msg.
bool parse_json_arg(const std::string& text, json& out, std::string& err_msg);

// --file contents parsed as JSON (UTF-8, BOM tolerant).
bool read_json_file(const std::string& path, json& out, std::string& err_msg);

// Raw UTF-8 file read, BOM stripped when present.
bool read_text_file(const std::string& path, std::string& out, std::string& err_msg);

// Split comma list, trimmed, empties dropped.
std::vector<std::string> split_csv(const std::string& s);

}  // namespace sa_cli
