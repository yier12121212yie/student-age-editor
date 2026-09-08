// wip/P4/p4_util.h — shared helpers for the P4 networking/artifact services.
//
// Kept deliberately small: path/stat/base64/hex primitives already live in
// sa_core; this file only carries the odd Python-semantics glue that several
// P4 files need (os.path.basename/extname, fs_tools.resolve, random hex for
// multipart boundaries, utf-8 codepoint length for search_talks ordering).
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include <nlohmann/json.hpp>

namespace sa {
namespace p4 {

using json = nlohmann::ordered_json;

// os.path.splitext (POSIX flavour, works on Windows paths too): returns
// {root, ext} where ext is "" / ".<tail>". Edge cases honoured: leading-dot
// files (.bashrc) have no ext; trailing dot ("abc.") has no ext; the split
// only considers the basename segment after the last '/' or '\\'.
std::pair<std::string, std::string> split_ext(std::string_view p);

// os.path.basename on mixed separators: the segment after the last '/' or
// '\\'. "" for "".
std::string basename(std::string_view p);

// os.path.dirname: everything up to and excluding the last separator.
std::string dirname(std::string_view p);

// ASCII-only lowercase (Python .lower() is Unicode-aware; all key/file-name
// domains here are ASCII — documented deviation).
std::string lower_ascii(std::string_view s);

// Python str.strip() over ASCII whitespace (" \t\n\r\v\f").
std::string strip(std::string_view s);

// len(str) over utf-8 = codepoint count (search_talks content-length order).
size_t utf8_len(std::string_view s);

// fs_tools.resolve: absolute join under `root` with sandbox checks; throws
// SandboxError like the Python (root missing / escape). Lives here rather
// than in server/ because wave-1 only ported _norm so far.
std::string fs_resolve(const std::string& root, const std::string& rel_path);

// Random lowercase hex (n chars) — multipart boundary + temp names.
std::string random_hex(size_t n);

// Python `int(x)` on a JSON scalar: numbers truncate toward zero, strings
// parse like int(str) (sign+digits, ASCII ws). nullopt where Python raises.
std::optional<long long> json_int(const json& v);

// Raise like Python `int("abc")`: ValueError with the repr'd literal. Used by
// query params the Python route leaves to the httpd 500 envelope.
[[noreturn]] void raise_int_error(const std::string& literal);

}  // namespace p4
}  // namespace sa
