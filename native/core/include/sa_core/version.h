// sa_core: version / identity constants for the native backend.
#pragma once

namespace sa_core {

// Semantic version of the sa_core static library / scaffold.
inline constexpr int kVersionMajor = 0;
inline constexpr int kVersionMinor = 1;
inline constexpr int kVersionPatch = 0;

// Dotted version string, e.g. "0.1.0".
const char* version() noexcept;

// Release version the ship was built as, i.e. the GitHub release tag form the
// updater compares against (e.g. "Alpha-v0.6"). Injected at configure time via
// -DSA_APP_VERSION=<version> (build_release.py / release.yml pass the same
// string used for the artifact names). Plain dev builds fall back to "dev",
// which carries no numeric version and so is always reported as outdated by
// the update check -- the GUI labels it a development build.
const char* app_version() noexcept;

// The application identifier the HTTP /api/ping contract reports as "app".
// Kept here so core, server and tests agree on one literal.
const char* app_name() noexcept;

}  // namespace sa_core
