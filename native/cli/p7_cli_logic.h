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
    UpdateCheck,    // GET /api/update/check（检查更新）
    AiSettings,     // GET  /api/ai/settings
    AiSet,          // PUT  /api/ai/settings
    Search,         // GET  /api/search/talk?q=<kw> (Python CLI parity)
    SettingsNoCode, // GET/PUT /api/settings/editor (M3 无代码模式开关)
    SettingsAppearance,  // GET/PUT /api/settings/editor appearanceMode (白日/暗色)
    EnvGet,         // local editor_env.json (no HTTP route exists)
    EnvSet,
    Repl,           // interactive mode (handled by p7_repl.cpp, never planned)
    None,
};

struct GlobalFlags {
    std::string url;          // --url: talk to a running instance (no embed)
    std::string data_root;    // --data-root -> EDITOR_DATA_ROOT
    std::string workspace;    // --workspace -> init_state workspace_root
    std::string mod;          // --mod: explicit mod selection (Python parity)
    bool json = false;        // --json raw output
    int color = -1;           // --color / --no-color: 1 / 0; -1 = auto (tty)
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
    std::string setting_value;              // settings no-code: on|off|show

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

    // update ----------------------------------------------------------------
    int update_timeout = 6;    // update check --timeout（默认 6 秒）
    std::string update_url;    // update check --update-url（覆盖 GitHub Releases API）
    std::string update_current; // update check --current（覆盖当前版本）

    // ai / oobe extras ------------------------------------------------------
    json ai_settings;          // ai set --data / oobe setup --ai
    bool has_ai_settings = false;
    json cloud_provider;       // oobe setup --cloud-provider (client-side composed)
    bool has_cloud_provider = false;

    long long expect_mtime = 0;
    bool has_expect_mtime = false;
    std::string suffix;        // cfg get ?suffix= (endswith filter, comma list)
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

// True when every bare (non-dash) argv token names a known command, i.e. an
// empty invocation or "a command group with no subcommand". Used to decide
// whether a UsageError means "open the REPL" or "unknown subcommand, exit 2"
// (bug #11). Global value-option values are skipped.
bool references_known_commands_only(const std::vector<std::string>& args);

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

// GET /api/settings/editor ({"settings":{"noCodeMode":bool}}) and its PUT
// counterpart (flat {"noCodeMode":bool} — the route accepts both shapes).
HttpRequestSpec editor_settings_get_request();
HttpRequestSpec editor_settings_put_request(bool no_code);

// /api/settings/editor response -> noCodeMode. `known` (optional) reports
// whether the envelope carried a boolean; callers show 未知 on false.
bool parse_no_code_mode(const json& body, bool* known = nullptr);

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
// Interactive mode (「类 Claude Code」 REPL) — pure line handling
// ---------------------------------------------------------------------------

// One REPL input line, classified. The interactive loop in p7_repl.cpp acts on
// it; sa_tests drives this function directly.
struct ReplLine {
    enum Kind {
        Empty,    // "" / whitespace: repeat the previous command
        Quit,     // /exit /quit /q
        Repeat,   // ↻ sentinel: caller re-runs last non-empty line
        Shell,    // "!<cmd>" / "!shell <cmd>": pass through to the OS shell
        Slash,    // "/<word> ...": payload keeps the words (no leading slash)
        Command,  // a plain CLI command line
    } kind = Empty;
    std::string payload;
};

ReplLine classify_repl_line(const std::string& line);

// Quote-aware token split for REPL input (double/single quotes group, "!"
// and "@提及" stay ordinary tokens; the REPL interprets them afterwards).
std::vector<std::string> split_repl_tokens(const std::string& line);

// ---------------------------------------------------------------------------
// 无代码模式 + 自动补全（M3）
//
// ReplComplete is the pure half of the REPL's Tab key: every candidate pool
// (commands / subcommands / flags / paths / 最近使用 / effect_suggest / roles)
// is injected through CompletionCtx, so the whole lexical-slot routing is
// unit-testable without a terminal or a socket. p7_repl.cpp only fills the
// pools (HTTP fetches, cached per REPL session) and renders the numbered menu.
// ---------------------------------------------------------------------------

// 模糊匹配打分：前缀 100 > 包含 60 > 子序列 30，0 = 不匹配；空 query 记 1
// （"全命中"的最低分，便于调用方区分空查询与不匹配）。ASCII 大小写不敏感；
// 中文按 UTF-8 字节包含匹配（整段字节连续出现即算包含）。
int FuzzyScore(const std::string& query, const std::string& candidate);

// 一个补全候选：text = 接受后整行输入的新内容；hint = 候选行的中文主显示
// （effect 的 desc / 人物名；空则显示插入值本身）。
struct ReplCompletion {
    std::string text;
    std::string hint;
};

// 补全池条目：value = 插入文本，hint = 中文说明（可为空）。
struct CompletionItem {
    std::string value;
    std::string hint;
};

// 词法槽类型：决定 ReplComplete 用哪个池、REPL 需要按需拉哪个 HTTP 池。
enum class CompletionSlot {
    None,         // 不补全（自由文本 / 数值 id）
    Recent,       // 空行 Tab：高频命令 top-N
    Command,      // 顶层命令
    SlashCommand, // 斜杠命令
    Subcommand,   // 当前顶层命令的子命令
    Flag,         // 当前命令的 flag
    Literal,      // 固定枚举值（on|off|show、--direction 等）
    Table,        // cfg 表名
    Mod,          // 模组名
    Path,         // 文件 / 目录路径
    Effect,       // effect_suggest 效果候选（value=code，hint=desc）
    Role,         // /api/roles 人物候选（value=id，hint=名字）
    Mention,      // @提及：@role: 人物 + @表 + @模组
};

// 当前输入行需要的补全槽（REPL 据此决定拉哪个池；纯函数）。
struct CompletionPlan {
    CompletionSlot slot = CompletionSlot::None;
    std::string effect_mode;   // slot==Effect 时的 suggest mode
    bool json_string = false;  // 值槽位于 JSON 字符串内（插入保留引号）
    bool json_bare = false;    // 值槽紧跟 `"key":`（插入自动补引号）
};
CompletionPlan plan_completion(const std::string& buffer);

// ReplComplete 的全部输入池（REPL 会话级缓存注入；函数本身零 IO）。
struct CompletionCtx {
    std::vector<CompletionItem> commands;        // 顶层命令（非斜杠）
    std::vector<CompletionItem> slash_commands;  // 斜杠命令（含 "/"）
    std::vector<CompletionItem> subcommands;     // 当前命令的子命令
    std::vector<CompletionItem> flags;           // 当前命令的 flag
    std::vector<CompletionItem> recent;          // 高频命令 top-N
    std::vector<CompletionItem> tables;          // cfg 表名
    std::vector<CompletionItem> mods;            // 模组名
    std::vector<CompletionItem> paths;           // 文件 / 目录路径
    std::vector<CompletionItem> effects;         // 效果候选
    std::vector<CompletionItem> roles;           // 人物候选
};

// 按 token 词法槽分流：首词→命令池；`cfg <sub>`→子命令池；`-`前缀→当前命令
// flag 池；值槽（cfg 表名 / 模组名 / 路径 / 枚举值 / effect-like 值 / 人物
// id）→对应池；`@` 提及扩展 `@role:`。返回按分数降序、按 text 去重后的候选
// （唯一候选即直接补全）。
std::vector<ReplCompletion> ReplComplete(const std::string& buffer, const CompletionCtx& ctx);

// wire_app 命令树的纯数据镜像（补全用；无子命令/flag 时返回空表）。
std::vector<CompletionItem> top_level_commands();
std::vector<CompletionItem> command_subcommands(const std::string& command);
std::vector<CompletionItem> command_flags(const std::string& command, const std::string& subcommand);

// 固定枚举值槽的取值表（settings no-code / --direction / --dual / ai --mode）。
std::vector<CompletionItem> literal_values(const std::string& group);

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
