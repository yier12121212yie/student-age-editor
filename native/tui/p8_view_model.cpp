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
#include <utility>

#include "p8_cfg.h"

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

// Raw JSON text of the selected row: the pending edit wins over the base row.
// Returns false when the selection is empty or the row is queued for removal.
bool CurrentRowRaw(AppState& s, std::string* key_out, std::string* raw_out) {
    int ri = SelectedVisibleIndex(s);
    if (ri < 0) return false;
    const std::string& key = s.table.rows[ri].key;
    if (std::find(s.table.removes.begin(), s.table.removes.end(), key) != s.table.removes.end()) {
        s.status = "该行已标记删除（再按 d 取消）";
        return false;
    }
    auto it = s.table.edits.find(key);
    if (key_out) *key_out = key;
    if (raw_out) *raw_out = it != s.table.edits.end() ? it->second : s.table.rows[ri].raw;
    return true;
}

void AppendRow(AppState& s, const std::string& key, const std::string& raw) {
    Json v = Json::parse(raw, nullptr, /*allow_exceptions=*/false);
    s.table.rows.push_back(TableRow{key, v.is_discarded() ? raw : ValuePreview(v), raw});
    s.table.edits[key] = raw;
    s.table.adds.push_back(key);
    // The selection index addresses visible rows: clear the filter so the new
    // row is visible and the editor / d / y target it, not a clamped neighbour.
    s.filter.clear();
    s.row_sel = static_cast<int>(s.table.rows.size()) - 1;
}

// ---- overlay key handling -------------------------------------------------

Intent HandleSearchOverlay(AppState& s, const KeyInput& k) {
    switch (k.kind) {
        case KeyInput::Enter:
            if (s.search.input.empty()) {
                s.status = "输入搜索关键词";
                return Intent::None;
            }
            s.search.busy = true;
            s.search.error.clear();
            return Intent::SearchTalk;
        case KeyInput::Escape:
            s.search.active = false;
            return Intent::None;
        case KeyInput::Up:
            s.search.sel = s.ClampSel(s.search.sel - 1, static_cast<int>(s.search.results.size()));
            return Intent::None;
        case KeyInput::Down:
            s.search.sel = s.ClampSel(s.search.sel + 1, static_cast<int>(s.search.results.size()));
            return Intent::None;
        case KeyInput::Backspace:
            PopCodepoint(s.search.input);
            return Intent::None;
        case KeyInput::Char:
            s.search.input += k.text;
            return Intent::None;
        default:
            return Intent::None;
    }
}

// The validation result overlay is read-only: any key dismisses it.
Intent HandleValidateOverlay(AppState& s, const KeyInput&) {
    s.validate.active = false;
    return Intent::None;
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

std::vector<int> AppState::VisibleTables() const {
    std::vector<int> out;
    for (int i = 0; i < static_cast<int>(tables.size()); ++i)
        if (CaseInsensitiveContains(tables[i], table_filter)) out.push_back(i);
    return out;
}

Intent HandleKey(AppState& s, const KeyInput& k) {
    if (k.kind == KeyInput::CtrlChar) {
        // Page jumps never carry transient edit state or the validation overlay
        // across (the search overlay is re-openable and Esc-dismissable).
        if (k.ctrl == 'd' || k.ctrl == 't' || k.ctrl == 'b' || k.ctrl == 'a') {
            s.editing = false;
            s.editing_field = false;
            s.validate.active = false;
        }
        switch (k.ctrl) {
            case 'q':
                return Intent::Quit;
            case 'd':
                s.page = Page::Mods;
                s.status = "选择模组";
                return Intent::RefreshMods;
            case 't':
                s.page = Page::Table;
                s.focus = s.table.name.empty() ? Focus::Tables : s.focus;
                return Intent::RefreshTables;
            case 'b':
                s.page = Page::Bugfix;
                return Intent::ScanBugs;
            case 'a':
                s.page = Page::Agent;
                return Intent::None;
            case 'k':
                s.show_help = false;
                s.search.active = true;
                s.search.busy = false;
                s.search.sel = 0;
                s.search.error.clear();
                return Intent::None;
            default:
                break;  // Ctrl-S / Ctrl-R fall through to page-specific handling
        }
    }

    // Ctrl-K opens the search overlay from anywhere (including the help view).
    if (s.search.active) return HandleSearchOverlay(s, k);
    if (s.validate.active) return HandleValidateOverlay(s, k);

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
        case Page::Table: {
            // Whole-row editor (raw JSON) — active regardless of pane focus.
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
            // Form-mode field editor (one field's JSON value).
            if (s.editing_field) {
                switch (k.kind) {
                    case KeyInput::Enter: {
                        std::string key, raw, out;
                        if (CurrentRowRaw(s, &key, &raw) &&
                            ApplyFieldEdit(raw, s.field_name, s.field_buffer, &out)) {
                            s.table.edits[key] = std::move(out);
                            s.status = "标记修改字段 " + s.field_name + "（Ctrl-S 保存）";
                        }
                        s.editing_field = false;
                        return Intent::None;
                    }
                    case KeyInput::Escape:
                        s.editing_field = false;
                        return Intent::None;
                    case KeyInput::Backspace:
                        PopCodepoint(s.field_buffer);
                        return Intent::None;
                    case KeyInput::Char:
                        s.field_buffer += k.text;
                        return Intent::None;
                    default:
                        return Intent::None;
                }
            }

            // Ctrl-S saves from any pane focus: the patch is table-wide.
            if (k.kind == KeyInput::CtrlChar) {
                if (k.ctrl == 's') {
                    if (s.table.edits.empty() && s.table.removes.empty() &&
                        s.table.adds.empty()) {
                        s.status = "无改动";
                        return Intent::None;
                    }
                    return Intent::SaveTable;
                }
                return Intent::None;
            }

            switch (s.focus) {
                case Focus::Tables: {
                    auto vis = s.VisibleTables();
                    switch (k.kind) {
                        case KeyInput::Up:
                            s.table_sel = s.ClampSel(s.table_sel - 1, static_cast<int>(vis.size()));
                            return Intent::None;
                        case KeyInput::Down:
                            s.table_sel = s.ClampSel(s.table_sel + 1, static_cast<int>(vis.size()));
                            return Intent::None;
                        case KeyInput::Enter: {
                            if (vis.empty()) return Intent::None;
                            int idx = vis[s.ClampSel(s.table_sel, static_cast<int>(vis.size()))];
                            s.table = Table{};
                            s.table.name = s.tables[idx];
                            s.focus = Focus::Rows;
                            s.editing = false;
                            s.editing_field = false;
                            s.filter.clear();
                            s.row_sel = 0;
                            s.detail_mode = DetailMode::Json;
                            s.field_sel = 0;
                            s.status = "加载 " + s.table.name;
                            return Intent::LoadTable;
                        }
                        case KeyInput::Char:
                            if (k.text == "r") return Intent::RefreshTables;
                            s.table_filter += k.text;
                            s.table_sel = 0;
                            return Intent::None;
                        case KeyInput::Backspace:
                            PopCodepoint(s.table_filter);
                            s.table_sel = 0;
                            return Intent::None;
                        case KeyInput::Tab:
                            s.focus = Focus::Rows;
                            return Intent::None;
                        case KeyInput::Escape:
                            s.page = Page::Mods;
                            return Intent::None;
                        default:
                            return Intent::None;
                    }
                }
                case Focus::Rows: {
                    auto vis = s.VisibleRows();
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
                            const std::string& key = s.table.rows[ri].key;
                            if (std::find(s.table.removes.begin(), s.table.removes.end(), key) !=
                                s.table.removes.end()) {
                                s.status = "该行已标记删除（再按 d 取消）";
                                return Intent::None;
                            }
                            auto it = s.table.edits.find(key);
                            s.editing = true;
                            s.edit_buffer = it != s.table.edits.end() ? it->second
                                                                      : s.table.rows[ri].raw;
                            return Intent::None;
                        }
                        case KeyInput::Char:
                            if (k.text == "d") {
                                int ri = SelectedVisibleIndex(s);
                                if (ri >= 0) {
                                    const std::string key = s.table.rows[ri].key;
                                    // A row appended this session never hit disk:
                                    // drop it outright instead of queueing a remove.
                                    auto added = std::find(s.table.adds.begin(),
                                                           s.table.adds.end(), key);
                                    if (added != s.table.adds.end()) {
                                        s.table.adds.erase(added);
                                        s.table.edits.erase(key);
                                        s.table.rows.erase(s.table.rows.begin() + ri);
                                        s.row_sel = s.ClampSel(
                                            s.row_sel, static_cast<int>(s.VisibleRows().size()));
                                        s.status = "撤销新增: " + key;
                                        return Intent::None;
                                    }
                                    auto found = std::find(s.table.removes.begin(),
                                                           s.table.removes.end(), key);
                                    if (found != s.table.removes.end()) {
                                        s.table.removes.erase(found);
                                        s.status = "取消删除: " + key;
                                    } else {
                                        s.table.removes.push_back(key);
                                        s.table.edits.erase(key);
                                        s.status = "标记删除: " + key;
                                    }
                                }
                                return Intent::None;
                            }
                            if (k.text == "n") {
                                std::string key = NextRowKey(s.table.rows);
                                AppendRow(s, key, "{}");
                                s.editing = true;
                                s.edit_buffer = "{}";
                                s.status = "新增行 " + key + "（Enter 确认，Ctrl-S 保存）";
                                return Intent::None;
                            }
                            if (k.text == "y") {
                                std::string key, raw;
                                if (!CurrentRowRaw(s, &key, &raw)) return Intent::None;
                                std::string dup = NextRowKey(s.table.rows);
                                AppendRow(s, dup, raw);
                                s.status = "复制 " + key + " → " + dup + "（Ctrl-S 保存）";
                                return Intent::None;
                            }
                            if (k.text == "r") return Intent::LoadTable;
                            if (k.text == "v") {
                                s.validate.active = true;
                                s.validate.busy = true;
                                s.validate.cfg = s.table.name;
                                s.validate.error.clear();
                                return Intent::ValidateTable;
                            }
                            // Filter typing (anything that is not a command char).
                            s.filter += k.text;
                            s.row_sel = 0;
                            return Intent::None;
                        case KeyInput::Backspace:
                            PopCodepoint(s.filter);
                            s.row_sel = 0;
                            return Intent::None;
                        case KeyInput::Tab:
                            s.focus = Focus::Detail;
                            s.field_sel = 0;
                            return Intent::None;
                        case KeyInput::Escape:
                            s.focus = Focus::Tables;
                            return Intent::None;
                        default:
                            return Intent::None;
                    }
                }
                case Focus::Detail: {
                    auto fields = [&s] {
                        std::string key, raw;
                        if (!CurrentRowRaw(s, &key, &raw)) return FormFields("");
                        return FormFields(raw);
                    }();
                    switch (k.kind) {
                        case KeyInput::Up:
                            s.field_sel = s.ClampSel(s.field_sel - 1, static_cast<int>(fields.size()));
                            return Intent::None;
                        case KeyInput::Down:
                            s.field_sel = s.ClampSel(s.field_sel + 1, static_cast<int>(fields.size()));
                            return Intent::None;
                        case KeyInput::Enter:
                            if (s.detail_mode == DetailMode::Json) {
                                s.detail_mode = DetailMode::Form;
                                return Intent::None;
                            }
                            if (s.field_sel < 0 ||
                                s.field_sel >= static_cast<int>(fields.size()))
                                return Intent::None;
                            s.editing_field = true;
                            s.field_name = fields[s.field_sel].first;
                            s.field_buffer = fields[s.field_sel].second;
                            return Intent::None;
                        case KeyInput::Char:
                            if (k.text == "m") {
                                s.detail_mode = s.detail_mode == DetailMode::Json
                                                    ? DetailMode::Form
                                                    : DetailMode::Json;
                                return Intent::None;
                            }
                            return Intent::None;
                        case KeyInput::Tab:
                            s.focus = Focus::Tables;
                            return Intent::None;
                        case KeyInput::Escape:
                            s.focus = Focus::Rows;
                            return Intent::None;
                        default:
                            return Intent::None;
                    }
                }
            }
            return Intent::None;
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
                    s.page = Page::Table;
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
                    s.page = Page::Table;
                    return Intent::None;
                default:
                    return Intent::None;
            }
        }
    }
    return Intent::None;
}

}  // namespace p8
