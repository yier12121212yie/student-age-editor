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

// --------------------------------------------------- plugins / cloud / confirm
namespace {
AppState PluginsFixture() {
    AppState s;
    s.page = Page::Plugins;
    s.plugins = {PluginEntry{"demo", "Demo Plugin", "1.2.3", "me", "示例插件", "", true},
                 PluginEntry{"broken", "Broken", "", "", "", "manifest 解析失败", false}};
    s.plugins_loaded = true;
    s.plugin_sel = 1;
    s.status = "插件 2 个";
    return s;
}

AppState CloudFixture() {
    AppState s;
    s.page = Page::Cloud;
    s.selected_mod = "DemoMod";
    s.providers = {CloudProvider{"p_1", "我的网盘", "webdav", "mods"},
                   CloudProvider{"p_2", "本地目录", "local", "mods"}};
    s.providers_loaded = true;
    s.provider_sel = 0;
    s.cloud_local = {CloudFile{"Cfgs/zh-cn/TalkCfg.json", false, 128}};
    s.cloud_remote = {CloudFile{"mods/DemoMod/Cfgs/zh-cn/TalkCfg.json", false, 128},
                      CloudFile{"mods/DemoMod/Cfgs/zh-cn/EvtCfg.json", true, 0}};
    s.cloud_files_loaded = true;
    return s;
}
}  // namespace

TEST_CASE("Snapshot: plugins page lists ids, versions and load state", "[p8]") {
    std::string out = RenderPageToString(PluginsFixture(), 90, 18);
    REQUIRE(Contains(out, "插件管理"));
    REQUIRE(Contains(out, "Demo Plugin v1.2.3"));
    REQUIRE(Contains(out, "已加载"));
    REQUIRE(Contains(out, "manifest 解析失败"));
    REQUIRE(Contains(out, "» broken"));   // cursor on the selection
    REQUIRE(Contains(out, "安装 zip"));
}

TEST_CASE("Snapshot: plugins page shows the zip path prompt while typing", "[p8]") {
    AppState s = PluginsFixture();
    s.plugin_input_active = true;
    s.plugin_input = "C:/tmp/p.zip";
    std::string out = RenderPageToString(s, 90, 18);
    REQUIRE(Contains(out, "zip 路径>"));
    REQUIRE(Contains(out, "C:/tmp/p.zip"));
    REQUIRE(Contains(out, "Enter 安装"));
}

TEST_CASE("Snapshot: cloud page renders the dual local/remote comparison", "[p8]") {
    std::string out = RenderPageToString(CloudFixture(), 110, 20);
    REQUIRE(Contains(out, "Provider"));
    REQUIRE(Contains(out, "我的网盘"));
    REQUIRE(Contains(out, "本地 Mod 文件"));
    REQUIRE(Contains(out, "远端文件"));
    REQUIRE(Contains(out, "Cfgs/zh-cn/TalkCfg.json"));
    REQUIRE(Contains(out, "mods/DemoMod/Cfgs/zh-cn/TalkCfg.json"));
    REQUIRE(Contains(out, "mods/DemoMod/Cfgs/zh-cn/EvtCfg.json/"));  // dir marker
    REQUIRE(Contains(out, "方向: upload"));
    REQUIRE(Contains(out, "DryRun: 关"));
}

TEST_CASE("Snapshot: cloud page surfaces the DryRun/summary and provider errors", "[p8]") {
    AppState s = CloudFixture();
    s.cloud_dry_run = true;
    s.cloud_delete_extra = true;
    s.cloud_direction = "sync";
    s.cloud_sync_summary = "DRY-RUN 方向 sync  共 2  上传 1  下载 0  跳过 1  失败 0";
    s.cloud_error = "provider not found";
    std::string out = RenderPageToString(s, 110, 20);
    REQUIRE(Contains(out, "DryRun: 开"));
    REQUIRE(Contains(out, "清理远端多余: 开"));
    REQUIRE(Contains(out, "方向: sync"));
    REQUIRE(Contains(out, "DRY-RUN 方向 sync"));
    REQUIRE(Contains(out, "错误: provider not found"));
}

TEST_CASE("Snapshot: header carries the permission-mode badge", "[p8]") {
    AppState s = ModsFixture();
    REQUIRE(Contains(RenderPageToString(s, 100, 14), "[权限:confirm]"));
    s.permission_mode = "full";
    REQUIRE(Contains(RenderPageToString(s, 100, 14), "[权限:full]"));
}

TEST_CASE("Snapshot: confirm overlay replaces the body, then yields to the page", "[p8]") {
    AppState s = TableFixture();
    s.confirm.active = true;
    s.confirm.title = "保存表格";
    s.confirm.detail = "TalkCfg  修改 1  删除 0  新增 0";
    s.confirm.pending = Intent::SaveTable;
    std::string out = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(out, "保存表格"));
    REQUIRE(Contains(out, "TalkCfg  修改 1"));
    REQUIRE(Contains(out, "[y / Enter] 允许"));
    // The browse panes are hidden behind the modal.
    REQUIRE_FALSE(Contains(out, "ItemCfg"));

    s.confirm.active = false;
    std::string back = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(back, "ItemCfg"));
}

TEST_CASE("Snapshot: help overlay documents the new page bindings", "[p8]") {
    AppState s = PluginsFixture();
    s.show_help = true;
    std::string out = RenderPageToString(s, 100, 30);
    REQUIRE(Contains(out, "Ctrl-P"));
    REQUIRE(Contains(out, "Ctrl-L"));
    REQUIRE(Contains(out, "Ctrl-M"));
    REQUIRE(Contains(out, "confirm"));
}
