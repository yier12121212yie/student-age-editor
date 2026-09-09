// wip/P8/p8_model.h — P8 TUI view-model data types.
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

enum class Page { Mods, Tables, Table, Bugfix, Agent };

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

    // tables
    std::vector<std::string> tables;
    int table_sel = 0;
    std::string table_filter;

    // current table (browse + edit)
    Table table;
    int row_sel = 0;
    bool editing = false;      // cell editor active on the selected row
    std::string edit_buffer;   // text being typed in the cell editor
    std::string filter;        // row filter substring within the table

    // bugfix
    std::vector<BugEntry> bugs;
    int bug_sel = 0;
    bool bug_scanned = false;

    // agent chat
    std::vector<ChatMsg> chat;
    std::string chat_input;
    bool chat_busy = false;

    // shared chrome
    std::string status;   // one-line transient status / error
    bool show_help = false;

    // helpers --------------------------------------------------------------
    int ClampSel(int sel, int count) const;
    // Rows currently visible after the filter (indices into table.rows).
    std::vector<int> VisibleRows() const;
    // Chat transcript rows for the current message list (used by render too).
};

// Drive one keypress. Returns the intent the caller must act on. Pure: only
// mutates `s` from `s` + `k`, never performs I/O.
Intent HandleKey(AppState& s, const KeyInput& k);

}  // namespace p8
