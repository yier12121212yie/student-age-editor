#include "sa_core/strings.h"

#include <algorithm>

namespace sa_core {
namespace str {

std::string trim(std::string_view s) {
    constexpr std::string_view ws = " \t\n\r\f\v";
    std::size_t b = s.find_first_not_of(ws);
    if (b == std::string_view::npos) {
        return {};
    }
    std::size_t e = s.find_last_not_of(ws);
    return std::string(s.substr(b, e - b + 1));
}

bool starts_with(std::string_view s, std::string_view prefix) {
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

bool ends_with(std::string_view s, std::string_view suffix) {
    return s.size() >= suffix.size() &&
           s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string replace_all(std::string s, std::string_view from, std::string_view to) {
    if (from.empty()) {
        return s;
    }
    std::string out;
    out.reserve(s.size());
    std::size_t pos = 0;
    std::size_t idx;
    while ((idx = s.find(from, pos)) != std::string::npos) {
        out.append(s, pos, idx - pos);
        out.append(to);
        pos = idx + from.size();
    }
    out.append(s, pos, std::string::npos);
    return out;
}

}  // namespace str
}  // namespace sa_core
