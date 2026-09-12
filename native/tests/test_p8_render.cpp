// tests/test_p8_render.cpp — FTXUI snapshot tests.
//
// Renders the panel to a plain string (ANSI stripped) via RenderPageToString and
// asserts on the key content lines. This exercises the DOM layout for real (not a
// mock) but stays headless — the interactive event loop is intentionally not
// covered here (see the snapshot cases). [p8]
#include <catch_amalgamated.hpp>

#include <string>

#include "p8_model.h"
#include "p8_render.h"

using namespace p8;

namespace {
bool Contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

AppState ModsFixture() {
    AppState s;
    s.page = Page::Mods;
    s.mods = {ModEntry{"DemoMod", "m/DemoMod"}, ModEntry{"Other", "m/Other"}};
    s.mod_sel = 0;
    s.status = "已连接 http://127.0.0.1:8770";
    return s;
}

AppState TableFixture() {
    AppState s;
    s.page = Page::Table;
    s.focus = Focus::Rows;
    s.tables = {"TalkCfg", "ItemCfg"};
    s.table.name = "TalkCfg";
    s.table.exists = true;
    s.table.rows = {TableRow{"1", "你好", "\"你好\""},
                    TableRow{"2", "旧值", R"({"id":2,"content":"旧值"})"}};
    s.table.edits["2"] = R"({"id":2,"content":"新值"})";
    s.row_sel = 1;
    return s;
}
}  // namespace

TEST_CASE("Snapshot: mods page renders title, cursor and mod names", "[p8]") {
    std::string out = RenderPageToString(ModsFixture(), 80, 14);
    REQUIRE(Contains(out, "编辑器 TUI"));
    REQUIRE(Contains(out, "模组"));           // tab bar + page name
    REQUIRE(Contains(out, "DemoMod"));
    REQUIRE(Contains(out, "Other"));
    REQUIRE(Contains(out, "»"));             // the selection cursor marker
    REQUIRE(Contains(out, "已连接"));          // the status line
}

TEST_CASE("Snapshot: browse page renders the three panes and edit state", "[p8]") {
    std::string out = RenderPageToString(TableFixture(), 100, 20);
    // Tab bar + panes.
    REQUIRE(Contains(out, "表格"));
    REQUIRE(Contains(out, "表列表"));
    REQUIRE(Contains(out, "详情"));
    REQUIRE(Contains(out, "TalkCfg"));
    REQUIRE(Contains(out, "ItemCfg"));
    // Edited cell shows the new text with the dirty marker.
    REQUIRE(Contains(out, "新值"));
    REQUIRE(Contains(out, "*2"));
    // Detail pane pretty-prints the pending edit of the selected row.
    REQUIRE(Contains(out, "\"content\": \"新值\""));
    // Footer hint line.
    REQUIRE(Contains(out, "Ctrl-S 保存"));
    // Row count / dirty counters.
    REQUIRE(Contains(out, "未保存: 1"));
}

TEST_CASE("Snapshot: browse page renders the form pane when toggled", "[p8]") {
    AppState s = TableFixture();
    s.focus = Focus::Detail;
    s.detail_mode = DetailMode::Form;
    s.field_sel = 1;
    std::string out = RenderPageToString(s, 100, 20);
    REQUIRE(Contains(out, "[表单]"));
    REQUIRE(Contains(out, "content"));
    REQUIRE(Contains(out, "id = 2"));
}

TEST_CASE("Snapshot: help overlay replaces the body when toggled", "[p8]") {
    AppState s = ModsFixture();
    s.show_help = true;
    std::string out = RenderPageToString(s, 80, 24);
    REQUIRE(Contains(out, "键位"));
    REQUIRE(Contains(out, "Ctrl-Q"));
    REQUIRE(Contains(out, "Ctrl-K"));
    // The mod list is hidden while help is shown.
    REQUIRE_FALSE(Contains(out, "DemoMod"));
}

TEST_CASE("Snapshot: search overlay shows input and results", "[p8]") {
    AppState s = TableFixture();
    s.search.active = true;
    s.search.input = "你好";
    s.search.results = {SearchHit{"Mod", "101", "开学第一天", "101001", "你好，同学"}};
    std::string out = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(out, "全局搜索对白"));
    REQUIRE(Contains(out, "你好"));
    REQUIRE(Contains(out, "101001"));
    // The three-pane body is hidden behind the overlay.
    REQUIRE_FALSE(Contains(out, "ItemCfg"));
}

TEST_CASE("Snapshot: validate overlay shows issues and counts", "[p8]") {
    AppState s = TableFixture();
    s.validate.active = true;
    s.validate.cfg = "TalkCfg";
    s.validate.issues = {Issue{"error", "9", "缺少必填字段"}, Issue{"warn", "", "字段为空"}};
    s.validate.errors = 1;
    s.validate.warns = 1;
    std::string out = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(out, "校验: TalkCfg"));
    REQUIRE(Contains(out, "[error] 9: 缺少必填字段"));
    REQUIRE(Contains(out, "counts: error=1 warn=1 info=0"));
    REQUIRE_FALSE(Contains(out, "ItemCfg"));
}
