// wip/P3b sandbox: port of backend/editor/server/fs_tools.py (151 lines).
//
// Every path enters through resolve(): _norm rejects absolute paths, drive
// letters and ".." escapes with the verbatim message
// "path escapes sandbox: <repr>" (the selftest asserts the "escapes"
// substring), then the joined absolute path must still sit under the sandbox
// root. Read/write responses echo the *raw* rel_path the caller passed.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {
namespace p3b {

using json = nlohmann::ordered_json;

// fs_tools.TEXT_EXTS / BINARY_EXTS (extension-with-dot, lowercase).
extern const std::vector<std::string> kTextExts;
extern const std::vector<std::string> kBinaryExts;
inline constexpr long long kMaxListEntries = 2000;      // MAX_LIST_ENTRIES
inline constexpr long long kMaxFileBytes = 8 * 1024 * 1024;  // MAX_FILE_BYTES

// fs_tools._norm: normalized relative path ("" for "."/empty); throws
// SandboxError on escapes. Declared in server/state.h (wave-1 P2 landed it
// there because _cfg_path shares it) — re-exported for readability.
std::string norm_rel(const std::string& rel_path);

// fs_tools.resolve: absolute path for a sandbox-relative one.
std::string resolve(const std::string& root, const std::string& rel_path);

// fs_tools.list_dir (deep recurses to depth 4, MAX_LIST_ENTRIES cap).
json list_dir(const std::string& root, const std::string& rel_path, bool deep);

// fs_tools.read_file: {"path","size","text"} or {"path","size","base64"}.
json read_file(const std::string& root, const std::string& rel_path, bool as_binary);

// fs_tools.write_file: text content or base64; parent dirs auto-created.
json write_file(const std::string& root, const std::string& rel_path,
                const std::string& content, bool base64_mode);

// fs_tools.stat_path.
json stat_path(const std::string& root, const std::string& rel_path);

// os.path.splitext(p)[1].lower()
std::string ext_of(const std::string& path);

// Directory walk counting files (os.walk; resource_pack._count_files).
long long count_files_recursive(const std::string& dir);
// Any "*.json" file anywhere under dir (resource_pack has_content fallback).
bool has_any_json_recursive(const std::string& dir);

}  // namespace p3b
}  // namespace sa
