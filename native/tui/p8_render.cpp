// p8_render.cpp — AppState -> FTXUI DOM.
//
// The browse page is the Python-TUI-style three-pane layout: 表列表 (left) /
// 记录 (middle) / 详情 (right) with a per-pane focus cursor, a form/JSON mode
// toggle on the right pane and modal overlays for Ctrl-K global search and `v`
// validation. Rendering stays a pure function of the view-model.
#include "p8_render.h"

#include <algorithm>
#include <regex>
#include <string>
#include <vector>

#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/screen.hpp>

#include "p8_cfg.h"  // ValuePreview / FormFields for consistent truncation

namespace p8 {
namespace {

using namespace ftxui;
namespace core = sa_core;

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

// One selectable list row: cursor marker + label, highlighted when selected.
// `active` marks the pane that owns the keyboard (only it shows the cursor).
Element Row(const std::string& label, bool selected, bool active, int width) {
    std::string marker = active ? (selected ? "» " : "  ") : "  ";
    std::string text_ = marker + Cut(label, static_cast<size_t>(std::max(0, width - 2)));
    Element e = text(text_);
    if (!active) e |= dim;
    return selected && active ? (e | inverted) : e;
}

// Tab bar like the desktop frontend's page rail: current page inverted. Keys
// are shown as a single letter (full bindings live in the help overlay) so the
// header fits narrow terminals.
Element TabBar(const AppState& s) {
    struct Tab {
        Page page;
        const char* label;
        const char* key;
    };
    static const Tab tabs[] = {
        {Page::Mods, "模组", "D"},  {Page::Table, "表格", "T"},
        {Page::Bugfix, "Bug", "B"}, {Page::Agent, "助手", "A"},
        {Page::Plugins, "插件", "P"}, {Page::Cloud, "云", "L"},
    };
    Elements cells;
    for (const auto& t : tabs) {
        std::string label = std::string(t.label) + " " + t.key;
        Element cell = text(Cut(label, 10));
        if (s.page == t.page && !s.show_help) cell |= inverted;
        cells.push_back(cell);
        cells.push_back(text(" "));
    }
    return hbox(std::move(cells));
}

Element Header(const AppState& s) {
    // The permission mode is global chrome: it gates every mutating action, so
    // it stays visible on every page (Ctrl-M toggles it). The header budget is
    // tight at 80 columns, so the help/quit cue lives in the hint bar instead.
    const bool confirming = s.permission_mode == "confirm";
    Element badge = confirming ? (text("[权限:confirm]") | dim)
                               : (text("[权限:full]") | bold | color(Color::Yellow));
    return hbox({text("学生时代·编辑器 TUI") | bold, text(" "), TabBar(s), filler(), badge});
}

Element StatusLine(const AppState& s) {
    return text("  " + Cut(s.status, 120)) | dim;
}

// Per-page key hints (the footer line above the status), so the most common
// actions are discoverable without opening the help overlay.
Element HintBar(const AppState& s) {
    std::string hint;
    switch (s.page) {
        case Page::Mods:
            hint = "↑↓ 选择  Enter 进入浏览  r 刷新  Esc 退出";
            break;
        case Page::Table:
            if (s.editing || s.editing_field)
                hint = "Enter 确认  Esc 取消";
            else if (s.focus == Focus::Tables)
                hint = "↑↓ 选表  Enter 打开  输入过滤  Tab 切焦点  Esc 返回";
            else if (s.focus == Focus::Detail)
                hint = "↑↓ 选字段  Enter 编辑  m JSON/表单切换  Tab 切焦点";
            else
                hint = "↑↓ 行  Enter 编辑  n 新增  y 复制  d 删除  v 校验  Ctrl-S 保存  Tab 切焦点";
            break;
        case Page::Bugfix:
            hint = "↑↓ 选择  r 重扫  f 修复全部  Esc 返回";
            break;
        case Page::Agent:
            hint = "Enter 发送  Esc 返回  Ctrl-M 权限模式";
            break;
        case Page::Plugins:
            hint = s.plugin_input_active
                       ? "Enter 安装  Esc 取消"
                       : "↑↓ 选择  r 刷新  R 重载全部  i 安装 zip  u 卸载  Esc 返回";
            break;
        case Page::Cloud:
            hint = "↑↓ 选 Provider  Enter 读取文件  u/d/b 方向  y DryRun  x 清理远端  s 同步  t 测试  r 刷新";
            break;
    }
    return text(" [?] 帮助  " + hint) | dim;
}

// ---------------------------------------------------------------------------
// Browse page panes
// ---------------------------------------------------------------------------

Element PaneTitle(const std::string& title, bool focused) {
    return text((focused ? "» " : "  ") + title) | (focused ? bold : dim);
}

Element TablesPane(const AppState& s, int width, int lh) {
    bool active = s.focus == Focus::Tables && !s.editing && !s.editing_field;
    auto vis = s.VisibleTables();
    Elements out{PaneTitle("表列表", active),
                 text("   过滤:" + (s.table_filter.empty() ? "-" : s.table_filter)) | dim,
                 separator()};
    Slice w = Window(static_cast<int>(vis.size()), s.table_sel, lh);
    for (int i = w.start; i < w.end; ++i) {
        int ti = vis[i];
        bool is_open = s.tables[ti] == s.table.name;
        std::string label = (is_open ? "* " : "") + s.tables[ti];
        out.push_back(Row(label, ti == s.ClampSel(s.table_sel, static_cast<int>(vis.size())),
                          active, width));
    }
    if (vis.empty()) out.push_back(text("  （无匹配表）") | dim);
    return vbox(std::move(out));
}

Element RowsPane(const AppState& s, int width, int lh) {
    bool active = s.focus == Focus::Rows && !s.editing && !s.editing_field;
    auto vis = s.VisibleRows();
    int dirty = static_cast<int>(s.table.edits.size()) + static_cast<int>(s.table.removes.size());
    Elements out{PaneTitle("表格: " + s.table.name +
                               (s.table.exists ? "" : "  [缺失]"),
                           active),
                 text("   行数: " + std::to_string(s.table.rows.size()) +
                      "  未保存: " + std::to_string(dirty) +
                      "  过滤:" + (s.filter.empty() ? "-" : s.filter)) |
                     dim,
                 separator()};
    Slice w = Window(static_cast<int>(vis.size()), s.row_sel, lh);
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
        out.push_back(Row(line, wi == s.row_sel, active, row_width));
    }
    if (vis.empty()) out.push_back(text("  （无匹配行）") | dim);
    if (s.editing) {
        out.push_back(separator());
        out.push_back(hbox({text("编辑值> ") | bold, text(s.edit_buffer + "▏") | inverted}));
    }
    return vbox(std::move(out));
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

Element DetailPane(const AppState& s, int width, int lh) {
    bool active = s.focus == Focus::Detail && !s.editing && !s.editing_field;
    Elements out{PaneTitle("详情", active),
                 text("   " + std::string(s.detail_mode == DetailMode::Json ? "[JSON]"
                                                                            : "[表单]") +
                      "  m 切换  Enter 编辑字段") |
                     dim,
                 separator()};
    std::string raw = DetailRaw(s);
    if (raw.empty()) {
        out.push_back(text("  （无选中行）") | dim);
    } else if (s.detail_mode == DetailMode::Json) {
        Json parsed = Json::parse(raw, nullptr, /*allow_exceptions=*/false);
        std::string pretty = parsed.is_discarded() ? raw : core::py_dumps_indent(parsed);
        size_t pos = 0;
        int shown = 0;
        while (pos <= pretty.size() && shown < lh) {
            size_t nl = pretty.find('\n', pos);
            std::string line = pretty.substr(
                pos, nl == std::string::npos ? std::string::npos : nl - pos);
            out.push_back(text(Cut(line, static_cast<size_t>(width))));
            ++shown;
            if (nl == std::string::npos) break;
            pos = nl + 1;
        }
    } else {
        auto fields = FormFields(raw);
        Slice w = Window(static_cast<int>(fields.size()), s.field_sel, lh);
        for (int i = w.start; i < w.end; ++i) {
            std::string line = fields[i].first + " = " + fields[i].second;
            out.push_back(Row(line, i == s.field_sel, active, width));
        }
        if (fields.empty()) out.push_back(text("  （该记录不是 JSON object）") | dim);
    }
    if (s.editing_field) {
        out.push_back(separator());
        out.push_back(hbox({text("编辑 " + s.field_name + "> ") | bold,
                            text(s.field_buffer + "▏") | inverted}));
    }
    return vbox(std::move(out));
}

Element BrowseBody(const AppState& s, int width, int lh) {
    int left = std::clamp(width / 5, 16, 26);
    int right = std::clamp(width / 3, 24, 44);
    int mid = std::max(20, width - left - right - 2);
    return hbox({TablesPane(s, left - 1, lh), separator(),
                 RowsPane(s, mid - 1, lh), separator(),
                 DetailPane(s, right - 1, lh)});
}

// ---------------------------------------------------------------------------
// Other pages
// ---------------------------------------------------------------------------

Element ModsBody(const AppState& s, int width, int lh) {
    Elements out{hbox({text("选择模组 (Enter 进入浏览, r 刷新):")}) | bold, separator()};
    Slice w = Window(static_cast<int>(s.mods.size()), s.mod_sel, lh);
    for (int i = w.start; i < w.end; ++i)
        out.push_back(Row(s.mods[i].name, i == s.mod_sel, true, width));
    if (s.mods.empty()) out.push_back(text("  （无模组，检查后端 workspace）") | dim);
    return vbox(std::move(out));
}

Element BugfixBody(const AppState& s, int width, int lh) {
    Elements out{hbox({text("Bug 扫描/修复  模组: " + s.selected_mod + "  共 " +
                            std::to_string(s.bugs.size()) + " 条") |
                       bold,
                       filler()}),
                 text(s.bug_scanned ? "↑↓ 选择  r 重扫  f 修复全部  Esc 返回"
                                    : "按 r 扫描当前模组…") |
                     dim,
                 separator()};
    Slice w = Window(static_cast<int>(s.bugs.size()), s.bug_sel, lh);
    for (int i = w.start; i < w.end; ++i) {
        const auto& b = s.bugs[i];
        std::string label = "[" + b.flag + "] " + b.cfg + "/" + b.id + " " + b.key + ": " + b.message;
        out.push_back(Row(label, i == s.bug_sel, true, width));
    }
    if (s.bugs.empty() && s.bug_scanned) out.push_back(text("  （未发现 Bug）") | dim);
    return vbox(std::move(out));
}

Element AgentBody(const AppState& s, int width, int lh) {
    Elements out{hbox({text("AI 助手 (openai_compatible, 纯对话)") | bold, filler(),
                       text(std::string("权限: ") + s.permission_mode) | dim}),
                 text("Enter 发送  Esc 返回  Ctrl-M 切换 confirm/full") | dim,
                 separator()};
    int n = static_cast<int>(s.chat.size());
    int start = std::max(0, n - lh);
    for (int i = start; i < n; ++i) {
        const auto& m = s.chat[i];
        std::string who = m.role == "user" ? "你" : (m.role == "assistant" ? "AI" : m.role);
        out.push_back(text(Cut(who + ": " + m.content, width)));
    }
    if (n == 0) out.push_back(text("  （开始一段新对话；未配置 Key 时按 Enter 会提示）") | dim);
    out.push_back(separator());
    if (s.chat_busy) {
        out.push_back(hbox({text("输入> ") | bold, text("（生成中…）") | dim}));
    } else {
        out.push_back(hbox({text("输入> ") | bold, text(s.chat_input + "▏") | inverted}));
    }
    return vbox(std::move(out));
}

// Plugins page: the declarative inventory plus the two mutating actions
// (install a zip by path, uninstall the selected id) that the desktop plugins
// page offers.
Element PluginsBody(const AppState& s, int width, int lh) {
    Elements out{hbox({text("插件管理（声明型：常开，无启用态）") | bold, filler(),
                       text(std::to_string(s.plugins.size()) + " 个") | dim}),
                 text("↑↓ 选择  r 刷新  R 重载全部  i 安装 zip  u 卸载") | dim,
                 separator()};
    int lines = std::max(1, lh - (s.plugin_input_active ? 2 : 0));
    Slice w = Window(static_cast<int>(s.plugins.size()), s.plugin_sel, lines);
    for (int i = w.start; i < w.end; ++i) {
        const auto& p = s.plugins[i];
        std::string label = p.id + "  " + (p.name.empty() ? p.id : p.name);
        if (!p.version.empty()) label += " v" + p.version;
        label += p.loaded ? "  已加载" : "  未加载";
        if (!p.error.empty())
            label += "  ! " + p.error;
        else if (!p.author.empty())
            label += "  作者:" + p.author;
        out.push_back(Row(label, i == s.plugin_sel, true, width));
    }
    if (s.plugins.empty())
        out.push_back(text(s.plugins_loaded ? "  （未安装插件）" : "  （按 r 读取插件列表）") | dim);
    if (s.plugin_input_active) {
        out.push_back(separator());
        out.push_back(hbox({text("zip 路径> ") | bold, text(s.plugin_input + "▏") | inverted}));
    }
    return vbox(std::move(out));
}

// Cloud page: provider rail + the desktop page's dual local/remote comparison,
// with the direction/DryRun state that the sync button acts on.
Element CloudBody(const AppState& s, int width, int lh) {
    int rail = std::clamp(width / 4, 18, 32);
    int side = std::max(16, (width - rail - 2) / 2);

    Elements pv{hbox({PaneTitle("Provider", true), filler(),
                      text(std::to_string(s.providers.size())) | dim}),
                separator()};
    int pv_lines = std::max(1, lh - 5);
    Slice pw = Window(static_cast<int>(s.providers.size()), s.provider_sel, pv_lines);
    for (int i = pw.start; i < pw.end; ++i) {
        const auto& p = s.providers[i];
        pv.push_back(Row(p.name.empty() ? p.id : p.name, i == s.provider_sel, true, rail - 1));
    }
    if (s.providers.empty())
        pv.push_back(text(s.providers_loaded ? "  （无 Provider）" : "  （按 r 读取）") | dim);
    pv.push_back(separator());
    pv.push_back(text(std::string("  模组: ") + (s.selected_mod.empty() ? "-" : s.selected_mod)) |
                 dim);
    pv.push_back(text(std::string("  方向: ") + s.cloud_direction) | dim);
    pv.push_back(text(std::string("  DryRun: ") + (s.cloud_dry_run ? "开" : "关")) |
                 (s.cloud_dry_run ? dim : color(Color::Yellow)));
    if (s.cloud_delete_extra) pv.push_back(text("  清理远端多余: 开") | color(Color::Yellow));

    auto file_panel = [&](const char* title, const std::vector<CloudFile>& files) {
        Elements out{hbox({PaneTitle(title, false), filler(),
                           text(std::to_string(files.size())) | dim}),
                     separator()};
        int lines = std::max(1, lh - 2);
        for (size_t i = 0; i < files.size() && static_cast<int>(i) < lines; ++i) {
            const auto& f = files[i];
            std::string line = f.name + (f.is_dir ? "/" : "");
            out.push_back(text("  " + Cut(line, static_cast<size_t>(std::max(4, side - 2)))));
        }
        if (files.empty())
            out.push_back(text(s.cloud_files_loaded ? "  （空）" : "  （Enter 读取）") | dim);
        return vbox(std::move(out));
    };

    Elements body{hbox({vbox(std::move(pv)), separator(),
                        file_panel("本地 Mod 文件", s.cloud_local), separator(),
                        file_panel("远端文件", s.cloud_remote)})};
    if (!s.cloud_sync_summary.empty()) body.push_back(text("  " + s.cloud_sync_summary) | dim);
    if (!s.cloud_error.empty())
        body.push_back(text("  错误: " + Cut(s.cloud_error, static_cast<size_t>(width - 8))) |
                       color(Color::Red));
    return vbox(std::move(body));
}

// The permissionMode=="confirm" approval box (topmost modal).
Element ConfirmOverlayEl(const AppState& s, int width) {
    return vbox({text(s.confirm.title) | bold, separator(),
                 text("  " + Cut(s.confirm.detail, static_cast<size_t>(std::max(20, width - 8)))),
                 separator(),
                 text("  [y / Enter] 允许    [n / Esc] 拒绝") | bold}) |
           border;
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

Element SearchOverlayEl(const AppState& s, int width, int lh) {
    Elements out{hbox({text("全局搜索对白 (TalkCfg/EvtCfg)") | bold, filler()}),
                 text("输入关键词，Enter 搜索，Esc 关闭") | dim, separator()};
    out.push_back(hbox({text("搜索> ") | bold, text(s.search.input + "▏") | inverted}));
    out.push_back(separator());
    int result_lines = std::max(1, lh - 4);
    Slice w = Window(static_cast<int>(s.search.results.size()), s.search.sel, result_lines);
    for (int i = w.start; i < w.end; ++i) {
        const auto& hit = s.search.results[i];
        std::string label = "[" + hit.src + "] " + hit.talk_id + " (" + hit.evt_title + "): " +
                            hit.content;
        out.push_back(Row(label, i == s.search.sel, true, width));
    }
    if (s.search.busy) {
        out.push_back(text("  搜索中…") | dim);
    } else if (!s.search.error.empty()) {
        out.push_back(text("  错误: " + Cut(s.search.error, width - 6)) | color(Color::Red));
    } else if (s.search.results.empty()) {
        out.push_back(text("  （无结果）") | dim);
    }
    return vbox(std::move(out)) | border;
}

Element ValidateOverlayEl(const AppState& s, int width, int lh) {
    Elements out{hbox({text("校验: " + s.validate.cfg) | bold, filler()}),
                 separator()};
    if (s.validate.busy) {
        out.push_back(text("  校验中…") | dim);
    } else if (!s.validate.error.empty()) {
        out.push_back(text("  错误: " + Cut(s.validate.error, width - 6)) | color(Color::Red));
    } else {
        for (const auto& it : s.validate.issues) {
            if (static_cast<int>(out.size()) > lh) {
                out.push_back(text("  …") | dim);
                break;
            }
            std::string line = "[" + it.level + "] " +
                               (it.rid.empty() ? "" : it.rid + ": ") + it.msg;
            out.push_back(text("  " + Cut(line, static_cast<size_t>(width - 4))));
        }
        if (s.validate.issues.empty())
            out.push_back(text("  （未发现问题）") | color(Color::Green));
        out.push_back(separator());
        out.push_back(text("  counts: error=" + std::to_string(s.validate.errors) +
                           " warn=" + std::to_string(s.validate.warns) +
                           " info=" + std::to_string(s.validate.infos) + "   （按任意键关闭）") |
                       dim);
    }
    return vbox(std::move(out)) | border;
}

Element HelpBody() {
    // Kept to <=18 lines: that is all the body gets at 80x24 (height - chrome),
    // and anything longer is silently clipped at the bottom.
    return vbox({text("键位") | bold,
                 separator(),
                 text("Ctrl-D/T/B/A     模组 / 表格 / Bug / 助手"),
                 text("Ctrl-P / Ctrl-L  插件管理 / 云同步"),
                 text("Ctrl-M           权限模式 confirm ↔ full"),
                 text("Ctrl-K           全局搜索对白"),
                 text("Ctrl-S           保存补丁 / 应用修复"),
                 text("Tab/↑↓/Enter     切焦点 / 移动 / 打开·编辑·发送"),
                 text("m / n / y / d    表单↔JSON / 新增 / 复制 / 标记删除"),
                 text("v                校验当前打开的表"),
                 text("r                刷新（表·列表·Bug·插件·Provider）"),
                 text("Esc / Ctrl-Q     返回上层 / 退出"),
                 text("?                开关本帮助"),
                 text("直接输入          表列表 / 记录页过滤"),
                 separator(),
                 text("插件页: r 刷新  R 重载  i 安装zip  u 卸载"),
                 text("云同步页: Enter 读取  u/d/b 方向  y DryRun  x 清理远端  s 同步  t 测试"),
                 text("confirm 模式：保存/修复/装插件/卸载/云同步先弹审批框；dry-run 与只读不弹。") |
                     dim});
}

std::string StripAnsi(const std::string& s) {
    static const std::regex re("\x1b\\[[0-9;]*[A-Za-z]");
    return std::regex_replace(s, re, "");
}

}  // namespace

ftxui::Element BuildElement(const AppState& s, int width, int list_height) {
    Element body;
    if (s.confirm.active) {
        body = ConfirmOverlayEl(s, std::max(30, width - 8));
    } else if (s.search.active) {
        body = SearchOverlayEl(s, std::max(30, width - 8), list_height);
    } else if (s.validate.active) {
        body = ValidateOverlayEl(s, std::max(30, width - 8), list_height);
    } else if (s.show_help) {
        body = HelpBody();
    } else {
        switch (s.page) {
            case Page::Mods: body = ModsBody(s, width, list_height); break;
            case Page::Table: body = BrowseBody(s, width, list_height); break;
            case Page::Bugfix: body = BugfixBody(s, width, list_height); break;
            case Page::Agent: body = AgentBody(s, width, list_height); break;
            case Page::Plugins: body = PluginsBody(s, width, list_height); break;
            case Page::Cloud: body = CloudBody(s, width, list_height); break;
        }
    }
    return vbox({Header(s), separator(), body | flex, HintBar(s), StatusLine(s)}) | border;
}

std::string RenderPageToString(const AppState& s, int width, int height) {
    int list_height = std::max(1, height - 6);
    Element el = BuildElement(s, std::max(8, width - 2), list_height);
    auto screen = Screen::Create(Dimension::Fixed(width), Dimension::Fixed(height));
    Render(screen, el);
    return StripAnsi(screen.ToString());
}

}  // namespace p8
