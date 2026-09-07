// sa_core: filesystem path/stat utilities mirroring the Python os.path semantics
// the cfg pipeline depends on.
//
// Mapping (Python -> C++):
//   os.path.abspath  -> sa_core::paths::abs_path   (lexical normalize, no resolve)
//   os.path.normcase -> sa_core::paths::normcase   (Windows: '/'->'\\' + lower)
//   _path_key        -> sa_core::paths::path_key   (cfg_store.py:71-73 / CONVENTIONS 4)
//   os.stat          -> sa_core::paths::stat_info  (st_mtime_ns / st_size)
//   os.utime         -> sa_core::paths::set_mtime_ns (S1 tests: forced invalidation)
//
// mtime_ns: Windows FILETIME is a 100ns grid since 1601-01-01; converted to
// ns since the Unix epoch exactly, so values are comparable with the Python
// backend's st_mtime_ns on NTFS.
#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace sa_core {
namespace paths {

// UTF-8 std::string <-> std::filesystem::path (MSVC's u8string() returns
// std::u8string, which is not implicitly convertible to std::string).
std::string path_to_utf8(const std::filesystem::path& p);
std::filesystem::path to_path(std::string_view utf8);

struct StatInfo {
    long long mtime_ns = 0;
    long long size = 0;
};

// Directory containing the running executable (""); tests use it to locate
// native/assets next to build/bin.
std::string exe_dir();

// Path separators: normalized to '/' internally for portability of string
// handling, but Win32 APIs accept '/' too; native strings keep whichever form
// they came in. All comparisons go through normcase/abs to neutralize this.
std::string join(std::string_view a, std::string_view b);
std::string dirname(std::string_view p);      // os.path.dirname
std::string basename(std::string_view p);     // os.path.basename
std::string abs_path(std::string_view p);     // os.path.abspath
std::string normcase(std::string_view p);     // os.path.normcase
std::string path_key(std::string_view p);     // normcase(abspath(p))
bool is_dir(std::string_view p);
bool is_file(std::string_view p);
bool exists(std::string_view p);
std::optional<StatInfo> stat(std::string_view p);
int64_t file_size(std::string_view p);  // missing -> -1
bool set_mtime_ns(std::string_view p, long long ns);
bool remove_file(std::string_view p);   // missing -> false
bool create_dirs(std::string_view p);   // os.makedirs(exist_ok=True)
// Remove a directory tree (shutil.rmtree(ignore_errors=True) equivalent).
bool remove_tree(std::string_view p);
// Sorted names (os.listdir + sorted): directories and files alike, no '.' entries.
std::vector<std::string> listdir_sorted(std::string_view p, bool* ok = nullptr);
std::optional<std::string> read_bytes(std::string_view p);  // any IO failure -> nullopt
bool write_bytes_simple(std::string_view p, std::string_view data);  // truncate-write

}  // namespace paths
}  // namespace sa_core
