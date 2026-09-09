// wip/P8/test_p8_logic.cpp — pure-logic tests for the P8 TUI + agent.
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
    AppState s;
    s.page = Page::Table;
    s.table.name = "TalkCfg";
    s.table.exists = true;
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
    AppState s;
    s.page = Page::Table;
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
    REQUIRE(HandleKey(s, K(KeyInput::CtrlChar, "", 'q')) == Intent::Quit);
}

TEST_CASE("HandleKey: filter typing narrows visible rows", "[p8]") {
    AppState s;
    s.page = Page::Table;
    s.table.rows = {TableRow{"apple", "1", "1"}, TableRow{"banana", "2", "2"}};
    HandleKey(s, K(KeyInput::Char, "app"));
    auto vis = s.VisibleRows();
    REQUIRE(vis.size() == 1);
    REQUIRE(s.table.rows[vis[0]].key == "apple");
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
