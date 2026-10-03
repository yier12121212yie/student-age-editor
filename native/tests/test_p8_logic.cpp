// tests/test_p8_logic.cpp — pure-logic tests for the P8 TUI + agent.
//
// Everything here is headless: the view-model state machine (HandleKey), the
// cfg edit->patch diff, the backend response parsers, the agent SSE/chat-codec
// and the session history store. No network, no terminal. [p8]
#include <catch_amalgamated.hpp>

#include <filesystem>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "p8_agent.h"
#include "p8_api.h"
#include "p8_cfg.h"
#include "p8_model.h"

namespace fs = std::filesystem;
using namespace p8;

namespace {
KeyInput K(KeyInput::Kind kind, std::string text = "", char ctrl = 0) {
    KeyInput k;
    k.kind = kind;
    k.text = std::move(text);
    k.ctrl = ctrl;
    return k;
}

AppState NavState() {
    AppState s;
    s.mods = {ModEntry{"A", "r/A"}, ModEntry{"B", "r/B"}};
    s.selected_mod = "A";
    return s;
}

// A browse screen seeded with rows and the keyboard on the rows pane.
// (Page::Main is the Alpha-v0.3 three-pane home; the rest are modals.)
AppState RowsState() {
    AppState s;
    s.page = Page::Main;
    s.focus = Focus::Rows;
    s.table.name = "TalkCfg";
    s.table.exists = true;
    return s;
}
}  // namespace

// ---------------------------------------------------------------- view model
TEST_CASE("HandleKey: tree navigation clamps and Enter selects + expands", "[p8]") {
    AppState s = NavState();
    REQUIRE(s.TreeItems().size() == 2);  // two mod nodes, nothing expanded yet
    REQUIRE(HandleKey(s, K(KeyInput::Down)) == Intent::None);
    REQUIRE(s.tree_sel == 1);
    HandleKey(s, K(KeyInput::Down));  // clamp at bottom
    REQUIRE(s.tree_sel == 1);
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::SelectMod);
    REQUIRE(s.selected_mod == "B");
    REQUIRE(s.expanded_mods.count("B") == 1);  // the newly selected mod shows its cfgs
}

TEST_CASE("HandleKey: cfg node Enter loads the table; Left collapses", "[p8]") {
    AppState s = NavState();
    s.tables = {"TalkCfg", "ItemCfg"};
    s.expanded_mods.insert("A");
    s.mod_tables["A"] = {"TalkCfg", "ItemCfg"};  // selected mod "A" renders its cfg children
    auto items = s.TreeItems();
    REQUIRE(items.size() == 4);  // A, TalkCfg, ItemCfg (expanded) + the B node
    s.tree_sel = 1;              // TalkCfg
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::LoadTable);
    REQUIRE(s.table.name == "TalkCfg");
    REQUIRE(s.focus == Focus::Rows);
    // Left from a cfg node walks back to its mod node.
    s.focus = Focus::Tables;
    s.tree_sel = 2;
    HandleKey(s, K(KeyInput::Left));
    REQUIRE(s.tree_sel == 0);  // the mod node index
    // Enter again on the selected+expanded node collapses it.
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);
    REQUIRE(s.expanded_mods.count("A") == 0);
    REQUIRE(s.TreeItems().size() == 2);
}

TEST_CASE("HandleKey: table page edit + remove + save intent", "[p8]") {
    AppState s = RowsState();
    s.permission_mode = "full";  // ungated: this case asserts the raw intents
    s.table.rows = {TableRow{"1", "one", "\"one\""}, TableRow{"2", "two", "\"two\""}};
    // Enter -> editing, buffer seeded with raw JSON text.
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);
    REQUIRE(s.editing);
    REQUIRE(s.edit_buffer == "\"one\"");
    // Type a replacement, commit with Enter.
    for (char c : std::string("\"uno\"")) HandleKey(s, K(KeyInput::Char, std::string(1, c)));
    s.edit_buffer.clear();
    s.edit_buffer = "\"uno\"";
    HandleKey(s, K(KeyInput::Enter));
    REQUIRE_FALSE(s.editing);
    REQUIRE(s.table.edits.count("1") == 1);
    REQUIRE(s.table.edits["1"] == "\"uno\"");
    // Move down and mark row 2 for removal.
    HandleKey(s, K(KeyInput::Down));
    REQUIRE(s.row_sel == 1);
    HandleKey(s, K(KeyInput::Char, "d"));
    REQUIRE(s.table.removes.size() == 1);
    // Ctrl-S triggers a save because there are pending changes.
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 's')) == Intent::SaveTable);
}

TEST_CASE("HandleKey: table with no changes -> Ctrl-S is a no-op intent", "[p8]") {
    AppState s = RowsState();
    s.table.rows = {TableRow{"1", "x", "\"x\""}};
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 's')) == Intent::None);
}

TEST_CASE("HandleKey: agent send chat and empty guard", "[p8]") {
    AppState s;
    s.page = Page::Agent;
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);  // empty input
    HandleKey(s, K(KeyInput::Char, "hi"));
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::SendChat);
    REQUIRE(s.chat.size() == 1);
    REQUIRE(s.chat[0].role == "user");
    REQUIRE(s.chat[0].content == "hi");
    REQUIRE(s.chat_input.empty());
}

TEST_CASE("HandleKey: modal openers, Esc closes, Ctrl-Q quits", "[p8]") {
    AppState s = NavState();
    // a/c/p/b open the Alpha modals over the browse view (no auto-refresh —
    // the modal's own r key triggers it).
    REQUIRE(HandleKey(s, K(KeyInput::Char, "b")) == Intent::None);
    REQUIRE(s.page == Page::Bugfix);
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE(s.page == Page::Main);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "a")) == Intent::None);
    REQUIRE(s.page == Page::Agent);
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);  // one modal at a time
    REQUIRE(HandleKey(s, K(KeyInput::Char, "c")) == Intent::None);
    REQUIRE(s.page == Page::Cloud);
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "p")) == Intent::None);
    REQUIRE(s.page == Page::Plugins);
    // Ctrl-Q quits from anywhere.
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'q')) == Intent::Quit);
}

TEST_CASE("HandleKey: / enters filter mode which captures every key", "[p8]") {
    AppState s = RowsState();
    s.table.rows = {TableRow{"apple", "1", "1"}, TableRow{"banana", "2", "2"}};
    // '/' starts capturing; letters are filter text, not commands.
    REQUIRE(HandleKey(s, K(KeyInput::Char, "/")) == Intent::None);
    REQUIRE(s.filtering);
    HandleKey(s, K(KeyInput::Char, "a"));
    HandleKey(s, K(KeyInput::Char, "p"));
    auto vis = s.VisibleRows();
    REQUIRE(vis.size() == 1);
    REQUIRE(s.table.rows[vis[0]].key == "apple");
    // Enter keeps the filter and releases the keys; Esc clears it.
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);
    REQUIRE_FALSE(s.filtering);
    REQUIRE(s.filter == "ap");
    HandleKey(s, K(KeyInput::Char, "/"));
    HandleKey(s, K(KeyInput::Char, "x"));
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE_FALSE(s.filtering);
    REQUIRE(s.filter.empty());
}

TEST_CASE("HandleKey: q quits clean but confirms over unsaved changes", "[p8]") {
    AppState s = RowsState();
    REQUIRE(HandleKey(s, K(KeyInput::Char, "q")) == Intent::Quit);
    s.table.edits["1"] = "\"b\"";
    REQUIRE(HandleKey(s, K(KeyInput::Char, "q")) == Intent::None);
    REQUIRE(s.confirm.active);  // Alpha behaviour: guard the dirty quit
    REQUIRE(s.confirm.pending == Intent::Quit);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "y")) == Intent::Quit);
}

TEST_CASE("HandleKey: Tab/Shift+Tab cycles browse panes; tree Enter loads", "[p8]") {
    AppState s;
    s.page = Page::Main;
    REQUIRE(s.focus == Focus::Tables);  // browse starts on the tree pane
    s.mods = {ModEntry{"A", "r/A"}};
    s.selected_mod = "A";
    s.expanded_mods.insert("A");
    s.mod_tables["A"] = {"TalkCfg", "ItemCfg"};
    s.tree_sel = 1;  // TalkCfg under A
    // Tab: Tables -> Rows -> Detail -> Tables; Shift+Tab walks back.
    REQUIRE(HandleKey(s, K(KeyInput::Tab)) == Intent::None);
    REQUIRE(s.focus == Focus::Rows);
    REQUIRE(HandleKey(s, K(KeyInput::Tab)) == Intent::None);
    REQUIRE(s.focus == Focus::Detail);
    REQUIRE(HandleKey(s, K(KeyInput::Tab)) == Intent::None);
    REQUIRE(s.focus == Focus::Tables);
    REQUIRE(HandleKey(s, K(KeyInput::ShiftTab)) == Intent::None);
    REQUIRE(s.focus == Focus::Detail);
    REQUIRE(HandleKey(s, K(KeyInput::ShiftTab)) == Intent::None);
    REQUIRE(s.focus == Focus::Rows);
    REQUIRE(HandleKey(s, K(KeyInput::ShiftTab)) == Intent::None);
    REQUIRE(s.focus == Focus::Tables);
    // Enter on the cfg node loads it and lands on the rows pane.
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::LoadTable);
    REQUIRE(s.table.name == "TalkCfg");
    REQUIRE(s.focus == Focus::Rows);
    // Esc walks rows -> tables and stops there (Main is the top level).
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE(s.focus == Focus::Tables);
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE(s.focus == Focus::Tables);
    REQUIRE(s.page == Page::Main);
}

TEST_CASE("HandleKey: n/y append rows, d toggles removal", "[p8]") {
    AppState s = RowsState();
    s.table.rows = {TableRow{"1", "a", "\"a\""}, TableRow{"2", "b", "\"b\""}};
    // n: append {} with the next numeric key and open the editor.
    REQUIRE(HandleKey(s, K(KeyInput::Char, "n")) == Intent::None);
    REQUIRE(s.table.rows.size() == 3);
    REQUIRE(s.table.rows.back().key == "3");
    REQUIRE(s.table.edits.at("3") == "{}");
    REQUIRE(s.table.adds == std::vector<std::string>{"3"});  // survives the no-op drop
    REQUIRE(s.editing);
    HandleKey(s, K(KeyInput::Escape));  // cancel editor; the row stays dirty
    // y: duplicate row 3 -> key 4 with the same raw.
    HandleKey(s, K(KeyInput::Char, "y"));
    REQUIRE(s.table.rows.size() == 4);
    REQUIRE(s.table.rows.back().key == "4");
    REQUIRE(s.table.edits.at("4") == "{}");
    REQUIRE(s.table.adds.size() == 2);
    // d on an added row drops it outright (it never hit disk, no remove queued).
    HandleKey(s, K(KeyInput::Char, "d"));
    REQUIRE(s.table.removes.empty());
    REQUIRE(s.table.rows.size() == 3);
    REQUIRE_FALSE(s.table.edits.count("4"));
    REQUIRE(s.table.adds == std::vector<std::string>{"3"});
    // d on a base row marks removal, d again un-removes.
    s.row_sel = 1;  // row "2"
    HandleKey(s, K(KeyInput::Char, "d"));
    REQUIRE(s.table.removes.size() == 1);
    REQUIRE(s.table.removes[0] == "2");
    HandleKey(s, K(KeyInput::Char, "d"));
    REQUIRE(s.table.removes.empty());
}

TEST_CASE("HandleKey: n under an active filter clears it and targets the new row", "[p8]") {
    AppState s = RowsState();
    s.table.rows = {TableRow{"1", "apple", "\"apple\""}, TableRow{"2", "banana", "\"banana\""}};
    HandleKey(s, K(KeyInput::Char, "/"));    // filter capture
    HandleKey(s, K(KeyInput::Char, "a"));    // -> only row 1 visible
    HandleKey(s, K(KeyInput::Char, "p"));
    HandleKey(s, K(KeyInput::Char, "p"));
    HandleKey(s, K(KeyInput::Enter));        // keep filter, release the keys
    REQUIRE(s.VisibleRows().size() == 1);
    HandleKey(s, K(KeyInput::Char, "n"));    // append row "3"
    REQUIRE(s.filter.empty());               // filter cleared: selection is unambiguous
    REQUIRE(s.editing);
    s.edit_buffer = "{\"hi\":1}";
    HandleKey(s, K(KeyInput::Enter));        // commit must land on the NEW row
    REQUIRE(s.table.edits.size() == 1);      // only the new row is dirty
    REQUIRE(s.table.edits.at("3") == "{\"hi\":1}");
    REQUIRE_FALSE(s.table.edits.count("1"));  // the filtered base row untouched
}

TEST_CASE("HandleKey: opening a modal drops edit state; Ctrl-S saves from any pane", "[p8]") {
    AppState s = RowsState();
    s.permission_mode = "full";  // ungated: this case asserts the raw intents
    s.table.rows = {TableRow{"1", "a", "\"a\""}};
    s.table.edits["1"] = "\"b\"";
    HandleKey(s, K(KeyInput::Enter));  // open the row editor
    REQUIRE(s.editing);
    // While the editor is up it swallows letters, so the escape hatch is
    // Ctrl-K (or Ctrl-Q): a global key that clears the transient state.
    HandleKey(s, K(KeyInput::CtrlChar, "", 'k'));
    REQUIRE_FALSE(s.editing);
    REQUIRE(s.search.active);
    HandleKey(s, K(KeyInput::Escape));
    HandleKey(s, K(KeyInput::Char, "b"));  // now the Bug 扫描 modal opens
    REQUIRE(s.page == Page::Bugfix);
    s.page = Page::Main;
    // Back on the browse screen, Ctrl-S works from Tables/Detail focus too.
    s.focus = Focus::Tables;
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 's')) == Intent::SaveTable);
    s.focus = Focus::Detail;
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 's')) == Intent::SaveTable);
    s.table.edits.clear();
    s.table.adds.clear();
    s.table.removes.clear();
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 's')) == Intent::None);
    REQUIRE(s.status == "无改动");
}

TEST_CASE("HandleKey: Ctrl-K opens the search overlay and drives it", "[p8]") {
    AppState s = RowsState();
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'k')) == Intent::None);
    REQUIRE(s.search.active);
    HandleKey(s, K(KeyInput::Char, "你"));
    HandleKey(s, K(KeyInput::Char, "好"));
    REQUIRE(s.search.input == "你好");
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::SearchTalk);
    // Esc closes; keys then fall through to the page again.
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE_FALSE(s.search.active);
}

TEST_CASE("HandleKey: v opens the validate overlay, any key closes", "[p8]") {
    AppState s = RowsState();
    s.table.rows = {TableRow{"1", "a", "\"a\""}};
    REQUIRE(HandleKey(s, K(KeyInput::Char, "v")) == Intent::ValidateTable);
    REQUIRE(s.validate.active);
    REQUIRE(s.validate.cfg == "TalkCfg");
    REQUIRE(HandleKey(s, K(KeyInput::Char, "x")) == Intent::None);
    REQUIRE_FALSE(s.validate.active);
}

TEST_CASE("HandleKey: form-mode field edit writes back into the row edit", "[p8]") {
    AppState s = RowsState();
    s.table.rows = {TableRow{"1", "x", R"({"id":1,"content":"你好"})"}};
    // Detail focus via Tab: form view is the default, the cursor snaps onto
    // the first field row and Enter opens the field editor.
    HandleKey(s, K(KeyInput::Tab));   // Rows -> Detail
    REQUIRE(s.detail_mode == DetailMode::Form);
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);
    REQUIRE(s.editing_field);
    REQUIRE(s.field_name == "content");
    s.field_buffer = "\"再见\"";
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);
    REQUIRE_FALSE(s.editing_field);
    REQUIRE(s.table.edits.at("1") == R"({"id":1,"content":"再见"})");
}

// ---------------------------------------------------------------- cfg diff
TEST_CASE("BuildPatchSet drops no-ops, keeps changes, coerces invalid JSON to string", "[p8]") {
    std::map<std::string, std::string> orig = {{"a", "1"}, {"b", "\"x\""}};
    std::map<std::string, std::string> edits = {
        {"a", "1"},        // unchanged -> dropped
        {"b", "\"y\""},    // changed -> kept
        {"c", "plain"},    // invalid JSON -> stored as string "plain"
    };
    Json set = BuildPatchSet(orig, edits);
    REQUIRE_FALSE(set.contains("a"));
    REQUIRE(set.at("b") == Json("y"));
    REQUIRE(set.at("c") == Json("plain"));
}

TEST_CASE("BuildSaveBody shapes the patch branch contract", "[p8]") {
    std::map<std::string, std::string> orig = {{"a", "1"}};
    std::map<std::string, std::string> edits = {{"a", "2"}};
    Json body = BuildSaveBody(orig, edits, {"z"}, 12345);
    REQUIRE(body.contains("patch"));
    REQUIRE(body.at("patch").at("set").at("a") == Json(2));
    REQUIRE(body.at("patch").at("remove").size() == 1);
    REQUIRE(body.at("patch").at("remove")[0] == Json("z"));
    REQUIRE(body.at("expect_mtime_ns") == Json(12345));
}

TEST_CASE("BuildSaveBody keeps added rows even when their text round-trips", "[p8]") {
    // n/y seed edits[key] with the row's raw text; OrigMapFromRows then contains
    // the same text for that key. Without the adds list the patch would drop the
    // new row as a no-op and the save would silently lose it.
    std::map<std::string, std::string> orig = {{"1", "\"a\""}, {"2", "{}"}};
    std::map<std::string, std::string> edits = {{"2", "{}"}};
    Json set_without = BuildPatchSet(orig, edits);
    REQUIRE_FALSE(set_without.contains("2"));  // baseline: treated as a no-op
    Json set_with = BuildPatchSet(orig, edits, {"2"});
    REQUIRE(set_with.at("2").is_object());     // added rows always survive
    Json body = BuildSaveBody(orig, edits, {}, 0, {"2"});
    REQUIRE(body.at("patch").at("set").contains("2"));
}

TEST_CASE("RowsFromData sorts by key and keeps raw JSON", "[p8]") {
    Json data = Json::object();
    data["b"] = Json(2);
    data["a"] = Json("hello");
    auto rows = RowsFromData(data);
    REQUIRE(rows.size() == 2);
    REQUIRE(rows[0].key == "a");
    REQUIRE(rows[0].raw == "\"hello\"");
    REQUIRE(rows[1].key == "b");
}

// ------------------------------------------------------------- browse helpers
TEST_CASE("NextRowKey grows numeric tables, falls back to _new scheme", "[p8]") {
    REQUIRE(NextRowKey({}) == "1");
    REQUIRE(NextRowKey({TableRow{"1", "", ""}, TableRow{"3", "", ""}}) == "4");
    REQUIRE(NextRowKey({TableRow{"a", "", ""}}) == "_new");
    REQUIRE(NextRowKey({TableRow{"a", "", ""}, TableRow{"_new", "", ""}}) == "_new2");
}

TEST_CASE("FormFields / ApplyFieldEdit round-trip one field", "[p8]") {
    auto fields = FormFields(R"({"id":1,"content":"你好","flag":true})");
    REQUIRE(fields.size() == 3);
    REQUIRE(fields[0].first == "id");
    REQUIRE(fields[0].second == "1");
    REQUIRE(fields[1].second == "你好");
    std::string out;
    REQUIRE(ApplyFieldEdit(R"({"id":1,"content":"你好"})", "content", "再见", &out));
    Json back = Json::parse(out, nullptr, false);
    REQUIRE(back.at("content") == Json("再见"));
    REQUIRE(back.at("id") == Json(1));
    // Invalid JSON value text coerces to a plain string (cell-editor parity).
    REQUIRE(ApplyFieldEdit(R"({"a":1})", "b", "[unclosed", &out));
    REQUIRE(Json::parse(out, nullptr, false).at("b") == Json("[unclosed"));
    // Non-object records reject editing.
    std::string untouched;
    REQUIRE_FALSE(ApplyFieldEdit("\"scalar\"", "a", "1", &untouched));
}

TEST_CASE("TableDataForValidate applies edits and drops removed rows", "[p8]") {
    std::vector<TableRow> rows = {TableRow{"1", "", "\"one\""}, TableRow{"2", "", "\"two\""},
                                  TableRow{"3", "", "\"three\""}};
    Json data = TableDataForValidate(rows, {{"1", "\"uno\""}}, {"2"});
    REQUIRE(data.size() == 2);
    REQUIRE(data.at("1") == Json("uno"));
    REQUIRE(data.at("3") == Json("three"));
}

// ---------------------------------------------------------------- api parsers
TEST_CASE("ParseMods / ParseTables read the backend shapes", "[p8]") {
    Json mods = Json::parse(R"({"mods":[{"name":"A","root":"/a"},{"name":"B","root":"/b"}],"selected":"A"})");
    auto m = BackendApi::ParseMods(mods);
    REQUIRE(m.size() == 2);
    REQUIRE(m[0].name == "A");
    Json cfg = Json::parse(R"({"mod":"A","cfg_files":["TalkCfg","ItemCfg"]})");
    auto t = BackendApi::ParseTables(cfg);
    REQUIRE(t.size() == 2);
    REQUIRE(t[0] == "TalkCfg");
}

TEST_CASE("ParseTable fills rows/mtime/exists", "[p8]") {
    Json body = Json::parse(R"({"cfg":"TalkCfg","exists":true,"mtime_ns":99,"data":{"2":{"a":1},"1":"x"}})");
    std::vector<TableRow> rows;
    long long mtime = 0;
    bool exists = false;
    BackendApi::ParseTable(body, rows, mtime, exists);
    REQUIRE(exists);
    REQUIRE(mtime == 99);
    REQUIRE(rows.size() == 2);
    REQUIRE(rows[0].key == "1");
}

TEST_CASE("InterpretSave maps status codes to kinds", "[p8]") {
    auto ok = BackendApi::InterpretSave(200, Json::parse(R"({"ok":true,"mtime_ns":7})"));
    REQUIRE(ok.kind == SaveResult::Kind::Ok);
    REQUIRE(ok.mtime_ns == 7);
    auto rows = BackendApi::InterpretSave(409, Json::parse(R"({"error":"conflict","reason":"rows"})"));
    REQUIRE(rows.kind == SaveResult::Kind::ConflictRows);
    auto tbl = BackendApi::InterpretSave(409, Json::parse(R"({"error":"conflict","data":{}})"));
    REQUIRE(tbl.kind == SaveResult::Kind::ConflictTable);
    auto lossy = BackendApi::InterpretSave(409, Json::parse(R"({"error":"non-utf8-source"})"));
    REQUIRE(lossy.kind == SaveResult::Kind::LossySource);
    auto err = BackendApi::InterpretSave(500, Json::parse(R"({"error":"boom"})"));
    REQUIRE(err.kind == SaveResult::Kind::Error);
}

TEST_CASE("ParseBugs reads cfg/id/key/flag/desc", "[p8]") {
    Json body = Json::parse(R"({"bugs":[{"cfg":"TalkCfg","id":"5","key":"roleIds","flag":"REF","desc":"bad"}]})");
    auto bugs = BackendApi::ParseBugs(body);
    REQUIRE(bugs.size() == 1);
    REQUIRE(bugs[0].flag == "REF");
    REQUIRE(bugs[0].message == "bad");
}

TEST_CASE("ParseSearch reads the /api/search/talk hit shape", "[p8]") {
    Json body = Json::parse(
        R"({"results":[{"src":"Mod","evt_id":"101","evt_title":"开学","talk_id":"101001","content":"你好"}]})");
    auto hits = BackendApi::ParseSearch(body);
    REQUIRE(hits.size() == 1);
    REQUIRE(hits[0].src == "Mod");
    REQUIRE(hits[0].talk_id == "101001");
    REQUIRE(hits[0].content == "你好");
}

TEST_CASE("ParseValidate reads issues and counts", "[p8]") {
    Json body = Json::parse(
        R"({"issues":[{"level":"error","rid":"9","msg":"missing"},{"level":"warn","rid":"","msg":"odd"}],)"
        R"("counts":{"error":1,"warn":1,"info":0}})");
    ValidateResult r;
    BackendApi::ParseValidate(body, r);
    REQUIRE(r.issues.size() == 2);
    REQUIRE(r.issues[0].level == "error");
    REQUIRE(r.issues[0].rid == "9");
    REQUIRE(r.errors == 1);
    REQUIRE(r.warns == 1);
    REQUIRE(r.infos == 0);
}

TEST_CASE("JoinUrl trims trailing slash", "[p8]") {
    REQUIRE(BackendApi::JoinUrl("http://127.0.0.1:8770/", "/api/ping") == "http://127.0.0.1:8770/api/ping");
    REQUIRE(BackendApi::JoinUrl("http://h:1", "/api/x") == "http://h:1/api/x");
}

// ---------------------------------------------------------------- agent codec
TEST_CASE("SplitSSE yields data payloads, skips [DONE] and non-data", "[p8]") {
    std::string body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n"
        "\n"
        "data: [DONE]\n"
        "event: ping\n"
        "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n";
    auto lines = AgentClient::SplitSSE(body);
    REQUIRE(lines.size() == 2);
    REQUIRE(AgentClient::AccumulateStream(lines) == "Hello");
}

TEST_CASE("ParseWhole reads non-streaming message content", "[p8]") {
    Json resp = Json::parse(R"({"choices":[{"message":{"role":"assistant","content":"hi"}}]})");
    REQUIRE(AgentClient::ParseWhole(resp) == "hi");
}

TEST_CASE("BuildChatBody places system first and streams", "[p8]") {
    std::vector<ChatMsg> hist = {ChatMsg{"user", "q"}};
    Json body = AgentClient::BuildChatBody("m", 0.3, "SYS", hist);
    REQUIRE(body.at("model") == Json("m"));
    REQUIRE(body.at("stream") == Json(true));
    REQUIRE(body.at("messages").size() == 2);
    REQUIRE(body.at("messages")[0].at("role") == Json("system"));
    REQUIRE(body.at("messages")[0].at("content") == Json("SYS"));
    REQUIRE(body.at("messages")[1].at("content") == Json("q"));
}

TEST_CASE("AgentSettingsFromJson reads keys", "[p8]") {
    Json j = Json::parse(R"({"provider":"openai_compatible","baseUrl":"http://x/v1","model":"gpt","temperature":0.2,"apiKey":"k"})");
    auto s = AgentSettingsFromJson(j);
    REQUIRE(s.base == "http://x/v1");
    REQUIRE(s.api_key == "k");
    REQUIRE(s.temperature == Catch::Approx(0.2));
}

TEST_CASE("SaveSession/LoadSession round-trips through disk", "[p8]") {
    std::string root = (fs::temp_directory_path() / "p8_hist_test").string();
    fs::remove_all(root);
    std::vector<ChatMsg> msgs = {ChatMsg{"user", "问"}, ChatMsg{"assistant", "答"}};
    REQUIRE(SaveSession(root, "s1", msgs));
    auto loaded = LoadSession(root, "s1");
    REQUIRE(loaded.size() == 2);
    REQUIRE(loaded[0].content == "问");
    REQUIRE(loaded[1].role == "assistant");
    // Unsafe id rejected.
    REQUIRE_FALSE(SaveSession(root, "../evil", msgs));
    fs::remove_all(root);
}

// ------------------------------------------- permission mode / confirm gate
TEST_CASE("HandleKey: Ctrl-M toggles permission mode and asks for a persist", "[p8]") {
    AppState s = NavState();
    REQUIRE(s.permission_mode == "confirm");  // the backend default
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'm')) == Intent::SetPermissionMode);
    REQUIRE(s.permission_mode == "full");
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'm')) == Intent::SetPermissionMode);
    REQUIRE(s.permission_mode == "confirm");
}

TEST_CASE("Confirm gate: confirm mode defers save, y approves and releases it", "[p8]") {
    AppState s;
    s.page = Page::Main;
    s.focus = Focus::Rows;
    s.table.name = "TalkCfg";
    s.table.rows = {TableRow{"1", "a", "\"a\""}};
    s.table.edits["1"] = "\"b\"";
    REQUIRE(s.permission_mode == "confirm");

    // Ctrl-S arms the dialog instead of returning the save intent.
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 's')) == Intent::None);
    REQUIRE(s.confirm.active);
    REQUIRE(s.confirm.title == "保存表格");
    REQUIRE(s.confirm.detail.find("TalkCfg") != std::string::npos);
    REQUIRE(s.confirm.detail.find("修改 1") != std::string::npos);
    REQUIRE(s.confirm.pending == Intent::SaveTable);

    // Any other key is swallowed by the modal.
    REQUIRE(HandleKey(s, K(KeyInput::Char, "z")) == Intent::None);
    REQUIRE(s.confirm.active);

    // y approves: the deferred intent is released exactly once.
    REQUIRE(HandleKey(s, K(KeyInput::Char, "y")) == Intent::SaveTable);
    REQUIRE_FALSE(s.confirm.active);
    REQUIRE(s.confirm.pending == Intent::None);
}

TEST_CASE("Confirm gate: n and Esc reject and clear the deferred intent", "[p8]") {
    AppState s;
    s.page = Page::Main;
    s.focus = Focus::Rows;
    s.table.name = "TalkCfg";
    s.table.rows = {TableRow{"1", "a", "\"a\""}};
    s.table.removes.push_back("1");

    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 's')) == Intent::None);
    REQUIRE(s.confirm.active);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "n")) == Intent::None);
    REQUIRE_FALSE(s.confirm.active);
    REQUIRE(s.confirm.pending == Intent::None);
    REQUIRE(s.status.find("已拒绝") != std::string::npos);

    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 's')) == Intent::None);
    REQUIRE(s.confirm.active);
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE_FALSE(s.confirm.active);
}

TEST_CASE("Confirm gate: full mode runs the write straight through", "[p8]") {
    AppState s;
    s.page = Page::Main;
    s.focus = Focus::Rows;
    s.table.name = "TalkCfg";
    s.permission_mode = "full";
    s.table.rows = {TableRow{"1", "a", "\"a\""}};
    s.table.edits["1"] = "\"b\"";
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 's')) == Intent::SaveTable);
    REQUIRE_FALSE(s.confirm.active);
}

TEST_CASE("Confirm gate: bugfix fix-all is gated too", "[p8]") {
    AppState s;
    s.page = Page::Bugfix;
    s.selected_mod = "M";
    s.bugs = {BugEntry{"T", "1", "k", "REF", "d"}};
    REQUIRE(HandleKey(s, K(KeyInput::Char, "f")) == Intent::None);
    REQUIRE(s.confirm.active);
    REQUIRE(s.confirm.pending == Intent::FixBugs);
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::FixBugs);

    s.permission_mode = "full";
    REQUIRE(HandleKey(s, K(KeyInput::Char, "f")) == Intent::FixBugs);
    // Rescanning (a read) is never gated.
    REQUIRE(HandleKey(s, K(KeyInput::Char, "r")) == Intent::ScanBugs);
}

TEST_CASE("HandleKey: p opens the plugins modal and drives its actions", "[p8]") {
    AppState s = NavState();
    REQUIRE(HandleKey(s, K(KeyInput::Char, "p")) == Intent::None);
    REQUIRE(s.page == Page::Plugins);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "r")) == Intent::RefreshPlugins);
    s.plugins = {PluginEntry{"demo", "Demo", "1", "", "", "", true},
                 PluginEntry{"other", "Other", "1", "", "", "", true}};
    s.plugins_loaded = true;
    REQUIRE(HandleKey(s, K(KeyInput::Down)) == Intent::None);
    REQUIRE(s.plugin_sel == 1);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "r")) == Intent::RefreshPlugins);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "R")) == Intent::ReloadPlugins);

    // `u` uninstall is a write -> gated; the dialog names the selected id.
    REQUIRE(HandleKey(s, K(KeyInput::Char, "u")) == Intent::None);
    REQUIRE(s.confirm.active);
    REQUIRE(s.confirm.detail == "other");
    REQUIRE(HandleKey(s, K(KeyInput::Char, "y")) == Intent::UninstallPlugin);

    // `i` opens a path prompt; Enter installs (also gated) with the trimmed path.
    REQUIRE(HandleKey(s, K(KeyInput::Char, "i")) == Intent::None);
    REQUIRE(s.plugin_input_active);
    for (char c : std::string("  C:/tmp/p.zip  ")) HandleKey(s, K(KeyInput::Char, std::string(1, c)));
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);
    REQUIRE_FALSE(s.plugin_input_active);
    REQUIRE(s.confirm.active);
    REQUIRE(s.confirm.detail == "C:/tmp/p.zip");
    REQUIRE(HandleKey(s, K(KeyInput::Char, "y")) == Intent::InstallPlugin);

    // Esc closes the modal back onto the browse view.
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE(s.page == Page::Main);
}

TEST_CASE("HandleKey: Ctrl-K over the plugins modal abandons the half-typed path", "[p8]") {
    AppState s = NavState();
    s.page = Page::Plugins;
    HandleKey(s, K(KeyInput::Char, "i"));
    HandleKey(s, K(KeyInput::Char, "x"));
    REQUIRE(s.plugin_input_active);
    // Ctrl-K opens the search overlay on top; the transient input state does
    // not survive it (ClearTransient), and Esc returns to the plugins modal.
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'k')) == Intent::None);
    REQUIRE(s.search.active);
    REQUIRE_FALSE(s.plugin_input_active);
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE_FALSE(s.search.active);
    REQUIRE(s.page == Page::Plugins);
}

TEST_CASE("HandleKey: c opens the cloud modal; direction/DryRun and gated sync", "[p8]") {
    AppState s = NavState();
    REQUIRE(HandleKey(s, K(KeyInput::Char, "c")) == Intent::None);
    REQUIRE(s.page == Page::Cloud);
    s.providers = {CloudProvider{"p_1", "Drive", "webdav", "mods"}};

    // Direction radio: u/d/b; default is upload.
    REQUIRE(s.cloud_direction == "upload");
    HandleKey(s, K(KeyInput::Char, "d"));
    REQUIRE(s.cloud_direction == "download");
    HandleKey(s, K(KeyInput::Char, "b"));
    REQUIRE(s.cloud_direction == "sync");
    HandleKey(s, K(KeyInput::Char, "u"));
    REQUIRE(s.cloud_direction == "upload");

    // DryRun toggles and is off by default (desktop parity).
    REQUIRE_FALSE(s.cloud_dry_run);
    HandleKey(s, K(KeyInput::Char, "y"));
    REQUIRE(s.cloud_dry_run);
    // delete-extra toggle.
    REQUIRE_FALSE(s.cloud_delete_extra);
    HandleKey(s, K(KeyInput::Char, "x"));
    REQUIRE(s.cloud_delete_extra);

    // A dry run mutates nothing -> runs without approval.
    REQUIRE(HandleKey(s, K(KeyInput::Char, "s")) == Intent::CloudSync);
    REQUIRE_FALSE(s.confirm.active);

    // A real run is a write -> approval first.
    HandleKey(s, K(KeyInput::Char, "y"));
    REQUIRE_FALSE(s.cloud_dry_run);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "s")) == Intent::None);
    REQUIRE(s.confirm.active);
    REQUIRE(s.confirm.pending == Intent::CloudSync);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "y")) == Intent::CloudSync);

    // Read-only actions are never gated.
    REQUIRE(HandleKey(s, K(KeyInput::Char, "t")) == Intent::CloudTest);
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::LoadCloudFiles);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "r")) == Intent::RefreshCloudProviders);
}

TEST_CASE("HandleKey: cloud with no provider refuses to act", "[p8]") {
    AppState s;
    s.page = Page::Cloud;
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);
    REQUIRE(s.status == "没有云盘 Provider（先 cloud add）");
    REQUIRE(HandleKey(s, K(KeyInput::Char, "s")) == Intent::None);
    REQUIRE(s.status == "没有可选 Provider");
    REQUIRE_FALSE(s.confirm.active);
}

TEST_CASE("HandleKey: u opens the update modal; r/Enter check, Esc/q close", "[p8]") {
    AppState s = NavState();
    // 打开弹窗本身不发请求（和 a/c/p/b 一样），r / Enter 才产生检查 intent。
    REQUIRE(HandleKey(s, K(KeyInput::Char, "u")) == Intent::None);
    REQUIRE(s.page == Page::Update);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "r")) == Intent::CheckUpdate);
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::CheckUpdate);
    REQUIRE_FALSE(s.confirm.active);  // 只读，从不弹审批框
    // 其余键被忽略，弹窗留在原地。
    REQUIRE(HandleKey(s, K(KeyInput::Char, "x")) == Intent::None);
    REQUIRE(s.page == Page::Update);
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE(s.page == Page::Main);
    // q 是关闭弹窗，不是退出程序。
    REQUIRE(HandleKey(s, K(KeyInput::Char, "u")) == Intent::None);
    REQUIRE(s.page == Page::Update);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "q")) == Intent::None);
    REQUIRE(s.page == Page::Main);
}

TEST_CASE("HandleKey: the update page gates the home keys", "[p8]") {
    AppState s = NavState();
    REQUIRE(HandleKey(s, K(KeyInput::Char, "u")) == Intent::None);
    REQUIRE(s.page == Page::Update);
    // a/c/p/b 被弹窗吞掉：既不切换弹窗，也不产生任何网络 intent。
    REQUIRE(HandleKey(s, K(KeyInput::Char, "a")) == Intent::None);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "c")) == Intent::None);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "p")) == Intent::None);
    REQUIRE(HandleKey(s, K(KeyInput::Char, "b")) == Intent::None);
    REQUIRE(s.page == Page::Update);
    // Ctrl-Q 仍然是全局退出。
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'q')) == Intent::Quit);
}

TEST_CASE("ParseUpdate reads the ok/failure envelopes and assets", "[p8]") {
    Json ok = Json::parse(
        R"({"ok":true,"current":"Alpha-v0.3","latest_tag":"Alpha-v0.4","latest_name":"暑期更新",)"
        R"("prerelease":false,"published_at":"2025-08-01T10:00:00Z","html_url":"https://x/rel",)"
        R"("notes":"新功能\n- 检查更新","update_available":true,)"
        R"("assets":[{"name":"editor.zip","url":"https://x/a.zip","size":15728640}]})");
    UpdateResult r = BackendApi::ParseUpdate(ok);
    REQUIRE(r.ok);
    REQUIRE(r.current == "Alpha-v0.3");
    REQUIRE(r.latest_tag == "Alpha-v0.4");
    REQUIRE(r.latest_name == "暑期更新");
    REQUIRE(r.update_available);
    REQUIRE_FALSE(r.prerelease);
    REQUIRE(r.published_at == "2025-08-01T10:00:00Z");
    REQUIRE(r.html_url == "https://x/rel");
    REQUIRE(r.notes == "新功能\n- 检查更新");
    REQUIRE(r.assets.size() == 1);
    REQUIRE(r.assets[0].name == "editor.zip");
    REQUIRE(r.assets[0].url == "https://x/a.zip");
    REQUIRE(r.assets[0].size == 15728640);

    // 失败形态：路由仍回 200，靠 ok==false + error，current 依然有效。
    Json bad = Json::parse(R"({"ok":false,"error":"连接超时","current":"Alpha-v0.3"})");
    UpdateResult e = BackendApi::ParseUpdate(bad);
    REQUIRE_FALSE(e.ok);
    REQUIRE(e.error == "连接超时");
    REQUIRE(e.current == "Alpha-v0.3");
    REQUIRE_FALSE(e.update_available);
    REQUIRE(e.assets.empty());
}

// ------------------------------------------------------ plugin/cloud parsing
TEST_CASE("ParsePlugins reads the declarative plugin entry shape", "[p8]") {
    Json body = Json::parse(
        R"({"plugins":[{"id":"demo","name":"Demo","version":"1.0","author":"me",)"
        R"("description":"d","error":"","loaded":true},)"
        R"({"id":"bad","name":"Bad","loaded":false,"error":"manifest not found"}]})");
    auto ps = BackendApi::ParsePlugins(body);
    REQUIRE(ps.size() == 2);
    REQUIRE(ps[0].id == "demo");
    REQUIRE(ps[0].version == "1.0");
    REQUIRE(ps[0].loaded);
    REQUIRE_FALSE(ps[1].loaded);
    REQUIRE(ps[1].error == "manifest not found");
    // A missing plugins array is empty, not a crash.
    REQUIRE(BackendApi::ParsePlugins(Json::object()).empty());
}

TEST_CASE("ParseProviders / ParseLocalFiles / ParseRemoteObjects", "[p8]") {
    Json prov = Json::parse(
        R"({"providers":[{"id":"p_1","name":"Drive","type":"webdav","remote_root":"mods"}],)"
        R"("drivers":["local","webdav"]})");
    auto ps = BackendApi::ParseProviders(prov);
    REQUIRE(ps.size() == 1);
    REQUIRE(ps[0].id == "p_1");
    REQUIRE(ps[0].type == "webdav");
    REQUIRE(ps[0].remote_root == "mods");

    Json local = Json::parse(
        R"({"mod":"M","root":"/m","entries":[{"name":"Cfgs/x.json","type":"file","size":12}],"count":1})");
    auto lf = BackendApi::ParseLocalFiles(local);
    REQUIRE(lf.size() == 1);
    REQUIRE(lf[0].name == "Cfgs/x.json");
    REQUIRE(lf[0].size == 12);

    Json remote = Json::parse(
        R"({"remote":"mods","objects":[{"name":"d","path":"mods/d","is_dir":true,"size":0},)"
        R"({"name":"a.json","path":"mods/a.json","is_dir":false,"size":5}]})");
    auto rf = BackendApi::ParseRemoteObjects(remote);
    REQUIRE(rf.size() == 2);
    REQUIRE(rf[0].is_dir);              // path preferred over name for the diff
    REQUIRE(rf[0].name == "mods/d");
    REQUIRE(rf[1].size == 5);
}

TEST_CASE("InterpretSync folds both cloud/sync response shapes", "[p8]") {
    // Folder shape.
    Json folder = Json::parse(
        R"({"direction":"upload","dry_run":true,"total":3,"results":[)"
        R"({"rel":"a","ok":true,"action":"upload_new"},)"
        R"({"rel":"b","ok":true,"action":"skip_unchanged"},)"
        R"({"rel":"c","ok":false,"action":"","error":"boom"}]})");
    auto f = BackendApi::InterpretSync(folder);
    REQUIRE(f.dry_run);
    REQUIRE(f.direction == "upload");
    REQUIRE(f.total == 3);
    REQUIRE(f.uploaded == 1);
    REQUIRE(f.downloaded == 0);
    REQUIRE(f.skipped == 1);
    REQUIRE(f.failed == 1);

    // Single-file shape (no results[]).
    Json one = Json::parse(
        R"({"dry_run":true,"local_exists":true,"remote_exists":false,"direction":"upload"})");
    auto o = BackendApi::InterpretSync(one);
    REQUIRE(o.dry_run);
    REQUIRE(o.total == 1);
    REQUIRE(o.skipped == 1);

    // An HTTP error envelope surfaces its message.
    auto e = BackendApi::InterpretSync(Json::parse(R"({"error":"invalid direction"})"));
    REQUIRE(e.message == "invalid direction");
}

TEST_CASE("ParsePermissionMode defaults to confirm on anything unusable", "[p8]") {
    REQUIRE(BackendApi::ParsePermissionMode(Json::parse(R"({"settings":{"permissionMode":"full"}})")) ==
            "full");
    REQUIRE(BackendApi::ParsePermissionMode(Json::parse(R"({"permissionMode":"confirm"})")) ==
            "confirm");
    REQUIRE(BackendApi::ParsePermissionMode(Json::parse(R"({"settings":{"permissionMode":"yolo"}})")) ==
            "confirm");
    REQUIRE(BackendApi::ParsePermissionMode(Json::object()) == "confirm");
    REQUIRE(BackendApi::ParsePermissionMode(Json()) == "confirm");
}

// ------------------------------------------------------------ no-code mode (M2)
namespace {

bool Has(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

// The plain (slot-free) effect candidate the intent runner writes back after a
// FetchFieldSuggestions on TalkCfg.effect: {"effect":"","id":1}, field 0.
FieldSuggestion PlainCand() {
    return FieldSuggestion{"4015", "屏幕效果：模糊", "4015", {}};
}
// The slotted candidate: ATTR dict pool + V free number.
FieldSuggestion SlottedCand() {
    return FieldSuggestion{"[1,1,ATTR,V]", "属性增加", "[1,1,@ATTR@,V]",
                           {SuggestionSlot{"dict", "ATTR", "ATTR", "属性", 1},
                            SuggestionSlot{"number", "V", "", "数值", 1}}};
}

// Detail-pane form editing TalkCfg row "1" field `effect`, no-code on.
AppState EffectEditor() {
    AppState s;
    s.page = Page::Main;
    s.focus = Focus::Detail;
    s.detail_mode = DetailMode::Form;
    s.no_code_mode = true;
    s.table.name = "TalkCfg";
    s.table.exists = true;
    s.table.rows = {TableRow{"1", "空效果", R"({"effect":"","id":1})"}};
    s.row_sel = 0;
    s.field_sel = 0;
    return s;
}

// Mirror of the app's FetchFieldSuggestions write-back (p8_view_model never
// talks to the network; this is what the intent runner does with the result).
void WriteBackCandidates(AppState& s) {
    s.sug.all = {PlainCand(), SlottedCand()};
    s.sug.shown = FilterSuggestions(s.sug.all, "");
    s.sug.sel = 0;
    s.sug.query.clear();
    s.sug.active = !s.sug.all.empty();
}

}  // namespace

TEST_CASE("HandleKey: Ctrl-N toggles no-code mode and drops stale candidates", "[p8]") {
    AppState s = NavState();
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'n')) == Intent::SetNoCodeMode);
    REQUIRE(s.no_code_mode);
    REQUIRE(Has(s.status, "无代码模式: 开（选效果/人物）"));
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'n')) == Intent::SetNoCodeMode);
    REQUIRE_FALSE(s.no_code_mode);
    REQUIRE(Has(s.status, "无代码模式: 关（手输代码）"));

    // Turning it off with an open list must clear the whole sug cache.
    AppState t = EffectEditor();
    REQUIRE(HandleKey(t, K(KeyInput::Enter)) == Intent::FetchFieldSuggestions);
    WriteBackCandidates(t);
    REQUIRE(t.sug.active);
    REQUIRE_FALSE(t.sug.all.empty());
    REQUIRE(HandleKey(t, K(KeyInput::CtrlChar, "", 'n')) == Intent::SetNoCodeMode);
    REQUIRE_FALSE(t.no_code_mode);
    REQUIRE(t.sug.all.empty());
    REQUIRE_FALSE(t.sug.active);
    REQUIRE(t.sug.mode.empty());
    REQUIRE_FALSE(t.sug.slot_mode);
}

TEST_CASE("HandleKey: entering a suggestable field in no-code mode fetches candidates", "[p8]") {
    AppState s = EffectEditor();
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::FetchFieldSuggestions);
    REQUIRE(s.editing_field);
    REQUIRE(s.field_name == "effect");
    REQUIRE(s.sug.mode == "effect");
    REQUIRE_FALSE(s.sug.active);  // the fetcher opens the list once items land

    // A field with no suggestion source just opens the plain editor.
    AppState t = EffectEditor();
    t.field_sel = 2;  // id（行 0 是组标题，行 1 是 effect）
    REQUIRE(HandleKey(t, K(KeyInput::Enter)) == Intent::None);
    REQUIRE(t.editing_field);
    REQUIRE(t.field_name == "id");
    REQUIRE(t.sug.mode.empty());

    // Outside no-code mode nothing is fetched, but editing still opens.
    AppState u = EffectEditor();
    u.no_code_mode = false;
    REQUIRE(HandleKey(u, K(KeyInput::Enter)) == Intent::None);
    REQUIRE(u.editing_field);
    REQUIRE(u.sug.mode.empty());
}

TEST_CASE("HandleKey: candidate list cycles, filters locally, reopens and submits", "[p8]") {
    AppState s = EffectEditor();
    HandleKey(s, K(KeyInput::Enter));
    WriteBackCandidates(s);
    REQUIRE(s.sug.shown.size() == 2);

    // Tab/Down cycle with wraparound; Up wraps backwards.
    REQUIRE(HandleKey(s, K(KeyInput::Tab)) == Intent::None);
    REQUIRE(s.sug.sel == 1);
    HandleKey(s, K(KeyInput::Down));
    REQUIRE(s.sug.sel == 0);
    HandleKey(s, K(KeyInput::Up));
    REQUIRE(s.sug.sel == 1);

    // Typing feeds the buffer AND the query — pure local filtering, zero GETs.
    HandleKey(s, K(KeyInput::Char, "4"));
    REQUIRE(s.field_buffer == "4");  // seed was the empty preview, buffer grows raw
    REQUIRE(s.sug.query == "4");
    REQUIRE(s.sug.shown.size() == 1);
    REQUIRE(s.sug.shown[0] == 0);   // only "4015" contains the 4
    REQUIRE(s.sug.all.size() == 2);  // the cache is untouched
    REQUIRE(s.sug.sel == 0);

    // Backspace pops the typed char and the list returns to the full cache.
    HandleKey(s, K(KeyInput::Backspace));
    REQUIRE(s.field_buffer.empty());
    REQUIRE(s.sug.query.empty());
    REQUIRE(s.sug.shown.size() == 2);
    REQUIRE(s.sug.active);

    HandleKey(s, K(KeyInput::Escape));  // close the list, keep the editor open
    REQUIRE_FALSE(s.sug.active);
    REQUIRE(s.sug.query.empty());
    REQUIRE(s.editing_field);
    REQUIRE(s.field_buffer.empty());  // the edit buffer survived the close

    HandleKey(s, K(KeyInput::Tab));  // reopen from the cache — no intent
    REQUIRE(s.sug.active);
    REQUIRE(s.sug.shown.size() == 2);
    REQUIRE(s.sug.sel == 0);

    HandleKey(s, K(KeyInput::Escape));  // close again, then hand-submit
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);
    REQUIRE_FALSE(s.editing_field);
    REQUIRE(s.table.edits.count("1") == 1);  // ApplyFieldEdit wrote back
    REQUIRE(Has(s.status, "标记修改字段 effect"));
}

TEST_CASE("HandleKey: Backspace pops the last UTF-8 code point in every editor", "[p8]") {
    // Regression: PopCodepoint used to erase from the *last code point's lead
    // byte* (`s.erase(i)`), which is a no-op for an ASCII tail and leaves a
    // dangling lead byte (invalid UTF-8) for a CJK tail. One helper backs every
    // text field, so probe the candidate list, the field editor and the row
    // editor.
    AppState s = EffectEditor();
    HandleKey(s, K(KeyInput::Enter));
    WriteBackCandidates(s);
    HandleKey(s, K(KeyInput::Char, "4"));
    CHECK(s.field_buffer == "4");
    CHECK(s.sug.shown.size() == 1);
    HandleKey(s, K(KeyInput::Backspace));
    CHECK(s.field_buffer.empty());
    CHECK(s.sug.shown.size() == 2);  // the filter rolls back with the character
    // CJK tail: the whole code point goes, never a partial byte sequence.
    AppState c = EffectEditor();
    HandleKey(c, K(KeyInput::Enter));
    WriteBackCandidates(c);
    HandleKey(c, K(KeyInput::Char, "模"));
    CHECK(c.field_buffer == "模");
    HandleKey(c, K(KeyInput::Backspace));
    CHECK(c.field_buffer.empty());
    // The row editor shares the same helper.
    AppState r = RowsState();
    r.table.rows = {TableRow{"1", "x", "\"x\""}};
    HandleKey(r, K(KeyInput::Enter));
    HandleKey(r, K(KeyInput::Char, "a"));
    HandleKey(r, K(KeyInput::Backspace));
    CHECK(r.edit_buffer == "\"x\"");
}

TEST_CASE("HandleKey: Enter accepts a slot-free candidate and reports usage", "[p8]") {
    AppState s = EffectEditor();
    HandleKey(s, K(KeyInput::Enter));
    WriteBackCandidates(s);
    REQUIRE(s.sug.sel == 0);
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::ReportUsage);
    REQUIRE(s.field_buffer == "\"4015\"");  // merged into the JSON buffer quoted
    REQUIRE_FALSE(s.sug.active);
    REQUIRE(s.sug.pending_kind == "effect");
    REQUIRE(s.sug.pending_key == "4015");
    REQUIRE(s.editing_field);  // accepted into the buffer; Enter submits later
    REQUIRE(Has(s.status, "已补全: 4015"));
}

TEST_CASE("HandleKey: slotted candidate drives the slot fill-in flow to ReportUsage", "[p8]") {
    AppState s = EffectEditor();
    HandleKey(s, K(KeyInput::Enter));
    WriteBackCandidates(s);
    HandleKey(s, K(KeyInput::Down));
    REQUIRE(s.sug.sel == 1);
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::FetchSlotEntries);
    REQUIRE(s.sug.slot_mode);
    REQUIRE(s.sug.cand == 1);
    REQUIRE(s.sug.slot_i == 0);
    REQUIRE(s.status == "选择属性");
    REQUIRE(s.field_buffer.empty());  // nothing merged yet

    // app write-back for the ATTR dict pool
    s.sug.slot_entries = {{"1", "智力"}, {"7", "魅力"}};
    s.sug.entry_shown = FilterEntries(s.sug.slot_entries, "");
    s.sug.entry_sel = 0;

    HandleKey(s, K(KeyInput::Down));
    REQUIRE(s.sug.entry_sel == 1);
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);  // V is free-typed
    REQUIRE(s.sug.slot_i == 1);
    REQUIRE(s.sug.slot_values["ATTR"] == "7");
    REQUIRE(Has(s.status, "输入数值（Enter 下一槽）"));

    HandleKey(s, K(KeyInput::Char, "3"));
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::ReportUsage);
    REQUIRE(s.field_buffer == "\"[1,1,7,3]\"");
    REQUIRE_FALSE(s.sug.slot_mode);
    REQUIRE_FALSE(s.sug.active);
    REQUIRE(s.sug.pending_kind == "effect");
    REQUIRE(s.sug.pending_key == "[1,1,@ATTR@,V]");  // usage keys on the template
    REQUIRE(Has(s.status, "已补全: [1,1,7,3]"));
}

TEST_CASE("HandleKey: Esc inside the slot flow cancels without touching the buffer", "[p8]") {
    AppState s = EffectEditor();
    HandleKey(s, K(KeyInput::Enter));
    WriteBackCandidates(s);
    HandleKey(s, K(KeyInput::Down));
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::FetchSlotEntries);
    s.sug.slot_entries = {{"1", "智力"}, {"7", "魅力"}};
    s.sug.entry_shown = FilterEntries(s.sug.slot_entries, "");
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE_FALSE(s.sug.slot_mode);
    REQUIRE_FALSE(s.sug.active);
    REQUIRE(s.field_buffer.empty());  // still the initial "" seed
    REQUIRE(s.editing_field);         // hand typing remains possible
    REQUIRE(s.status == "已取消补全");
}

TEST_CASE("HandleKey: speaker field offers roles and reports role usage", "[p8]") {
    AppState s = EffectEditor();
    s.table.rows = {TableRow{"1", "无说话人", R"({"speaker":"","effect":""})"}};
    s.field_sel = 2;  // speaker（行 0 是组标题，行 1 是 effect）
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::FetchFieldSuggestions);
    REQUIRE(s.field_name == "speaker");
    REQUIRE(s.sug.mode == "role");

    // app write-back for GET /api/roles
    s.sug.all = {FieldSuggestion{"10", "林晓", "10", {}}};
    s.sug.shown = FilterSuggestions(s.sug.all, "");
    s.sug.active = true;
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::ReportUsage);
    REQUIRE(s.field_buffer == "\"10\"");
    REQUIRE(s.sug.pending_kind == "role");
    REQUIRE(s.sug.pending_key == "10");
}

// ---------------------------------------------------------------- pure helpers

TEST_CASE("FieldSuggestMode maps cfg/field onto the candidate source", "[p8]") {
    REQUIRE(FieldSuggestMode("TalkCfg", "roles") == "action");
    REQUIRE(FieldSuggestMode("ItemCfg", "roles") == "role");
    REQUIRE(FieldSuggestMode("TalkCfg", "speaker") == "role");
    REQUIRE(FieldSuggestMode("EvtCfg", "roleIds") == "role");
    REQUIRE(FieldSuggestMode("TalkCfg", "screenEffect") == "screen");
    REQUIRE(FieldSuggestMode("ItemCfg", "cost") == "cost");
    REQUIRE(FieldSuggestMode("TalkCfg", "check") == "condition");
    REQUIRE(FieldSuggestMode("TalkCfg", "xxEffect") == "effect");
    REQUIRE(FieldSuggestMode("TalkCfg", "content").empty());
}

TEST_CASE("ParseCodeSlots: dict placeholders, standalone letters, merging", "[p8]") {
    auto a = ParseCodeSlots("[1,1,@ATTR@,V]");
    REQUIRE(a.size() == 2);
    REQUIRE(a[0].kind == "dict");
    REQUIRE(a[0].name == "ATTR");
    REQUIRE(a[0].dict == "ATTR");
    REQUIRE(a[1].kind == "number");
    REQUIRE(a[1].name == "V");
    REQUIRE(a[1].count == 1);

    auto b = ParseCodeSlots("[N,1001,0,S]");
    REQUIRE(b.size() == 2);
    REQUIRE(b[0].kind == "number");
    REQUIRE(b[0].name == "N");
    REQUIRE(b[1].name == "S");

    auto c = ParseCodeSlots("[V,0,V]");
    REQUIRE(c.size() == 1);  // repeats merge into one slot
    REQUIRE(c[0].name == "V");
    REQUIRE(c[0].count == 2);

    auto d = ParseCodeSlots("[1,AVG,V]");
    REQUIRE(d.size() == 1);  // AVG is a word, not three letter slots
    REQUIRE(d[0].name == "V");
}

TEST_CASE("NormalizeForMatch: upper-case, space-strip, math-sign folding", "[p8]") {
    REQUIRE(NormalizeForMatch(" a≥b＜c ") == "A>=B<C");
    REQUIRE(NormalizeForMatch("≤") == "<=");
    REQUIRE(NormalizeForMatch("＞") == ">");
    REQUIRE(NormalizeForMatch("").empty());
}

TEST_CASE("FilterSuggestions: normalized desc/code contains, order kept", "[p8]") {
    std::vector<FieldSuggestion> all = {PlainCand(), SlottedCand()};
    REQUIRE(FilterSuggestions(all, "") == std::vector<int>({0, 1}));  // doc order
    REQUIRE(FilterSuggestions(all, "模糊") == std::vector<int>({0}));  // desc hit
    REQUIRE(FilterSuggestions(all, "attr") == std::vector<int>({1}));  // case-insensitive
    REQUIRE(FilterSuggestions(all, "1, 1") == std::vector<int>({1}));  // spaces folded
    REQUIRE(FilterSuggestions(all, "不存在的词").empty());
}

TEST_CASE("FilterEntries: id or name substring, empty query keeps all", "[p8]") {
    std::vector<std::pair<std::string, std::string>> e = {{"1", "智力"}, {"7", "魅力"}};
    REQUIRE(FilterEntries(e, "7") == std::vector<int>({1}));    // by id
    REQUIRE(FilterEntries(e, "魅") == std::vector<int>({1}));   // by name
    REQUIRE(FilterEntries(e, "") == std::vector<int>({0, 1}));  // all, in order
    REQUIRE(FilterEntries(e, "9").empty());
}

TEST_CASE("AssembleEffectCode: dict wholesale, letters standalone, gaps kept", "[p8]") {
    const std::vector<SuggestionSlot> slots = SlottedCand().slots;
    REQUIRE(AssembleEffectCode("[1,1,@ATTR@,V]", slots, {{"ATTR", "7"}, {"V", "3"}}) ==
            "[1,1,7,3]");
    REQUIRE(AssembleEffectCode("[1,1,@ATTR@,V]", slots, {{"V", "3"}}) == "[1,1,@ATTR@,3]");
    // The V inside AVG must not be hit by the V slot.
    const auto s2 = ParseCodeSlots("[1,AVG,V]");
    REQUIRE(AssembleEffectCode("[1,AVG,V]", s2, {{"V", "5"}}) == "[1,AVG,5]");
}

TEST_CASE("MergeCodeIntoBuffer: seed / append / replace rules", "[p8]") {
    REQUIRE(MergeCodeIntoBuffer("", "code") == "\"code\"");
    REQUIRE(MergeCodeIntoBuffer("\"\"", "code") == "\"code\"");
    REQUIRE(MergeCodeIntoBuffer("\"a\"", "code") == "\"a, code\"");
    REQUIRE(MergeCodeIntoBuffer("123", "code") == "\"code\"");  // non-string replaced
    REQUIRE(MergeCodeIntoBuffer("null", "code") == "\"code\"");
    REQUIRE(MergeCodeIntoBuffer("  \"x\"  ", "y") == "\"x, y\"");  // trimmed first
}

TEST_CASE("SlotPoolDictKey: upper-cases, known pools only", "[p8]") {
    REQUIRE(SlotPoolDictKey("ATTR") == "attrs");
    REQUIRE(SlotPoolDictKey("ROLE") == "roles");
    REQUIRE(SlotPoolDictKey("attr") == "attrs");
    REQUIRE(SlotPoolDictKey("FOO").empty());
    REQUIRE(SlotPoolDictKey("").empty());
}

// ------------------------------------------------------------------- parsers

TEST_CASE("ParseNoCodeMode reads wrapped and flat shapes, rejects junk", "[p8]") {
    REQUIRE(BackendApi::ParseNoCodeMode(
        Json::parse(R"({"settings":{"noCodeMode":true}})")));
    REQUIRE(BackendApi::ParseNoCodeMode(Json::parse(R"({"noCodeMode":true})")));
    REQUIRE_FALSE(BackendApi::ParseNoCodeMode(
        Json::parse(R"({"settings":{"noCodeMode":false}})")));
    REQUIRE_FALSE(BackendApi::ParseNoCodeMode(Json::parse(R"({"noCodeMode":"yes"})")));
    REQUIRE_FALSE(BackendApi::ParseNoCodeMode(Json::parse(R"({"settings":{}})")));
    REQUIRE_FALSE(BackendApi::ParseNoCodeMode(Json()));
}

TEST_CASE("ParseSuggestions: full shape, slots, template_, fallback parse, drops", "[p8]") {
    Json body = Json::parse(
        R"({"items":[
  {"code":"[1,1,ATTR,V]","desc":"属性增加","raw_code":"[1,1,@ATTR@,V]","slots":[
     {"kind":"dict","name":"ATTR","dict":"ATTR","label":"属性","count":1},
     {"kind":"number","name":"V","label":"数值","count":2},
     {"name":"Z","label":"值"},
     {"kind":"number","name":""}]},
  {"code":"4015","desc":"屏幕效果：模糊"},
  {"code":"","desc":"空 code 必须被丢弃"},
  {"code":"[1,1,ATTR,V]","desc":"旧后端无 slots","raw_code":"[1,1,@ATTR@,V]"}]})");
    auto v = BackendApi::ParseSuggestions(body);
    REQUIRE(v.size() == 3);  // the empty-code item is dropped
    REQUIRE(v[0].code == "[1,1,ATTR,V]");
    REQUIRE(v[0].desc == "属性增加");
    REQUIRE(v[0].template_ == "[1,1,@ATTR@,V]");  // raw_code wins
    REQUIRE(v[0].slots.size() == 3);              // name-empty slot dropped
    REQUIRE(v[0].slots[0].kind == "dict");
    REQUIRE(v[0].slots[0].name == "ATTR");
    REQUIRE(v[0].slots[0].dict == "ATTR");
    REQUIRE(v[0].slots[0].label == "属性");
    REQUIRE(v[0].slots[0].count == 1);
    REQUIRE(v[0].slots[1].kind == "number");
    REQUIRE(v[0].slots[1].dict.empty());
    REQUIRE(v[0].slots[1].count == 2);
    REQUIRE(v[0].slots[2].kind == "number");  // kind defaults to number
    REQUIRE(v[1].template_ == "4015");        // no raw_code -> code
    REQUIRE(v[1].slots.empty());
    // Old backend: no slots + '@' in the template -> ParseCodeSlots fallback.
    REQUIRE(v[2].slots.size() == 2);
    REQUIRE(v[2].slots[0].kind == "dict");
    REQUIRE(v[2].slots[0].name == "ATTR");
    REQUIRE(v[2].slots[1].kind == "number");
    REQUIRE(v[2].slots[1].name == "V");
    REQUIRE(BackendApi::ParseSuggestions(Json::object()).empty());
    REQUIRE(BackendApi::ParseSuggestions(Json()).empty());
}

TEST_CASE("ParseRoles folds id/name into insertable candidates", "[p8]") {
    auto v = BackendApi::ParseRoles(Json::parse(
        R"({"roles":[{"id":10,"name":"林晓"},{"id":"-1"},{"name":"无id丢弃"}]})"));
    REQUIRE(v.size() == 2);  // the id-less entry is dropped
    REQUIRE(v[0].code == "10");              // numeric id stringified
    REQUIRE(v[0].desc == "林晓");
    REQUIRE(v[0].template_ == "10");
    REQUIRE(v[1].code == "-1");
    REQUIRE(v[1].desc == "角色 -1");  // missing name -> placeholder label
    REQUIRE(BackendApi::ParseRoles(Json::parse(R"({"roles":[]})")).empty());
    REQUIRE(BackendApi::ParseRoles(Json::object()).empty());
    REQUIRE(BackendApi::ParseRoles(Json()).empty());
}
