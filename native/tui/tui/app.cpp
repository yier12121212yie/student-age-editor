// native/tui/tui/app.cpp
#include "app.h"

#include <algorithm>
#include <ctime>
#include <string>

#include <ftxui/component/component.hpp>
#include <ftxui/component/component_base.hpp>
#include <ftxui/component/event.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/screen.hpp>

#include "p8_cfg.h"
#include "p8_render.h"

namespace p8 {
namespace {

const char* kSystemPrompt =
    "你是「学生时代模组编辑器」的 AI 助手。用简体中文回答，简洁清晰。"
    "本终端版为纯对话（不含自动改表工具），需要改动时请给出手动操作步骤。";

std::string Trim(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

// A single top-level component: it renders the panel and translates keys.
class TuiComponent : public ftxui::ComponentBase {
public:
    TuiComponent(TuiApp* app, ftxui::ScreenInteractive* screen) : app_(app), screen_(screen) {}

    ftxui::Element Render() override {
        return BuildElement(app_->st, app_->render_width(), app_->render_list_height());
    }

    bool OnEvent(ftxui::Event event) override {
        KeyInput k = app_->MapEventPublic(event);
        if (k.kind == KeyInput::None) return false;
        Intent intent = HandleKey(app_->st, k);
        if (intent == Intent::Quit) {
            screen_->Exit();
            return true;
        }
        app_->RunIntent(intent);
        return true;
    }

private:
    TuiApp* app_;
    ftxui::ScreenInteractive* screen_;
};

}  // namespace

TuiApp::TuiApp(std::string base_url, AgentSettings agent_settings, std::string data_root)
    : api_(std::move(base_url)),
      agent_(std::move(agent_settings)),
      data_root_(std::move(data_root)) {
    std::time_t now = std::time(nullptr);
    session_id_ = "tui-" + std::to_string(static_cast<long long>(now));
}

int TuiApp::render_width() const { return width_; }
int TuiApp::render_list_height() const { return std::max(1, height_ - 6); }

void TuiApp::Run() {
    auto probe = ftxui::Screen::Create(ftxui::Dimension::Full(), ftxui::Dimension::Full());
    width_ = probe.dimx();
    height_ = probe.dimy();

    auto screen = ftxui::ScreenInteractive::TerminalOutput();
    screen_ = &screen;
    auto component = std::make_shared<TuiComponent>(this, &screen);

    std::string err;
    if (api_.Ping(&err)) {
        st.status = "已连接 " + api_.base_url();
    } else {
        st.status = "后端未连接: " + err + "  (" + api_.base_url() + ")";
    }
    LoadMods();
    // The permission mode gates every mutating action, so it is seeded from the
    // same .editor_ai.json the desktop frontend reads (GET /api/ai/settings).
    {
        std::string ac_err;
        st.permission_mode = api_.LoadPermissionMode(&ac_err);
    }

    screen.Loop(component);
}

void TuiApp::LoadMods() {
    std::string err;
    st.mods = api_.ListMods(&err);
    if (!err.empty()) {
        st.status = err;
        return;
    }
    st.mod_sel = st.ClampSel(st.mod_sel, static_cast<int>(st.mods.size()));
}

void TuiApp::RunIntent(Intent intent) {
    std::string err;
    switch (intent) {
        case Intent::RefreshMods:
            LoadMods();
            break;
        case Intent::SelectMod: {
            if (api_.SelectMod(st.selected_mod, &err)) {
                st.tables = api_.ListTables(&err);
                st.table_sel = 0;
                st.table = Table{};
                st.page = Page::Table;
                st.focus = Focus::Tables;  // browse starts on the tables pane
                st.status = err.empty() ? ("模组 " + st.selected_mod + " 共 " +
                                           std::to_string(st.tables.size()) + " 张表")
                                        : err;
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::RefreshTables:
            st.tables = api_.ListTables(&err);
            st.status = err;
            break;
        case Intent::LoadTable: {
            Table t;
            if (api_.LoadTable(st.table.name, t, &err)) {
                st.table = std::move(t);
                st.row_sel = 0;
                st.status = st.table.exists ? ("载入 " + std::to_string(st.table.rows.size()) + " 行")
                                            : "该表文件尚不存在（保存将新建）";
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::SearchTalk: {
            st.search.results = api_.SearchTalk(st.search.input, &err);
            st.search.busy = false;
            st.search.sel = 0;
            if (!err.empty()) {
                st.search.error = err;
                st.status = err;
            } else {
                st.status = "搜索到 " + std::to_string(st.search.results.size()) + " 条";
            }
            break;
        }
        case Intent::ValidateTable: {
            if (st.table.name.empty()) {
                st.validate.active = false;
                st.validate.busy = false;
                st.status = "先打开一张表";
                break;
            }
            Json data = TableDataForValidate(st.table.rows, st.table.edits, st.table.removes);
            ValidateResult r;
            if (api_.ValidateTable(st.table.name, data, &r, &err)) {
                st.validate.busy = false;
                st.validate.issues = std::move(r.issues);
                st.validate.errors = r.errors;
                st.validate.warns = r.warns;
                st.validate.infos = r.infos;
                st.status = "校验完成: error=" + std::to_string(r.errors) +
                            " warn=" + std::to_string(r.warns) +
                            " info=" + std::to_string(r.infos);
            } else {
                st.validate.busy = false;
                st.validate.error = err;
                st.status = err;
            }
            break;
        }
        case Intent::SaveTable: {
            auto orig = OrigMapFromRows(st.table.rows);
            Json body = BuildSaveBody(orig, st.table.edits, st.table.removes,
                                      st.table.mtime_ns, st.table.adds);
            if (force_save_) body["force"] = true;
            SaveResult r = api_.SaveTable(st.table.name, body, &err);
            switch (r.kind) {
                case SaveResult::Kind::Ok:
                    st.status = "已保存";
                    force_save_ = false;
                    {
                        Table t;
                        std::string e2;
                        if (api_.LoadTable(st.table.name, t, &e2)) st.table = std::move(t);
                        st.row_sel = 0;
                    }
                    break;
                case SaveResult::Kind::ConflictTable:
                case SaveResult::Kind::LossySource:
                    force_save_ = true;
                    st.status = r.message + "（再按 Ctrl-S 强制覆盖）";
                    break;
                default:
                    st.status = err.empty() ? r.message : err;
                    break;
            }
            break;
        }
        case Intent::ScanBugs:
            st.bugs = api_.ScanBugs(&err);
            st.bug_scanned = true;
            st.bug_sel = 0;
            st.status = err.empty() ? ("扫描到 " + std::to_string(st.bugs.size()) + " 条") : err;
            break;
        case Intent::FixBugs: {
            long long fixed = 0;
            if (api_.FixAllBugs(&fixed, &err)) {
                st.status = "已修复 " + std::to_string(fixed) + " 条，重扫中…";
                st.bugs = api_.ScanBugs(&err);
                st.bug_scanned = true;
                st.bug_sel = 0;
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::SendChat: {
            std::string reply = agent_.SendTurn(kSystemPrompt, st.chat, &err);
            st.chat_busy = false;
            if (!err.empty()) {
                st.status = err;
            } else {
                st.chat.push_back(ChatMsg{"assistant", reply});
                SaveSession(data_root_, session_id_, st.chat);
                st.status.clear();
            }
            break;
        }
        case Intent::RefreshPlugins:
            st.plugins = api_.ListPlugins(&err);
            st.plugins_loaded = true;
            st.plugin_sel = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
            st.status = err.empty() ? ("插件 " + std::to_string(st.plugins.size()) + " 个") : err;
            break;
        case Intent::InstallPlugin: {
            // The path lives in plugin_input (the state machine cleared only the
            // input *mode*); trim it again so a stray space never reaches the FS.
            const std::string path = Trim(st.plugin_input);
            if (path.empty()) {
                st.status = "输入插件 zip 路径";
                break;
            }
            std::string id;
            if (api_.InstallPlugin(path, &id, &err)) {
                st.plugins = api_.ListPlugins(&err);
                st.plugins_loaded = true;
                st.plugin_sel = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
                st.status = "已安装 " + (id.empty() ? path : id);
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::UninstallPlugin: {
            if (st.plugins.empty()) {
                st.status = "没有可卸载的插件";
                break;
            }
            const int pi = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
            const std::string id = st.plugins[pi].id;
            if (api_.UninstallPlugin(id, &err)) {
                st.plugins = api_.ListPlugins(&err);
                st.plugins_loaded = true;
                st.plugin_sel = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
                st.status = "已卸载 " + id;
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::ReloadPlugins: {
            std::vector<PluginEntry> list;
            if (api_.ReloadPlugins(&list, &err)) {
                st.plugins = std::move(list);
                st.plugins_loaded = true;
                st.plugin_sel = st.ClampSel(st.plugin_sel, static_cast<int>(st.plugins.size()));
                st.status = "已重载 " + std::to_string(st.plugins.size()) + " 个插件";
            } else {
                st.status = err;
            }
            break;
        }
        case Intent::RefreshCloudProviders:
            st.providers = api_.ListCloudProviders(&err);
            st.providers_loaded = true;
            st.provider_sel = st.ClampSel(st.provider_sel, static_cast<int>(st.providers.size()));
            st.status =
                err.empty() ? ("Provider " + std::to_string(st.providers.size()) + " 个") : err;
            break;
        case Intent::LoadCloudFiles: {
            st.cloud_error.clear();
            std::string e_local, e_remote;
            st.cloud_local = api_.CloudLocalFiles(st.selected_mod, &e_local);
            st.cloud_remote.clear();
            if (!st.providers.empty()) {
                const int pi = st.ClampSel(st.provider_sel, static_cast<int>(st.providers.size()));
                st.cloud_remote = api_.CloudRemoteFiles(st.providers[pi].id, st.selected_mod,
                                                       &e_remote);
            }
            st.cloud_files_loaded = true;
            // The local failure is fatal-ish; a dead remote is informational
            // (the desktop page shows it as a non-blocking empty state too).
            st.cloud_error = !e_local.empty() ? e_local : e_remote;
            st.status = "本地 " + std::to_string(st.cloud_local.size()) + " 个 / 远端 " +
                        std::to_string(st.cloud_remote.size()) + " 个";
            break;
        }
        case Intent::CloudTest: {
            if (st.providers.empty()) {
                st.status = "没有可选 Provider";
                break;
            }
            const int pi = st.ClampSel(st.provider_sel, static_cast<int>(st.providers.size()));
            st.status = api_.CloudTest(st.providers[pi].id, &err) ? "连接测试通过" : err;
            break;
        }
        case Intent::CloudSync: {
            if (st.providers.empty()) {
                st.status = "没有可选 Provider";
                break;
            }
            const int pi = st.ClampSel(st.provider_sel, static_cast<int>(st.providers.size()));
            CloudSyncSummary sum =
                api_.CloudSync(st.providers[pi].id, st.cloud_direction, st.selected_mod,
                               st.cloud_dry_run, st.cloud_delete_extra, /*full=*/true, &err);
            st.cloud_error = err;
            st.cloud_sync_summary = std::string(sum.dry_run ? "DRY-RUN " : "") + "方向 " +
                                    sum.direction + "  共 " + std::to_string(sum.total) +
                                    "  上传 " + std::to_string(sum.uploaded) + "  下载 " +
                                    std::to_string(sum.downloaded) + "  跳过 " +
                                    std::to_string(sum.skipped) + "  失败 " +
                                    std::to_string(sum.failed);
            if (!sum.message.empty()) st.cloud_sync_summary += "  (" + sum.message + ")";
            st.status = st.cloud_sync_summary;
            break;
        }
        case Intent::LoadAiSettings:
            st.permission_mode = api_.LoadPermissionMode(&err);
            break;
        case Intent::SetPermissionMode: {
            std::string e2;
            if (!api_.SavePermissionMode(st.permission_mode, &e2)) st.status = e2;
            break;
        }
        case Intent::Quit:
        case Intent::None:
            break;
    }
}

KeyInput TuiApp::MapEventPublic(const ftxui::Event& e) const { return MapEvent(e); }

KeyInput TuiApp::MapEvent(const ftxui::Event& e) const {
    using ftxui::Event;
    auto mk = [](KeyInput::Kind kind) {
        KeyInput k;
        k.kind = kind;
        return k;
    };
    if (e == Event::ArrowUp) return mk(KeyInput::Up);
    if (e == Event::ArrowDown) return mk(KeyInput::Down);
    if (e == Event::ArrowLeft) return mk(KeyInput::Left);
    if (e == Event::ArrowRight) return mk(KeyInput::Right);
    if (e == Event::Return) return mk(KeyInput::Enter);
    if (e == Event::Escape) return mk(KeyInput::Escape);
    if (e == Event::Backspace) return mk(KeyInput::Backspace);
    if (e == Event::Tab) return mk(KeyInput::Tab);
    if (e == Event::Home) return mk(KeyInput::Home);
    if (e == Event::End) return mk(KeyInput::End);
    if (e == Event::PageUp) return mk(KeyInput::PageUp);
    if (e == Event::PageDown) return mk(KeyInput::PageDown);

    // Control letters arrive as a single byte in 0x01..0x1A (Ctrl+letter).
    if (!e.is_character() && e.input().size() == 1) {
        unsigned char b = static_cast<unsigned char>(e.input()[0]);
        if (b >= 1 && b <= 26) {
            KeyInput k = mk(KeyInput::CtrlChar);
            k.ctrl = static_cast<char>('a' + (b - 1));
            return k;
        }
    }
    if (e.is_character()) {
        KeyInput k = mk(KeyInput::Char);
        k.text = e.character();
        return k;
    }
    return mk(KeyInput::None);
}

AppState TuiApp::SampleState(Page page) {
    AppState s;
    s.page = page;
    s.mods = {ModEntry{"DemoMod", "mods/DemoMod"}, ModEntry{"Another", "mods/Another"}};
    s.selected_mod = "DemoMod";
    s.tables = {"TalkCfg", "ItemCfg", "PersonCfg", "EvtCfg"};
    s.table = Table{};
    s.table.name = "TalkCfg";
    s.table.exists = true;
    s.table.mtime_ns = 1700000000000000000LL;
    s.table.rows = {TableRow{"1", "你好，同学", "\"你好，同学\""},
                    TableRow{"2", "今天天气不错", "\"今天天气不错\""}};
    s.table.edits["2"] = "\"今天下雨了\"";
    s.focus = Focus::Rows;
    s.bugs = {BugEntry{"TalkCfg", "5", "roleIds", "REF", "引用了不存在的角色 ID 999"},
              BugEntry{"ItemCfg", "12", "icon", "SCHEMA_HEAL", "字段应为数组 []"} };
    s.bug_scanned = true;
    s.chat = {ChatMsg{"user", "帮我看看 TalkCfg 的第一句"},
              ChatMsg{"assistant", "第一句对白内容为「你好，同学」，说话人角色已配置。"}};
    s.plugins = {PluginEntry{"demo", "Demo Plugin", "1.2.3", "me", "示例插件", "", true},
                 PluginEntry{"broken", "Broken", "", "", "", "manifest 解析失败", false}};
    s.plugins_loaded = true;
    s.providers = {CloudProvider{"p_1", "我的网盘", "webdav", "mods"},
                   CloudProvider{"p_2", "本地目录", "local", "mods"}};
    s.providers_loaded = true;
    s.cloud_local = {CloudFile{"Cfgs/zh-cn/TalkCfg.json", false, 128},
                     CloudFile{"Cfgs/zh-cn/EvtCfg.json", false, 256}};
    s.cloud_remote = {CloudFile{"mods/DemoMod/Cfgs/zh-cn/TalkCfg.json", false, 128}};
    s.cloud_files_loaded = true;
    s.cloud_sync_summary = "DRY-RUN 方向 upload  共 2  上传 1  下载 0  跳过 1  失败 0";
    s.status = "示例数据（--render-check）";
    if (page == Page::Table) s.editing = false;
    return s;
}

}  // namespace p8
