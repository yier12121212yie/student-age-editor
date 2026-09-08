// sa_core/steam_paths: the C++ port of `backend/editor/core/steam_paths.py`
// (cross-platform Steam library / game / Mods discovery, P2 wave).
//
// Platform behaviour (mirrors the Python docstring):
//   * Windows: HKCU\Software\Valve\Steam\SteamPath registry read (advapi32)
//     + Program Files fallbacks, then libraryfolders.vdf enumeration.
//   * Linux:   ~/.steam/steam, ~/.steam/root, ~/.local/share/Steam, Flatpak.
//   * macOS:   ~/Library/Application Support/Steam.
// Non-Windows probing is compile-time guarded; this build primarily exercises
// the _WIN32 branch, the POSIX branches are HOME-based best-effort ports.
//
// Contract isolation switch (P2 addition, no Python counterpart — the golden
// recording patches steam_paths in-process, see golden/README.md §3):
//   EDITOR_DISABLE_STEAM_DETECT=1 (also "true"/"yes"/"on", like the
//   EDITOR_NO_OOBE tri-state accepted values) suppresses every machine probe:
//   registry, Program Files, libraryfolders.vdf, Proton prefixes and the
//   workshop content scan. workshop_mods_roots() then still honours an
//   explicit "workshop_root" from editor_env.json (a configured path is not
//   a discovery), so a test environment can inject fake workshop roots the
//   same way the Python mock did.
//
// `user_mods_dir()` on Windows never touches Steam (pure %USERPROFILE% join),
// so it is NOT suppressed by the switch — /api/oobe/status and the
// workspace fallback need a stable suggested value under isolation too.
#pragma once

#include <string>
#include <vector>

namespace sa_core {
namespace steam_paths {

// steam_paths.py:24-26 constants.
inline constexpr const char* kGameAppid = "1991040";
inline constexpr const char* kGameDirName = "StudentAge";
inline constexpr const char* kGamePublisher = "PakyiGame";

// True when EDITOR_DISABLE_STEAM_DETECT is set to a truthy value.
bool steam_detect_disabled();

// _steam_root_candidates (steam_paths.py:34-61): unfiltered candidates.
std::vector<std::string> steam_root_candidates();

// steam_library_paths (steam_paths.py:64-94): install roots + every
// libraryfolders.vdf "path", dirs-only, normcase-deduplicated
// (vdf-discovered entries first, matching the Python `libs + roots` order).
std::vector<std::string> steam_library_paths();

// game_install_dirs (steam_paths.py:97-100).
std::vector<std::string> game_install_dirs();

// detect_game_aa_dir (steam_paths.py:103-112): "" when not found or the
// switch is on.
std::string detect_game_aa_dir();

// proton_mods_dirs (steam_paths.py:115-126): always [] on Windows/macOS.
std::vector<std::string> proton_mods_dirs();

// user_mods_dir (steam_paths.py:129-150): the default local Mods workspace.
std::string user_mods_dir();

// workshop_mods_roots (steam_paths.py:153-185): editor_env.json workshop_root
// override first (when it names an existing directory), then one
// <library>/steamapps/workshop/content/<appid> per discovered library.
// `editor_root` is the directory holding editor_env.json (injected by the
// caller; sa_core has no notion of the server's data root).
std::vector<std::string> workshop_mods_roots(const std::string& editor_root);

// Valve VDF text enumeration: collect every string value stored under a key
// named `key` (any nesting depth). Handles quoted strings with \\ and \"
// escapes, nested { } blocks, bare-word blocks and // line comments — a
// strictly better parser than the Python line heuristic it replaces while
// agreeing on every realistic libraryfolders.vdf.
std::vector<std::string> vdf_collect_string_values(const std::string& text,
                                                   const std::string& key);

// Parse + filter helper: the raw "path" values of one libraryfolders.vdf
// document (used by steam_library_paths and by the [p2] tests).
std::vector<std::string> parse_libraryfolders_vdf(const std::string& text);

}  // namespace steam_paths
}  // namespace sa_core
