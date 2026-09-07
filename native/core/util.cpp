#include "sa_core/util.h"

#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <limits>

namespace sa_core {

long long now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

std::string py_str(const nlohmann::ordered_json& v) {
    if (v.is_null()) return "None";
    if (v.is_boolean()) return v.get<bool>() ? "True" : "False";
    if (v.is_number_integer()) return std::to_string(v.get<long long>());
    if (v.is_number_unsigned()) return std::to_string(v.get<unsigned long long>());
    if (v.is_number_float()) {
        // Python repr(float): shortest round-trip with ".0" for integral values.
        double d = v.get<double>();
        if (std::isfinite(d)) {
            std::string s = v.dump();
            if (s.find('.') == std::string::npos && s.find('e') == std::string::npos &&
                s.find("inf") == std::string::npos) {
                s += ".0";
            }
            return s;
        }
        if (std::isnan(d)) return "nan";
        return d < 0 ? "-inf" : "inf";
    }
    if (v.is_string()) return v.get<std::string>();
    return v.dump();  // containers: str(list)/str(dict) == json-ish; good enough
}

std::string py_repr_str(std::string_view s) {
    // CPython repr(str): prefers single quotes; escapes \\, \n, \r and the
    // quote character actually used. Non-ASCII passes through raw (py3).
    bool has_single = s.find('\'') != std::string_view::npos;
    bool has_double = s.find('"') != std::string_view::npos;
    char quote = (has_single && !has_double) ? '"' : '\'';
    std::string out;
    out += quote;
    for (char c : s) {
        switch (c) {
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c == quote) {
                    out += '\\';
                    out += c;
                } else {
                    out += c;
                }
        }
    }
    out += quote;
    return out;
}

std::optional<long long> py_int(std::string_view s) {
    // int(str): strip surrounding whitespace, optional sign, decimal digits
    // with underscores allowed strictly between digits.
    size_t i = 0, n = s.size();
    auto isws = [](char c) {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
    };
    while (i < n && isws(s[i])) ++i;
    while (n > i && isws(s[n - 1])) --n;
    if (i >= n) return std::nullopt;
    bool neg = false;
    if (s[i] == '+' || s[i] == '-') {
        neg = s[i] == '-';
        ++i;
    }
    if (i >= n) return std::nullopt;
    long long acc = 0;
    bool prev_digit = false;
    for (; i < n; ++i) {
        char c = s[i];
        if (c == '_') {
            if (!prev_digit || i + 1 >= n || !std::isdigit(static_cast<unsigned char>(s[i + 1]))) {
                return std::nullopt;
            }
            prev_digit = false;
            continue;
        }
        if (!std::isdigit(static_cast<unsigned char>(c))) return std::nullopt;
        prev_digit = true;
        int digit = c - '0';
        constexpr long long kMax = std::numeric_limits<long long>::max();
        if (acc > (kMax - digit) / 10) {
            return std::nullopt;  // overflow -> fail
        }
        acc = acc * 10 + digit;
    }
    return neg ? -acc : acc;
}

std::optional<std::string> origin_hostname(std::string_view origin) {
    size_t pos = origin.find("://");
    if (pos == std::string_view::npos) return std::nullopt;
    std::string_view rest = origin.substr(pos + 3);
    size_t end = rest.find_first_of("/?#");
    if (end != std::string_view::npos) rest = rest.substr(0, end);
    // Drop userinfo (urlparse splits it off before hostname).
    size_t at = rest.rfind('@');
    if (at != std::string_view::npos) rest = rest.substr(at + 1);
    // Strip port: for bracketed IPv6 the last ']' comes first.
    if (!rest.empty() && rest[0] == '[') {
        size_t close = rest.find(']');
        if (close == std::string_view::npos) return std::nullopt;
        rest = rest.substr(1, close - 1);
    } else {
        size_t colon = rest.rfind(':');
        if (colon != std::string_view::npos) rest = rest.substr(0, colon);
    }
    std::string out(rest);
    for (char& c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

}  // namespace sa_core
