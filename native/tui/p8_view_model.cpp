// native/tui/p8_view_model.cpp — the headless TUI state machine.
//
// Everything here is a pure function of (AppState, KeyInput): it mutates only
// navigation/selection/edit state and returns an Intent describing the single
// side-effect the interactive caller must perform (an HTTP or agent round-trip).
// This separation is why the whole panel is unit-testable without a terminal or
// a live backend.
#include "p8_model.h"

#include <algorithm>
#include <cctype>

namespace p8 {

namespace {

// Strip the last UTF-8 code point from `s` (Python's str[:-1] on a decoded char).
void PopCodepoint(std::string& s) {
    if (s.empty()) return;
    size_t i = s.size();
    // A continuation byte is 0b10xxxxxx.
    while (i > 1 && (static_cast<unsigned char>(s[i - 1]) & 0xC0) == 0x80) --i;
    s.erase(i);
}

bool CaseInsensitiveContains(const std::string& hay, const std::string& needle) {
    if (needle.empty()) return true;
    auto lower = [](std::string x) {
        for (auto& c : x) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return x;
    };
    return lower(hay).find(lower(needle)) != std::string::npos;
}

int SelectedVisibleIndex(const AppState& s) {
    auto vis = s.VisibleRows();
    if (vis.empty()) return -1;
    int idx = std::clamp(s.row_sel, 0, static_cast<int>(vis.size()) - 1);
    return vis[idx];
}

}  // namespace

int AppState::ClampSel(int sel, int count) const {
    if (count <= 0) return 0;
    return std::clamp(sel, 0, count - 1);
}

std::vector<int> AppState::VisibleRows() const {
    std::vector<int> out;
    for (int i = 0; i < static_cast<int>(table.rows.size()); ++i) {
        const auto& row = table.rows[i];
        if (CaseInsensitiveContains(row.key, filter) ||
            CaseInsensitiveContains(row.preview, filter)) {
            out.push_back(i);
        }
    }
    return out;
}

Intent HandleKey(AppState& s, const KeyInput& k) {
    if (k.kind == KeyInput::CtrlChar) {
        switch (k.ctrl) {
            case 'q':
                return Intent::Quit;
            case 'd':
                s.page = Page::Mods;
                s.status = "选择模组";
                return Intent::RefreshMods;
            case 't':
                s.page = Page::Tables;
                return Intent::RefreshTables;
            case 'b':
                s.page = Page::Bugfix;
                return Intent::ScanBugs;
            case 'a':
                s.page = Page::Agent;
                return Intent::None;
            default:
                break;  // Ctrl-S / Ctrl-R fall through to page-specific handling
        }
    }

    if (k.kind == KeyInput::Char && k.text == "?") {
        s.show_help = !s.show_help;
        return Intent::None;
    }
    if (s.show_help) {  // any other key first dismisses the help overlay
        s.show_help = false;
        if (k.kind != KeyInput::None) return Intent::None;
    }

    switch (s.page) {
        case Page::Mods: {
            switch (k.kind) {
                case KeyInput::Up:
                    s.mod_sel = s.ClampSel(s.mod_sel - 1, static_cast<int>(s.mods.size()));
                    return Intent::None;
                case KeyInput::Down:
                    s.mod_sel = s.ClampSel(s.mod_sel + 1, static_cast<int>(s.mods.size()));
                    return Intent::None;
                case KeyInput::Enter:
                    if (s.mods.empty()) {
                        s.status = "没有可用模组";
                        return Intent::None;
                    }
                    s.selected_mod = s.mods[s.ClampSel(s.mod_sel, static_cast<int>(s.mods.size()))].name;
                    s.status = "加载中模组: " + s.selected_mod;
                    return Intent::SelectMod;
                case KeyInput::Char:
                    if (k.text == "r") return Intent::RefreshMods;
                    return Intent::None;
                case KeyInput::Escape:
                    return Intent::Quit;  // top-level
                default:
                    return Intent::None;
            }
        }
        case Page::Tables: {
            std::vector<std::string> shown;
            for (const auto& t : s.tables)
                if (CaseInsensitiveContains(t, s.table_filter)) shown.push_back(t);
            switch (k.kind) {
                case KeyInput::Up:
                    s.table_sel = s.ClampSel(s.table_sel - 1, static_cast<int>(shown.size()));
                    return Intent::None;
                case KeyInput::Down:
                    s.table_sel = s.ClampSel(s.table_sel + 1, static_cast<int>(shown.size()));
                    return Intent::None;
                case KeyInput::Enter:
                    if (shown.empty()) return Intent::None;
                    s.table = Table{};
                    s.table.name = shown[s.ClampSel(s.table_sel, static_cast<int>(shown.size()))];
                    s.editing = false;
                    s.filter.clear();
                    s.row_sel = 0;
                    s.page = Page::Table;
                    s.status = "加载 " + s.table.name;
                    return Intent::LoadTable;
                case KeyInput::Backspace:
                    PopCodepoint(s.table_filter);
                    s.table_sel = 0;
                    return Intent::None;
                case KeyInput::Char:
                    if (k.text == "r") return Intent::RefreshTables;
                    s.table_filter += k.text;
                    s.table_sel = 0;
                    return Intent::None;
                case KeyInput::Escape:
                    s.page = Page::Mods;
                    return Intent::None;
                default:
                    return Intent::None;
            }
        }
        case Page::Table: {
            auto vis = s.VisibleRows();
            if (s.editing) {
                switch (k.kind) {
                    case KeyInput::Enter: {
                        int ri = SelectedVisibleIndex(s);
                        if (ri >= 0) s.table.edits[s.table.rows[ri].key] = s.edit_buffer;
                        s.editing = false;
                        s.status = "标记修改（Ctrl-S 保存）";
                        return Intent::None;
                    }
                    case KeyInput::Escape:
                        s.editing = false;
                        return Intent::None;
                    case KeyInput::Backspace:
                        PopCodepoint(s.edit_buffer);
                        return Intent::None;
                    case KeyInput::Char:
                        s.edit_buffer += k.text;
                        return Intent::None;
                    default:
                        return Intent::None;
                }
            }
            switch (k.kind) {
                case KeyInput::Up:
                    s.row_sel = s.ClampSel(s.row_sel - 1, static_cast<int>(vis.size()));
                    return Intent::None;
                case KeyInput::Down:
                    s.row_sel = s.ClampSel(s.row_sel + 1, static_cast<int>(vis.size()));
                    return Intent::None;
                case KeyInput::Enter: {
                    int ri = SelectedVisibleIndex(s);
                    if (ri < 0) return Intent::None;
                    s.editing = true;
                    s.edit_buffer = s.table.rows[ri].raw;
                    return Intent::None;
                }
                case KeyInput::Char:
                    if (k.text == "d") {
                        int ri = SelectedVisibleIndex(s);
                        if (ri >= 0) {
                            const std::string& key = s.table.rows[ri].key;
                            s.table.removes.push_back(key);
                            s.table.edits.erase(key);
                            s.status = "标记删除: " + key;
                        }
                        return Intent::None;
                    }
                    if (k.text == "r") return Intent::LoadTable;
                    // Filter typing (anything that is not a command char).
                    s.filter += k.text;
                    s.row_sel = 0;
                    return Intent::None;
                case KeyInput::Backspace:
                    PopCodepoint(s.filter);
                    s.row_sel = 0;
                    return Intent::None;
                case KeyInput::CtrlChar:
                    if (k.ctrl == 's') {
                        if (s.table.edits.empty() && s.table.removes.empty()) {
                            s.status = "无改动";
                            return Intent::None;
                        }
                        return Intent::SaveTable;
                    }
                    return Intent::None;
                case KeyInput::Escape:
                    s.editing = false;
                    s.page = Page::Tables;
                    return Intent::None;
                default:
                    return Intent::None;
            }
        }
        case Page::Bugfix: {
            switch (k.kind) {
                case KeyInput::Up:
                    s.bug_sel = s.ClampSel(s.bug_sel - 1, static_cast<int>(s.bugs.size()));
                    return Intent::None;
                case KeyInput::Down:
                    s.bug_sel = s.ClampSel(s.bug_sel + 1, static_cast<int>(s.bugs.size()));
                    return Intent::None;
                case KeyInput::Char:
                    if (k.text == "r" || k.text == "s") return Intent::ScanBugs;
                    if (k.text == "f") return Intent::FixBugs;
                    return Intent::None;
                case KeyInput::CtrlChar:
                    if (k.ctrl == 'r') return Intent::ScanBugs;
                    if (k.ctrl == 's') return Intent::FixBugs;
                    return Intent::None;
                case KeyInput::Escape:
                    s.page = Page::Tables;
                    return Intent::None;
                default:
                    return Intent::None;
            }
        }
        case Page::Agent: {
            switch (k.kind) {
                case KeyInput::Enter: {
                    std::string trimmed = s.chat_input;
                    while (!trimmed.empty() && (trimmed.back() == ' ')) trimmed.pop_back();
                    if (trimmed.empty()) {
                        s.status = "输入为空";
                        return Intent::None;
                    }
                    s.chat.push_back(ChatMsg{"user", s.chat_input});
                    s.chat_input.clear();
                    s.chat_busy = true;
                    return Intent::SendChat;
                }
                case KeyInput::Backspace:
                    PopCodepoint(s.chat_input);
                    return Intent::None;
                case KeyInput::Char:
                    s.chat_input += k.text;
                    return Intent::None;
                case KeyInput::Escape:
                    s.page = Page::Tables;
                    return Intent::None;
                default:
                    return Intent::None;
            }
        }
    }
    return Intent::None;
}

}  // namespace p8
