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

// Table is the three-pane browser (表列表 / 记录 / 详情) — the old separate
// "Tables" page was absorbed into its left pane (Python TUI parity).
enum class Page { Mods, Table, Bugfix, Agent };

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
    enum Kind { None, Up, Down, Left, Right, Enter, Escape, Tab, Backspace,
                Char, Home, End, PageUp, PageDown, CtrlChar } kind = None;
    std::string text;  // for Char: the typed UTF-8 sequence (one grapheme)
    char ctrl = 0;     // for CtrlChar: the control letter (e.g. 'r', 'q')
};

struct AppState {
    Page page = Page::Mods;

    // mods
    std::vector<ModEntry> mods;
    int mod_sel = 0;
    std::string selected_mod;

    // tables (left pane of the browse page)
    std::vector<std::string> tables;
    int table_sel = 0;
    std::string table_filter;

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

    // overlays
    SearchOverlay search;      // Ctrl-K global talk search
    ValidateOverlay validate;  // v: validate the open table

    // shared chrome
    std::string status;   // one-line transient status / error
    bool show_help = false;

    // helpers --------------------------------------------------------------
    int ClampSel(int sel, int count) const;
    // Rows currently visible after the filter (indices into table.rows).
    std::vector<int> VisibleRows() const;
    // Tables currently visible after the table filter (indices into tables).
    std::vector<int> VisibleTables() const;
    // Chat transcript rows for the current message list (used by render too).
};

// Drive one keypress. Returns the intent the caller must act on. Pure: only
// mutates `s` from `s` + `k`, never performs I/O.
Intent HandleKey(AppState& s, const KeyInput& k);

}  // namespace p8
