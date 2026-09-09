// wip/P8/test_p8_render.cpp — FTXUI snapshot tests.
//
// Renders the panel to a plain string (ANSI stripped) via RenderPageToString and
// asserts on the key content lines. This exercises the DOM layout for real (not a
// mock) but stays headless — the interactive event loop is intentionally not
// covered here (see the two snapshot cases). [p8]
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
    s.table.name = "TalkCfg";
    s.table.exists = true;
    s.table.rows = {TableRow{"1", "你好", "\"你好\""}, TableRow{"2", "旧值", "\"旧值\""}};
    s.table.edits["2"] = "\"新值\"";
    s.row_sel = 1;
    return s;
}
}  // namespace

TEST_CASE("Snapshot: mods page renders title, cursor and mod names", "[p8]") {
    std::string out = RenderPageToString(ModsFixture(), 80, 14);
    REQUIRE(Contains(out, "编辑器 TUI"));
    REQUIRE(Contains(out, "模组"));           // page name in the header
    REQUIRE(Contains(out, "DemoMod"));
    REQUIRE(Contains(out, "Other"));
    REQUIRE(Contains(out, "»"));             // the selection cursor marker
    REQUIRE(Contains(out, "已连接"));          // the status line
}

TEST_CASE("Snapshot: table page renders edit marker, new value and hint", "[p8]") {
    std::string out = RenderPageToString(TableFixture(), 80, 14);
    REQUIRE(Contains(out, "表格"));                 // header page name
    REQUIRE(Contains(out, "TalkCfg"));
    REQUIRE(Contains(out, "新值"));                 // edited cell shows the new text
    REQUIRE(Contains(out, "*2"));                  // dirty marker prefix on row 2
    REQUIRE(Contains(out, "Ctrl-S 保存"));  // help hint line
}

TEST_CASE("Snapshot: help overlay replaces the body when toggled", "[p8]") {
    AppState s = ModsFixture();
    s.show_help = true;
    std::string out = RenderPageToString(s, 80, 18);
    REQUIRE(Contains(out, "键位"));
    REQUIRE(Contains(out, "Ctrl-Q"));
    // The mod list is hidden while help is shown.
    REQUIRE_FALSE(Contains(out, "DemoMod"));
}
