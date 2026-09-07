// sa_core: atomic writes — the C++ port of `backend/editor/core/atomic_io.py`.
//
// Contract (CONVENTIONS 5.5 step 4):
//   * parent directory created first;
//   * UNIQUE temp file in the SAME directory:
//       <abs_path>.tmp_<pid>_<tid>_<hex12>          (atomic_io.py:32-42)
//     the random suffix stops two threads/processes racing on one target from
//     clobbering each other's temp file;
//   * write + flush + fsync, then replace the target;
//   * Windows ERROR_ACCESS_DENIED(5)/ERROR_SHARING_VIOLATION(32) — i.e. the
//     PermissionError os.replace() raises for transient AV/indexer locks — get
//     retries=5 x delay=20ms backoff (atomic_io.py:64-76);
//   * final failure deletes the temp file and throws FsError.
//
// `write_text_atomic` normalizes newlines (CRLF -> LF first, then LF -> newline)
// so a Windows text-mode write can never turn the whole table into CRLF
// (pitfall B4, atomic_io.py:85-97); `bom=true` re-prefixes the UTF-8 BOM (B5).
#pragma once

#include <stdexcept>
#include <string>

namespace sa_core {

// Raised for every IO failure on the atomic-write path. `.what()` is formatted
// like a Python OSError so "%s"-style messages stay recognizable.
class FsError : public std::runtime_error {
  public:
    using std::runtime_error::runtime_error;
};

// The temp name for `abs_path`, exposed for tests (pattern check only — the
// pid/tid/hex components vary per call).
std::string unique_tmp_path(const std::string& abs_path);

// atomic_io.write_bytes_atomic: returns the number of bytes written.
std::size_t write_bytes_atomic(const std::string& abs_path, std::string_view data,
                               int retries = 5, double delay_seconds = 0.02);

// atomic_io.write_text_atomic: text is newline-normalized to `newline` (default
// "\n" == force LF), encoded UTF-8, optional BOM, then written atomically.
std::size_t write_text_atomic(const std::string& abs_path, const std::string& text,
                              bool bom = false, const std::string& newline = "\n");

}  // namespace sa_core
