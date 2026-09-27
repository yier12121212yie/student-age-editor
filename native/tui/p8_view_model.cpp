// native/tui/p8_view_model.cpp — the headless TUI state machine.
//
// Everything here is a pure function of (AppState, KeyInput): it mutates only
// navigation/selection/edit state and returns an Intent describing the single
// side-effect the interactive caller must perform (an HTTP or agent round-trip).
// This separation is why the whole panel is unit-testable without a terminal or
// a live backend.
//
// Layout parity with the Alpha-v0.3 Python TUI: the home screen is the
// three-pane browser and the other surfaces (AI 助手 / 插件 / 云 / Bug 扫描)
// are centered modals, so `page` doubles as the modal selector. Command keys
// (a c p b q n N y d v r m …) are live while `/` filter mode is off; typing
// `/` enters the filter (Alpha's filter-input behaviour) and captures every
// keystroke until Enter (keep) or Esc (clear).
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
    // Walk back to the lead byte of the last code point: continuation bytes are
    // 0b10xxxxxx, so the loop stops at the first byte that is not one.
    size_t i = s.size();
    while (i > 1 && (static_cast<unsigned char>(s[i - 1]) & 0xC0) == 0x80) --i;
    s.erase(i - 1);
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

bool TableDirty(const AppState& s) {
    return !s.table.edits.empty() || !s.table.removes.empty() || !s.table.adds.empty();
}

// Any pending transient state (editors, filter capture) must not leak into a
// newly opened modal or across a quit — the Alpha closed its inputs the same way.
void ClearTransient(AppState& s) {
    s.editing = false;
    s.editing_field = false;
    s.filtering = false;
    s.mod_input_active = false;
    s.validate.active = false;
    s.plugin_input_active = false;
    s.confirm.active = false;
    s.confirm.pending = Intent::None;
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

// permissionMode gating (desktop parity). In "confirm" — the default the
// backend stores — every mutating action first raises the approval dialog; in
// "full" the action runs straight away. Either way this is a pure function of
// the view-model: the overlay carries the deferred intent as data.
Intent GateWrite(AppState& s, Intent want, std::string title, std::string detail) {
    if (s.permission_mode != "confirm") return want;
    s.confirm.active = true;
    s.confirm.title = std::move(title);
    s.confirm.detail = std::move(detail);
    s.confirm.pending = want;
    return Intent::None;
}

// y/Enter approves (and releases the deferred intent), n/Esc rejects.
Intent HandleConfirmOverlay(AppState& s, const KeyInput& k) {
    bool approve = false;
    switch (k.kind) {
        case KeyInput::Enter:
            approve = true;
            break;
        case KeyInput::Escape:
            approve = false;
            break;
        case KeyInput::Char:
            if (k.text == "y" || k.text == "Y") approve = true;
            else if (k.text == "n" || k.text == "N") approve = false;
            else return Intent::None;  // other keys are ignored while the box is up
            break;
        default:
            return Intent::None;
    }
    const std::string title = s.confirm.title;
    Intent pending = s.confirm.pending;
    s.confirm.active = false;
    s.confirm.pending = Intent::None;
    if (!approve) {
        s.status = "已拒绝: " + title;
        return Intent::None;
    }
    return pending;
}

std::string TrimAscii(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

// Open one of the Alpha modals (a/c/p/b). Closing them restores the browse
// view untouched, so modal state (selections, chat, provider cursor) persists.
Intent OpenModal(AppState& s, Page modal) {
    ClearTransient(s);
    s.page = modal;
    return Intent::None;
}

// The tree pane's navigation core, shared by the mod/cfg node keys.
Intent HandleTree(AppState& s, const KeyInput& k) {
    auto items = s.TreeItems();
    switch (k.kind) {
        case KeyInput::Up:
            if (!items.empty()) s.tree_sel = s.ClampSel(s.tree_sel - 1, static_cast<int>(items.size()));
            return Intent::None;
        case KeyInput::Down:
            if (!items.empty()) s.tree_sel = s.ClampSel(s.tree_sel + 1, static_cast<int>(items.size()));
            return Intent::None;
        case KeyInput::Right: {
            // Expand the node under the cursor; a collapsed unselected mod is
            // selected first (the backend only lists the selected mod's cfgs).
            if (items.empty()) return Intent::None;
            TreeItem it = items[s.ClampSel(s.tree_sel, static_cast<int>(items.size()))];
            if (it.table_index >= 0) return Intent::None;
            if (s.mods[it.mod_index].name != s.selected_mod) {
                s.selected_mod = s.mods[it.mod_index].name;
                s.mod_sel = it.mod_index;
                s.expanded_mod = it.mod_index;
                return Intent::SelectMod;
            }
            s.expanded_mod = it.mod_index;
            return Intent::None;
        }
        case KeyInput::Left: {
            if (items.empty()) return Intent::None;
            TreeItem it = items[s.ClampSel(s.tree_sel, static_cast<int>(items.size()))];
            if (it.table_index >= 0) {  // cfg node -> its mod node
                s.tree_sel = it.mod_index;
                return Intent::None;
            }
            if (s.expanded_mod == it.mod_index) s.expanded_mod = -1;
            return Intent::None;
        }
        case KeyInput::Enter: {
            if (items.empty()) {
                s.status = "没有可用模组";
                return Intent::None;
            }
            TreeItem it = items[s.ClampSel(s.tree_sel, static_cast<int>(items.size()))];
            if (it.table_index < 0) {
                // Mod node: select + expand; Enter again on the selected node
                // toggles the expansion like the Alpha tree did.
                if (s.mods[it.mod_index].name == s.selected_mod &&
                    s.expanded_mod == it.mod_index) {
                    s.expanded_mod = -1;
                    return Intent::None;
                }
                s.selected_mod = s.mods[it.mod_index].name;
                s.mod_sel = it.mod_index;
                s.expanded_mod = it.mod_index;
                s.status = "加载中模组: " + s.selected_mod;
                return Intent::SelectMod;
            }
            s.table = Table{};
            s.table.name = s.tables[it.table_index];
            s.focus = Focus::Rows;
            s.editing = false;
            s.editing_field = false;
            s.filter.clear();
            s.filtering = false;
            s.row_sel = 0;
            s.detail_mode = DetailMode::Json;
            s.field_sel = 0;
            s.status = "加载 " + s.table.name;
            return Intent::LoadTable;
        }
        case KeyInput::Char:
            if (k.text == "r") return Intent::RefreshMods;
            return Intent::None;
        default:
            return Intent::None;
    }
}

// Bug 扫描/修复 modal (b) — the Alpha had no such dialog, so the page's whole
// surface moved into the modal frame unchanged.
Intent HandleBugfixModal(AppState& s, const KeyInput& k) {
    switch (k.kind) {
        case KeyInput::Up:
            s.bug_sel = s.ClampSel(s.bug_sel - 1, static_cast<int>(s.bugs.size()));
            return Intent::None;
        case KeyInput::Down:
            s.bug_sel = s.ClampSel(s.bug_sel + 1, static_cast<int>(s.bugs.size()));
            return Intent::None;
        case KeyInput::Char:
            if (k.text == "r" || k.text == "s") return Intent::ScanBugs;
            if (k.text == "f")
                return GateWrite(s, Intent::FixBugs, "修复全部 Bug",
                                 "模组 " + s.selected_mod + "  共 " +
                                     std::to_string(s.bugs.size()) + " 条");
            return Intent::None;
        case KeyInput::CtrlChar:
            if (k.ctrl == 'r') return Intent::ScanBugs;
            if (k.ctrl == 's')
                return GateWrite(s, Intent::FixBugs, "修复全部 Bug",
                                 "模组 " + s.selected_mod + "  共 " +
                                     std::to_string(s.bugs.size()) + " 条");
            return Intent::None;
        case KeyInput::Escape:
            s.page = Page::Main;
            return Intent::None;
        default:
            return Intent::None;
    }
}

Intent HandleAgentModal(AppState& s, const KeyInput& k) {
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
            s.page = Page::Main;
            return Intent::None;
        default:
            return Intent::None;
    }
}

Intent HandlePluginsModal(AppState& s, const KeyInput& k) {
    // `i` opens a one-line path prompt; nothing touches the filesystem
    // until Enter, and the install itself is confirmation-gated.
    if (s.plugin_input_active) {
        switch (k.kind) {
            case KeyInput::Enter: {
                std::string path = TrimAscii(s.plugin_input);
                if (path.empty()) {
                    s.status = "输入插件 zip 路径";
                    return Intent::None;
                }
                s.plugin_input_active = false;
                return GateWrite(s, Intent::InstallPlugin, "安装插件", path);
            }
            case KeyInput::Escape:
                s.plugin_input_active = false;
                s.status = "已取消安装";
                return Intent::None;
            case KeyInput::Backspace:
                PopCodepoint(s.plugin_input);
                return Intent::None;
            case KeyInput::Char:
                s.plugin_input += k.text;
                return Intent::None;
            default:
                return Intent::None;
        }
    }
    switch (k.kind) {
        case KeyInput::Up:
            s.plugin_sel = s.ClampSel(s.plugin_sel - 1, static_cast<int>(s.plugins.size()));
            return Intent::None;
        case KeyInput::Down:
            s.plugin_sel = s.ClampSel(s.plugin_sel + 1, static_cast<int>(s.plugins.size()));
            return Intent::None;
        case KeyInput::Char:
            if (k.text == "r") return Intent::RefreshPlugins;
            if (k.text == "R") return Intent::ReloadPlugins;
            if (k.text == "i") {
                s.plugin_input_active = true;
                s.plugin_input.clear();
                s.status = "输入插件 zip 路径，Enter 安装，Esc 取消";
                return Intent::None;
            }
            if (k.text == "u") {
                if (s.plugins.empty()) {
                    s.status = "没有可卸载的插件";
                    return Intent::None;
                }
                int pi = s.ClampSel(s.plugin_sel, static_cast<int>(s.plugins.size()));
                return GateWrite(s, Intent::UninstallPlugin, "卸载插件", s.plugins[pi].id);
            }
            return Intent::None;
        case KeyInput::Escape:
            s.page = Page::Main;
            return Intent::None;
        default:
            return Intent::None;
    }
}

Intent HandleCloudModal(AppState& s, const KeyInput& k) {
    switch (k.kind) {
        case KeyInput::Up:
            s.provider_sel = s.ClampSel(s.provider_sel - 1, static_cast<int>(s.providers.size()));
            return Intent::None;
        case KeyInput::Down:
            s.provider_sel = s.ClampSel(s.provider_sel + 1, static_cast<int>(s.providers.size()));
            return Intent::None;
        case KeyInput::Enter:
            if (s.providers.empty()) {
                s.status = "没有云盘 Provider（先 cloud add）";
                return Intent::None;
            }
            s.status = "读取本地/远端文件列表…";
            return Intent::LoadCloudFiles;
        case KeyInput::Char:
            if (k.text == "r") return Intent::RefreshCloudProviders;
            if (k.text == "t") {
                if (s.providers.empty()) {
                    s.status = "没有可选 Provider";
                    return Intent::None;
                }
                return Intent::CloudTest;
            }
            if (k.text == "y") {
                s.cloud_dry_run = !s.cloud_dry_run;
                s.status = std::string("DryRun: ") +
                           (s.cloud_dry_run ? "开（只预览不写入）" : "关（会真实写盘）");
                return Intent::None;
            }
            if (k.text == "x") {
                s.cloud_delete_extra = !s.cloud_delete_extra;
                s.status = std::string("清理远端多余: ") + (s.cloud_delete_extra ? "开" : "关");
                return Intent::None;
            }
            if (k.text == "u" || k.text == "d" || k.text == "b") {
                s.cloud_direction = k.text == "u"   ? "upload"
                                    : k.text == "d" ? "download"
                                                    : "sync";
                s.status = "方向: " + s.cloud_direction;
                return Intent::None;
            }
            if (k.text == "s") {
                if (s.providers.empty()) {
                    s.status = "没有可选 Provider";
                    return Intent::None;
                }
                // A dry run mutates nothing, so it never needs approval.
                if (s.cloud_dry_run) return Intent::CloudSync;
                return GateWrite(s, Intent::CloudSync, "云同步",
                                 "方向 " + s.cloud_direction + "  模组 " + s.selected_mod);
            }
            return Intent::None;
        case KeyInput::Escape:
            s.page = Page::Main;
            return Intent::None;
        default:
            return Intent::None;
    }
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

std::vector<TreeItem> AppState::TreeItems() const {
    std::vector<TreeItem> out;
    for (int i = 0; i < static_cast<int>(mods.size()); ++i) {
        out.push_back(TreeItem{i, -1});
        // Only the selected mod has a cfg list (GET /api/cfg is per-selection),
        // so only that node can render children.
        if (expanded_mod == i && mods[i].name == selected_mod)
            for (int t : VisibleTables()) out.push_back(TreeItem{i, t});
    }
    return out;
}

// ---- no-code field suggestions (live during editing_field) ----------------

std::string SlotPrompt(const SuggestionSlot& slot) {
    return slot.label.empty() ? slot.name : slot.label;
}

// Does this slot have a lookup list (dict pool / role directory)?
bool SlotHasEntries(const SuggestionSlot& slot) {
    return slot.kind == "dict" && !SlotPoolDictKey(slot.dict).empty();
}

// Begin the slot fill-in sub-list for candidate `si` (index into sug.all).
Intent EnterSlotMode(AppState& s, int si) {
    FieldSuggestState& sg = s.sug;
    sg.slot_mode = true;
    sg.cand = si;
    sg.slot_i = 0;
    sg.slot_q.clear();
    sg.slot_values.clear();
    sg.slot_entries.clear();
    sg.entry_shown.clear();
    sg.entry_sel = 0;
    const SuggestionSlot& slot = sg.all[si].slots[0];
    s.status = SlotHasEntries(slot) ? ("选择" + SlotPrompt(slot))
                                    : ("输入" + SlotPrompt(slot) + "（Enter 下一槽）");
    return SlotHasEntries(slot) ? Intent::FetchSlotEntries : Intent::None;
}

// Accept the highlighted candidate: insert the code, or — when it still has
// parameter slots — open the secondary fill-in list instead.
Intent AcceptSuggestion(AppState& s) {
    FieldSuggestState& sg = s.sug;
    if (sg.shown.empty()) return Intent::None;
    const int si = sg.shown[std::clamp(sg.sel, 0, static_cast<int>(sg.shown.size()) - 1)];
    const FieldSuggestion& cand = sg.all[si];
    if (!cand.slots.empty() && s.no_code_mode) return EnterSlotMode(s, si);
    s.field_buffer = MergeCodeIntoBuffer(s.field_buffer, cand.code);
    sg.pending_kind = sg.mode == "role" ? "role" : sg.mode;
    sg.pending_key = cand.template_.empty() ? cand.code : cand.template_;
    sg.active = false;
    sg.query.clear();
    sg.shown.clear();
    sg.sel = 0;
    s.status = "已补全: " + cand.code + "（Enter 应用，Ctrl-S 保存）";
    return Intent::ReportUsage;
}

// One slot of the fill-in flow: type filters the entry list, Enter advances,
// Esc cancels the whole candidate (buffer untouched).
Intent HandleSlotEditor(AppState& s, const KeyInput& k) {
    FieldSuggestState& sg = s.sug;
    const std::vector<SuggestionSlot>& slots = sg.all[sg.cand].slots;
    if (sg.slot_i >= static_cast<int>(slots.size())) {
        sg.slot_mode = false;
        return Intent::None;
    }
    const SuggestionSlot& slot = slots[sg.slot_i];
    const bool list = !sg.slot_entries.empty();
    auto refilter = [&sg] {
        sg.entry_shown = FilterEntries(sg.slot_entries, sg.slot_q);
        sg.entry_sel = 0;
    };
    switch (k.kind) {
        case KeyInput::Up:
        case KeyInput::ShiftTab:
            if (list && !sg.entry_shown.empty())
                sg.entry_sel =
                    (sg.entry_sel + static_cast<int>(sg.entry_shown.size()) - 1) %
                    static_cast<int>(sg.entry_shown.size());
            return Intent::None;
        case KeyInput::Down:
        case KeyInput::Tab:
            if (list && !sg.entry_shown.empty())
                sg.entry_sel = (sg.entry_sel + 1) % static_cast<int>(sg.entry_shown.size());
            return Intent::None;
        case KeyInput::Enter: {
            std::string value;
            if (list) {
                if (sg.entry_shown.empty()) {
                    s.status = "无匹配项：清空重打，或 Esc 取消补全";
                    return Intent::None;
                }
                value = sg.slot_entries[sg.entry_shown[std::clamp(
                    sg.entry_sel, 0, static_cast<int>(sg.entry_shown.size()) - 1)]]
                            .first;
            } else {
                value = sg.slot_q;
                while (!value.empty() && value.back() == ' ') value.pop_back();
                if (value.empty()) {
                    s.status = "输入" + SlotPrompt(slot) + "（Enter 下一槽，Esc 取消）";
                    return Intent::None;
                }
            }
            sg.slot_values[slot.name] = value;
            ++sg.slot_i;
            sg.slot_q.clear();
            sg.slot_entries.clear();
            sg.entry_shown.clear();
            sg.entry_sel = 0;
            if (sg.slot_i < static_cast<int>(slots.size())) {
                const SuggestionSlot& nx = slots[sg.slot_i];
                s.status = SlotHasEntries(nx) ? ("选择" + SlotPrompt(nx))
                                              : ("输入" + SlotPrompt(nx) + "（Enter 下一槽）");
                return SlotHasEntries(nx) ? Intent::FetchSlotEntries : Intent::None;
            }
            const FieldSuggestion& cand = sg.all[sg.cand];
            const std::string code =
                AssembleEffectCode(cand.template_.empty() ? cand.code : cand.template_,
                                   cand.slots, sg.slot_values);
            s.field_buffer = MergeCodeIntoBuffer(s.field_buffer, code);
            sg.pending_kind = sg.mode == "role" ? "role" : sg.mode;
            sg.pending_key = cand.template_.empty() ? cand.code : cand.template_;
            sg.slot_mode = false;
            sg.active = false;
            sg.query.clear();
            sg.shown.clear();
            sg.slot_values.clear();
            s.status = "已补全: " + code + "（Enter 应用，Ctrl-S 保存）";
            return Intent::ReportUsage;
        }
        case KeyInput::Escape:
            sg.slot_mode = false;
            sg.active = false;
            sg.query.clear();
            sg.shown.clear();
            sg.slot_q.clear();
            sg.slot_values.clear();
            s.status = "已取消补全";
            return Intent::None;
        case KeyInput::Backspace:
            PopCodepoint(sg.slot_q);
            refilter();
            return Intent::None;
        case KeyInput::Char:
            sg.slot_q += k.text;
            refilter();
            return Intent::None;
        default:
            return Intent::None;
    }
}

Intent HandleKey(AppState& s, const KeyInput& k) {
    if (k.kind == KeyInput::CtrlChar) {
        switch (k.ctrl) {
            case 'q':
                ClearTransient(s);
                return Intent::Quit;
            case 'm':
                // Desktop parity: the AI panel's permission-mode quick toggle.
                s.permission_mode = s.permission_mode == "confirm" ? "full" : "confirm";
                s.status = std::string("权限模式: ") +
                           (s.permission_mode == "confirm" ? "confirm（变更前确认）"
                                                           : "full（不再确认）");
                return Intent::SetPermissionMode;
            case 'n':
                // Shared editor setting (backend /api/settings/editor): pick
                // effects/roles from lists instead of hand-writing code DSL.
                s.no_code_mode = !s.no_code_mode;
                if (!s.no_code_mode) s.sug = FieldSuggestState{};
                s.status = std::string("无代码模式: ") +
                           (s.no_code_mode ? "开（选效果/人物）" : "关（手输代码）");
                return Intent::SetNoCodeMode;
            case 'k':
                s.show_help = false;
                ClearTransient(s);
                s.search.active = true;
                s.search.busy = false;
                s.search.sel = 0;
                s.search.error.clear();
                return Intent::None;
            default:
                break;  // Ctrl-S falls through to focus-specific handling
        }
    }

    // The approval dialog is the topmost modal and swallows every key.
    if (s.confirm.active) return HandleConfirmOverlay(s, k);
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

    // ---- modals (the Alpha's a/c/p/b dialogs) ------------------------------
    if (s.page != Page::Main) {
        switch (s.page) {
            case Page::Bugfix: return HandleBugfixModal(s, k);
            case Page::Agent: return HandleAgentModal(s, k);
            case Page::Plugins: return HandlePluginsModal(s, k);
            case Page::Cloud: return HandleCloudModal(s, k);
            case Page::Main: break;
        }
        return Intent::None;
    }

    // ---- home screen: three-pane browser -----------------------------------

    // N's title prompt for POST /api/mods/create.
    if (s.mod_input_active) {
        switch (k.kind) {
            case KeyInput::Enter: {
                std::string title = TrimAscii(s.mod_input);
                if (title.empty()) {
                    s.status = "输入模组标题";
                    return Intent::None;
                }
                s.mod_input_active = false;
                return Intent::CreateMod;
            }
            case KeyInput::Escape:
                s.mod_input_active = false;
                s.status = "已取消新建模组";
                return Intent::None;
            case KeyInput::Backspace:
                PopCodepoint(s.mod_input);
                return Intent::None;
            case KeyInput::Char:
                s.mod_input += k.text;
                return Intent::None;
            default:
                return Intent::None;
        }
    }

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
        if (s.sug.slot_mode) return HandleSlotEditor(s, k);
        if (s.sug.active) {
            // Candidate list owns the keyboard: Tab/↑↓ cycle, Enter accepts,
            // typing filters the cached set locally (never a per-key GET).
            FieldSuggestState& sg = s.sug;
            switch (k.kind) {
                case KeyInput::Tab:
                case KeyInput::Down:
                    if (!sg.shown.empty())
                        sg.sel = (sg.sel + 1) % static_cast<int>(sg.shown.size());
                    return Intent::None;
                case KeyInput::Up:
                case KeyInput::ShiftTab:
                    if (!sg.shown.empty())
                        sg.sel = (sg.sel + static_cast<int>(sg.shown.size()) - 1) %
                                 static_cast<int>(sg.shown.size());
                    return Intent::None;
                case KeyInput::Enter:
                    return AcceptSuggestion(s);
                case KeyInput::Escape:
                    sg.active = false;  // close the list, keep typing by hand
                    sg.query.clear();
                    return Intent::None;
                case KeyInput::Backspace:
                    PopCodepoint(s.field_buffer);
                    PopCodepoint(sg.query);
                    sg.shown = FilterSuggestions(sg.all, sg.query);
                    sg.sel = 0;
                    if (sg.shown.empty()) sg.active = false;
                    return Intent::None;
                case KeyInput::Char:
                    s.field_buffer += k.text;
                    sg.query += k.text;
                    sg.shown = FilterSuggestions(sg.all, sg.query);
                    sg.sel = 0;
                    if (sg.shown.empty()) sg.active = false;
                    return Intent::None;
                default:
                    return Intent::None;
            }
        }
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
            case KeyInput::Tab:
                // Explicit reopen of the cached candidates (no-code mode).
                if (s.no_code_mode && !s.sug.all.empty()) {
                    s.sug.active = true;
                    s.sug.query.clear();
                    s.sug.shown = FilterSuggestions(s.sug.all, std::string());
                    s.sug.sel = 0;
                }
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
    if (k.kind == KeyInput::CtrlChar && k.ctrl == 's') {
        if (!TableDirty(s)) {
            s.status = "无改动";
            return Intent::None;
        }
        return GateWrite(s, Intent::SaveTable, "保存表格",
                         s.table.name + "  修改 " + std::to_string(s.table.edits.size()) +
                             "  删除 " + std::to_string(s.table.removes.size()) + "  新增 " +
                             std::to_string(s.table.adds.size()));
    }

    // `/` filter mode comes first: while capturing, every char — including
    // the command letters — feeds the filter, exactly like the Alpha's filter
    // inputs swallowed the keyboard.
    if (k.kind == KeyInput::Char && k.text == "/" && !s.filtering) {
        s.filtering = true;
        return Intent::None;
    }
    if (s.filtering) {
        std::string& target = s.focus == Focus::Tables ? s.table_filter : s.filter;
        switch (k.kind) {
            case KeyInput::Enter:
                s.filtering = false;
                return Intent::None;
            case KeyInput::Escape:
                s.filtering = false;
                target.clear();
                s.row_sel = 0;
                s.tree_sel = 0;
                return Intent::None;
            case KeyInput::Backspace:
                PopCodepoint(target);
                s.row_sel = 0;
                s.tree_sel = 0;
                return Intent::None;
            case KeyInput::Char:
                target += k.text;
                s.row_sel = 0;
                s.tree_sel = 0;
                return Intent::None;
            default:
                return Intent::None;
        }
    }

    // Keys shared by every pane: modal openers + Alpha's `q` quit guard.
    if (k.kind == KeyInput::Char) {
        if (k.text == "q") {
            if (TableDirty(s)) {
                s.editing = false;
                s.editing_field = false;
                s.filtering = false;
                return GateWrite(s, Intent::Quit, "退出",
                                 "有未保存的修改（" +
                                     std::to_string(s.table.edits.size() +
                                                    s.table.removes.size() +
                                                    s.table.adds.size()) +
                                     " 条），退出将丢弃");
            }
            return Intent::Quit;
        }
        if (k.text == "a") return OpenModal(s, Page::Agent);
        if (k.text == "c") return OpenModal(s, Page::Cloud);
        if (k.text == "p") return OpenModal(s, Page::Plugins);
        if (k.text == "b") return OpenModal(s, Page::Bugfix);
    }
    // Tab / Shift+Tab cycle the three panes (Alpha's panel switcher).
    if (k.kind == KeyInput::Tab || k.kind == KeyInput::ShiftTab) {
        static const Focus order[] = {Focus::Tables, Focus::Rows, Focus::Detail};
        int i = 0;
        for (int j = 0; j < 3; ++j)
            if (order[j] == s.focus) i = j;
        i = (i + (k.kind == KeyInput::Tab ? 1 : 2)) % 3;
        s.focus = order[i];
        if (s.focus == Focus::Detail) s.field_sel = 0;
        return Intent::None;
    }

    switch (s.focus) {
        case Focus::Tables:
            return HandleTree(s, k);
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
                    s.edit_buffer =
                        it != s.table.edits.end() ? it->second : s.table.rows[ri].raw;
                    return Intent::None;
                }
                case KeyInput::Char:
                    if (k.text == "d") {
                        int ri = SelectedVisibleIndex(s);
                        if (ri >= 0) {
                            const std::string key = s.table.rows[ri].key;
                            // A row appended this session never hit disk:
                            // drop it outright instead of queueing a remove.
                            auto added = std::find(s.table.adds.begin(), s.table.adds.end(),
                                                   key);
                            if (added != s.table.adds.end()) {
                                s.table.adds.erase(added);
                                s.table.edits.erase(key);
                                s.table.rows.erase(s.table.rows.begin() + ri);
                                s.row_sel = s.ClampSel(s.row_sel,
                                                       static_cast<int>(s.VisibleRows().size()));
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
                    if (s.field_sel < 0 || s.field_sel >= static_cast<int>(fields.size()))
                        return Intent::None;
                    s.editing_field = true;
                    s.field_name = fields[s.field_sel].first;
                    s.field_buffer = fields[s.field_sel].second;
                    // No-code mode: effect/role-ish fields open straight into
                    // the candidate list (backend empty-q = recent/curated).
                    s.sug = FieldSuggestState{};
                    if (s.no_code_mode) {
                        s.sug.mode = FieldSuggestMode(s.table.name, s.field_name);
                        if (!s.sug.mode.empty()) return Intent::FetchFieldSuggestions;
                    }
                    return Intent::None;
                case KeyInput::Char:
                    if (k.text == "m") {
                        s.detail_mode = s.detail_mode == DetailMode::Json ? DetailMode::Form
                                                                          : DetailMode::Json;
                        return Intent::None;
                    }
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

}  // namespace p8
