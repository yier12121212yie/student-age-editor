#include "sa_core/atomic_io.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <random>
#include <sstream>
#include <thread>

#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <sys/types.h>
#include <unistd.h>
#endif

namespace sa_core {
namespace {

#ifdef _WIN32
// RAII close for HANDLE (the temp file must not leak if a later step throws).
struct HandleGuard {
    HANDLE h;
    explicit HandleGuard(HANDLE hh) : h(hh) {}
    ~HandleGuard() {
        if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    }
    HandleGuard(const HandleGuard&) = delete;
    HandleGuard& operator=(const HandleGuard&) = delete;
};
#else
struct FdGuard {
    int fd;
    explicit FdGuard(int f) : fd(f) {}
    ~FdGuard() {
        if (fd >= 0) ::close(fd);
    }
    FdGuard(const FdGuard&) = delete;
    FdGuard& operator=(const FdGuard&) = delete;
    void release() { fd = -1; }
};
#endif

// secrets.token_hex(6) equivalent: 12 lowercase hex chars per call.
std::string hex12() {
    static std::atomic<uint64_t> counter{0};
    uint64_t seed = static_cast<uint64_t>(std::random_device{}()) ^
                    (static_cast<uint64_t>(counter.fetch_add(1) + 1) << 20) ^
                    static_cast<uint64_t>(
                        std::chrono::steady_clock::now().time_since_epoch().count());
    std::mt19937_64 rng(seed);
    uint64_t v = rng();
    char buf[16];
    std::snprintf(buf, sizeof(buf), "%012llx",
                  static_cast<unsigned long long>(v & 0xFFFFFFFFFFFFULL));
    return std::string(buf);
}

unsigned long process_ident() {
#ifdef _WIN32
    return static_cast<unsigned long>(::GetCurrentProcessId());
#else
    return static_cast<unsigned long>(::getpid());
#endif
}

unsigned long thread_ident() {
#ifdef _WIN32
    return static_cast<unsigned long>(::GetCurrentThreadId());
#else
    return static_cast<unsigned long>(
        std::hash<std::thread::id>{}(std::this_thread::get_id()) & 0xFFFFFFFFUL);
#endif
}

void sleep_ms(double seconds) {
    std::this_thread::sleep_for(
        std::chrono::milliseconds(static_cast<long long>(seconds * 1000)));
}

#ifdef _WIN32
std::wstring to_wide(const std::string& utf8) {
    if (utf8.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                                nullptr, 0);
    if (n <= 0) return {};
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), w.data(), n);
    return w;
}

const char* win_err_text(DWORD code) {
    switch (code) {
        case ERROR_ACCESS_DENIED: return "Access is denied";
        case ERROR_SHARING_VIOLATION:
            return "The process cannot access the file because it is being used by "
                   "another process";
        case ERROR_FILE_EXISTS: return "The file exists";
        case ERROR_ALREADY_EXISTS:
            return "Cannot create a file when that file already exists";
        case ERROR_PATH_NOT_FOUND: return "The system cannot find the path specified";
        case ERROR_FILE_NOT_FOUND: return "The system cannot find the file specified";
        default: return "Unspecified error";
    }
}

// Python-style OSError text: "[WinError 5] Access is denied: '<path>'".
std::string win_err_str(DWORD code, const std::string& path) {
    std::string out = "[WinError ";
    out += std::to_string(code);
    out += "] ";
    out += win_err_text(code);
    out += ": '";
    out += path;
    out += "'";
    return out;
}

#endif

}  // namespace

std::string unique_tmp_path(const std::string& abs_path) {
    // atomic_io.py:32-42: "<abs>.tmp_<pid>_<tid>_<hex12>", retried until free.
    for (int guard = 0;; ++guard) {
        std::ostringstream os;
        os << abs_path << ".tmp_" << process_ident() << '_' << thread_ident() << '_' << hex12();
        std::string tmp = os.str();
        if (guard > 10000) throw FsError("cannot allocate unique temp name");
        if (!paths::exists(tmp)) return tmp;
    }
}

std::size_t write_bytes_atomic(const std::string& abs_path, std::string_view data,
                               int retries, double delay_seconds) {
    const std::string target = paths::abs_path(abs_path);
    const std::string parent = paths::dirname(target);
    if (!parent.empty() && !paths::create_dirs(parent)) {
        throw FsError("makedirs failed: " + parent);
    }
    const std::string tmp = unique_tmp_path(target);
    bool replaced = false;
    try {
#ifdef _WIN32
        {
            std::wstring wtmp = to_wide(tmp);
            HANDLE h = CreateFileW(wtmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                                   FILE_ATTRIBUTE_NORMAL, nullptr);
            if (h == INVALID_HANDLE_VALUE) {
                throw FsError(win_err_str(GetLastError(), tmp));
            }
            HandleGuard guard(h);
            size_t off = 0;
            while (off < data.size()) {
                size_t want = std::min<size_t>(data.size() - off, 1u << 20);
                DWORD written = 0;
                if (!WriteFile(h, data.data() + off, static_cast<DWORD>(want), &written,
                               nullptr) ||
                    written != static_cast<DWORD>(want)) {
                    throw FsError(win_err_str(GetLastError(), tmp));
                }
                off += written;
            }
            // os.fsync(f.fileno()) — durability before the rename (atomic_io.py:63).
            if (!FlushFileBuffers(h)) {
                throw FsError(win_err_str(GetLastError(), tmp));
            }
        }
        const int attempts = retries < 1 ? 1 : retries;
        std::string last_err;
        const std::wstring wtmp = to_wide(tmp);
        const std::wstring wtarget = to_wide(target);
        for (int attempt = 0; attempt < attempts; ++attempt) {
            // os.replace == MoveFileEx(MOVEFILE_REPLACE_EXISTING).
            if (MoveFileExW(wtmp.c_str(), wtarget.c_str(), MOVEFILE_REPLACE_EXISTING)) {
                replaced = true;
                return data.size();
            }
            const DWORD code = GetLastError();
            // PermissionError (WinError 5/32) / FileExistsError (80/183): transient
            // locks from AV/indexers -> backoff and retry (atomic_io.py:71-74).
            if (code == ERROR_ACCESS_DENIED || code == ERROR_SHARING_VIOLATION ||
                code == ERROR_FILE_EXISTS || code == ERROR_ALREADY_EXISTS) {
                last_err = win_err_str(code, target);
                if (attempt < attempts - 1 && delay_seconds > 0) sleep_ms(delay_seconds);
                continue;
            }
            throw FsError(win_err_str(code, target));
        }
        throw FsError("os.replace 失败（已重试 " + std::to_string(attempts) +
                      " 次，目标被瞬时占用）: " + last_err);
#else
        {
            int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0644);
            if (fd < 0) throw FsError("open failed: " + tmp);
            FdGuard guard(fd);
            size_t off = 0;
            while (off < data.size()) {
                ssize_t n = ::write(fd, data.data() + off, data.size() - off);
                if (n < 0) {
                    if (errno == EINTR) continue;
                    throw FsError("write failed: " + tmp);
                }
                if (n == 0) throw FsError("write returned 0: " + tmp);  // never spin
                off += static_cast<size_t>(n);
            }
            if (::fsync(fd) != 0) throw FsError("fsync failed: " + tmp);
        }
        const int attempts = retries < 1 ? 1 : retries;
        std::string last_err;
        for (int attempt = 0; attempt < attempts; ++attempt) {
            if (::rename(tmp.c_str(), target.c_str()) == 0) {
                replaced = true;
                return data.size();
            }
            const int e = errno;
            if (e == EACCES || e == EPERM || e == EBUSY || e == EEXIST) {
                last_err = "errno " + std::to_string(e);
                if (attempt < attempts - 1 && delay_seconds > 0) sleep_ms(delay_seconds);
                continue;
            }
            throw FsError("rename failed: errno " + std::to_string(e));
        }
        throw FsError("os.replace 失败（已重试 " + std::to_string(attempts) +
                      " 次，目标被瞬时占用）: " + last_err);
#endif
    } catch (...) {
        // finally: unlink the temp file on any failure path (atomic_io.py:77-82).
        if (!replaced) paths::remove_file(tmp);
        throw;
    }
}

std::size_t write_text_atomic(const std::string& abs_path, const std::string& text,
                              bool bom, const std::string& newline) {
    // atomic_io.py:85-97: normalize CRLF -> LF, then LF -> `newline`
    // (newline="\n" == force LF; pitfall B4).
    std::string normalized = str::replace_all(text, "\r\n", "\n");
    normalized = str::replace_all(normalized, "\n", newline);
    std::string raw;
    if (bom) raw.append(kBom);
    raw += normalized;
    return write_bytes_atomic(abs_path, raw);
}

}  // namespace sa_core
