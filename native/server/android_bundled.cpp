#include "server/android_bundled.h"

#include <cstddef>
#include <cstring>
#include <fstream>
#include <string>

// Vendored miniz, reader-only configuration (MINIZ_NO_DEFLATE_APIS keeps the
// COMPRESSOR out — inflate/zip-READ stays in; the archive-WRITE half is out
// too). The bare-name include rides sa_server's PUBLIC services/ dir on the
// include path (server/CMakeLists.txt), same convention as the p3b files.
#include "p3b_miniz_config.h"

#include "sa_core/md5.h"
#include "sa_core/paths.h"

namespace sa {
namespace {

// Python: hashlib.md5(f.read(1 << 20)).hexdigest() — first MiB of the zip.
constexpr std::size_t kFingerprintBytes = 1u << 20;

std::string ascii_strip(const std::string& s) {  // Python str.strip() (hex/ASCII here)
    const char* ws = " \t\n\r\v\f";
    size_t b = s.find_first_not_of(ws);
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(ws);
    return s.substr(b, e - b + 1);
}

}  // namespace

void extract_bundled(const std::string& zip_path, const std::string& packs_root) {
    if (zip_path.empty() || packs_root.empty()) return;
    if (!sa_core::paths::is_file(zip_path)) return;  // os.path.isfile

    // ---- fingerprint of the zip head (failure => "" like the Python except) --
    std::string digest;
    {
        std::ifstream f(zip_path, std::ios::binary);
        if (f) {
            std::string prefix;
            prefix.resize(kFingerprintBytes);
            f.read(&prefix[0], static_cast<std::streamsize>(kFingerprintBytes));
            auto got = static_cast<size_t>(f.gcount());
            prefix.resize(got);
            digest = sa_core::md5_hex(prefix);
        }
    }

    const std::string dest = sa_core::paths::join(packs_root, "bundled");
    const std::string marker = sa_core::paths::join(dest, ".bundled_version");

    // Skip on fingerprint match. Marker unreadable => fall through (Python's
    // inner try/except only guards the read itself).
    if (sa_core::paths::is_file(marker)) {
        if (auto cur = sa_core::paths::read_bytes(marker)) {
            if (ascii_strip(*cur) == digest) return;
        }
    }

    // Everything from here is Python's outer `try: ... except Exception:
    // pass`: any failure aborts silently, leaves (at most) a half-written
    // tree, and — crucially — NO marker, so the next start retries.
    // Note makedirs runs BEFORE the archive is opened: a corrupt zip still
    // leaves dest in place (matches zipfile.ZipFile raising after makedirs).
    if (!sa_core::paths::create_dirs(dest)) return;

    // (The vendored miniz spells the reader as mz_zip_archive; there is no
    // mz_zip_reader typedef in this amalgamation — same spelling p3b uses.)
    mz_zip_archive reader;
    std::memset(&reader, 0, sizeof(reader));
    // UTF-8 narrow path: correct on bionic/POSIX; on Windows this entry point
    // is only exercised with ASCII temp paths by the tests (the desktop
    // product never passes a bundled_zip).
    if (!mz_zip_reader_init_file(&reader, zip_path.c_str(), 0)) return;
    struct ReaderGuard {
        mz_zip_archive* r;
        ~ReaderGuard() { mz_zip_reader_end(r); }
    } guard{&reader};

    const mz_uint count = mz_zip_reader_get_num_files(&reader);
    for (mz_uint i = 0; i < count; ++i) {
        mz_zip_archive_file_stat st;
        if (!mz_zip_reader_file_stat(&reader, i, &st)) return;
        const std::string name(st.m_filename);
        // __init__.py:56 verbatim: startswith("/"), ".." anywhere, ":" anywhere.
        if (name.rfind("/", 0) == 0 || name.find("..") != std::string::npos ||
            name.find(':') != std::string::npos) {
            continue;
        }
        const std::string target = sa_core::paths::join(dest, name);
        if (st.m_is_directory) {
            if (!sa_core::paths::create_dirs(target)) return;
            continue;
        }
        if (!sa_core::paths::create_dirs(sa_core::paths::dirname(target))) return;

        std::string content;
        if (st.m_uncomp_size > 0) {
            size_t n = 0;
            // Index-based (not by-name): keeps duplicate names byte-faithful
            // and avoids the O(log n) lookup; heap-then-write keeps the final
            // file write on the wide-path ofstream below (parent dirs are
            // ASCII-or-UTF-8 native on Android).
            void* p = mz_zip_reader_extract_to_heap(&reader, i, &n, 0);
            if (!p) return;
            content.assign(static_cast<const char*>(p), n);
            mz_free(p);
        }
        std::ofstream out(sa_core::paths::to_path(target),
                          std::ios::binary | std::ios::trunc);
        if (!out) return;
        out.write(content.data(), static_cast<std::streamsize>(content.size()));
        if (!out) return;  // write failure (ENOSPC etc.) — Python raises here
        out.close();
    }

    // Marker only after a full pass; `f.write(digest)` — no newline.
    if (!sa_core::paths::write_bytes_simple(marker, digest)) return;
}

}  // namespace sa
