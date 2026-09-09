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
                st.page = Page::Tables;
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
        case Intent::SaveTable: {
            auto orig = OrigMapFromRows(st.table.rows);
            Json body = BuildSaveBody(orig, st.table.edits, st.table.removes, st.table.mtime_ns);
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
    s.bugs = {BugEntry{"TalkCfg", "5", "roleIds", "REF", "引用了不存在的角色 ID 999"},
              BugEntry{"ItemCfg", "12", "icon", "SCHEMA_HEAL", "字段应为数组 []"} };
    s.bug_scanned = true;
    s.chat = {ChatMsg{"user", "帮我看看 TalkCfg 的第一句"},
              ChatMsg{"assistant", "第一句对白内容为「你好，同学」，说话人角色已配置。"}};
    s.status = "示例数据（--render-check）";
    if (page == Page::Table) s.editing = false;
    return s;
}

}  // namespace p8
