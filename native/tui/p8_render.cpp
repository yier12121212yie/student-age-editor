// p8_render.cpp — AppState -> FTXUI DOM.
//
// Alpha-v0.3 parity: the home screen is the three-pane VS Code Dark+ editor
// (blue title bars 📦 Mods / Cfgs | 📋 Records | 📝 Detail / JSON, layered gray
// backgrounds) and every other surface renders as a centered blue-bordered
// modal. Rendering stays a pure function of the view-model; palette + chrome
// builders live in p8_theme.
#include "p8_render.h"

#include <algorithm>
#include <regex>
#include <string>
#include <vector>

#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/screen.hpp>

#include "p8_cfg.h"  // ValuePreview / FormFields for consistent truncation
#include "p8_theme.h"

namespace p8 {
namespace {

using namespace ftxui;
namespace core = sa_core;
namespace th = theme;

// Cut to at most `n` code points (single-line safety; matches p8_cfg).
std::string Cut(const std::string& s, size_t n) {
    size_t chars = 0, i = 0;
    while (i < s.size() && chars < n) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t step = 1;
        if ((c & 0x80) == 0x00) step = 1;
        else if ((c & 0xE0) == 0xC0) step = 2;
        else if ((c & 0xF0) == 0xE0) step = 3;
        else if ((c & 0xF8) == 0xF0) step = 4;
        if (i + step > s.size()) step = s.size() - i;
        i += step;
        ++chars;
    }
    return s.substr(0, i);
}

struct Slice {
    int start, end;
};
Slice Window(int count, int sel, int maxlines) {
    if (count <= maxlines) return {0, count};
    int start = std::clamp(sel - maxlines / 2, 0, count - maxlines);
    return {start, start + maxlines};
}

Color SelBlue() { return Color::RGB(0x09, 0x47, 0x71); }  // VS Code list selection

// One selectable list row: cursor marker + label. The selected row gets the VS
// Code list-selection blue; zebra striping (`bg`) alternates behind it.
Element Row(const std::string& label, bool selected, bool active, int width, bool zebra) {
    std::string marker = active ? (selected ? "» " : "  ") : "  ";
    std::string text_ = marker + Cut(label, static_cast<size_t>(std::max(0, width - 2)));
    Element e = hbox({text(text_), filler()});
    if (selected && active) return e | bgcolor(SelBlue()) | color(Color::White) | bold;
    if (!active) e |= dim;
    if (zebra) e |= bgcolor(th::BgLeft());
    return e;
}

Element FooterBar(const AppState& s) {
    return th::HintLine(
        "a AI 助手   c 云同步   p 插件   b Bug 扫描   Ctrl-K 搜索   Ctrl-M 权限   Ctrl-N 无代码   "
        "? 帮助   q 退出");
}

// ---------------------------------------------------------------------------
// Home screen panes
// ---------------------------------------------------------------------------

Element TablesPane(const AppState& s, int width, int lh) {
    bool active = s.focus == Focus::Tables && !s.editing && !s.editing_field;
    auto items = s.TreeItems();
    Elements out{th::PanelTitleBar("📦", "Mods / Cfgs", active)};
    if (s.filtering && s.focus == Focus::Tables)
        out.push_back(text("  过滤: " + s.table_filter + "▏") | color(Color::White));
    else if (!s.table_filter.empty())
        out.push_back(text("  过滤: " + s.table_filter) | color(th::TextDim()));
    Slice w = Window(static_cast<int>(items.size()), s.tree_sel, lh - 3);
    for (int i = w.start; i < w.end; ++i) {
        const TreeItem& it = items[i];
        const ModEntry& mod = s.mods[it.mod_index];
        if (it.table_index < 0) {
            bool expanded = s.expanded_mod == it.mod_index &&
                            mod.name == s.selected_mod && !s.VisibleTables().empty();
            std::string label = std::string(expanded ? "📂 " : "📁 ") + mod.name;
            if (mod.name == s.selected_mod) label += "  ●";
            out.push_back(Row(label, i == s.tree_sel, active, width, false));
        } else {
            bool is_open = s.tables[it.table_index] == s.table.name;
            std::string label = "    " + std::string(is_open ? "● " : "◦ ") +
                                s.tables[it.table_index];
            out.push_back(Row(label, i == s.tree_sel, active, width, false));
        }
    }
    if (items.empty()) out.push_back(text("  （无模组，r 刷新）") | color(th::TextDim()));
    out.push_back(filler());
    out.push_back(th::HintLine("↑↓ 选择 Enter 打开"));
    out.push_back(th::HintLine("→ 展开  N 新建Mod"));
    return vbox(std::move(out)) | bgcolor(th::BgLeft());
}

Element RowsPane(const AppState& s, int width, int lh) {
    bool active = s.focus == Focus::Rows && !s.editing && !s.editing_field;
    auto vis = s.VisibleRows();
    int dirty = static_cast<int>(s.table.edits.size()) + static_cast<int>(s.table.removes.size());
    Elements out{th::PanelTitleBar("📋", Cut("Records — " + (s.table.name.empty()
                                                                 ? std::string("（未打开）")
                                                                 : s.table.name),
                                              static_cast<size_t>(std::max(4, width - 6))),
                                  active)};
    out.push_back(text("  行数: " + std::to_string(s.table.rows.size()) + "  未保存: " +
                       std::to_string(dirty) +
                       (s.filter.empty() ? "" : "  过滤: " + s.filter)) |
                   color(th::TextDim()));
    Slice w = Window(static_cast<int>(vis.size()), s.row_sel, lh - 2);
    int row_width = std::max(8, width - 2);
    for (int wi = w.start; wi < w.end; ++wi) {
        int ri = vis[wi];
        const std::string& key = s.table.rows[ri].key;
        bool edited = s.table.edits.count(key) > 0;
        bool removed = std::find(s.table.removes.begin(), s.table.removes.end(), key) !=
                       s.table.removes.end();
        std::string val;
        if (removed)
            val = "（已标记删除）";
        else if (edited)
            val = s.table.edits.at(key);
        else
            val = s.table.rows[ri].preview;
        std::string marker = removed ? "-" : (edited ? "*" : " ");
        std::string line = marker + key + " = " + val;
        out.push_back(Row(line, wi == s.row_sel, active, row_width, /*zebra=*/wi % 2 == 1));
    }
    if (vis.empty() && !s.table.name.empty())
        out.push_back(text("  （无匹配行）") | color(th::TextDim()));
    if (s.editing) {
        out.push_back(separator());
        out.push_back(hbox({text(" 编辑值> ") | bold | color(th::FocusPurple()),
                            text(s.edit_buffer + "▏") | inverted}));
    }
    out.push_back(filler());
    out.push_back(th::HintLine("n 新建  y 复制  d 删除"));
    out.push_back(th::HintLine("Enter 编辑  Ctrl-S 保存"));
    return vbox(std::move(out)) | bgcolor(th::BgMiddle());
}

// Current row's JSON text: pending edit wins, removed rows have no detail.
std::string DetailRaw(const AppState& s) {
    auto vis = s.VisibleRows();
    if (vis.empty()) return "";
    int idx = std::clamp(s.row_sel, 0, static_cast<int>(vis.size()) - 1);
    const std::string& key = s.table.rows[vis[idx]].key;
    if (std::find(s.table.removes.begin(), s.table.removes.end(), key) != s.table.removes.end())
        return "";
    auto it = s.table.edits.find(key);
    return it != s.table.edits.end() ? it->second : s.table.rows[vis[idx]].raw;
}

// The 📝 title bar mirrors the record's save state the way the Alpha right
// pane did: red while dirty, the standard blue once synced.
Element DetailTitle(const AppState& s, bool active) {
    bool dirty = !s.table.edits.empty() || !s.table.removes.empty() || !s.table.adds.empty();
    Element bar =
        hbox({text(" 📝 Detail / JSON" + std::string(dirty ? "  ●" : "")), filler()}) |
        bold;
    if (dirty) return bar | bgcolor(Color::RGB(0x5a, 0x1d, 0x1d)) | color(th::DirtyRed());
    return bar | bgcolor(active ? th::AccentBlue() : Color::RGB(0x3a, 0x3d, 0x41)) |
           color(Color::White);
}

// The Alpha right pane's button row: 保存 in primary blue, the rest gray.
Element ButtonRow(const AppState& s) {
    (void)s;
    auto btn = [](const std::string& label, Color bg) {
        return text(" " + label + " ") | bgcolor(bg) | color(Color::White) | bold;
    };
    Color gray = Color::RGB(0x3c, 0x3c, 0x3c);
    return hbox({btn("s 保存", th::ButtonBlue()), text(" "), btn("v 校验", gray),
                 text(" "), btn("y 复制", gray), text(" "), btn("d 删除", gray)});
}

Element DetailPane(const AppState& s, int width, int lh) {
    bool active = s.focus == Focus::Detail && !s.editing && !s.editing_field;
    Elements out{DetailTitle(s, active)};
    if (s.table.name.empty()) {
        // Startup welcome (Alpha: the right pane opened on the guide text).
        for (const auto& line : th::WelcomeLines())
            out.push_back(text(Cut("  " + line, static_cast<size_t>(std::max(4, width)))) |
                          color(line.rfind('#', 0) == 0 ? th::SectionOrange() : th::TextMain()));
        out.push_back(filler());
        out.push_back(ButtonRow(s));
        return vbox(std::move(out)) | bgcolor(th::BgRight());
    }
    out.push_back(text("  " + std::string(s.detail_mode == DetailMode::Json ? "[JSON]"
                                                                            : "[表单]") +
                       "  m 切换  Enter 编辑字段") |
                   color(th::TextDim()));
    std::string raw = DetailRaw(s);
    if (raw.empty()) {
        out.push_back(text("  （无选中行）") | color(th::TextDim()));
    } else if (s.detail_mode == DetailMode::Json) {
        Json parsed = Json::parse(raw, nullptr, /*allow_exceptions=*/false);
        std::string pretty = parsed.is_discarded() ? raw : core::py_dumps_indent(parsed);
        size_t pos = 0;
        int shown = 0;
        while (pos <= pretty.size() && shown < lh) {
            size_t nl = pretty.find('\n', pos);
            std::string line =
                pretty.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
            out.push_back(text(Cut(line, static_cast<size_t>(width))) | color(th::TextMain()));
            ++shown;
            if (nl == std::string::npos) break;
            pos = nl + 1;
        }
    } else {
        auto fields = FormFields(raw);
        Slice w = Window(static_cast<int>(fields.size()), s.field_sel, lh);
        for (int i = w.start; i < w.end; ++i) {
            Element line = hbox({text("  " + Cut(fields[i].first, 16) + " ") |
                                     color(active && i == s.field_sel ? Color::White
                                                                       : th::TextDim()),
                                 text(Cut(fields[i].second, static_cast<size_t>(
                                                              std::max(4, width - 20)))) |
                                     color(th::TextMain()),
                                 filler()});
            if (active && i == s.field_sel) line |= bgcolor(th::FocusPurple());
            out.push_back(line);
        }
        if (fields.empty()) out.push_back(text("  （该记录不是 JSON object）") | color(th::TextDim()));
    }
    if (s.editing_field) {
        out.push_back(separator());
        out.push_back(hbox({text(" 编辑 " + s.field_name + "> ") | bold |
                                color(th::FocusPurple()),
                            text(s.field_buffer + "▏") | inverted}));
        // 无代码模式：就地候选列表 / 参数槽二级选择（Tab/↑↓ 选，Enter 接受）。
        const int sug_h = std::min(6, lh);
        if (s.sug.slot_mode && s.sug.cand >= 0 && s.sug.cand < static_cast<int>(s.sug.all.size()) &&
            s.sug.slot_i < static_cast<int>(s.sug.all[s.sug.cand].slots.size())) {
            const auto& slots = s.sug.all[s.sug.cand].slots;
            const auto& slot = slots[s.sug.slot_i];
            std::string head = " 槽 " + std::to_string(s.sug.slot_i + 1) + "/" +
                               std::to_string(slots.size()) + " · " +
                               (slot.label.empty() ? slot.name : slot.label) + " (" + slot.name + ")";
            out.push_back(text(Cut(head, static_cast<size_t>(width))) | color(th::SectionOrange()));
            if (!s.sug.slot_entries.empty()) {
                Slice w = Window(static_cast<int>(s.sug.entry_shown.size()), s.sug.entry_sel, sug_h);
                for (int i = w.start; i < w.end; ++i) {
                    const auto& e = s.sug.slot_entries[s.sug.entry_shown[i]];
                    std::string label = std::string("  ") +
                                        (i == s.sug.entry_sel ? "» " : "  ") + e.first +
                                        " · " + e.second;
                    Element line = text(Cut(label, static_cast<size_t>(width)));
                    if (i == s.sug.entry_sel) line |= bgcolor(th::FocusPurple()) | color(Color::White);
                    out.push_back(std::move(line));
                }
            } else {
                out.push_back(text("  （手输值，Enter 确认，Esc 取消）") | color(th::TextDim()));
            }
        } else if (s.sug.active) {
            Slice w = Window(static_cast<int>(s.sug.shown.size()), s.sug.sel, sug_h);
            for (int i = w.start; i < w.end; ++i) {
                const FieldSuggestion& f = s.sug.all[s.sug.shown[i]];
                std::string label = std::string("  ") + (i == s.sug.sel ? "» " : "  ") +
                                    Cut(f.desc, static_cast<size_t>(std::max(4, width - 12)));
                Element line = text(label);
                if (i == s.sug.sel) line |= bgcolor(th::FocusPurple()) | color(Color::White);
                out.push_back(std::move(line));
            }
            out.push_back(text("  ↑↓/Tab 选 · Enter 接受 · 打字过滤 · Esc 手输") |
                          color(th::TextDim()));
        }
    }
    out.push_back(filler());
    out.push_back(ButtonRow(s));
    return vbox(std::move(out)) | bgcolor(th::BgRight());
}

Element BrowseBody(const AppState& s, int width, int lh) {
    // Pane widths are pinned (EQUAL) — hbox would otherwise negotiate widths
    // from content and squeeze the middle pane when the welcome text is long.
    int left = std::clamp(width / 4, 22, 34);
    int right = std::clamp(width / 3, 30, 46);
    int mid = std::max(20, width - left - right - 2);
    return hbox({TablesPane(s, left, lh) | size(WIDTH, EQUAL, left),
                 separator(),
                 RowsPane(s, mid, lh) | size(WIDTH, EQUAL, mid),
                 separator(),
                 DetailPane(s, right, lh) | size(WIDTH, EQUAL, right)}) |
           flex;
}

// ---------------------------------------------------------------------------
// Modal bodies (rendered inside theme::ModalFrame)
// ---------------------------------------------------------------------------

Element BugfixBody(const AppState& s, int width, int lh) {
    Elements out{text("  模组: " + s.selected_mod + "  共 " + std::to_string(s.bugs.size()) +
                      " 条") |
                     color(th::TextDim())};
    Slice w = Window(static_cast<int>(s.bugs.size()), s.bug_sel, lh - 1);
    for (int i = w.start; i < w.end; ++i) {
        const auto& b = s.bugs[i];
        std::string label = "[" + b.flag + "] " + b.cfg + "/" + b.id + " " + b.key + ": " +
                            b.message;
        out.push_back(Row(label, i == s.bug_sel, true, width - 2, false));
    }
    if (s.bugs.empty())
        out.push_back(text(s.bug_scanned ? "  （未发现 Bug）" : "  （按 r 扫描当前模组…）") |
                      color(th::TextDim()));
    return vbox(std::move(out));
}

Element AgentBody(const AppState& s, int width, int lh) {
    Elements out;
    int n = static_cast<int>(s.chat.size());
    int start = std::max(0, n - (lh - 2));
    for (int i = start; i < n; ++i) {
        const auto& m = s.chat[i];
        std::string who = m.role == "user" ? "你" : (m.role == "assistant" ? "AI" : m.role);
        // Multi-line content: split so long replies stay inside the modal.
        size_t pos = 0;
        bool first = true;
        while (pos <= m.content.size()) {
            size_t nl = m.content.find('\n', pos);
            std::string line =
                m.content.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
            out.push_back(text(Cut((first ? who + "：" : "  ") + line,
                                   static_cast<size_t>(width))) |
                          color(m.role == "user" ? th::TextMain() : th::SyncGreen()));
            first = false;
            if (nl == std::string::npos) break;
            pos = nl + 1;
        }
    }
    if (n == 0)
        out.push_back(text("  （开始一段新对话；未配置 Key 时按 Enter 会提示）") |
                      color(th::TextDim()));
    out.push_back(separator());
    if (s.chat_busy) {
        out.push_back(hbox({text(" 输入> ") | bold, text("（生成中…）") | dim}));
    } else {
        out.push_back(hbox({text(" 输入> ") | bold, text(s.chat_input + "▏") | inverted}));
    }
    return vbox(std::move(out));
}

Element PluginsBody(const AppState& s, int width, int lh) {
    Elements out;
    int lines = std::max(1, lh - (s.plugin_input_active ? 2 : 1));
    for (int i = 0; i < static_cast<int>(s.plugins.size()) && i < lines; ++i) {
        const auto& p = s.plugins[i];
        std::string label = p.id + "  " + (p.name.empty() ? p.id : p.name);
        if (!p.version.empty()) label += " v" + p.version;
        label += p.loaded ? "  ✓ 已加载" : "  ✗ 未加载";
        if (!p.error.empty())
            label += "  ! " + p.error;
        else if (!p.author.empty())
            label += "  作者:" + p.author;
        Element e = Row(label, i == s.plugin_sel, !s.plugin_input_active, width - 2, i % 2 == 1);
        out.push_back(e);
    }
    if (s.plugins.empty())
        out.push_back(text(s.plugins_loaded ? "  （未安装插件）" : "  （按 r 读取插件列表）") |
                      color(th::TextDim()));
    if (s.plugin_input_active) {
        out.push_back(separator());
        out.push_back(hbox({text(" zip 路径> ") | bold, text(s.plugin_input + "▏") | inverted}));
    }
    return vbox(std::move(out));
}

Element CloudBody(const AppState& s, int width, int lh) {
    int rail = std::clamp(width / 4, 18, 32);
    int side = std::max(16, (width - rail - 2) / 2);

    Elements pv{th::PanelTitleBar("☁", "Provider", true)};
    int pv_lines = std::max(1, lh - 6);
    Slice pw = Window(static_cast<int>(s.providers.size()), s.provider_sel, pv_lines);
    for (int i = pw.start; i < pw.end; ++i) {
        const auto& p = s.providers[i];
        pv.push_back(Row(p.name.empty() ? p.id : p.name, i == s.provider_sel, true, rail - 1,
                         false));
    }
    if (s.providers.empty())
        pv.push_back(text(s.providers_loaded ? "  （无 Provider）" : "  （按 r 读取）") |
                     color(th::TextDim()));
    pv.push_back(separator());
    pv.push_back(text("  模组: " + (s.selected_mod.empty() ? "-" : s.selected_mod)) |
                 color(th::TextDim()));
    pv.push_back(text("  方向: " + s.cloud_direction) | color(th::TextDim()));
    pv.push_back(text(std::string("  DryRun: ") + (s.cloud_dry_run ? "开" : "关")) |
                 (s.cloud_dry_run ? color(th::WarnColor()) : color(th::TextDim())));
    if (s.cloud_delete_extra)
        pv.push_back(text("  清理远端多余: 开") | color(th::WarnColor()));

    auto file_panel = [&](const std::string& title, const std::vector<CloudFile>& files) {
        Elements out{th::PanelTitleBar("", title, false)};
        int lines = std::max(1, lh - 2);
        for (size_t i = 0; i < files.size() && static_cast<int>(i) < lines; ++i) {
            const auto& f = files[i];
            std::string line = f.name + (f.is_dir ? "/" : "");
            out.push_back(text("  " + Cut(line, static_cast<size_t>(std::max(4, side - 2)))) |
                          color(th::TextMain()));
        }
        if (files.empty())
            out.push_back(text(s.cloud_files_loaded ? "  （空）" : "  （Enter 读取）") |
                          color(th::TextDim()));
        return vbox(std::move(out)) | bgcolor(th::BgLeft());
    };

    Elements body{hbox({vbox(std::move(pv)) | bgcolor(th::BgLeft()), separator(),
                        file_panel("本地 Mod 文件", s.cloud_local), separator(),
                        file_panel("远端文件", s.cloud_remote)})};
    if (!s.cloud_sync_summary.empty())
        body.push_back(text("  " + s.cloud_sync_summary) | color(th::SyncGreen()));
    if (!s.cloud_error.empty())
        body.push_back(text("  错误: " + Cut(s.cloud_error, static_cast<size_t>(width - 8))) |
                       color(th::ErrorColor()));
    return vbox(std::move(body));
}

// The permissionMode=="confirm" approval box (topmost modal).
Element ConfirmBody(const AppState& s, int width) {
    return vbox({text("  " + Cut(s.confirm.detail,
                                   static_cast<size_t>(std::max(20, width - 8)))) |
                     color(th::TextMain()),
                 separator(),
                 text("  [y / Enter] 允许    [n / Esc] 拒绝") | bold}) |
           size(HEIGHT, GREATER_THAN, 4);
}

Element SearchBody(const AppState& s, int width, int lh) {
    Elements out{hbox({text(" 搜索> ") | bold, text(s.search.input + "▏") | inverted})};
    int result_lines = std::max(1, lh - 3);
    Slice w = Window(static_cast<int>(s.search.results.size()), s.search.sel, result_lines);
    for (int i = w.start; i < w.end; ++i) {
        const auto& hit = s.search.results[i];
        std::string label = "[" + hit.src + "] " + hit.talk_id + " (" + hit.evt_title + "): " +
                            hit.content;
        out.push_back(Row(label, i == s.search.sel, true, width - 2, i % 2 == 1));
    }
    if (s.search.busy) {
        out.push_back(text("  搜索中…") | dim);
    } else if (!s.search.error.empty()) {
        out.push_back(text("  错误: " + Cut(s.search.error, width - 6)) | color(th::ErrorColor()));
    } else if (s.search.results.empty()) {
        out.push_back(text("  （无结果）") | color(th::TextDim()));
    }
    return vbox(std::move(out));
}

Element ValidateBody(const AppState& s, int width, int lh) {
    Elements out;
    if (s.validate.busy) {
        out.push_back(text("  校验中…") | dim);
    } else if (!s.validate.error.empty()) {
        out.push_back(text("  错误: " + Cut(s.validate.error, width - 6)) | color(th::ErrorColor()));
    } else {
        for (const auto& it : s.validate.issues) {
            if (static_cast<int>(out.size()) > lh) {
                out.push_back(text("  …") | dim);
                break;
            }
            std::string line =
                "[" + it.level + "] " + (it.rid.empty() ? "" : it.rid + ": ") + it.msg;
            Color c = it.level == "error"  ? th::ErrorColor()
                      : it.level == "warn" ? th::WarnColor()
                                           : th::TextDim();
            out.push_back(text("  " + Cut(line, static_cast<size_t>(width - 4))) | color(c));
        }
        if (s.validate.issues.empty())
            out.push_back(text("  ✓ 校验通过，未发现问题") | color(th::SyncGreen()));
        out.push_back(separator());
        out.push_back(text("  counts: error=" + std::to_string(s.validate.errors) +
                           " warn=" + std::to_string(s.validate.warns) +
                           " info=" + std::to_string(s.validate.infos) + "   （按任意键关闭）") |
                      color(th::TextDim()));
    }
    return vbox(std::move(out));
}

Element HelpBody() {
    using th::TextDim;
    // Kept compact: the body area at 80x24 after chrome is what the modal shows.
    return vbox({hbox({text(" 全局") | bold | color(th::SectionOrange()), filler()}),
                 text("  q / Ctrl-Q    退出（有未保存修改先确认）") | color(TextDim()),
                 text("  a / c / p / b  AI 助手 / 云同步 / 插件 / Bug 扫描弹窗") | color(TextDim()),
                 text("  Ctrl-K        全局搜索对白") | color(TextDim()),
                 text("  Ctrl-M        权限模式 confirm ↔ full") | color(TextDim()),
                 text("  Ctrl-N        无代码模式开关（选效果/人物，不写代码）") |
                     color(TextDim()),
                 text("  无代码: 编辑字段时 Tab/↑↓ 选候选 · Enter 接受（带参槽进二级选择）") |
                     color(TextDim()),
                 text("  ?             开关本帮助") | color(TextDim()),
                 hbox({text(" 浏览") | bold | color(th::SectionOrange()), filler()}),
                 text("  Tab/Shift+Tab 左→右 / 右→左 切换面板") | color(TextDim()),
                 text("  ↑↓/Enter      移动 / 打开（模组·记录·字段）") | color(TextDim()),
                 text("  →/←           展开 / 收起模组的 Cfgs") | color(TextDim()),
                 text("  /             过滤当前面板（Enter 保留，Esc 清空）") | color(TextDim()),
                 text("  N             新建模组（输入标题）") | color(TextDim()),
                 hbox({text(" 编辑") | bold | color(th::SectionOrange()), filler()}),
                 text("  n / y / d     新增 / 复制 / 标记删除记录") | color(TextDim()),
                 text("  Enter         编辑 JSON（或表单字段）") | color(TextDim()),
                 text("  m             JSON ↔ 表单视图") | color(TextDim()),
                 text("  v / Ctrl-S    校验当前表 / 保存补丁") | color(TextDim()),
                 text("  r             刷新（模组列表 / 当前表 / 弹窗数据）") | color(TextDim()),
                 hbox({text(" 弹窗内") | bold | color(th::SectionOrange()), filler()}),
                 text("  插件: R 重载  i 安装zip  u 卸载") | color(TextDim()),
                 text("  云: Enter 读取  u/d/b 方向  y DryRun  x 清理远端  s 同步  t 测试") |
                     color(TextDim()),
                 text("  confirm 模式：保存/修复/装插件/卸载/云同步先弹审批框；dry-run 与只读不弹。") |
                     color(TextDim())});
}

std::string StripAnsi(const std::string& s) {
    static const std::regex re("\x1b\\[[0-9;]*[A-Za-z]");
    return std::regex_replace(s, re, "");
}

// Wrap a modal body in the Alpha chrome and swap it in as the screen body.
Element Modal(const AppState& s, Element body, const std::string& title, const std::string& hint,
              int width, int lh) {
    return th::ModalFrame(std::move(body), title, hint, std::max(30, width - 6), lh + 2);
}

}  // namespace

ftxui::Element BuildElement(const AppState& s, int width, int list_height) {
    Element body;
    std::string modal_hint;
    if (s.confirm.active) {
        body = Modal(s, ConfirmBody(s, width), "⚠ " + s.confirm.title,
                     "y 允许 · n 拒绝", width, list_height);
    } else if (s.search.active) {
        body = Modal(s, SearchBody(s, width, list_height), "🔍 全局搜索对白",
                     "Enter 搜索 · Esc 关闭", width, list_height);
    } else if (s.validate.active) {
        body = Modal(s, ValidateBody(s, width, list_height), "● 校验: " + s.validate.cfg,
                     "按任意键关闭", width, list_height);
    } else if (s.show_help) {
        body = Modal(s, HelpBody(), "⌨️ 键位帮助", "按任意键关闭", width, list_height);
    } else {
        switch (s.page) {
            case Page::Bugfix:
                body = Modal(s, BugfixBody(s, width, list_height), "🐞 Bug 扫描 / 修复",
                             "↑↓ 选择  r 重扫  f 修复全部  Esc 返回", width, list_height);
                break;
            case Page::Agent:
                body = Modal(s, AgentBody(s, width, list_height),
                             "🤖 AI 助手" + (s.agent_label.empty() ? "" : "  " + s.agent_label),
                             "Enter 发送  Esc 关闭  Ctrl-M 权限模式", width, list_height);
                break;
            case Page::Plugins:
                body = Modal(s, PluginsBody(s, width, list_height), "🧩 插件管理",
                             "↑↓ 选择  r 刷新  R 重载  i 安装zip  u 卸载  Esc 关闭", width,
                             list_height);
                break;
            case Page::Cloud:
                body = Modal(s, CloudBody(s, width, list_height), "☁️ 云同步",
                             "↑↓ 选 Provider  Enter 读取  u/d/b 方向  y DryRun  x 清理  s 同步  "
                             "t 测试  Esc 关闭",
                             width, list_height);
                break;
            case Page::Main:
                body = BrowseBody(s, width, list_height);
                break;
        }
    }
    return vbox({th::HeaderBar(), std::move(body) | flex, FooterBar(s),
                 th::StatusBar(s, width)});
}

std::string RenderPageToString(const AppState& s, int width, int height) {
    int list_height = std::max(1, height - 5);
    Element el = BuildElement(s, std::max(8, width), list_height);
    auto screen = Screen::Create(Dimension::Fixed(width), Dimension::Fixed(height));
    Render(screen, el);
    return StripAnsi(screen.ToString());
}

}  // namespace p8
