// p8_theme.h — the Alpha-v0.3 (Python Textual) look, ported to FTXUI.
//
// The Python TUI was a VS Code Dark+ pastiche: blue #007acc panel title bars,
// layered gray backgrounds (#252526 / #1e1e1e / #1f1f1f), purple #6c5ce7 focus
// accents and semantic status colors. Those hex values and the shared chrome
// builders (panel title bar / modal frame / hint line) live here so the
// renderer keeps only layout. Everything returns ftxui Elements/Decorators and
// stays a pure function of its arguments.
#pragma once

#include <string>

#include <ftxui/dom/elements.hpp>

#include "p8_model.h"

namespace p8 {
namespace theme {

using ftxui::Color;

// ---- VS Code Dark+ palette (Alpha-v0.3 parity) ----------------------------
Color BgLeft();      // #252526 left pane / button row
Color BgMiddle();    // #1e1e1e middle pane
Color BgRight();     // #1f1f1f right pane / modals
Color AccentBlue();  // #007acc title bars + status bar
Color ButtonBlue();  // #0e639c primary button
Color TextMain();    // #d4d4d4 body text
Color TextDim();     // #858585 de-emphasised text
Color DirtyRed();    // #f48771 unsaved-changes title
Color SyncGreen();   // #89d185 synced title / success text
Color WarnColor();   // #a66a00 warning
Color ErrorColor();  // #be1100 error
Color FocusPurple();// #6c5ce7 focused input border (form mode)
Color SectionOrange();  // #ff8c00 form section headers

// ---- shared chrome --------------------------------------------------------

// The blue full-width panel title bar: `emoji + title` in white bold on
// AccentBlue, padded to the pane width. `focused` panes keep the saturated
// blue; unfocused ones dim it toward gray so the eye follows the keyboard.
ftxui::Element PanelTitleBar(const std::string& emoji, const std::string& title, bool focused);

// A dim gray hint line (` ↑↓ 选择  Enter 打开 …`) like the panes' bottom bars.
ftxui::Element HintLine(const std::string& text);

// Alpha modal chrome: a centered box with a heavy blue border, the emoji title
// on the top edge's inside and the gray key-hint line at the bottom.
// `content` is the modal body; `title` already carries its emoji.
ftxui::Element ModalFrame(ftxui::Element content, const std::string& title,
                          const std::string& hint, int width, int max_height);

// The bottom status bar: blue background like the Alpha right-pane status.
// `status` is the transient message; an error-ish message flips the bar to
// ErrorColor the way the Alpha's error variant did.
ftxui::Element StatusBar(const AppState& s, int width);

// Blue full-width app header: `学生时代 · 模组编辑器 — TUI — 终端版 · …`.
ftxui::Element HeaderBar();

// The startup welcome block shown in the detail pane until a table is open.
std::vector<std::string> WelcomeLines();

}  // namespace theme
}  // namespace p8
