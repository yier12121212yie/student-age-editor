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
    (void)focused;  // the Alpha keeps every title strip #007acc; focus shows
                    // on the panel border instead.
    Element bar = hbox({text(" " + emoji + " " + title), filler()}) |
                  bgcolor(AccentBlue()) | color(Color::White) | bold;
    return bar;
}

Color PanelBorder(bool focused) {
    // $primary 30% over the #1e1e1e surface ≈ RGB(0x15,0x2b,0x53).
    return focused ? AccentBlue() : Color::RGB(0x15, 0x2b, 0x53);
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

// Success-ish messages go green (Alpha's -success class).
bool StatusIsSuccess(const std::string& s) {
    static const char* markers[] = {"已保存", "已创建", "已卸载", "已安装", "已重载", "已修复",
                                    "已格式化", "已是最新", "已切换", "通过", "成功", "已连接"};
    for (const char* m : markers)
        if (s.find(m) != std::string::npos) return true;
    return false;
}

// Warning-ish messages go amber (Alpha's -warning class: unsaved changes etc).
bool StatusIsWarning(const std::string& s) {
    static const char* markers[] = {"未保存", "无改动", "未选择", "未发现", "请先", "尚不",
                                    "（按", "丢弃", "不存在"};
    for (const char* m : markers)
        if (s.find(m) != std::string::npos) return true;
    return false;
}
}  // namespace

Element StatusBar(const AppState& s, int width) {
    (void)width;
    const std::string& msg = s.status.empty() ? std::string(" ") : s.status;
    Color bg = AccentBlue();
    if (StatusIsError(msg)) bg = ErrorColor();
    else if (StatusIsSuccess(msg)) bg = Hex(0x16825d);
    else if (StatusIsWarning(msg)) bg = WarnColor();
    const bool dirty = !s.table.edits.empty() || !s.table.removes.empty() || !s.table.adds.empty();
    Element bar = hbox({text(" " + msg), filler(),
                        dirty ? text(" 有未保存改动 · s 保存 ") | bold : text("")}) |
                  bgcolor(bg) | color(Color::White) | bold;
    return bar;
}

Element HeaderBar(const AppState& s) {
    std::string title = "学生时代 · 模组编辑器 — TUI";
    if (!s.selected_mod.empty())
        title += " — " + s.selected_mod +
                 (s.workspace.empty() ? "" : " @ " + s.workspace);
    std::string flags = (s.permission_mode.empty() ? "" : "权限 " + s.permission_mode) +
                        (s.no_code_mode ? " · 无代码" : "");
    Elements mid{text(title) | bold};
    if (!flags.empty()) mid.push_back(text("  " + flags) | color(Hex(0xcfd8dc)));
    return hbox({text(" ○"), filler(), hbox(std::move(mid)), filler(), text(" ")}) |
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
