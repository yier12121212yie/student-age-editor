#include "p8_theme.h"

#include <algorithm>

#include <ftxui/dom/elements.hpp>

namespace p8 {
namespace theme {

using namespace ftxui;

namespace {
Color Hex(unsigned rgb) {
    return Color::RGB(static_cast<uint8_t>((rgb >> 16) & 0xFF),
                      static_cast<uint8_t>((rgb >> 8) & 0xFF),
                      static_cast<uint8_t>(rgb & 0xFF));
}

// Cut to at most `n` code points (single-line display budget).
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
}  // namespace

Color BgLeft() { return Hex(0x252526); }
Color BgMiddle() { return Hex(0x1e1e1e); }
Color BgRight() { return Hex(0x1f1f1f); }
Color AccentBlue() { return Hex(0x007acc); }
Color ButtonBlue() { return Hex(0x0e639c); }
Color TextMain() { return Hex(0xd4d4d4); }
Color TextDim() { return Hex(0x858585); }
Color DirtyRed() { return Hex(0xf48771); }
Color SyncGreen() { return Hex(0x89d185); }
Color WarnColor() { return Hex(0xa66a00); }
Color ErrorColor() { return Hex(0xbe1100); }
Color FocusPurple() { return Hex(0x6c5ce7); }
Color SectionOrange() { return Hex(0xff8c00); }

Element PanelTitleBar(const std::string& emoji, const std::string& title, bool focused) {
    Element bar = hbox({text(" " + emoji + " " + title), filler()}) |
                  bgcolor(focused ? AccentBlue() : Hex(0x3a3d41)) |
                  color(Color::White) | bold;
    return bar;
}

Element HintLine(const std::string& hint) {
    return text(" " + hint) | color(TextDim());
}

Element ModalFrame(Element content, const std::string& title, const std::string& hint,
                   int width, int max_height) {
    size_t budget = static_cast<size_t>(std::max(8, width - 6));
    Elements rows;
    rows.push_back(hbox({text(" " + Cut(title, budget)) | bold | color(Color::White),
                         filler()}));
    rows.push_back(separator());
    rows.push_back(std::move(content));
    if (!hint.empty()) {
        rows.push_back(separator());
        rows.push_back(hbox({text(" " + Cut(hint, budget)) | color(TextDim()), filler()}));
    }
    Element box = vbox(std::move(rows)) |
                  borderStyled(BorderStyle::HEAVY, AccentBlue()) |
                  bgcolor(BgRight()) | size(WIDTH, LESS_THAN, width) |
                  size(HEIGHT, LESS_THAN, max_height);
    return vbox({filler(), hbox({filler(), std::move(box), filler()}), filler()});
}

namespace {
// Error-ish transient messages flip the bar red (the Alpha's error variant).
bool StatusIsError(const std::string& s) {
    static const char* markers[] = {"错误", "失败", "error", "Error", "ERROR", "未连接",
                                    "cannot", "无法"};
    for (const char* m : markers)
        if (s.find(m) != std::string::npos) return true;
    return false;
}
}  // namespace

Element StatusBar(const AppState& s, int width) {
    (void)width;
    const bool dirty = !s.table.edits.empty() || !s.table.removes.empty() || !s.table.adds.empty();
    std::string line1 = " Workspace: " + (s.selected_mod.empty() ? "-" : s.selected_mod) +
                        " · " + std::to_string(s.mods.size()) + " mods · 表 " +
                        (s.table.name.empty() ? "-" : s.table.name) +
                        " · 权限: " + s.permission_mode +
                        (s.no_code_mode ? " · 无代码" : "") +
                        (dirty ? " · 未保存 " + std::to_string(s.table.edits.size() +
                                                               s.table.removes.size() +
                                                               s.table.adds.size())
                               : "");
    Color bg = StatusIsError(s.status) ? ErrorColor() : AccentBlue();
    Element bar = vbox({
                       hbox({text(line1) | bold, filler()}),
                       hbox({text(" " + (s.status.empty() ? " " : s.status)), filler()}),
                   }) |
                   bgcolor(bg) | color(Color::White);
    return bar;
}

Element HeaderBar() {
    return hbox({
               text(" 学生时代 · 模组编辑器 — TUI") | bold,
               text("  终端版 · 直接读写 Cfgs 文件") | color(Hex(0xcfd8dc)),
               filler(),
           }) |
           bgcolor(AccentBlue()) | color(Color::White);
}

std::vector<std::string> WelcomeLines() {
    // Each line fits the right pane's minimum 30 columns (80-col terminals).
    return {
        "# 学生时代 · TUI 编辑器",
        "",
        "① 左栏 Enter 选择模组并展开",
        "② Enter 打开 Cfg 表",
        "③ ↑↓ 选行 Enter 编辑记录",
        "④ m 切换 JSON/表单",
        "⑤ Ctrl-S 保存 · v 校验",
        "⑥ ? 键位  a AI  p 插件",
        "　 c 云同步  b Bug 扫描",
    };
}

}  // namespace theme
}  // namespace p8
