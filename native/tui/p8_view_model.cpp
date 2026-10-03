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
    auto table_name = [&s](const TreeItem& it) -> std::string {
        auto mt = s.mod_tables.find(s.mods[it.mod_index].name);
        if (mt == s.mod_tables.end() || it.table_index < 0 ||
            it.table_index >= static_cast<int>(mt->second.size()))
            return {};
        return mt->second[it.table_index];
    };
    switch (k.kind) {
        case KeyInput::Up:
            if (!items.empty()) s.tree_sel = s.ClampSel(s.tree_sel - 1, static_cast<int>(items.size()));
            return Intent::None;
        case KeyInput::Down:
            if (!items.empty()) s.tree_sel = s.ClampSel(s.tree_sel + 1, static_cast<int>(items.size()));
            return Intent::None;
        case KeyInput::Right: {
            // Expand the node under the cursor. An unselected mod must be
            // selected first — that is the round-trip that caches its cfg list.
            if (items.empty()) return Intent::None;
            TreeItem it = items[s.ClampSel(s.tree_sel, static_cast<int>(items.size()))];
            if (it.table_index >= 0) return Intent::None;
            const std::string& name = s.mods[it.mod_index].name;
            if (name != s.selected_mod) {
                s.selected_mod = name;
                s.mod_sel = it.mod_index;
                s.expanded_mods.insert(name);
                return Intent::SelectMod;
            }
            s.expanded_mods.insert(name);
            return Intent::None;
        }
        case KeyInput::Left: {
            if (items.empty()) return Intent::None;
            TreeItem it = items[s.ClampSel(s.tree_sel, static_cast<int>(items.size()))];
            if (it.table_index >= 0) {  // cfg node -> its mod node
                s.tree_sel = it.mod_index;
                return Intent::None;
            }
            s.expanded_mods.erase(s.mods[it.mod_index].name);
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
                const std::string& name = s.mods[it.mod_index].name;
                if (name == s.selected_mod &&
                    s.expanded_mods.find(name) != s.expanded_mods.end()) {
                    s.expanded_mods.erase(name);
                    return Intent::None;
                }
                s.selected_mod = name;
                s.mod_sel = it.mod_index;
                s.expanded_mods.insert(name);
                s.status = "加载中模组: " + s.selected_mod;
                return Intent::SelectMod;
            }
            const std::string name = table_name(it);
            if (name.empty()) return Intent::None;
            if (s.mods[it.mod_index].name != s.selected_mod) {
                // Opening a cfg of another mod: select it, then load the table
                // once the selection (and its cfg list) has round-tripped.
                s.selected_mod = s.mods[it.mod_index].name;
                s.mod_sel = it.mod_index;
                s.expanded_mods.insert(s.selected_mod);
                s.pending_table = name;
                s.status = "加载中模组: " + s.selected_mod;
                return Intent::SelectMod;
            }
            s.table = Table{};
            s.table.name = name;
            s.focus = Focus::Rows;
            s.editing = false;
            s.editing_field = false;
            s.filter.clear();
            s.filtering = false;
            s.row_sel = 0;
            s.detail_mode = DetailMode::Form;  // Alpha: form view is default
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

// 检查更新 modal (u)。只读：Enter/r 发一次 GET /api/update/check（结果由
// intent runner 写回 update_* 字段），其余键忽略；Esc/q 关闭回浏览页。
Intent HandleUpdateModal(AppState& s, const KeyInput& k) {
    switch (k.kind) {
        case KeyInput::Enter:
            return Intent::CheckUpdate;
        case KeyInput::Escape:
            s.page = Page::Main;
            return Intent::None;
        case KeyInput::Char:
            if (k.text == "r") return Intent::CheckUpdate;
            if (k.text == "q") {
                s.page = Page::Main;
                return Intent::None;
            }
            return Intent::None;
        default:
            return Intent::None;
    }
}

// 🔊 配音 (TTS) modal (t) — the Alpha's TtsScreen trimmed to the fields the
// shared settings carry: provider / key / base url / model / voice, a test
// round-trip and a synthesize-to-mod save. Enter edits the selected field,
// t tests the connection, s synthesizes the text into the mod.
Intent HandleTtsModal(AppState& s, const KeyInput& k) {
    if (s.tts.editing_field) {
        std::string* target = nullptr;
        switch (s.tts.field_sel) {
            case 0: target = &s.tts.provider; break;
            case 1: target = &s.tts.api_key; break;
            case 2: target = &s.tts.base_url; break;
            case 3: target = &s.tts.model; break;
            case 4: target = &s.tts.voice; break;
            case 5: target = &s.tts.text; break;
            default: s.tts.editing_field = false; return Intent::None;
        }
        switch (k.kind) {
            case KeyInput::Enter:
                s.tts.editing_field = false;
                if (s.tts.field_sel == 5 && !s.tts.text.empty()) {
                    return GateWrite(s, Intent::TtsSynthesize, "合成并保存配音",
                                     "模组 " + s.selected_mod);
                }
                return Intent::None;
            case KeyInput::Escape:
                s.tts.editing_field = false;
                return Intent::None;
            case KeyInput::Backspace:
                PopCodepoint(*target);
                return Intent::None;
            case KeyInput::Char:
                *target += k.text;
                return Intent::None;
            default:
                return Intent::None;
        }
    }
    switch (k.kind) {
        case KeyInput::Up:
            s.tts.field_sel = s.ClampSel(s.tts.field_sel - 1, 6);
            return Intent::None;
        case KeyInput::Down:
            s.tts.field_sel = s.ClampSel(s.tts.field_sel + 1, 6);
            return Intent::None;
        case KeyInput::Enter:
            s.tts.editing_field = true;
            return Intent::None;
        case KeyInput::Char:
            if (k.text == "t") {
                if (s.tts.busy) return Intent::None;
                s.tts.error.clear();
                s.tts.result.clear();
                return Intent::TtsTest;
            }
            if (k.text == "s") {
                if (s.tts.busy) return Intent::None;
                if (s.tts.text.empty()) {
                    s.status = "输入要合成的文本";
                    return Intent::None;
                }
                s.tts.error.clear();
                s.tts.result.clear();
                return GateWrite(s, Intent::TtsSynthesize, "合成并保存配音",
                                 "模组 " + s.selected_mod + "  音色 " +
                                     (s.tts.voice.empty() ? "(默认)" : s.tts.voice));
            }
            if (k.text == "q") {
                s.page = Page::Main;
                return Intent::None;
            }
            return Intent::None;
        case KeyInput::Escape:
            s.page = Page::Main;
            return Intent::None;
        default:
            return Intent::None;
    }
}

// 🚀 OOBE 首启向导 — step 0 types an optional workspace path, step 1 an
// optional mod title, then the wizard completes (POST /api/oobe/complete).
Intent HandleOobeModal(AppState& s, const KeyInput& k) {
    if (s.oobe.step == 0) {
        switch (k.kind) {
            case KeyInput::Enter: {
                std::string ws = TrimAscii(s.oobe.workspace_input);
                s.oobe.workspace_input.clear();
                if (!ws.empty()) return Intent::OobeSetWorkspace;
                s.oobe.step = 1;
                return Intent::None;
            }
            case KeyInput::Escape:
                s.oobe.step = 1;
                s.oobe.workspace_input.clear();
                return Intent::None;
            case KeyInput::Backspace:
                PopCodepoint(s.oobe.workspace_input);
                return Intent::None;
            case KeyInput::Char:
                s.oobe.workspace_input += k.text;
                return Intent::None;
            default:
                return Intent::None;
        }
    }
    if (s.oobe.step == 1) {
        switch (k.kind) {
            case KeyInput::Enter: {
                std::string title = TrimAscii(s.oobe.mod_title);
                s.oobe.mod_title.clear();
                s.oobe.step = 2;
                if (title.empty()) return Intent::OobeComplete;
                s.mod_input = title;
                return Intent::CreateMod;
            }
            case KeyInput::Escape:
                s.oobe.active = false;
                return Intent::OobeComplete;
            case KeyInput::Backspace:
                PopCodepoint(s.oobe.mod_title);
                return Intent::None;
            case KeyInput::Char:
                s.oobe.mod_title += k.text;
                return Intent::None;
            default:
                return Intent::None;
        }
    }
    // step 2 (done): any key closes.
    s.oobe.active = false;
    return Intent::OobeComplete;
}

// ---- Ctrl-P command palette ------------------------------------------------

Intent FormatCurrentRecord(AppState& s);

void RebuildPalette(AppState& s) {
    s.palette.items.clear();
    auto add = [&s](const std::string& id, const std::string& label, const std::string& hint) {
        s.palette.items.push_back(PaletteItem{id, label, hint});
    };
    for (int i = 0; i < static_cast<int>(s.mods.size()); ++i)
        add("mod:" + std::to_string(i), "切换到模组 " + s.mods[i].name,
            s.mods[i].name == s.selected_mod ? "当前" : "");
    {
        auto mt = s.mod_tables.find(s.selected_mod);
        if (mt != s.mod_tables.end())
            for (const auto& t : mt->second) add("table:" + t, "打开表 " + t, "");
    }
    add("action:save", "保存当前表", "Ctrl-S");
    add("action:validate", "校验当前表", "v");
    add("action:format", "格式化当前记录 JSON", "f");
    add("action:search", "全局搜索对白", "Ctrl-K");
    add("action:agent", "AI 助手", "a");
    add("action:cloud", "云同步", "c");
    add("action:plugins", "插件管理", "p");
    add("action:bugfix", "Bug 扫描", "b");
    add("action:tts", "配音 TTS", "t");
    add("action:update", "检查更新", "u");
    add("action:permission", "切换权限模式", "Ctrl-M");
    add("action:nocode", "切换无代码模式", "Ctrl-N");
    add("action:newmod", "新建模组", "N");
    add("action:help", "键位帮助", "?");
    add("action:refresh", "刷新模组列表", "r");
    add("action:quit", "退出", "q");
}

Intent RunPaletteAction(AppState& s, const std::string& id) {
    if (id.rfind("mod:", 0) == 0) {
        int i = std::atoi(id.c_str() + 4);
        if (i < 0 || i >= static_cast<int>(s.mods.size())) return Intent::None;
        if (s.mods[i].name == s.selected_mod) return Intent::None;
        s.selected_mod = s.mods[i].name;
        s.mod_sel = i;
        s.expanded_mods.insert(s.selected_mod);
        s.tree_sel = i;
        s.status = "加载中模组: " + s.selected_mod;
        return Intent::SelectMod;
    }
    if (id.rfind("table:", 0) == 0) {
        s.table = Table{};
        s.table.name = id.substr(6);
        s.focus = Focus::Rows;
        s.row_sel = 0;
        s.filter.clear();
        s.detail_mode = DetailMode::Form;
        s.status = "加载 " + s.table.name;
        return Intent::LoadTable;
    }
    if (id == "action:save") {
        if (s.table.name.empty() || s.table.edits.empty() || !s.table.removes.empty() ||
            !s.table.adds.empty())
            return Intent::SaveTable;
        return Intent::SaveTable;
    }
    if (id == "action:validate") {
        if (s.table.name.empty()) {
            s.status = "先打开一张表";
            return Intent::None;
        }
        s.validate.active = true;
        s.validate.busy = true;
        s.validate.cfg = s.table.name;
        s.validate.error.clear();
        return Intent::ValidateTable;
    }
    if (id == "action:format") return FormatCurrentRecord(s);
    if (id == "action:search") {
        s.search.active = true;
        s.search.busy = false;
        s.search.sel = 0;
        s.search.error.clear();
        return Intent::None;
    }
    if (id == "action:agent") { ClearTransient(s); s.page = Page::Agent; return Intent::None; }
    if (id == "action:cloud") { ClearTransient(s); s.page = Page::Cloud; return Intent::None; }
    if (id == "action:plugins") { ClearTransient(s); s.page = Page::Plugins; return Intent::None; }
    if (id == "action:bugfix") { ClearTransient(s); s.page = Page::Bugfix; return Intent::None; }
    if (id == "action:tts") { ClearTransient(s); s.page = Page::Tts; return Intent::None; }
    if (id == "action:update") { ClearTransient(s); s.page = Page::Update; return Intent::None; }
    if (id == "action:permission") {
        s.permission_mode = s.permission_mode == "confirm" ? "full" : "confirm";
        return Intent::SetPermissionMode;
    }
    if (id == "action:nocode") {
        s.no_code_mode = !s.no_code_mode;
        if (!s.no_code_mode) s.sug = FieldSuggestState{};
        return Intent::SetNoCodeMode;
    }
    if (id == "action:newmod") {
        s.mod_input_active = true;
        s.mod_input.clear();
        return Intent::None;
    }
    if (id == "action:help") { s.show_help = true; return Intent::None; }
    if (id == "action:refresh") return Intent::RefreshMods;
    if (id == "action:quit") return Intent::Quit;
    return Intent::None;
}

// f — reformat the selected record's JSON with a 2-space indent (Alpha
// action_format): the pretty text lands in the row editor, Enter stages it.
Intent FormatCurrentRecord(AppState& s) {
    if (s.table.name.empty()) {
        s.status = "先打开一张表";
        return Intent::None;
    }
    int ri = SelectedVisibleIndex(s);
    if (ri < 0) {
        s.status = "未选中记录";
        return Intent::None;
    }
    const std::string& key = s.table.rows[ri].key;
    if (std::find(s.table.removes.begin(), s.table.removes.end(), key) != s.table.removes.end()) {
        s.status = "该行已标记删除（再按 d 取消）";
        return Intent::None;
    }
    auto it = s.table.edits.find(key);
    const std::string& raw = it != s.table.edits.end() ? it->second : s.table.rows[ri].raw;
    Json parsed = Json::parse(raw, nullptr, false);
    if (parsed.is_discarded()) {
        s.status = "JSON 解析失败，无法格式化";
        return Intent::None;
    }
    s.editing = true;
    s.edit_buffer = sa_core::py_dumps_indent(parsed);
    s.status = "已格式化 · Enter 应用，Esc 取消";
    return Intent::None;
}

// ^P palette key handling: typing filters, ↑↓/Tab cycles, Enter runs.
Intent HandlePaletteOverlay(AppState& s, const KeyInput& k) {
    auto shown = [&s]() {
        std::vector<int> out;
        const std::string q = s.palette.input;
        for (int i = 0; i < static_cast<int>(s.palette.items.size()); ++i) {
            const PaletteItem& it = s.palette.items[i];
            if (q.empty() || CaseInsensitiveContains(it.label, q) ||
                CaseInsensitiveContains(it.id, q))
                out.push_back(i);
        }
        return out;
    };
    switch (k.kind) {
        case KeyInput::Up: {
            auto v = shown();
            if (!v.empty())
                s.palette.sel = (s.palette.sel + static_cast<int>(v.size()) - 1) %
                                static_cast<int>(v.size());
            return Intent::None;
        }
        case KeyInput::Down:
        case KeyInput::Tab: {
            auto v = shown();
            if (!v.empty()) s.palette.sel = (s.palette.sel + 1) % static_cast<int>(v.size());
            return Intent::None;
        }
        case KeyInput::Enter: {
            auto v = shown();
            if (v.empty()) return Intent::None;
            int idx = v[std::clamp(s.palette.sel, 0, static_cast<int>(v.size()) - 1)];
            std::string id = s.palette.items[idx].id;
            s.palette.active = false;
            s.palette.input.clear();
            s.palette.sel = 0;
            return RunPaletteAction(s, id);
        }
        case KeyInput::Escape:
            s.palette.active = false;
            s.palette.input.clear();
            s.palette.sel = 0;
            return Intent::None;
        case KeyInput::Backspace:
            PopCodepoint(s.palette.input);
            s.palette.sel = 0;
            return Intent::None;
        case KeyInput::Char:
            s.palette.input += k.text;
            s.palette.sel = 0;
            return Intent::None;
        default:
            return Intent::None;
    }
}

// Open the field editor for one FormRow: the buffer carries the *encoded*
// display text (decoded back to JSON on Enter). Effect/role-ish fields in
// no-code mode open straight into the candidate list.
Intent BeginFieldEdit(AppState& s, const FormRow& row) {
    s.editing_field = true;
    s.field_name = row.key;
    s.field_type = row.type;
    s.field_buffer = row.value;
    s.sug = FieldSuggestState{};
    if (s.no_code_mode) {
        s.sug.mode = FieldSuggestMode(s.table.name, row.key);
        if (!s.sug.mode.empty()) return Intent::FetchFieldSuggestions;
    }
    // Dictionary-backed identity fields (roles/bgs/audios/...) suggest "ID ·
    // 名称" entries even outside no-code mode.
    if (!row.dict.empty()) {
        s.sug.mode = row.dict;  // the intent runner reads the pool from mode
        return Intent::FetchDictEntries;
    }
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

std::vector<TreeItem> AppState::TreeItems() const {
    std::vector<TreeItem> out;
    for (int i = 0; i < static_cast<int>(mods.size()); ++i) {
        out.push_back(TreeItem{i, -1});
        // Any mod whose cfg list is cached can show children (the Alpha tree
        // kept several mods expanded; the cache fills on selection).
        auto mt = mod_tables.find(mods[i].name);
        if (mt == mod_tables.end() || expanded_mods.find(mods[i].name) == expanded_mods.end())
            continue;
        for (int t = 0; t < static_cast<int>(mt->second.size()); ++t) {
            if (CaseInsensitiveContains(mt->second[t], table_filter))
                out.push_back(TreeItem{i, t});
        }
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
            case 'p':
                // Ctrl-P command palette (Alpha-later build's bottom bar entry).
                ClearTransient(s);
                s.show_help = false;
                RebuildPalette(s);
                s.palette.active = true;
                s.palette.input.clear();
                s.palette.sel = 0;
                return Intent::None;
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
    if (s.palette.active) return HandlePaletteOverlay(s, k);
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
            case Page::Update: return HandleUpdateModal(s, k);
            case Page::Tts: return HandleTtsModal(s, k);
            case Page::Oobe: return HandleOobeModal(s, k);
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
                // Decode the typed text through the field's schema type (the
                // Alpha _decode): "1, 2, 3" becomes [1,2,3] for arrays etc.
                std::string key, raw, out;
                if (CurrentRowRaw(s, &key, &raw)) {
                    Json decoded = DecodeFieldValue(s.field_buffer, s.field_type);
                    Json record = Json::parse(raw, nullptr, false);
                    if (!record.is_discarded() && record.is_object()) {
                        record[s.field_name] = std::move(decoded);
                        s.table.edits[key] = record.dump();
                        s.status = "标记修改字段 " + s.field_name + "（Ctrl-S 保存）";
                    } else if (ApplyFieldEdit(raw, s.field_name, s.field_buffer, &out)) {
                        s.table.edits[key] = std::move(out);
                        s.status = "标记修改字段 " + s.field_name + "（Ctrl-S 保存）";
                    }
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
        if (k.text == "u") return OpenModal(s, Page::Update);
        if (k.text == "t") {
            OpenModal(s, Page::Tts);
            return Intent::TtsLoadSettings;  // seed the fields from the backend
        }
        if (k.text == "f") return FormatCurrentRecord(s);
        if (k.text == "s") {
            // Alpha: `s` saves (the same patch flow Ctrl-S drives).
            if (!TableDirty(s)) {
                s.status = "无改动";
                return Intent::None;
            }
            return GateWrite(s, Intent::SaveTable, "保存表格",
                             s.table.name + "  修改 " + std::to_string(s.table.edits.size()) +
                                 "  删除 " + std::to_string(s.table.removes.size()) + "  新增 " +
                                 std::to_string(s.table.adds.size()));
        }
        if (k.text == "e") {
            // 聚焦编辑 (Alpha action_edit_record): jump to the detail pane and
            // open the selected field (form) / the whole-row editor (JSON).
            std::string key, raw;
            if (!CurrentRowRaw(s, &key, &raw)) return Intent::None;
            if (s.detail_mode == DetailMode::Json) {
                s.focus = Focus::Detail;
                s.editing = true;
                s.edit_buffer = raw;
                return Intent::None;
            }
            s.focus = Focus::Detail;
            auto rows = FormLayout(s.table.name, raw, s.schema, s.key_maps);
            // Keep the cursor where the user was; snap a stale one onto the
            // first field row (same rule the Detail pane applies on focus).
            if (s.field_sel < 0 || s.field_sel >= static_cast<int>(rows.size()) ||
                rows[s.field_sel].kind != FormRow::Kind::Field) {
                for (int i = 0; i < static_cast<int>(rows.size()); ++i)
                    if (rows[i].kind == FormRow::Kind::Field) {
                        s.field_sel = i;
                        break;
                    }
            }
            if (s.field_sel < 0 || s.field_sel >= static_cast<int>(rows.size()) ||
                rows[s.field_sel].kind != FormRow::Kind::Field)
                return Intent::None;
            return BeginFieldEdit(s, rows[s.field_sel]);
        }
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
            // Form rows (sections + fields) or the JSON pane — navigation
            // addresses field rows only, sections render as headers.
            auto rows = [&s]() {
                std::string key, raw;
                if (!CurrentRowRaw(s, &key, &raw))
                    return FormLayout(s.table.name, "{}", s.schema, s.key_maps);
                return FormLayout(s.table.name, raw, s.schema, s.key_maps);
            }();
            auto field_indices = [&rows]() {
                std::vector<int> out;
                for (int i = 0; i < static_cast<int>(rows.size()); ++i)
                    if (rows[i].kind == FormRow::Kind::Field) out.push_back(i);
                return out;
            };
            // A stale cursor (initial focus lands on row 0 = the first section
            // header) snaps onto the first field row: sections never take it.
            if (s.detail_mode == DetailMode::Form) {
                bool on_field = s.field_sel >= 0 &&
                                s.field_sel < static_cast<int>(rows.size()) &&
                                rows[s.field_sel].kind == FormRow::Kind::Field;
                if (!on_field)
                    for (int i = 0; i < static_cast<int>(rows.size()); ++i)
                        if (rows[i].kind == FormRow::Kind::Field) {
                            s.field_sel = i;
                            break;
                        }
            }
            switch (k.kind) {
                case KeyInput::Up: {
                    auto fr = field_indices();
                    if (s.detail_mode == DetailMode::Json) return Intent::None;
                    // Section headers do not take the cursor: step over them.
                    int cur = s.field_sel;
                    for (int step = 0; step < static_cast<int>(rows.size()); ++step) {
                        cur = s.ClampSel(cur - 1, static_cast<int>(rows.size()));
                        if (cur >= 0 && cur < static_cast<int>(rows.size()) &&
                            rows[cur].kind == FormRow::Kind::Field)
                            break;
                    }
                    s.field_sel = cur;
                    (void)fr;
                    return Intent::None;
                }
                case KeyInput::Down: {
                    if (s.detail_mode == DetailMode::Json) return Intent::None;
                    int cur = s.field_sel;
                    for (int step = 0; step < static_cast<int>(rows.size()); ++step) {
                        cur = s.ClampSel(cur + 1, static_cast<int>(rows.size()));
                        if (cur >= 0 && cur < static_cast<int>(rows.size()) &&
                            rows[cur].kind == FormRow::Kind::Field)
                            break;
                    }
                    s.field_sel = cur;
                    return Intent::None;
                }
                case KeyInput::Enter:
                    if (s.detail_mode == DetailMode::Json) {
                        s.detail_mode = DetailMode::Form;
                        return Intent::None;
                    }
                    if (s.field_sel < 0 || s.field_sel >= static_cast<int>(rows.size()) ||
                        rows[s.field_sel].kind != FormRow::Kind::Field)
                        return Intent::None;
                    return BeginFieldEdit(s, rows[s.field_sel]);
                case KeyInput::Char:
                    if (k.text == "m") {
                        s.detail_mode = s.detail_mode == DetailMode::Json ? DetailMode::Form
                                                                          : DetailMode::Json;
                        return Intent::None;
                    }
                    if (k.text == "f") return FormatCurrentRecord(s);
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
