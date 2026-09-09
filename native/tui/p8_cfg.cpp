// native/tui/p8_cfg.cpp
#include "p8_cfg.h"

#include <algorithm>

namespace p8 {
namespace {

// Cut a UTF-8 string to at most `max_len` code points (never mid-sequence).
std::string TruncateUtf8(const std::string& s, size_t max_len) {
    size_t chars = 0, i = 0;
    while (i < s.size() && chars < max_len) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t step = 1;
        if ((c & 0x80) == 0x00) step = 1;
        else if ((c & 0xE0) == 0xC0) step = 2;
        else if ((c & 0xF0) == 0xE0) step = 3;
        else if ((c & 0xF8) == 0xF0) step = 4;
        if (i + step > s.size()) step = s.size() - i;
        i += step;
        ++chars;
    }
    return s.substr(0, i);
}

}  // namespace

std::string ValuePreview(const Json& value, size_t max_len) {
    std::string text = value.is_string() ? value.get<std::string>() : value.dump();
    // Collapse newlines so a single row stays on one screen line.
    for (auto& c : text)
        if (c == '\n' || c == '\r') c = ' ';
    if (TruncateUtf8(text, max_len) != text) return TruncateUtf8(text, max_len) + "…";
    return TruncateUtf8(text, max_len);
}

std::vector<TableRow> RowsFromData(const Json& data) {
    std::vector<TableRow> rows;
    if (!data.is_object()) return rows;
    for (auto it = data.begin(); it != data.end(); ++it) {
        const Json& v = it.value();
        std::string raw = v.dump();
        rows.push_back(TableRow{it.key(), ValuePreview(v), raw});
    }
    std::sort(rows.begin(), rows.end(),
              [](const TableRow& a, const TableRow& b) { return a.key < b.key; });
    return rows;
}

std::map<std::string, std::string> OrigMapFromRows(const std::vector<TableRow>& rows) {
    std::map<std::string, std::string> orig;
    for (const auto& r : rows) orig[r.key] = r.raw;
    return orig;
}

Json BuildPatchSet(const std::map<std::string, std::string>& orig,
                   const std::map<std::string, std::string>& edits) {
    Json set = Json::object();
    for (const auto& [key, text] : edits) {
        Json parsed = Json::parse(text, nullptr, /*allow_exceptions=*/false);
        if (parsed.is_discarded()) parsed = Json(text);  // invalid JSON -> plain string
        auto it = orig.find(key);
        if (it != orig.end()) {
            Json original = Json::parse(it->second, nullptr, false);
            if (!original.is_discarded() && original == parsed) continue;  // no-op
        }
        set[key] = parsed;
    }
    return set;
}

Json BuildSaveBody(const std::map<std::string, std::string>& orig,
                   const std::map<std::string, std::string>& edits,
                   const std::vector<std::string>& removes, long long mtime_ns) {
    Json patch = Json::object();
    patch["set"] = BuildPatchSet(orig, edits);
    Json rem = Json::array();
    for (const auto& r : removes) rem.push_back(r);
    patch["remove"] = std::move(rem);
    Json body = Json::object();
    body["patch"] = std::move(patch);
    if (mtime_ns > 0) body["expect_mtime_ns"] = mtime_ns;
    return body;
}

}  // namespace p8
