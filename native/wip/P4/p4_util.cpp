// wip/P4/p4_util.cpp — see p4_util.h.
#include "p4_util.h"

#include <chrono>
#include <random>
#include <regex>
#include <sstream>

#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/httpd.h"
#include "server/state.h"

namespace sa {
namespace p4 {

std::pair<std::string, std::string> split_ext(std::string_view p) {
    // os.path.splitext operates on the basename: find the last separator.
    size_t sep = p.find_last_of("/\\");
    size_t base = (sep == std::string_view::npos) ? 0 : sep + 1;
    std::string_view name = p.substr(base);
    size_t dot = name.find_last_of('.');
    // No extension when: no dot, dot is first char (hidden file), or the dot
    // is the last char (e.g. "abc." -> Python keeps the ext empty).
    if (dot == std::string_view::npos || dot == 0 || dot == name.size() - 1) {
        return {std::string(p), ""};
    }
    return {std::string(p.substr(0, base + dot)), std::string(name.substr(dot))};
}

std::string basename(std::string_view p) {
    size_t sep = p.find_last_of("/\\");
    return std::string(sep == std::string_view::npos ? p : p.substr(sep + 1));
}

std::string dirname(std::string_view p) {
    size_t sep = p.find_last_of("/\\");
    if (sep == std::string_view::npos) return "";
    return std::string(p.substr(0, sep));
}

std::string lower_ascii(std::string_view s) { return sa_core::str::lower(s); }

std::string strip(std::string_view s) { return sa_core::str::trim(s); }

size_t utf8_len(std::string_view s) {
    size_t n = 0;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t len = 1;
        if (c >= 0xF0) len = 4;
        else if (c >= 0xE0) len = 3;
        else if (c >= 0xC0) len = 2;
        i += len;
        ++n;
    }
    return n;
}

std::string fs_resolve(const std::string& root, const std::string& rel_path) {
    // fs_tools.resolve: reject missing root / escape.
    if (root.empty() || !sa_core::paths::is_dir(root)) {
        throw SandboxError("sandbox root missing: " + sa_core::py_repr_str(root));
    }
    std::string rel = norm_rel(rel_path);  // fs_tools._norm, throws on escape
    std::string abs = sa_core::paths::abs_path(sa_core::paths::join(root, rel));
    std::string root_abs = sa_core::paths::abs_path(root);
    if (abs != root_abs &&
        !(abs.size() > root_abs.size() && abs.compare(0, root_abs.size(), root_abs) == 0 &&
          (abs[root_abs.size()] == '/' || abs[root_abs.size()] == '\\'))) {
        throw SandboxError("path escapes sandbox: " + sa_core::py_repr_str(rel_path));
    }
    return abs;
}

std::string random_hex(size_t n) {
    static thread_local std::mt19937_64 rng(
        static_cast<unsigned long long>(
            std::chrono::steady_clock::now().time_since_epoch().count()) ^
        std::random_device{}());
    static const char* hexd = "0123456789abcdef";
    std::string out;
    out.reserve(n);
    std::uniform_int_distribution<int> d(0, 15);
    for (size_t i = 0; i < n; ++i) out += hexd[d(rng)];
    return out;
}

std::optional<long long> json_int(const json& v) {
    if (v.is_number_integer() || v.is_number_unsigned()) return v.get<long long>();
    if (v.is_number_float()) return static_cast<long long>(v.get<double>());
    if (v.is_boolean()) return v.get<bool>() ? 1 : 0;
    if (v.is_string()) return sa_core::py_int(v.get<std::string>());
    return std::nullopt;
}

void raise_int_error(const std::string& literal) {
    // int("abc") -> ValueError("invalid literal for int() with base 10: 'abc'")
    throw ApiError("ValueError",
                   "invalid literal for int() with base 10: " + sa_core::py_repr_str(literal));
}

}  // namespace p4
}  // namespace sa
