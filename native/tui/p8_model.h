// native/tui/p8_model.h — P8 TUI view-model data types.
//
// Kept header-mostly and dependency-light: these structs are shared by the pure
// state machine (p8_view_model.cpp), the FTXUI DOM builders (p8_render.cpp) and
// the interactive loop (tui/app.cpp). No ftxui or networking lives here so the
// Catch2 suite can construct and drive them headlessly.
#pragma once

#include <map>
#include <string>
#include <vector>

#include <sa_core/json_wire.h>  // nlohmann::ordered_json

namespace p8 {

using Json = nlohmann::ordered_json;

// Main is the Alpha-v0.3 home screen: the three-pane browser (📦 Mods / Cfgs
// two-level tree | 📋 Records | 📝 Detail). The rest are the centered modal
// dialogs the Alpha opened over it (a/c/p/b keys) — `page` doubles as the
// "which modal is up" selector, None == Main.
enum class Page { Main, Bugfix, Agent, Plugins, Cloud };

// One flat row of the left pane's two-level tree: a mod node (table_index<0)
// or, under the expanded+selected mod, one of its Cfg tables.
struct TreeItem {
    int mod_index = -1;
    int table_index = -1;  // index into `tables` (the selected mod's cfg list)
};

// Which pane of the browse page owns the keyboard.
enum class Focus { Tables, Rows, Detail };

// Right pane presentation: pretty JSON vs the schema-less form (field list).
enum class DetailMode { Json, Form };

// A side-effect the caller (interactive loop) must perform after a key was
// handled. The state machine never talks to the network itself — it only emits
// intents — which is what makes it unit-testable.
enum class Intent {
    None,
    RefreshMods,   // GET /api/mods
    SelectMod,     // POST /api/mods/select {name}
    RefreshTables, // GET /api/cfg
    LoadTable,     // GET /api/cfg/<name>?keys=1
    SaveTable,     // PUT /api/cfg/<name> patch
    ScanBugs,      // POST /api/bugfix/scan
    FixBugs,       // POST /api/bugfix/fix
    SendChat,      // agent round-trip
    SearchTalk,    // GET /api/search/talk?q=<search.input> (Ctrl-K overlay)
    ValidateTable, // POST /api/validate {cfg, data} (v on the browse page)
    RefreshPlugins,// GET /api/plugins
    InstallPlugin, // POST /api/plugins/install_path {path}
    UninstallPlugin,// DELETE /api/plugins/<id>
    ReloadPlugins, // POST /api/plugins/reload
    RefreshCloudProviders, // GET /api/cloud/providers
    LoadCloudFiles,// GET /api/cloud/local_files + /api/cloud/list
    CloudSync,     // POST /api/cloud/sync
    CloudTest,     // POST /api/cloud/test
    CreateMod,     // POST /api/mods/create {title} (N on the tree pane)
    LoadAiSettings,// GET /api/ai/settings (seeds permission_mode)
    SetPermissionMode, // PUT /api/ai/settings {permissionMode}
    SetNoCodeMode,     // PUT /api/settings/editor {noCodeMode} (Ctrl-N)
    FetchFieldSuggestions, // GET /api/effect_suggest?mode&q= (or /api/roles)
    FetchSlotEntries,  // dict-pool / role entries for the active slot
    ReportUsage,       // POST /api/usage {kind,key} (accepted candidate)
    Quit,
};

struct ModEntry {
    std::string name;
    std::string root;
};

struct BugEntry {
    std::string cfg;
    std::string id;
    std::string key;
    std::string flag;
    std::string message;  // human-readable detail for the TUI row
};

// One installed plugin (GET /api/plugins). Declarative plugins are always-on:
// there is no enable/disable state, only "loaded" plus an optional load error.
struct PluginEntry {
    std::string id;
    std::string name;
    std::string version;
    std::string author;
    std::string description;
    std::string error;
    bool loaded = false;
};

// One cloud provider (GET /api/cloud/providers; secrets are already masked).
struct CloudProvider {
    std::string id;
    std::string name;
    std::string type;
    std::string remote_root;
};

// One row of either side of the cloud comparison: a mod-relative path (local)
// or a provider-relative path (remote).
struct CloudFile {
    std::string name;
    bool is_dir = false;
    long long size = 0;
};

// The permissionMode=="confirm" approval dialog (desktop parity: every mutating
// action pops a confirm box first). `pending` is the intent to run on approval.
struct ConfirmOverlay {
    bool active = false;
    std::string title;
    std::string detail;
    Intent pending = Intent::None;
};

struct ChatMsg {
    std::string role;     // "user" | "assistant" | "system"
    std::string content;
};

// One hit of GET /api/search/talk (global Ctrl-K search).
struct SearchHit {
    std::string src;        // "本体" | "Mod"
    std::string evt_id;
    std::string evt_title;
    std::string talk_id;
    std::string content;
};

// One schema/cross-table problem reported by POST /api/validate.
struct Issue {
    std::string level;  // error | warn | info
    std::string rid;
    std::string msg;
};

// Ctrl-K global search overlay state (models the Python GlobalSearchScreen).
struct SearchOverlay {
    bool active = false;
    bool busy = false;
    std::string input;
    std::vector<SearchHit> results;
    int sel = 0;
    std::string error;
};

// v-key validation overlay state (models the Python ValidationScreen).
struct ValidateOverlay {
    bool active = false;
    bool busy = false;
    std::string cfg;
    std::vector<Issue> issues;
    long long errors = 0, warns = 0, infos = 0;
    std::string error;  // transport / HTTP failure text (empty on success)
};

// A parameter slot of a suggested code (backend /api/effect_suggest items[].slots).
// kind=="dict": @NAME@ placeholder filled from a pool (dict); kind=="number":
// a lone-letter numeric slot. `count` is the number of occurrences (same value
// fills them all). Mirrors the GUI's SuggestionSlot.
struct SuggestionSlot {
    std::string kind;   // "dict" | "number"
    std::string name;   // ATTR / V ...
    std::string dict;   // pool name (ATTR/ROLE/...); empty = no lookup pool
    std::string label;  // Chinese label (属性/数值...)
    int count = 1;
};

// One field-editing candidate: an effect code (with optional slots) or a role.
// For roles code==id, desc==name, template_==id.
struct FieldSuggestion {
    std::string code;        // insertable text (rendered form)
    std::string desc;        // human description (primary line)
    std::string template_;   // raw_code with placeholders — stable usage key
    std::vector<SuggestionSlot> slots;
};

// No-code-mode in-place candidate list + the slot fill-in sub-list shown while
// editing a form field. Pure state machine: fetches are issued as intents.
struct FieldSuggestState {
    bool active = false;      // candidate list visible (during editing_field)
    std::string mode;         // effect|condition|cost|action|screen|role ("" = none)
    std::string query;        // typed filter over the cached candidates
    std::vector<FieldSuggestion> all;  // cached from the fetch (no per-key GET)
    std::vector<int> shown;            // FilterSuggestions(all, query)
    int sel = 0;
    // ---- slot fill-in (accept a slotted candidate -> fill every slot) ----
    bool slot_mode = false;
    int cand = 0;             // index into `all` for the candidate being filled
    int slot_i = 0;           // slot currently being filled
    std::string slot_q;       // filter over slot_entries
    std::vector<std::pair<std::string, std::string>> slot_entries;  // (id, name)
    std::vector<int> entry_shown;                                  // filtered
    int entry_sel = 0;
    std::map<std::string, std::string> slot_values;  // slot name -> chosen value
    // ---- usage report payload (consumed + cleared by the intent runner) ----
    std::string pending_kind, pending_key;
};

// One browsable row of a cfg table: the row key, a flattened value preview for
// display, and the compact JSON text used to seed the cell editor.
struct TableRow {
    std::string key;
    std::string preview;
    std::string raw;  // JSON text of the original value (edit seed / no-op check)
};

struct Table {
    std::string name;
    bool exists = false;
    long long mtime_ns = 0;  // from the load; sent back as expect_mtime_ns
    std::vector<TableRow> rows;  // sorted by key (stable navigation order)
    // key -> raw edit buffer (JSON text). Only dirty rows appear here; an entry
    // whose text round-trips to the base value is a no-op and dropped at save.
    std::map<std::string, std::string> edits;
    std::vector<std::string> removes;  // keys queued for deletion
    // Keys appended this session (n / y). They are NOT in the base data, so the
    // no-op drop must never skip them even when the edit text equals the seed.
    std::vector<std::string> adds;
};

// A single, normalized keypress. The interactive layer maps ftxui::Event onto
// this so the state machine is testable without a terminal.
struct KeyInput {
    enum Kind { None, Up, Down, Left, Right, Enter, Escape, Tab, ShiftTab, Backspace,
                Char, Home, End, PageUp, PageDown, CtrlChar } kind = None;
    std::string text;  // for Char: the typed UTF-8 sequence (one grapheme)
    char ctrl = 0;     // for CtrlChar: the control letter (e.g. 'r', 'q')
};

struct AppState {
    Page page = Page::Main;

    // mods + the left pane's two-level tree (mod node -> cfg nodes). The tree
    // cursor addresses TreeItems(); `expanded_mod` marks which mod node shows
    // its cfg list (only the selected mod has one — that is what the backend
    // lists). <0 = collapsed.
    std::vector<ModEntry> mods;
    int tree_sel = 0;
    int expanded_mod = -1;
    int mod_sel = 0;  // index of the selected mod within mods
    bool mod_input_active = false;  // N: typing a title for POST /api/mods/create
    std::string mod_input;
    std::string selected_mod;

    // tables (left pane of the browse page)
    std::vector<std::string> tables;
    std::string table_filter;  // `/` filter over the tree's cfg nodes
    bool filtering = false;    // `/` filter capture: every char feeds the filter

    // current table (middle pane: browse + edit)
    Table table;
    int row_sel = 0;
    bool editing = false;      // cell editor active on the selected row
    std::string edit_buffer;   // text being typed in the cell editor
    std::string filter;        // row filter substring within the table

    // browse-page pane focus + detail (right pane)
    Focus focus = Focus::Tables;      // tables first: nothing loaded yet
    DetailMode detail_mode = DetailMode::Json;
    int field_sel = 0;                // form mode: selected field index
    bool editing_field = false;       // form mode: one field value being edited
    std::string field_name;           // field being edited
    std::string field_buffer;         // JSON text being typed for that field

    // bugfix
    std::vector<BugEntry> bugs;
    int bug_sel = 0;
    bool bug_scanned = false;

    // agent chat
    std::vector<ChatMsg> chat;
    std::string chat_input;
    bool chat_busy = false;

    // plugins page
    std::vector<PluginEntry> plugins;
    int plugin_sel = 0;
    bool plugins_loaded = false;
    bool plugin_input_active = false;  // typing a zip path for `i`
    std::string plugin_input;

    // cloud page
    std::vector<CloudProvider> providers;
    int provider_sel = 0;
    bool providers_loaded = false;
    std::vector<CloudFile> cloud_local;
    std::vector<CloudFile> cloud_remote;
    bool cloud_files_loaded = false;
    std::string cloud_error;
    std::string cloud_direction = "upload";  // u/d/b select upload/download/both
    bool cloud_dry_run = false;              // desktop default: DryRun off
    bool cloud_delete_extra = false;         // desktop "清理远端多余" checkbox
    std::string cloud_sync_summary;          // last sync result, one line

    // permission mode + the confirm dialog it drives
    std::string permission_mode = "confirm";  // "confirm" | "full"
    ConfirmOverlay confirm;

    // shared editor setting (backend GET/PUT /api/settings/editor): picking
    // roles/effects without hand-writing code DSL. Ctrl-N toggles.
    bool no_code_mode = false;
    FieldSuggestState sug;  // live while editing_field (see p8_cfg.h helpers)

    // overlays
    SearchOverlay search;      // Ctrl-K global talk search
    ValidateOverlay validate;  // v: validate the open table

    // shared chrome
    std::string status;   // one-line transient status / error
    std::string agent_label;  // "provider · model" for the AI modal title
    bool show_help = false;

    // helpers --------------------------------------------------------------
    int ClampSel(int sel, int count) const;
    // Rows currently visible after the filter (indices into table.rows).
    std::vector<int> VisibleRows() const;
    // Tables currently visible after the table filter (indices into tables).
    std::vector<int> VisibleTables() const;
    // The left pane's flat tree rows: every mod, then (under the expanded
    // selected mod) its filter-visible cfgs.
    std::vector<TreeItem> TreeItems() const;
    // Chat transcript rows for the current message list (used by render too).
};

// Drive one keypress. Returns the intent the caller must act on. Pure: only
// mutates `s` from `s` + `k`, never performs I/O.
Intent HandleKey(AppState& s, const KeyInput& k);

}  // namespace p8
