// native/tui/p8_render.h — AppState -> FTXUI DOM, plus a headless string renderer.
//
// Lives at the native/tui/ root (not under tui/tui/) so the Catch2 suite can render the
// panel to a string and assert on it (the two required FTXUI snapshot tests)
// without dragging in the interactive event loop. Rendering is a pure function of
// the view-model; no state, no I/O.
#pragma once

#include <string>

#include <ftxui/dom/elements.hpp>

#include "p8_model.h"

namespace p8 {

// Build the DOM element for the current page. `width` bounds row text (no
// wrapping) and `list_height` is how many rows the selectable list window shows.
ftxui::Element BuildElement(const AppState& s, int width, int list_height);

// Convenience for --render-check and snapshot tests: render the panel to a plain
// string (ANSI colors stripped) at the given fixed size.
std::string RenderPageToString(const AppState& s, int width, int height);

}  // namespace p8
