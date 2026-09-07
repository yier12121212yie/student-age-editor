// sa_core: tiny string helpers used across the native backend.
//
// These are intentionally dependency-free placeholders for wave 0; they give the
// Catch2 suite something concrete to assert on and will be reused as the backend
// grows. Keep behaviour deterministic and side-effect free.
#pragma once

#include <string>
#include <string_view>

namespace sa_core {
namespace str {

// Remove leading/trailing ASCII whitespace (" \t\n\r\f\v").
std::string trim(std::string_view s);

bool starts_with(std::string_view s, std::string_view prefix);
bool ends_with(std::string_view s, std::string_view suffix);

// Replace every non-overlapping occurrence of `from` with `to`.
// `from` must be non-empty (returns `s` unchanged otherwise).
std::string replace_all(std::string s, std::string_view from, std::string_view to);

}  // namespace str
}  // namespace sa_core
