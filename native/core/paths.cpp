#include "sa_core/paths.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>

#ifdef _WIN32
#else
#include <fcntl.h>     // AT_FDCWD (utimensat)
#include <sys/stat.h>  // utimensat, struct timespec (Linux + macOS)
#include <unistd.h>    // readlink (/proc/self/exe on Linux)
#ifdef __APPLE__
#include <mach-o/dyld.h>  // _NSGetExecutablePath: no /proc/self/exe on macOS
#include <cstdint>        // uint32_t
#endif
#endif

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace sa_core {
namespace paths {
namespace {

namespace fs = std::filesystem;

// All internal path strings are UTF-8; std::filesystem on Windows treats narrow
// strings as ANSI, so every entry point goes through u8 conversion.
fs::path to_fs(std::string_view utf8) {
    return fs::path(std::u8string_view(reinterpret_cast<const char8_t*>(utf8.data()),
                                       utf8.size()));
}

std::string from_fs(const fs::path& p) { return path_to_utf8(p); }

}  // namespace

std::string path_to_utf8(const fs::path& p) {
    std::u8string u8 = p.u8string();
    return std::string(reinterpret_cast<const char*>(u8.data()), u8.size());
}

std::filesystem::path to_path(std::string_view utf8) { return to_fs(utf8); }

std::string exe_dir() {
#ifdef _WIN32
    wchar_t buf[4096];
    DWORD n = GetModuleFileNameW(nullptr, buf, 4096);
    if (n > 0 && n < 4096) return from_fs(fs::path(buf).parent_path());
#elif defined(__APPLE__)
    // macOS: no /proc/self/exe. _NSGetExecutablePath fills the caller buffer
    // and returns -1 (setting n to the required size) if 4096 is too small.
    char buf[4096];
    uint32_t n = sizeof(buf);
    if (_NSGetExecutablePath(buf, &n) == 0) {
        return from_fs(fs::path(buf).parent_path());
    }
#else
    char buf[4096];
    ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        return from_fs(fs::path(buf).parent_path());
    }
#endif
    return {};
}

std::string join(std::string_view a, std::string_view b) {
    fs::path pa = to_fs(a);
    fs::path pb = to_fs(b);
    if (pb.is_absolute()) return from_fs(pb);
    return from_fs(pa / pb);
}

std::string dirname(std::string_view p) {
    fs::path x = to_fs(p);
    fs::path parent = x.parent_path();
    if (parent == x) {  // root and "" are their own parent; Python yields '' for "x"
        return std::string();
    }
    return from_fs(parent);
}

std::string basename(std::string_view p) {
    return from_fs(to_fs(p).filename());
}

std::string abs_path(std::string_view p) {
    // os.path.abspath = normpath(join(cwd, path)): lexical, no symlink resolve,
    // no filesystem access (matches Python semantics for missing files).
    std::error_code ec;
    fs::path x = to_fs(p);
    if (!x.is_absolute()) {
        x = fs::current_path(ec) / x;
    }
    x = x.lexically_normal();
    // lexically_normal("C:\\a\\..\\") leaves "C:\\a"; Python normpath collapses
    // trailing ".." segments identically after join — close enough for our use
    // (all inputs are already normalized by their producers), and equality only
    // ever happens through normcase on both sides.
    std::string out = from_fs(x);
    // Python normpath strips trailing separators (except roots); lexically_normal
    // already drops them.
    return out;
}

std::string normcase(std::string_view p) {
    std::string s(p);
#ifdef _WIN32
    std::replace(s.begin(), s.end(), '/', '\\');
#endif
    // ASCII-only lowering: Python's str.lower() is Unicode-aware but every
    // affected codepoint here (drive letters, "Cfgs", "zh-cn") is ASCII; CJK
    // mod names have no case mapping and must pass through byte-exact.
    for (char& c : s) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return s;
}

std::string path_key(std::string_view p) { return normcase(abs_path(p)); }

bool is_dir(std::string_view p) {
    std::error_code ec;
    return fs::is_directory(to_fs(p), ec);
}

bool is_file(std::string_view p) {
    std::error_code ec;
    return fs::is_regular_file(to_fs(p), ec);
}

bool exists(std::string_view p) {
    std::error_code ec;
    return fs::exists(to_fs(p), ec);
}

#ifdef _WIN32
// FILETIME (100ns since 1601-01-01) -> ns since Unix epoch.
long long filetime_to_ns(const FILETIME& ft) {
    unsigned long long raw = (static_cast<unsigned long long>(ft.dwHighDateTime) << 32) |
                             ft.dwLowDateTime;
    constexpr unsigned long long kEpochDiff100ns = 116444736000000000ULL;
    if (raw < kEpochDiff100ns) return 0;
    return static_cast<long long>((raw - kEpochDiff100ns) * 100ULL);
}

FILETIME ns_to_filetime(long long ns) {
    constexpr unsigned long long kEpochDiff100ns = 116444736000000000ULL;
    unsigned long long raw = kEpochDiff100ns + static_cast<unsigned long long>(ns) / 100ULL;
    FILETIME ft;
    ft.dwLowDateTime = static_cast<DWORD>(raw & 0xFFFFFFFFu);
    ft.dwHighDateTime = static_cast<DWORD>(raw >> 32);
    return ft;
}
#endif

std::optional<StatInfo> stat(std::string_view p) {
#ifdef _WIN32
    std::wstring w = to_fs(p).wstring();
    WIN32_FILE_ATTRIBUTE_DATA data;
    if (!GetFileAttributesExW(w.c_str(), GetFileExInfoStandard, &data)) {
        return std::nullopt;
    }
    StatInfo info;
    info.mtime_ns = filetime_to_ns(data.ftLastWriteTime);
    LARGE_INTEGER sz;
    sz.HighPart = static_cast<LONG>(data.nFileSizeHigh);
    sz.LowPart = data.nFileSizeLow;
    info.size = static_cast<long long>(sz.QuadPart);
    return info;
#else
    std::error_code ec;
    fs::file_status st = fs::status(to_fs(p), ec);
    if (ec) return std::nullopt;
    auto ftime = fs::last_write_time(to_fs(p), ec);
    if (ec) return std::nullopt;
    StatInfo info;
    // file_time_type::clock (std::chrono::file_clock on libstdc++/libc++) has
    // its OWN epoch, not the Unix one — raw time_since_epoch was off by ~204
    // years (negative epoch ns), which poisoned every mtime_ns consumer
    // (A10 fingerprints, need_sync comparisons) and fed a negative tv_nsec
    // into utimensat (EINVAL). to_sys() converts to the Unix-epoch grid that
    // os.stat().st_mtime_ns — and the Windows FILETIME branch above — define.
    auto sys_time = decltype(ftime)::clock::to_sys(ftime);
    info.mtime_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(sys_time.time_since_epoch())
            .count();
    info.size = static_cast<long long>(fs::file_size(to_fs(p), ec));
    return info;
#endif
}

int64_t file_size(std::string_view p) {
    auto st = stat(p);
    return st ? st->size : -1;
}

bool set_mtime_ns(std::string_view p, long long ns) {
#ifdef _WIN32
    std::wstring w = to_fs(p).wstring();
    HANDLE h = CreateFileW(w.c_str(), FILE_WRITE_ATTRIBUTES,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    FILETIME ft = ns_to_filetime(ns);
    BOOL ok = SetFileTime(h, nullptr, nullptr, &ft);
    CloseHandle(h);
    return ok != FALSE;
#else
    // Linux/macOS: utimensat at ns precision — shutil.copy2's mtime face, used
    // by cloud_sync copy2 (server/services/cloud_sync.cpp:447-452) to carry a
    // synced file's source mtime onto the local copy so need_sync's mtime
    // comparison sees it as unchanged. UTIME_OMIT leaves atime alone; the
    // Windows branch above likewise only sets the write time. AT_FDCWD + no
    // flags = plain os.utime(path, ns=...), following symlinks like Python.
    struct timespec times[2];
    times[0].tv_sec = 0;
    times[0].tv_nsec = UTIME_OMIT;
    times[1].tv_sec = static_cast<time_t>(ns / 1000000000LL);
    times[1].tv_nsec = static_cast<long>(ns % 1000000000LL);
    std::string np = path_to_utf8(to_fs(p));
    return ::utimensat(AT_FDCWD, np.c_str(), times, 0) == 0;
#endif
}

bool remove_file(std::string_view p) {
    std::error_code ec;
    return fs::remove(to_fs(p), ec);
}

bool create_dirs(std::string_view p) {
    std::error_code ec;
    if (fs::is_directory(to_fs(p))) return true;
    fs::create_directories(to_fs(p), ec);
    return !ec;
}

bool remove_tree(std::string_view p) {
    // shutil.rmtree(ignore_errors=True) parity for callers that don't care, but
    // report the real outcome: error_code must be clear (or the tree absent).
    std::error_code ec;
    fs::remove_all(to_fs(p), ec);
    return !ec;
}

std::vector<std::string> listdir_sorted(std::string_view p, bool* ok) {
    std::vector<std::string> out;
#ifdef _WIN32
    std::wstring w = to_fs(p).wstring();
    if (!w.empty() && (w.back() == L'\\' || w.back() == L'/')) w.pop_back();
    w += L"\\*";
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(w.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) {
        if (ok) *ok = false;
        return out;
    }
    if (ok) *ok = true;
    do {
        std::wstring name = fd.cFileName;
        if (name == L"." || name == L"..") continue;
        out.push_back(from_fs(fs::path(std::wstring(name))));
    } while (FindNextFileW(h, &fd));
    FindClose(h);
#else
    std::error_code ec;
    fs::directory_iterator it(to_fs(p), fs::directory_options::skip_permission_denied, ec);
    if (ec) {
        if (ok) *ok = false;
        return out;
    }
    if (ok) *ok = true;
    for (const auto& e : it) out.push_back(from_fs(e.path().filename()));
#endif
    std::sort(out.begin(), out.end());  // UTF-8 byte order == codepoint order
    return out;
}

std::optional<std::string> read_bytes(std::string_view p) {
    // open("rb") + read(): any OSError -> None (cfg_store.read_raw).
    std::ifstream f(to_fs(p), std::ios::binary);
    if (!f) return std::nullopt;
    std::string out;
    if (!f.seekg(0, std::ios::end)) return std::nullopt;
    const std::streampos end = f.tellg();
    if (end < 0) return std::nullopt;  // tellg() == -1 must not become SIZE_MAX
    out.resize(static_cast<size_t>(end));
    f.seekg(0, std::ios::beg);
    size_t off = 0;
    while (off < out.size()) {
        f.read(out.data() + off, static_cast<std::streamsize>(out.size() - off));
        std::streamsize got = f.gcount();
        if (got <= 0) {
            out.resize(off);
            break;
        }
        off += static_cast<size_t>(got);
    }
    return out;
}

bool write_bytes_simple(std::string_view p, std::string_view data) {
    std::ofstream f(to_fs(p), std::ios::binary | std::ios::trunc);
    if (!f) return false;
    f.write(data.data(), static_cast<std::streamsize>(data.size()));
    f.flush();
    return f.good();
}

#ifdef _WIN32
namespace {
std::wstring utf8_to_wide(std::string_view s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (n <= 0) return {};
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return w;
}

std::string wide_to_utf8(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0,
                                nullptr, nullptr);
    if (n <= 0) return {};
    std::string s(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr,
                        nullptr);
    return s;
}
}  // namespace
#endif

std::string getenv_utf8(const char* name) {
#ifdef _WIN32
    std::wstring wn = utf8_to_wide(name);
    DWORD n = GetEnvironmentVariableW(wn.c_str(), nullptr, 0);
    if (n == 0) return {};  // missing or empty
    std::wstring buf(static_cast<size_t>(n), L'\0');
    DWORD got = GetEnvironmentVariableW(wn.c_str(), buf.data(), n);
    if (got == 0 || got >= n) return {};
    buf.resize(got);
    return wide_to_utf8(buf);
#else
    const char* v = std::getenv(name);
    return v ? std::string(v) : std::string();
#endif
}

bool setenv_utf8(const char* name, std::string_view value, bool overwrite) {
#ifdef _WIN32
    if (!overwrite && !getenv_utf8(name).empty()) return true;
    // SetEnvironmentVariableW with a null value deletes the variable; empty
    // input is normalized to "" (present-but-empty), matching _putenv_s.
    std::wstring wn = utf8_to_wide(name);
    std::wstring wv = utf8_to_wide(value.empty() ? std::string_view("") : value);
    return SetEnvironmentVariableW(wn.c_str(), wv.c_str()) != 0;
#else
    std::string v(value);
    return ::setenv(name, v.c_str(), overwrite ? 1 : 0) == 0;
#endif
}

}  // namespace paths
}  // namespace sa_core
