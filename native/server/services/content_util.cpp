#include "content_util.h"

#include <cmath>
#include <cstdio>
#include <mutex>

#include "sa_core/assets.h"
#include "sa_core/paths.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"

namespace sa {
namespace content {

// ---------------------------------------------------------------------------
// UTF-8 码点工具
// ---------------------------------------------------------------------------

std::vector<uint32_t> to_codepoints(std::string_view utf8) {
    std::vector<uint32_t> out;
    out.reserve(utf8.size());
    size_t i = 0;
    const size_t n = utf8.size();
    while (i < n) {
        unsigned char c = static_cast<unsigned char>(utf8[i]);
        uint32_t cp = 0xFFFD;
        size_t len = 1;
        if (c < 0x80) {
            cp = c;
        } else if ((c & 0xE0) == 0xC0 && i + 1 < n &&
                   (static_cast<unsigned char>(utf8[i + 1]) & 0xC0) == 0x80) {
            cp = ((c & 0x1Fu) << 6) | (utf8[i + 1] & 0x3Fu);
            len = 2;
        } else if ((c & 0xF0) == 0xE0 && i + 2 < n &&
                   (static_cast<unsigned char>(utf8[i + 1]) & 0xC0) == 0x80 &&
                   (static_cast<unsigned char>(utf8[i + 2]) & 0xC0) == 0x80) {
            cp = ((c & 0x0Fu) << 12) | ((utf8[i + 1] & 0x3Fu) << 6) | (utf8[i + 2] & 0x3Fu);
            len = 3;
        } else if ((c & 0xF8) == 0xF0 && i + 3 < n &&
                   (static_cast<unsigned char>(utf8[i + 1]) & 0xC0) == 0x80 &&
                   (static_cast<unsigned char>(utf8[i + 2]) & 0xC0) == 0x80 &&
                   (static_cast<unsigned char>(utf8[i + 3]) & 0xC0) == 0x80) {
            cp = ((c & 0x07u) << 18) | ((utf8[i + 1] & 0x3Fu) << 12) |
                 ((utf8[i + 2] & 0x3Fu) << 6) | (utf8[i + 3] & 0x3Fu);
            len = 4;
        }
        out.push_back(cp);
        i += len;
    }
    return out;
}

std::string cp_to_utf8(uint32_t cp) {
    std::string s;
    if (cp < 0x80) {
        s.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        s.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        s.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        s.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        s.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        s.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        s.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        s.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        s.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        s.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
    return s;
}

size_t cp_len(std::string_view utf8) {
    size_t n = 0;
    for (unsigned char c : utf8) {
        if ((c & 0xC0) != 0x80) ++n;  // 非续字节 = 新码点起点
    }
    return n;
}

size_t cp_to_byte(std::string_view utf8, size_t cp_index) {
    size_t seen = 0;
    for (size_t i = 0; i < utf8.size(); ++i) {
        if ((static_cast<unsigned char>(utf8[i]) & 0xC0) != 0x80) {
            if (seen == cp_index) return i;
            ++seen;
        }
    }
    return utf8.size();
}

std::string cp_prefix(std::string_view utf8, size_t cp_count) {
    return std::string(utf8.substr(0, cp_to_byte(utf8, cp_count)));
}

bool is_space_cp(uint32_t cp) {
    // CPython str.isspace / re \s 并集（Unicode 空白全集的常用面；
    // 剧情文本实际出现的即这些：ASCII 空白、U+0085 NBSP 类、U+3000 全角空格）。
    if (cp == 0x20) return true;
    if (cp >= 0x09 && cp <= 0x0D) return true;
    if (cp >= 0x1C && cp <= 0x1F) return true;
    if (cp == 0x85 || cp == 0xA0 || cp == 0x1680) return true;
    if (cp >= 0x2000 && cp <= 0x200A) return true;
    if (cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F || cp == 0x3000)
        return true;
    return false;
}

bool is_digit_cp(uint32_t cp) {
    // Python \d = Unicode Nd 类；这里覆盖实际会出现的区段（见头文件说明）。
    if (cp >= '0' && cp <= '9') return true;
    if (cp >= 0xFF10 && cp <= 0xFF19) return true;  // 全角数字
    if (cp >= 0x0660 && cp <= 0x0669) return true;  // 阿拉伯-印度
    if (cp >= 0x0966 && cp <= 0x096F) return true;  // 天城文
    return false;
}

std::string py_strip(const std::string& s) {
    auto cps = to_codepoints(s);
    size_t b = 0, e = cps.size();
    while (b < e && is_space_cp(cps[b])) ++b;
    while (e > b && is_space_cp(cps[e - 1])) --e;
    return cp_prefix(s, e).substr(cp_to_byte(s, b));
}

std::string py_lstrip_ws(const std::string& s) {
    auto cps = to_codepoints(s);
    size_t b = 0;
    while (b < cps.size() && is_space_cp(cps[b])) ++b;
    return s.substr(cp_to_byte(s, b));
}

std::string py_lower(std::string s) {
    for (char& c : s) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return s;
}

// ---------------------------------------------------------------------------
// Python 值语义
// ---------------------------------------------------------------------------

bool py_truthy(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number_integer()) return v.get<long long>() != 0;
    if (v.is_number_unsigned()) return v.get<unsigned long long>() != 0;
    if (v.is_number_float()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get_ref<const std::string&>().empty();
    return !v.empty();  // array/object: len(v) != 0
}

std::string story_repr(const json& v);

std::string story_str(const json& v) {
    if (v.is_array()) {
        std::string out = "[";
        bool first = true;
        for (const auto& item : v) {
            if (!first) out += ", ";
            first = false;
            out += story_repr(item);  // Python str(list) 对元素用 repr
        }
        return out + "]";
    }
    if (v.is_object()) {
        std::string out = "{";
        bool first = true;
        for (auto it = v.begin(); it != v.end(); ++it) {
            if (!first) out += ", ";
            first = false;
            out += story_repr(json(it.key()));
            out += ": ";
            out += story_repr(it.value());
        }
        return out + "}";
    }
    return sa_core::py_str(v);
}

std::string story_repr(const json& v) {
    if (v.is_string()) return sa_core::py_repr_str(v.get_ref<const std::string&>());
    return story_str(v);  // 数字/bool/null：str 与 repr 同形
}

std::optional<long long> as_ll(const json& v) {
    if (v.is_number_integer()) return v.get<long long>();
    if (v.is_number_unsigned()) return static_cast<long long>(v.get<unsigned long long>());
    if (v.is_number_float()) {
        double d = v.get<double>();
        if (std::isfinite(d) && d == std::floor(d) && std::fabs(d) < 9.2e18) {
            return static_cast<long long>(d);
        }
        return std::nullopt;
    }
    if (v.is_boolean()) return v.get<bool>() ? 1LL : 0LL;
    return std::nullopt;
}

const char* py_type_name(const json& v) {
    if (v.is_null()) return "NoneType";
    if (v.is_boolean()) return "bool";
    if (v.is_number_integer() || v.is_number_unsigned()) return "int";
    if (v.is_number_float()) return "float";
    if (v.is_string()) return "str";
    if (v.is_array()) return "list";
    return "dict";
}

json clean_floats(const json& v) {
    if (v.is_array()) {
        json out = json::array();
        for (const auto& item : v) out.push_back(clean_floats(item));
        return out;
    }
    if (v.is_object()) {
        json out = json::object();
        for (auto it = v.begin(); it != v.end(); ++it) out[it.key()] = clean_floats(it.value());
        return out;
    }
    if (v.is_number_float()) {
        double d = v.get<double>();
        if (std::isfinite(d) && d == std::floor(d)) return json(static_cast<long long>(d));
        return v;
    }
    if (v.is_string()) {
        const std::string& s = v.get_ref<const std::string&>();
        // data.endswith(".0") and data[:-2].lstrip("-").isdigit()
        if (s.size() >= 2 && s.compare(s.size() - 2, 2, ".0") == 0) {
            std::string head = s.substr(0, s.size() - 2);
            size_t b = 0;
            while (b < head.size() && head[b] == '-') ++b;  // lstrip("-")
            std::string digits = head.substr(b);
            auto dcps = to_codepoints(digits);
            bool all_digits = !dcps.empty();
            for (uint32_t c : dcps) {
                if (!is_digit_cp(c)) {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                auto ll = sa_core::py_int(head);
                if (ll) return json(*ll);
            }
        }
        return v;
    }
    return v;
}

const json* record_at(const json& table, const std::string& id) {
    if (!table.is_object()) return nullptr;
    auto it = table.find(id);
    if (it == table.end()) return nullptr;
    return &*it;
}

std::string clean_id(const json& v) {
    // float(v) 成功且整值 -> str(int)；否则 str(v)。
    if (v.is_number_integer() || v.is_number_unsigned()) return sa_core::py_str(v);
    if (v.is_number_float()) {
        double d = v.get<double>();
        if (std::isfinite(d) && d == std::floor(d))
            return std::to_string(static_cast<long long>(d));
        return sa_core::py_str(v);
    }
    if (v.is_boolean()) return v.get<bool>() ? "1" : "0";
    if (v.is_string()) {
        const std::string& s = v.get_ref<const std::string&>();
        // Python float(str)：整串是数值才算（允许前后空白/符号/小数/指数）。
        auto cps = to_codepoints(s);
        size_t b = 0, e = cps.size();
        while (b < e && is_space_cp(cps[b])) ++b;
        while (e > b && is_space_cp(cps[e - 1])) --e;
        std::string trimmed = cp_prefix(s, e).substr(cp_to_byte(s, b));
        try {
            size_t pos = 0;
            double d = std::stod(trimmed, &pos);
            if (pos == trimmed.size() && std::isfinite(d) && d == std::floor(d))
                return std::to_string(static_cast<long long>(d));
        } catch (...) {
        }
    }
    return story_str(v);
}

std::string value_error_int(std::string_view s) {
    return value_error_int_repr_quoted(std::string(s));
}

std::string value_error_int_repr_quoted(const std::string& s) {
    return "invalid literal for int() with base 10: " + sa_core::py_repr_str(s);
}

long long digits_to_ll(const std::vector<uint32_t>& cps) {
    // Python int() 对 Nd 类数字逐位求值（int("１２")==12）。调用方保证
    // 全部码点满足 is_digit_cp（re.findall(r"\d+") 的产出天然满足）。
    long long v = 0;
    for (uint32_t cp : cps) {
        int d;
        if (cp >= '0' && cp <= '9') d = static_cast<int>(cp - '0');
        else if (cp >= 0xFF10 && cp <= 0xFF19) d = static_cast<int>(cp - 0xFF10);
        else if (cp >= 0x0660 && cp <= 0x0669) d = static_cast<int>(cp - 0x0660);
        else d = static_cast<int>(cp - 0x0966);  // 0966-096F
        v = v * 10 + d;
    }
    return v;
}

std::optional<long long> int_digits_str(std::string_view s) {
    // 可选符号 + ≥1 个数字码点，别无他物（调用方已 strip/按语义给入）。
    auto cps = to_codepoints(s);
    size_t i = 0;
    bool neg = false;
    if (!cps.empty() && (cps[0] == '-' || cps[0] == '+')) {
        neg = cps[0] == '-';
        ++i;
    }
    if (i >= cps.size()) return std::nullopt;
    std::vector<uint32_t> digits;
    for (; i < cps.size(); ++i) {
        if (!is_digit_cp(cps[i])) return std::nullopt;
        digits.push_back(cps[i]);
    }
    long long v = digits_to_ll(digits);
    return neg ? -v : v;
}

std::vector<std::string> findall_digits(const std::string& s, bool allow_sign) {
    std::vector<std::string> out;
    auto cps = to_codepoints(s);
    std::vector<size_t> byte_of(cps.size() + 1);
    {
        size_t b = 0;
        const size_t n = s.size();
        for (size_t i = 0; i < cps.size(); ++i) {
            byte_of[i] = b;
            unsigned char c = static_cast<unsigned char>(s[b]);
            size_t w = 1;
            if ((c & 0xE0) == 0xC0) w = 2;
            else if ((c & 0xF0) == 0xE0) w = 3;
            else if ((c & 0xF8) == 0xF0) w = 4;
            b += w;
        }
        byte_of[cps.size()] = s.size();
        (void)n;
    }
    size_t i = 0;
    const size_t n = cps.size();
    while (i < n) {
        size_t j = i;
        bool negative = false;
        if (allow_sign && j < n && cps[j] == '-') {
            // 仅当 '-' 后紧跟数字才计入（re 的 -? 是可选整体）。
            if (j + 1 < n && is_digit_cp(cps[j + 1])) {
                negative = true;
                ++j;
            }
        }
        size_t dstart = j;
        while (j < n && is_digit_cp(cps[j])) ++j;
        if (j > dstart) {
            out.push_back(s.substr(byte_of[i], byte_of[j] - byte_of[i]));
            i = j;
        } else {
            i = negative ? i + 2 : i + 1;  // 未命中：前进（含跳掉孤立 '-'）
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// assets/dicts.json
// ---------------------------------------------------------------------------
namespace {

std::optional<std::string> read_json_text(const std::string& path) {
    auto raw = sa_core::paths::read_bytes(path);
    if (!raw) return std::nullopt;
    auto strict = sa_core::decode_utf8_sig_strict(*raw);
    if (strict) return strict;
    return sa_core::decode_utf8_sig_replace(*raw);
}

const json& dicts_singleton() {
    static std::once_flag once;
    static json g_dicts;
    std::call_once(once, [] {
        // R1 unification: candidate list shared with all other asset loaders
        // via sa_core/assets.cpp (this used to be a near-verbatim copy).
        for (const auto& p : sa_core::assets::candidate_paths("dicts.json")) {
            auto text = read_json_text(p);
            if (!text) continue;
            json parsed = json::parse(*text, nullptr, false);
            if (!parsed.is_discarded() && parsed.is_object()) {
                g_dicts = std::move(parsed);
                return;
            }
        }
        std::fprintf(stderr, "[p3a] WARN: dicts.json not found; dictionaries empty\n");
        g_dicts = json::object();
    });
    return g_dicts;
}

}  // namespace

const json& dicts_json() { return dicts_singleton(); }

const json& role_dict() {
    static const json roles = [] {
        const json& gd = dicts_json().value("game_dicts", json::object());
        const json& r = gd.contains("roles") && gd.at("roles").is_object()
                            ? gd.at("roles")
                            : json::object();
        return r;
    }();
    return roles;
}

}  // namespace content
}  // namespace sa
