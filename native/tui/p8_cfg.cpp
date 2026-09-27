// native/tui/p8_cfg.cpp
#include "p8_cfg.h"

#include <algorithm>
#include <cctype>

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
                   const std::map<std::string, std::string>& edits,
                   const std::vector<std::string>& adds) {
    Json set = Json::object();
    for (const auto& [key, text] : edits) {
        Json parsed = Json::parse(text, nullptr, /*allow_exceptions=*/false);
        if (parsed.is_discarded()) parsed = Json(text);  // invalid JSON -> plain string
        bool is_add = std::find(adds.begin(), adds.end(), key) != adds.end();
        if (!is_add) {
            auto it = orig.find(key);
            if (it != orig.end()) {
                Json original = Json::parse(it->second, nullptr, false);
                if (!original.is_discarded() && original == parsed) continue;  // no-op
            }
        }
        set[key] = parsed;
    }
    return set;
}

Json BuildSaveBody(const std::map<std::string, std::string>& orig,
                   const std::map<std::string, std::string>& edits,
                   const std::vector<std::string>& removes, long long mtime_ns,
                   const std::vector<std::string>& adds) {
    Json patch = Json::object();
    patch["set"] = BuildPatchSet(orig, edits, adds);
    Json rem = Json::array();
    for (const auto& r : removes) rem.push_back(r);
    patch["remove"] = std::move(rem);
    Json body = Json::object();
    body["patch"] = std::move(patch);
    if (mtime_ns > 0) body["expect_mtime_ns"] = mtime_ns;
    return body;
}

std::string NextRowKey(const std::vector<TableRow>& rows) {
    // An empty (or all-numeric) table grows 1,2,...; anything non-numeric in
    // the key set switches to the _new / _new2 / ... scheme.
    long long max_num = 0;
    bool all_numeric = true;
    for (const auto& r : rows) {
        bool numeric = !r.key.empty();
        long long v = 0;
        for (char c : r.key) {
            if (c < '0' || c > '9') {
                numeric = false;
                break;
            }
            if (v < 1000000000000000LL) v = v * 10 + (c - '0');
        }
        if (!numeric) {
            all_numeric = false;
            break;
        }
        max_num = std::max(max_num, v);
    }
    if (all_numeric) return std::to_string(max_num + 1);
    for (int i = 1;; ++i) {
        std::string candidate = i == 1 ? "_new" : ("_new" + std::to_string(i));
        bool taken = false;
        for (const auto& r : rows)
            if (r.key == candidate) {
                taken = true;
                break;
            }
        if (!taken) return candidate;
    }
}

std::vector<std::pair<std::string, std::string>> FormFields(const std::string& raw) {
    std::vector<std::pair<std::string, std::string>> out;
    Json parsed = Json::parse(raw, nullptr, /*allow_exceptions=*/false);
    if (parsed.is_discarded() || !parsed.is_object()) return out;
    for (auto it = parsed.begin(); it != parsed.end(); ++it)
        out.emplace_back(it.key(), ValuePreview(it.value(), 48));
    return out;
}

bool ApplyFieldEdit(const std::string& raw, const std::string& field,
                    const std::string& value_text, std::string* out) {
    Json parsed = Json::parse(raw, nullptr, /*allow_exceptions=*/false);
    if (parsed.is_discarded() || !parsed.is_object()) return false;
    Json value = Json::parse(value_text, nullptr, /*allow_exceptions=*/false);
    if (value.is_discarded()) value = Json(value_text);  // invalid JSON -> plain string
    parsed[field] = std::move(value);
    *out = parsed.dump();
    return true;
}

Json TableDataForValidate(const std::vector<TableRow>& rows,
                          const std::map<std::string, std::string>& edits,
                          const std::vector<std::string>& removes) {
    Json data = Json::object();
    for (const auto& r : rows) {
        bool removed = std::find(removes.begin(), removes.end(), r.key) != removes.end();
        if (removed) continue;
        auto it = edits.find(r.key);
        if (it != edits.end()) {
            Json parsed = Json::parse(it->second, nullptr, /*allow_exceptions=*/false);
            data[r.key] = parsed.is_discarded() ? Json(it->second) : std::move(parsed);
        } else {
            Json parsed = Json::parse(r.raw, nullptr, /*allow_exceptions=*/false);
            data[r.key] = parsed.is_discarded() ? Json(r.raw) : std::move(parsed);
        }
    }
    return data;
}

// ---- no-code mode / field suggestions -------------------------------------

namespace {

std::string ascii_lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

bool is_word_byte(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) || c == '_';
}

// Replace every standalone occurrence of the single letter `name` (not part of
// a larger word — same boundaries as the GUI's assembleEffectCode regex).
std::string replace_standalone(const std::string& src, const std::string& name,
                               const std::string& value) {
    if (name.size() != 1) return src;
    std::string out;
    for (size_t i = 0; i < src.size(); ++i) {
        if (src[i] == name[0] && (i == 0 || !is_word_byte(src[i - 1])) &&
            (i + 1 == src.size() || !is_word_byte(src[i + 1]))) {
            out += value;
        } else {
            out += src[i];
        }
    }
    return out;
}

}  // namespace

std::string FieldSuggestMode(const std::string& cfg, const std::string& field) {
    const std::string f = ascii_lower(field);
    if (cfg == "TalkCfg" && f == "roles") return "action";
    if (f == "screeneffect") return "screen";
    if (f == "cost") return "cost";
    if (f == "condition" || f == "cond" || f == "precondition" || f == "check")
        return "condition";
    if (f == "roles" || f == "roleids" || f == "speaker") return "role";
    if (f.find("effect") != std::string::npos) return "effect";
    return "";
}

std::vector<SuggestionSlot> ParseCodeSlots(const std::string& code) {
    std::vector<SuggestionSlot> out;
    auto find_slot = [&](const std::string& kind, const std::string& name) -> SuggestionSlot* {
        for (auto& s : out)
            if (s.kind == kind && s.name == name) return &s;
        return nullptr;
    };
    // "@NAME@" placeholders; mask the span so letters inside never count as
    // bare number slots.
    std::string masked = code;
    size_t pos = 0;
    while ((pos = masked.find('@', pos)) != std::string::npos) {
        const size_t end = masked.find('@', pos + 1);
        if (end == std::string::npos) break;
        const std::string name = code.substr(pos + 1, end - pos - 1);
        bool ok = !name.empty();
        for (char c : name)
            if (!is_word_byte(c)) ok = false;
        if (ok) {
            std::string pool = name;
            for (auto& c : pool)
                c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
            if (SuggestionSlot* s = find_slot("dict", pool)) {
                s->count++;
            } else {
                out.push_back(SuggestionSlot{"dict", pool, pool, pool, 1});
            }
        }
        for (size_t i = pos; i <= end && i < masked.size(); ++i) masked[i] = ' ';
        pos = end;
    }
    // Bare A-Z letters outside placeholders.
    for (size_t i = 0; i < masked.size(); ++i) {
        const char c = masked[i];
        if (c < 'A' || c > 'Z') continue;
        if ((i > 0 && is_word_byte(masked[i - 1])) ||
            (i + 1 < masked.size() && is_word_byte(masked[i + 1])))
            continue;
        const std::string name(1, c);
        if (SuggestionSlot* s = find_slot("number", name)) {
            s->count++;
        } else {
            out.push_back(SuggestionSlot{"number", name, "", "", 1});
        }
    }
    return out;
}

std::string NormalizeForMatch(const std::string& s) {
    std::string t;
    for (char c : s) {
        if (c == ' ') continue;
        t += static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }
    auto rep = [&t](const std::string& a, const std::string& b) {
        size_t p = 0;
        while ((p = t.find(a, p)) != std::string::npos) {
            t.replace(p, a.size(), b);
            p += b.size();
        }
    };
    rep("\xE2\x89\xA5", ">=");  // ≥
    rep("\xE2\x89\xA4", "<=");  // ≤
    rep("\xEF\xBC\x9E", ">");   // ＞
    rep("\xEF\xBC\x9C", "<");   // ＜
    return t;
}

std::vector<int> FilterSuggestions(const std::vector<FieldSuggestion>& all,
                                   const std::string& query) {
    // NormalizeForMatch strips spaces, so a blank query normalizes to "" = keep
    // document order (which is the backend's score order).
    const std::string q = NormalizeForMatch(query);
    std::vector<int> out;
    for (size_t i = 0; i < all.size(); ++i) {
        if (q.empty() || NormalizeForMatch(all[i].desc).find(q) != std::string::npos ||
            NormalizeForMatch(all[i].code).find(q) != std::string::npos)
            out.push_back(static_cast<int>(i));
    }
    return out;
}

std::vector<int> FilterEntries(const std::vector<std::pair<std::string, std::string>>& entries,
                               const std::string& q) {
    std::vector<int> out;
    const std::string needle = ascii_lower(q);
    for (size_t i = 0; i < entries.size(); ++i) {
        if (needle.empty() || !q.empty() && entries[i].second.find(q) != std::string::npos ||
            ascii_lower(entries[i].first).find(needle) != std::string::npos ||
            ascii_lower(entries[i].second).find(needle) != std::string::npos)
            out.push_back(static_cast<int>(i));
    }
    return out;
}

std::string AssembleEffectCode(const std::string& tmpl,
                               const std::vector<SuggestionSlot>& slots,
                               const std::map<std::string, std::string>& values) {
    std::string out = tmpl;
    for (const auto& s : slots) {
        auto it = values.find(s.name);
        if (it == values.end() || it->second.empty()) continue;
        if (s.kind == "dict") {
            const std::string ph = "@" + s.name + "@";
            std::string rebuilt;
            size_t pos = 0;
            while (true) {
                const size_t hit = out.find(ph, pos);
                if (hit == std::string::npos) {
                    rebuilt += out.substr(pos);
                    break;
                }
                rebuilt += out.substr(pos, hit - pos) + it->second;
                pos = hit + ph.size();
            }
            out = std::move(rebuilt);
        } else {
            out = replace_standalone(out, s.name, it->second);
        }
    }
    return out;
}

std::string MergeCodeIntoBuffer(const std::string& buf, const std::string& code) {
    std::string t = buf;
    while (!t.empty() && (t.front() == ' ' || t.front() == '\t')) t.erase(t.begin());
    while (!t.empty() && (t.back() == ' ' || t.back() == '\t')) t.pop_back();
    const std::string quoted = "\"" + code + "\"";
    if (t.empty() || t == "\"\"" || t == "null") return quoted;
    if (t.size() >= 2 && t.front() == '"' && t.back() == '"') {
        const std::string inner = t.substr(1, t.size() - 2);
        if (inner.empty()) return quoted;
        return "\"" + inner + ", " + code + "\"";
    }
    return quoted;
}

std::string SlotPoolDictKey(const std::string& pool) {
    static const std::map<std::string, std::string> kMap = {
        {"ATTR", "attrs"},         {"ROLE", "roles"},     {"ITEM", "items"},
        {"RELATION", "relations"}, {"MAP", "maps"},       {"JOB", "jobs"},
        {"BG", "bgs"},             {"STATE", "states"},   {"TEXT", "texts"},
        {"GAME", "games"},
    };
    std::string key;
    for (char c : pool) key += static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    auto it = kMap.find(key);
    return it == kMap.end() ? std::string() : it->second;
}

}  // namespace p8
