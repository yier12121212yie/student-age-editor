// wip/P3b sandbox implementation — port of backend/editor/server/fs_tools.py.
// See p3b_fs_tools.h for the contract; official layout at merge moves this to
// server/services/fs_tools_p3b.cpp.
#include "p3b_fs_tools.h"

#include <cstring>
#include <optional>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#include "p3b_support.h"
#include "sa_core/atomic_io.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/httpd.h"  // ApiError for the binascii.Error analogue
#include "server/state.h"  // sa::SandboxError, sa::norm_rel

namespace sa {
namespace p3b {
namespace {
namespace cs = sa_core::paths;

bool contains_ci_ext(const std::vector<std::string>& set_, const std::string& ext) {
    for (const auto& e : set_) {
        if (e == ext) return true;
    }
    return false;
}

// CPython's gbk codec (errors="replace") approximated through the in-box
// CP936 decoder: ASCII bytes pass through, a 0x81-0xFE lead + 0x40-0xFE trail
// (skipping 0x7F) is decoded pairwise, anything unrepresentable emits one
// U+FFFD and advances a single byte — the same "replace one per maximal
// bad subpart" behaviour the Python error handler gives on the data we ever
// see (GBK legacy mod files). Deviation: the CP936 and CPython gbk tables
// differ only on a handful of euro-sign / user-defined slots.
std::string gbk_replace_decode(std::string_view raw) {
#ifdef _WIN32
    std::string out;
    size_t i = 0;
    while (i < raw.size()) {
        const unsigned char c = static_cast<unsigned char>(raw[i]);
        if (c < 0x80) {
            out.push_back(static_cast<char>(c));
            ++i;
            continue;
        }
        if (c >= 0x81 && c <= 0xFE && i + 1 < raw.size()) {
            const unsigned char trail = static_cast<unsigned char>(raw[i + 1]);
            if ((trail >= 0x40 && trail <= 0xFE && trail != 0x7F)) {
                wchar_t wch = 0;
                const int n = MultiByteToWideChar(936 /*CP_GBK*/, 0, raw.data() + i, 2, &wch, 1);
                if (n == 1) {
                    sa_core::append_codepoint(out, static_cast<unsigned>(wch));
                    i += 2;
                    continue;
                }
            }
        }
        sa_core::append_codepoint(out, 0xFFFDu);
        ++i;
    }
    return out;
#else
    // Non-Windows hosts never run the editor; keep a deterministic fallback.
    return sa_core::decode_utf8_sig_replace(raw);
#endif
}

}  // namespace

const std::vector<std::string> kTextExts = {
    ".json", ".txt",  ".md",   ".csv",   ".xml",   ".html", ".css",   ".js",    ".ts",
    ".lua",  ".py",   ".cfg",  ".ini",   ".yaml",  ".yml",  ".log",   ".manifest",
    ".template", ".bat", ".sh",
};

const std::vector<std::string> kBinaryExts = {
    ".png", ".jpg", ".jpeg", ".webp", ".bmp",  ".gif",  ".wav",
    ".ogg", ".mp3", ".bundle", ".assets", ".bytes", ".dll", ".exe",
};

std::string norm_rel(const std::string& rel_path) { return sa::norm_rel(rel_path); }

std::string ext_of(const std::string& path) {
    // os.path.splitext(path)[1].lower()
    const size_t sep = path.find_last_of("/\\");
    const std::string base = sep == std::string::npos ? path : path.substr(sep + 1);
    if (base.empty()) return {};
    const size_t dot = base.rfind('.');
    // splitext has no extension when: no dot, leading dot only (".bashrc"), or
    // dot at the very end ("abc.").
    if (dot == std::string::npos || dot == 0 || dot + 1 >= base.size()) return {};
    return sa_core::str::lower(base.substr(dot));
}

std::string resolve(const std::string& root, const std::string& rel_path) {
    if (root.empty() || !cs::is_dir(root)) {
        throw SandboxError("sandbox root missing: " + sa_core::py_repr_str(root));
    }
    const std::string rel = norm_rel(rel_path);  // throws SandboxError escapes
    const std::string abs_path = cs::abs_path(cs::join(root, rel));
    const std::string root_abs = cs::abs_path(root);
    // Python compares raw abspath + os.sep; normcase() here additionally
    // absorbs drive-letter case (Windows is case-insensitive; STATE hands us
    // both paths from the same source, so this is strictly more forgiving and
    // never looser than the escape check itself).
    const std::string a = cs::normcase(abs_path);
    const std::string r = cs::normcase(root_abs);
    if (a != r && !sa_core::str::starts_with(a, r + "\\")) {
        throw SandboxError("path escapes sandbox: " + sa_core::py_repr_str(rel_path));
    }
    return abs_path;
}

json list_dir(const std::string& root, const std::string& rel_path, bool deep) {
    const std::string abs_path = resolve(root, rel_path);
    if (!cs::is_dir(abs_path)) {
        throw SandboxError("not a directory: " + sa_core::py_repr_str(rel_path));
    }
    json entries = json::array();
    // Depth-first walk with the Python invariants: names sorted per directory,
    // MAX_LIST_ENTRIES=2000 checked BEFORE each append, deep recursion capped
    // at depth 4, unreadable directories silently skipped (OSError -> return).
    struct Walk {
        static void run(const std::string& base, const std::string& rel, int depth,
                        json& entries, bool deep) {
            if (static_cast<long long>(entries.size()) >= kMaxListEntries) return;
            bool ok = false;
            const std::vector<std::string> names = cs::listdir_sorted(base, &ok);
            if (!ok) return;
            for (const std::string& name : names) {
                if (static_cast<long long>(entries.size()) >= kMaxListEntries) return;
                const std::string full = cs::join(base, name);
                const std::string child_rel = rel.empty() ? name : rel + "/" + name;
                json entry = json::object();
                if (cs::is_dir(full)) {
                    entry["name"] = child_rel;
                    entry["type"] = "dir";
                    entry["size"] = 0;
                    entries.push_back(std::move(entry));
                    if (deep && depth < 4) run(full, child_rel, depth + 1, entries, deep);
                } else {
                    long long size = 0;
                    if (auto st = cs::stat(full)) size = st->size;
                    entry["name"] = child_rel;
                    entry["type"] = "file";
                    entry["size"] = size;
                    entries.push_back(std::move(entry));
                }
            }
        }
    };
    Walk::run(abs_path, "", 0, entries, deep);
    return entries;
}

json read_file(const std::string& root, const std::string& rel_path, bool as_binary) {
    const std::string abs_path = resolve(root, rel_path);
    if (!cs::is_file(abs_path)) {
        throw SandboxError("not a file: " + sa_core::py_repr_str(rel_path));
    }
    long long size = 0;
    if (auto st = cs::stat(abs_path)) size = st->size;
    if (size > kMaxFileBytes && !as_binary) {
        throw SandboxError("file too large (" + std::to_string(size) + " bytes): " +
                           sa_core::py_repr_str(rel_path));
    }
    const std::string ext = ext_of(abs_path);
    const bool binary = as_binary || contains_ci_ext(kBinaryExts, ext);
    auto raw = cs::read_bytes(abs_path);
    if (!raw) throw SandboxError("not a file: " + sa_core::py_repr_str(rel_path));
    json out = json::object();
    out["path"] = rel_path;  // raw rel echoed (Python returns rel_path verbatim)
    out["size"] = static_cast<long long>(raw->size());
    if (binary) {
        out["base64"] = b64_encode(*raw);
        return out;
    }
    // utf-8 STRICT (BOM kept as \ufeff — Python does NOT use utf-8-sig here),
    // UnicodeDecodeError -> gbk replace.
    if (sa_core::is_utf8(*raw)) {
        out["text"] = *raw;
    } else {
        out["text"] = gbk_replace_decode(*raw);
    }
    return out;
}

json write_file(const std::string& root, const std::string& rel_path,
                const std::string& content, bool base64_mode) {
    const std::string abs_path = resolve(root, rel_path);
    std::string raw;
    if (base64_mode) {
        auto decoded = b64_decode_loose(content);
        if (!decoded) {
            // binascii.Error analogue: the HTTP layer renders 500 "Error: ...".
            throw ApiError("Error", "Invalid base64-encoded string: number of data "
                                    "characters cannot be 1 more than a multiple of 4 "
                                    "or contains incorrect padding");
        }
        raw = std::move(*decoded);
    } else {
        raw = content;  // caller already applied Python str() semantics + utf-8
    }
    sa_core::write_bytes_atomic(abs_path, raw);  // throws FsError -> 500
    json out = json::object();
    out["path"] = rel_path;
    out["size"] = static_cast<long long>(raw.size());
    return out;
}

json stat_path(const std::string& root, const std::string& rel_path) {
    const std::string abs_path = resolve(root, rel_path);
    json out = json::object();
    out["path"] = rel_path;
    if (!cs::exists(abs_path)) {
        out["exists"] = false;
        return out;
    }
    out["exists"] = true;
    out["type"] = cs::is_dir(abs_path) ? "dir" : "file";
    if (cs::is_file(abs_path)) {
        long long size = 0;
        if (auto st = cs::stat(abs_path)) size = st->size;
        out["size"] = size;
        out["ext"] = ext_of(abs_path);
    }
    return out;
}

// os.walk counting (resource_pack). Unreadable directories are skipped by
// os.walk itself; the same tolerance applies here.
long long count_files_recursive(const std::string& dir) {
    long long cnt = 0;
    std::vector<std::string> stack{dir};
    while (!stack.empty()) {
        const std::string cur = stack.back();
        stack.pop_back();
        bool ok = false;
        const auto names = cs::listdir_sorted(cur, &ok);
        if (!ok) continue;
        for (const auto& name : names) {
            const std::string full = cs::join(cur, name);
            if (cs::is_dir(full)) {
                stack.push_back(full);
            } else {
                ++cnt;
            }
        }
    }
    return cnt;
}

bool has_any_json_recursive(const std::string& dir) {
    std::vector<std::string> stack{dir};
    while (!stack.empty()) {
        const std::string cur = stack.back();
        stack.pop_back();
        bool ok = false;
        const auto names = cs::listdir_sorted(cur, &ok);
        if (!ok) continue;
        for (const auto& name : names) {
            const std::string full = cs::join(cur, name);
            if (cs::is_dir(full)) {
                stack.push_back(full);
            } else if (sa_core::str::ends_with(name, ".json")) {
                return true;
            }
        }
    }
    return false;
}

}  // namespace p3b
}  // namespace sa
