// tests/test_p8_logic.cpp — pure-logic tests for the P8 TUI + agent.
//
// Everything here is headless: the view-model state machine (HandleKey), the
// cfg edit->patch diff, the backend response parsers, the agent SSE/chat-codec
// and the session history store. No network, no terminal. [p8]
#include <catch_amalgamated.hpp>

#include <filesystem>
#include <string>

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

// A browse page seeded with rows and the keyboard on the rows pane.
AppState RowsState() {
    AppState s;
    s.page = Page::Table;
    s.focus = Focus::Rows;
    s.table.name = "TalkCfg";
    s.table.exists = true;
    return s;
}
}  // namespace

// ---------------------------------------------------------------- view model
TEST_CASE("HandleKey: mods navigation clamps and Enter selects", "[p8]") {
    AppState s = NavState();
    REQUIRE(HandleKey(s, K(KeyInput::Down)) == Intent::None);
    REQUIRE(s.mod_sel == 1);
    HandleKey(s, K(KeyInput::Down));  // clamp at bottom
    REQUIRE(s.mod_sel == 1);
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::SelectMod);
    REQUIRE(s.selected_mod == "B");
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

TEST_CASE("HandleKey: global ctrl page jumps and quit", "[p8]") {
    AppState s = NavState();
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'b')) == Intent::ScanBugs);
    REQUIRE(s.page == Page::Bugfix);
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'a')) == Intent::None);
    REQUIRE(s.page == Page::Agent);
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 't')) == Intent::RefreshTables);
    REQUIRE(s.page == Page::Table);
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'q')) == Intent::Quit);
}

TEST_CASE("HandleKey: filter typing narrows visible rows", "[p8]") {
    AppState s = RowsState();
    s.table.rows = {TableRow{"apple", "1", "1"}, TableRow{"banana", "2", "2"}};
    HandleKey(s, K(KeyInput::Char, "app"));
    auto vis = s.VisibleRows();
    REQUIRE(vis.size() == 1);
    REQUIRE(s.table.rows[vis[0]].key == "apple");
}

TEST_CASE("HandleKey: Tab cycles browse panes and tables Enter loads", "[p8]") {
    AppState s;
    s.page = Page::Table;
    REQUIRE(s.focus == Focus::Tables);  // browse starts on the tables pane
    s.tables = {"TalkCfg", "ItemCfg"};
    s.table_filter = "talk";  // only TalkCfg visible
    // Tab: Tables -> Rows -> Detail -> Tables.
    REQUIRE(HandleKey(s, K(KeyInput::Tab)) == Intent::None);
    REQUIRE(s.focus == Focus::Rows);
    REQUIRE(HandleKey(s, K(KeyInput::Tab)) == Intent::None);
    REQUIRE(s.focus == Focus::Detail);
    REQUIRE(HandleKey(s, K(KeyInput::Tab)) == Intent::None);
    REQUIRE(s.focus == Focus::Tables);
    // Enter on the tables pane loads the selected (visible) table.
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::LoadTable);
    REQUIRE(s.table.name == "TalkCfg");
    REQUIRE(s.focus == Focus::Rows);
    // Esc on rows goes back to tables, Esc on tables leaves to mods.
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE(s.focus == Focus::Tables);
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE(s.page == Page::Mods);
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
    HandleKey(s, K(KeyInput::Char, "app"));  // filter -> only row 1 visible
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

TEST_CASE("HandleKey: page jumps drop edit state; Ctrl-S saves from any pane", "[p8]") {
    AppState s = RowsState();
    s.permission_mode = "full";  // ungated: this case asserts the raw intents
    s.table.rows = {TableRow{"1", "a", "\"a\""}};
    s.table.edits["1"] = "\"b\"";
    HandleKey(s, K(KeyInput::Enter));  // open the row editor
    REQUIRE(s.editing);
    HandleKey(s, K(KeyInput::CtrlChar, "", 'b'));  // switch to Bugfix mid-edit
    REQUIRE_FALSE(s.editing);
    REQUIRE(s.page == Page::Bugfix);
    // Back on the browse page, Ctrl-S works from Tables/Detail focus too.
    s.page = Page::Table;
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
    // Detail focus via Tab, switch to form, pick the second field, edit it.
    HandleKey(s, K(KeyInput::Tab));   // Rows -> Detail
    REQUIRE(HandleKey(s, K(KeyInput::Enter)) == Intent::None);
    REQUIRE(s.detail_mode == DetailMode::Form);
    HandleKey(s, K(KeyInput::Down));  // -> "content"
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
    s.page = Page::Table;
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
    s.page = Page::Table;
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
    s.page = Page::Table;
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

TEST_CASE("HandleKey: Ctrl-P opens plugins, and the page drives its actions", "[p8]") {
    AppState s = NavState();
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'p')) == Intent::RefreshPlugins);
    REQUIRE(s.page == Page::Plugins);
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

    // Esc leaves the page.
    REQUIRE(HandleKey(s, K(KeyInput::Escape)) == Intent::None);
    REQUIRE(s.page == Page::Mods);
}

TEST_CASE("HandleKey: Ctrl-P jump abandons a half-typed install path", "[p8]") {
    AppState s = NavState();
    s.page = Page::Plugins;
    HandleKey(s, K(KeyInput::Char, "i"));
    HandleKey(s, K(KeyInput::Char, "x"));
    REQUIRE(s.plugin_input_active);
    HandleKey(s, K(KeyInput::CtrlChar, "", 't'));
    REQUIRE_FALSE(s.plugin_input_active);
    REQUIRE(s.page == Page::Table);
}

TEST_CASE("HandleKey: Ctrl-L opens cloud; direction/DryRun and gated sync", "[p8]") {
    AppState s = NavState();
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'l')) == Intent::RefreshCloudProviders);
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
