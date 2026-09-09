// wip/P8/p8_render.cpp
#include "p8_render.h"

#include <algorithm>
#include <regex>
#include <string>
#include <vector>

#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/screen.hpp>

#include "p8_cfg.h"  // ValuePreview reuse for consistent truncation semantics

namespace p8 {
namespace {

using namespace ftxui;

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
Element Row(const std::string& label, bool selected, int width) {
    std::string text_ = (selected ? "» " : "  ") + Cut(label, static_cast<size_t>(std::max(0, width - 2)));
    Element e = text(text_);
    return selected ? (e | inverted) : e;
}

const char* PageName(Page p) {
    switch (p) {
        case Page::Mods: return "模组";
        case Page::Tables: return "表列表";
        case Page::Table: return "表格";
        case Page::Bugfix: return "Bug 扫描";
        case Page::Agent: return "AI 助手";
    }
    return "?";
}

Element Header(const AppState& s) {
    std::string title = std::string("学生时代 · 编辑器 TUI") + "  |  " + PageName(s.page);
    return hbox({text(Cut(title, 60)) | bold, filler(),
                 text("[?] 帮助  [Ctrl-Q] 退出") | dim});
}

Element StatusLine(const AppState& s) {
    return text("  " + Cut(s.status, 120)) | dim;
}

Element ModsBody(const AppState& s, int width, int lh) {
    Elements out{hbox({text("选择模组 (Enter 进入表列表, r 刷新):")}) | bold, separator()};
    Slice w = Window(static_cast<int>(s.mods.size()), s.mod_sel, lh);
    for (int i = w.start; i < w.end; ++i)
        out.push_back(Row(s.mods[i].name, i == s.mod_sel, width));
    if (s.mods.empty()) out.push_back(text("  （无模组，检查后端 workspace）") | dim);
    return vbox(std::move(out));
}

Element TablesBody(const AppState& s, int width, int lh) {
    std::vector<std::string> shown;
    for (const auto& t : s.tables) {
        std::string low = t;
        for (auto& c : low) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        std::string f = s.table_filter;
        for (auto& c : f) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if (f.empty() || low.find(f) != std::string::npos) shown.push_back(t);
    }
    Elements out{hbox({text("模组: " + s.selected_mod + "   过滤: " +
                            (s.table_filter.empty() ? "-" : s.table_filter)) |
                       bold,
                       filler()}),
                 text("↑↓ 选择  Enter 打开  r 刷新  Esc 返回") | dim,
                 separator()};
    Slice w = Window(static_cast<int>(shown.size()), s.table_sel, lh);
    for (int i = w.start; i < w.end; ++i) out.push_back(Row(shown[i], i == s.table_sel, width));
    if (shown.empty()) out.push_back(text("  （该模组没有配置表）") | dim);
    return vbox(std::move(out));
}

Element TableBody(const AppState& s, int width, int lh) {
    auto vis = s.VisibleRows();
    int dirty = static_cast<int>(s.table.edits.size()) + static_cast<int>(s.table.removes.size());
    Elements out{hbox({text("表: " + s.table.name + "  行数: " + std::to_string(s.table.rows.size()) +
                            "  未保存: " + std::to_string(dirty) +
                            (s.table.exists ? "" : "  [缺失]")) |
                       bold,
                       filler()}),
                 text("↑↓ 行  Enter 编辑  d 删除  Ctrl-S 保存  过滤:" +
                      (s.filter.empty() ? "-" : s.filter) + "  Esc 返回") |
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
        out.push_back(Row(line, wi == s.row_sel, row_width));
    }
    if (vis.empty()) out.push_back(text("  （无匹配行）") | dim);
    if (s.editing) {
        out.push_back(separator());
        out.push_back(hbox({text("编辑值> ") | bold, text(s.edit_buffer + "▏") | inverted}));
    }
    return vbox(std::move(out));
}

Element BugfixBody(const AppState& s, int width, int lh) {
    Elements out{hbox({text("Bug 扫描/修复  共 " + std::to_string(s.bugs.size()) + " 条") | bold,
                       filler()}),
                 text(s.bug_scanned ? "↑↓ 选择  r 重扫  f 修复全部  Esc 返回"
                                    : "按 r 扫描当前模组…") |
                     dim,
                 separator()};
    Slice w = Window(static_cast<int>(s.bugs.size()), s.bug_sel, lh);
    for (int i = w.start; i < w.end; ++i) {
        const auto& b = s.bugs[i];
        std::string label = "[" + b.flag + "] " + b.cfg + "/" + b.id + " " + b.key + ": " + b.message;
        out.push_back(Row(label, i == s.bug_sel, width));
    }
    if (s.bugs.empty() && s.bug_scanned) out.push_back(text("  （未发现 Bug）") | dim);
    return vbox(std::move(out));
}

Element AgentBody(const AppState& s, int width, int lh) {
    Elements out{hbox({text("AI 助手 (openai_compatible, 纯对话)") | bold, filler()}),
                 text("Enter 发送  Esc 返回") | dim,
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

Element HelpBody() {
    return vbox({text("键位") | bold,
                 text("↑/↓        列表移动"),
                 text("Enter      进入 / 编辑 / 发送"),
                 text("d          标记删除当前行"),
                 text("Ctrl-S     保存 / 修复"),
                 text("Ctrl-R     重新扫描 Bug (在 Bug 页)"),
                 text("Ctrl-D/T/B/A  切换 模组/表/Bug/助手 页"),
                 text("r          刷新当前列表"),
                 text("Esc        返回上层"),
                 text("Ctrl-Q     退出"),
                 text("?          开关本帮助")});
}

std::string StripAnsi(const std::string& s) {
    static const std::regex re("\x1b\\[[0-9;]*[A-Za-z]");
    return std::regex_replace(s, re, "");
}

}  // namespace

ftxui::Element BuildElement(const AppState& s, int width, int list_height) {
    Element body;
    if (s.show_help) {
        body = HelpBody();
    } else {
        switch (s.page) {
            case Page::Mods: body = ModsBody(s, width, list_height); break;
            case Page::Tables: body = TablesBody(s, width, list_height); break;
            case Page::Table: body = TableBody(s, width, list_height); break;
            case Page::Bugfix: body = BugfixBody(s, width, list_height); break;
            case Page::Agent: body = AgentBody(s, width, list_height); break;
        }
    }
    return vbox({Header(s), separator(), body | flex, StatusLine(s)}) | border;
}

std::string RenderPageToString(const AppState& s, int width, int height) {
    int list_height = std::max(1, height - 6);
    Element el = BuildElement(s, std::max(8, width - 2), list_height);
    auto screen = Screen::Create(Dimension::Fixed(width), Dimension::Fixed(height));
    Render(screen, el);
    return StripAnsi(screen.ToString());
}

}  // namespace p8
