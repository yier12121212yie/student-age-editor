// sa_core: version / identity constants for the native backend.
#pragma once

namespace sa_core {

// Semantic version of the sa_core static library / scaffold.
inline constexpr int kVersionMajor = 0;
inline constexpr int kVersionMinor = 1;
inline constexpr int kVersionPatch = 0;

// Dotted version string, e.g. "0.1.0".
const char* version() noexcept;

// The application identifier the HTTP /api/ping contract reports as "app".
// Kept here so core, server and tests agree on one literal.
const char* app_name() noexcept;

}  // namespace sa_core
