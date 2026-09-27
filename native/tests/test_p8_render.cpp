// tests/test_p8_render.cpp — FTXUI snapshot tests.
//
// Renders the panel to a plain string (ANSI stripped) via RenderPageToString and
// asserts on the key content lines of the Alpha-v0.3 layout: the three-pane
// home screen, the centered modals and the blue chrome. Headless — the
// interactive event loop is intentionally not covered here. [p8]
#include <catch_amalgamated.hpp>

#include <string>

#include "p8_model.h"
#include "p8_render.h"

using namespace p8;

namespace {
bool Contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

AppState MainFixture() {
    AppState s;
    s.page = Page::Main;
    s.mods = {ModEntry{"DemoMod", "m/DemoMod"}, ModEntry{"Other", "m/Other"}};
    s.selected_mod = "DemoMod";
    s.mod_sel = 0;
    s.expanded_mod = 0;
    s.tree_sel = 1;
    s.tables = {"TalkCfg", "ItemCfg"};
    s.table.name = "TalkCfg";
    s.table.exists = true;
    s.table.rows = {TableRow{"1", "你好", "\"你好\""},
                    TableRow{"2", "旧值", R"({"id":2,"content":"旧值"})"}};
    s.table.edits["2"] = R"({"id":2,"content":"新值"})";
    s.row_sel = 1;
    s.focus = Focus::Rows;
    s.status = "已连接 http://127.0.0.1:8770";
    return s;
}

// The browse screen without an open table: the detail pane shows the welcome.
AppState FreshFixture() {
    AppState s;
    s.page = Page::Main;
    s.mods = {ModEntry{"DemoMod", "m/DemoMod"}};
    s.status = "已连接";
    return s;
}
}  // namespace

TEST_CASE("Snapshot: home carries the Alpha header, panes and tree", "[p8]") {
    std::string out = RenderPageToString(MainFixture(), 100, 20);
    // Blue chrome: the Alpha header + the three pane title bars.
    REQUIRE(Contains(out, "学生时代 · 模组编辑器 — TUI"));
    REQUIRE(Contains(out, "📦 Mods / Cfgs"));
    REQUIRE(Contains(out, "📋 Records — TalkCfg"));
    REQUIRE(Contains(out, "📝 Detail / JSON"));
    // The left pane is the two-level tree: expanded mod + cfg children.
    REQUIRE(Contains(out, "📂 DemoMod"));
    REQUIRE(Contains(out, "● TalkCfg"));
    REQUIRE(Contains(out, "◦ ItemCfg"));
    REQUIRE(Contains(out, "📁 Other"));
    // Status bar carries workspace + permission info.
    REQUIRE(Contains(out, "Workspace: DemoMod"));
    REQUIRE(Contains(out, "权限: confirm"));
    REQUIRE(Contains(out, "已连接"));
}

TEST_CASE("Snapshot: browse renders rows, edit markers and the dirty badge", "[p8]") {
    std::string out = RenderPageToString(MainFixture(), 100, 20);
    REQUIRE(Contains(out, "你好"));
    REQUIRE(Contains(out, "新值"));
    REQUIRE(Contains(out, "*2"));  // dirty marker on the edited key
    REQUIRE(Contains(out, "\"content\": \"新值\""));
    REQUIRE(Contains(out, "未保存: 1"));
    // Dirty right pane gets the red badge; the detail title stays recognisable.
    REQUIRE(Contains(out, "●"));
    // The right pane buttons row (保存 / 校验 / 复制 / 删除).
    REQUIRE(Contains(out, "s 保存"));
    REQUIRE(Contains(out, "v 校验"));
    REQUIRE(Contains(out, "y 复制"));
    REQUIRE(Contains(out, "d 删除"));
    // Footer global keys.
    REQUIRE(Contains(out, "Ctrl-S 保存"));
}

TEST_CASE("Snapshot: fresh session shows the welcome guide, not a table", "[p8]") {
    std::string out = RenderPageToString(FreshFixture(), 90, 20);
    REQUIRE(Contains(out, "# 学生时代 · TUI 编辑器"));
    REQUIRE(Contains(out, "① 左栏 Enter 选择模组并展开"));
    REQUIRE(Contains(out, "（未打开）"));
    REQUIRE(Contains(out, "📦 Mods / Cfgs"));
    REQUIRE(Contains(out, "📁 DemoMod"));
}

TEST_CASE("Snapshot: form pane renders fields when toggled", "[p8]") {
    AppState s = MainFixture();
    s.focus = Focus::Detail;
    s.detail_mode = DetailMode::Form;
    s.field_sel = 1;
    std::string out = RenderPageToString(s, 100, 20);
    REQUIRE(Contains(out, "[表单]"));
    REQUIRE(Contains(out, "content"));
    // The pending edit of row 2 supplies the field values.
    REQUIRE(Contains(out, "2"));
    REQUIRE(Contains(out, "新值"));
}

TEST_CASE("Snapshot: help modal replaces the home screen", "[p8]") {
    AppState s = FreshFixture();
    s.show_help = true;
    std::string out = RenderPageToString(s, 90, 30);
    REQUIRE(Contains(out, "⌨️ 键位帮助"));
    REQUIRE(Contains(out, "q / Ctrl-Q"));
    REQUIRE(Contains(out, "Ctrl-K"));
    // The home panes are hidden while the modal is up.
    REQUIRE_FALSE(Contains(out, "📦 Mods / Cfgs"));
}

TEST_CASE("Snapshot: search modal shows input and results", "[p8]") {
    AppState s = MainFixture();
    s.search.active = true;
    s.search.input = "你好";
    s.search.results = {SearchHit{"Mod", "101", "开学第一天", "101001", "你好，同学"}};
    std::string out = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(out, "🔍 全局搜索对白"));
    REQUIRE(Contains(out, "你好"));
    REQUIRE(Contains(out, "101001"));
    REQUIRE_FALSE(Contains(out, "📋 Records — TalkCfg"));
}

TEST_CASE("Snapshot: validate modal shows issues and counts", "[p8]") {
    AppState s = MainFixture();
    s.validate.active = true;
    s.validate.cfg = "TalkCfg";
    s.validate.issues = {Issue{"error", "9", "缺少必填字段"}, Issue{"warn", "", "字段为空"}};
    s.validate.errors = 1;
    s.validate.warns = 1;
    std::string out = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(out, "● 校验: TalkCfg"));
    REQUIRE(Contains(out, "[error] 9: 缺少必填字段"));
    REQUIRE(Contains(out, "counts: error=1 warn=1 info=0"));
    REQUIRE_FALSE(Contains(out, "📋 Records — TalkCfg"));
}

// --------------------------------------------------- plugins / cloud / confirm
namespace {
AppState PluginsFixture() {
    AppState s = FreshFixture();
    s.page = Page::Plugins;
    s.plugins = {PluginEntry{"demo", "Demo Plugin", "1.2.3", "me", "示例插件", "", true},
                 PluginEntry{"broken", "Broken", "", "", "", "manifest 解析失败", false}};
    s.plugins_loaded = true;
    s.plugin_sel = 1;
    s.status = "插件 2 个";
    return s;
}

AppState CloudFixture() {
    AppState s = FreshFixture();
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

TEST_CASE("Snapshot: plugins modal lists ids, versions and load state", "[p8]") {
    std::string out = RenderPageToString(PluginsFixture(), 90, 18);
    REQUIRE(Contains(out, "🧩 插件管理"));
    REQUIRE(Contains(out, "Demo Plugin v1.2.3"));
    REQUIRE(Contains(out, "已加载"));
    REQUIRE(Contains(out, "manifest 解析失败"));
    REQUIRE(Contains(out, "» broken"));   // cursor on the selection
    REQUIRE(Contains(out, "i 安装zip"));
}

TEST_CASE("Snapshot: plugins modal shows the zip path prompt while typing", "[p8]") {
    AppState s = PluginsFixture();
    s.plugin_input_active = true;
    s.plugin_input = "C:/tmp/p.zip";
    s.status = "输入插件 zip 路径，Enter 安装，Esc 取消";  // what the view model sets
    std::string out = RenderPageToString(s, 90, 18);
    REQUIRE(Contains(out, "zip 路径>"));
    REQUIRE(Contains(out, "C:/tmp/p.zip"));
    REQUIRE(Contains(out, "Enter 安装"));
}

TEST_CASE("Snapshot: cloud modal renders the dual local/remote comparison", "[p8]") {
    std::string out = RenderPageToString(CloudFixture(), 110, 20);
    REQUIRE(Contains(out, "☁️ 云同步"));
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

TEST_CASE("Snapshot: cloud modal surfaces the DryRun/summary and provider errors", "[p8]") {
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

TEST_CASE("Snapshot: the status bar carries the permission mode", "[p8]") {
    AppState s = FreshFixture();
    REQUIRE(Contains(RenderPageToString(s, 100, 14), "权限: confirm"));
    s.permission_mode = "full";
    REQUIRE(Contains(RenderPageToString(s, 100, 14), "权限: full"));
}

TEST_CASE("Snapshot: confirm modal replaces the body, then yields to the page", "[p8]") {
    AppState s = MainFixture();
    s.confirm.active = true;
    s.confirm.title = "保存表格";
    s.confirm.detail = "TalkCfg  修改 1  删除 0  新增 0";
    s.confirm.pending = Intent::SaveTable;
    std::string out = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(out, "⚠ 保存表格"));
    REQUIRE(Contains(out, "TalkCfg  修改 1"));
    REQUIRE(Contains(out, "[y / Enter] 允许"));
    // The browse panes are hidden behind the modal.
    REQUIRE_FALSE(Contains(out, "📋 Records — TalkCfg"));

    s.confirm.active = false;
    std::string back = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(back, "📋 Records — TalkCfg"));
}

TEST_CASE("Snapshot: agent modal titles with provider/model and chat history", "[p8]") {
    AppState s = FreshFixture();
    s.page = Page::Agent;
    s.agent_label = "openai_compatible · gpt-4o-mini";
    s.chat = {ChatMsg{"user", "帮我看看第一句"},
              ChatMsg{"assistant", "第一句是「你好，同学」。"}};
    std::string out = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(out, "🤖 AI 助手"));
    REQUIRE(Contains(out, "openai_compatible · gpt-4o-mini"));
    REQUIRE(Contains(out, "你：帮我看看第一句"));
    REQUIRE(Contains(out, "第一句是「你好，同学」。"));
    REQUIRE(Contains(out, "输入>"));
}

TEST_CASE("Snapshot: bugfix modal (b) lists findings", "[p8]") {
    AppState s = FreshFixture();
    s.page = Page::Bugfix;
    s.selected_mod = "DemoMod";
    s.bugs = {BugEntry{"TalkCfg", "5", "roleIds", "REF", "引用了不存在的角色 ID 999"}};
    s.bug_scanned = true;
    std::string out = RenderPageToString(s, 90, 20);
    REQUIRE(Contains(out, "🐞 Bug 扫描 / 修复"));
    REQUIRE(Contains(out, "[REF] TalkCfg/5 roleIds"));
    REQUIRE(Contains(out, "f 修复全部"));
}

TEST_CASE("Snapshot: help documents the Alpha modal keys", "[p8]") {
    AppState s = FreshFixture();
    s.show_help = true;
    std::string out = RenderPageToString(s, 100, 30);
    REQUIRE(Contains(out, "a / c / p / b"));
    REQUIRE(Contains(out, "Ctrl-M"));
    REQUIRE(Contains(out, "confirm"));
    REQUIRE(Contains(out, "Tab/Shift+Tab"));
}

// ---------------------------------------------------------------- no-code (M2)
namespace {
// The two candidates the intent runner caches for TalkCfg.effect.
FieldSuggestion CandPlain() {
    return FieldSuggestion{"4015", "屏幕效果：模糊", "4015", {}};
}
FieldSuggestion CandSlotted() {
    return FieldSuggestion{"[1,1,ATTR,V]", "属性增加", "[1,1,@ATTR@,V]",
                           {SuggestionSlot{"dict", "ATTR", "ATTR", "属性", 1},
                            SuggestionSlot{"number", "V", "", "数值", 1}}};
}
// Detail form mode, one field's editor open (what Ctrl-N + Enter produces).
AppState FieldEditing() {
    AppState s = MainFixture();
    s.focus = Focus::Detail;
    s.detail_mode = DetailMode::Form;
    s.no_code_mode = true;
    s.editing_field = true;
    s.field_name = "effect";
    s.field_buffer = "4";
    s.sug.mode = "effect";
    return s;
}
}  // namespace

TEST_CASE("Snapshot: the status bar carries the no-code chip", "[p8]") {
    AppState on = MainFixture();
    on.no_code_mode = true;
    REQUIRE(Contains(RenderPageToString(on, 100, 20), "权限: confirm · 无代码"));
    // Off: the chip is gone (the footer's "Ctrl-N 无代码" never has the dot).
    AppState off = MainFixture();
    REQUIRE_FALSE(Contains(RenderPageToString(off, 100, 20), "· 无代码"));
}

TEST_CASE("Snapshot: help lists the no-code toggle and its in-field keys", "[p8]") {
    AppState s = FreshFixture();
    s.show_help = true;
    std::string out = RenderPageToString(s, 100, 34);
    REQUIRE(Contains(out, "Ctrl-N        无代码模式开关（选效果/人物，不写代码）"));
    REQUIRE(Contains(out, "无代码: 编辑字段时 Tab/↑↓ 选候选 · Enter 接受（带参槽进二级选择）"));
}

TEST_CASE("Snapshot: the footer advertises the Ctrl-N no-code toggle", "[p8]") {
    std::string out = RenderPageToString(FreshFixture(), 100, 14);
    REQUIRE(Contains(out, "Ctrl-N 无代码"));
}

TEST_CASE("Snapshot: field editor shows the candidate list with its key hints", "[p8]") {
    AppState s = FieldEditing();
    s.sug.active = true;
    s.sug.all = {CandPlain(), CandSlotted()};
    s.sug.shown = {0, 1};
    s.sug.sel = 1;
    std::string out = RenderPageToString(s, 100, 22);
    REQUIRE(Contains(out, "编辑 effect>"));   // the editor line itself
    REQUIRE(Contains(out, "屏幕效果：模糊"));  // unselected candidate row
    REQUIRE(Contains(out, "» 属性增加"));      // cursor on the selection
    REQUIRE(Contains(out, "Enter 接受"));      // the hint under the list
}

TEST_CASE("Snapshot: slot fill-in renders the entry sub-list", "[p8]") {
    AppState s = FieldEditing();
    s.sug.active = true;
    s.sug.all = {CandSlotted()};
    s.sug.shown = {0};
    s.sug.sel = 0;
    // Accepting the slotted candidate (slot 0 = dict ATTR with a pool).
    s.sug.slot_mode = true;
    s.sug.cand = 0;
    s.sug.slot_i = 0;
    s.sug.slot_entries = {{"1", "智力"}, {"7", "魅力"}};
    s.sug.entry_shown = {0, 1};
    s.sug.entry_sel = 1;
    s.status = "选择属性";  // what EnterSlotMode sets
    std::string out = RenderPageToString(s, 100, 22);
    REQUIRE(Contains(out, "选择属性"));      // status bar line
    REQUIRE(Contains(out, "槽 1/2"));        // slot progress head
    REQUIRE(Contains(out, "属性 (ATTR)"));   // prompt + raw name
    REQUIRE(Contains(out, "» 7 · 魅力"));    // cursor on the second entry
    REQUIRE(Contains(out, "1 · 智力"));      // first entry still listed
}
