// native/tui/p8_cfg.cpp
#include "p8_cfg.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <set>

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

std::string TrimAscii(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

// The Alpha's split regex [;，,，\n]+ — ASCII ; , newline plus the full-width
// sequences ，(EF BC 8C) and ；(EF BC 9B). Matched byte-exact so ordinary CJK
// text inside a cell is never split.
bool IsSepAt(const std::string& s, size_t i, size_t* step) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    if (c == ';' || c == ',' || c == '\n') {
        *step = 1;
        return true;
    }
    if (c == 0xEF && i + 2 < s.size() && static_cast<unsigned char>(s[i + 1]) == 0xBC) {
        unsigned char c3 = static_cast<unsigned char>(s[i + 2]);
        if (c3 == 0x8C || c3 == 0x9B) {
            *step = 3;
            return true;
        }
    }
    return false;
}

std::vector<std::string> SplitFields(const std::string& s) {
    std::vector<std::string> out;
    std::string part;
    for (size_t i = 0; i < s.size();) {
        size_t step = 0;
        if (IsSepAt(s, i, &step)) {
            if (!part.empty()) out.push_back(TrimAscii(part));
            part.clear();
            i += step;
        } else {
            part += s[i];
            ++i;
        }
    }
    if (!part.empty()) out.push_back(TrimAscii(part));
    return out;
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

// ---- Alpha-v0.3 form view metadata (port of tui/app.py:110-196) ------------

namespace {

// TalkCfg's per-field display names (Alpha TALK_LABELS — friendlier than the
// generic key_maps entries the GUI's data_dicts ships).
const std::map<std::string, std::string>& TalkLabels() {
    static const std::map<std::string, std::string> kMap = {
        {"roleIds", "说话人群组"},   {"roleName", "自定义名字"},
        {"highlights", "高亮人物"},  {"bg", "切换背景"},
        {"audio", "背景音乐"},       {"roles", "人物控制指令"},
        {"screenEffect", "屏幕画面特效"}, {"content", "台词内容"},
        {"check", "前置判断"},       {"nextTalk", "下一对话ID"},
        {"nextTalk2", "失败跳转ID"}, {"option", "已选选项"},
        {"id", "ID"},                {"time", "时间"},
        {"effect", "效果"},          {"effect2", "效果2"},
        {"showTxt", "显示文本"},     {"vocals", "语音"},
        {"replace", "替换"},         {"maxoptions", "最大选项"},
        {"miniGame", "小游戏"},
    };
    return kMap;
}

// TalkCfg form grouping (Alpha TALK_SECTIONS) — the five sections the form
// pane shows in order; every other record key lands in "高级属性".
const std::vector<std::pair<std::string, std::vector<std::string>>>& TalkSections() {
    static const std::vector<std::pair<std::string, std::vector<std::string>>> kSections = {
        {"角色与台词", {"roleIds", "roleName", "highlights"}},
        {"场景与表现", {"bg", "audio", "roles", "screenEffect"}},
        {"台词内容", {"content"}},
        {"逻辑与分支", {"check", "nextTalk", "nextTalk2"}},
        {"已选选项", {"option"}},
    };
    return kSections;
}

// Per-field input hints (Alpha FIELD_HINTS).
const std::map<std::string, std::string>& FieldHints() {
    static const std::map<std::string, std::string> kMap = {
        {"roleIds", "输入角色 ID，逗号隔开"},
        {"roleName", "旁白（默认）"},
        {"highlights", "逗号隔开"},
        {"bg", "0=继承上文 -1=清空人物 -2=仅转场"},
        {"audio", "AudioCfg ID"},
        {"roles", "行: 动作,角色; 列: 动作ID,角色ID..."},
        {"screenEffect", "特效 ID，逗号隔开"},
        {"content", "输入对白内容，支持 <color=..> <size=..> 标签"},
        {"check", "行: 条件类型,判断ID,值; 分号分割多行"},
        {"nextTalk", "= 对话结束"},
        {"nextTalk2", "check 判断失败时跳转"},
        {"option", "逗号隔开"},
    };
    return kMap;
}

// Extra Chinese labels for fields the dicts key_maps misses (Alpha
// FIELD_LABELS_EXTRA, trimmed to the common ones).
const std::map<std::string, std::string>& FieldLabelsExtra() {
    static const std::map<std::string, std::string> kMap = {
        {"title", "标题"},   {"value", "数值"},   {"target", "目标值"},
        {"group", "分组"},   {"lv", "等级"},      {"last", "前置"},
        {"rate", "概率"},    {"priority", "优先级"}, {"order", "顺序"},
        {"next", "下一项"},  {"nextTalk", "下一对话ID"}, {"img", "图片"},
        {"imgs", "图片列表"}, {"sound", "音效"},  {"camera", "镜头参数"},
        {"unlock", "解锁条件"}, {"level", "等级"}, {"exp", "经验"},
        {"name", "名称"},    {"desc", "描述"},    {"type", "类型"},
        {"label", "标签"},   {"cost", "消耗"},    {"cond", "条件"},
    };
    return kMap;
}

std::string FieldLabel(const std::string& cfg, const std::string& key, const Json& key_maps) {
    if (cfg == "TalkCfg") {
        const auto& tl = TalkLabels();
        auto it = tl.find(key);
        if (it != tl.end()) return it->second;
    }
    if (key_maps.is_object()) {
        auto km = key_maps.find(cfg);
        if (km != key_maps.end() && km->is_object()) {
            auto f = km->find(key);
            if (f != km->end() && f->is_string()) return f->get<std::string>();
        }
    }
    const auto& extra = FieldLabelsExtra();
    auto it = extra.find(key);
    if (it != extra.end()) return it->second;
    return key;
}

// Schema type of one field with the Alpha's inference fallback for fields the
// schema misses (record value shapes decide).
std::string FieldTypeOf(const Json& schema_cfg, const Json& rec, const std::string& key) {
    if (schema_cfg.is_object()) {
        auto t = schema_cfg.find(key);
        if (t != schema_cfg.end() && t->is_string()) return t->get<std::string>();
    }
    auto v = rec.find(key);
    if (v == rec.end() || v->is_null()) return "String";
    if (v->is_array()) {
        if (!v->empty() && (*v)[0].is_array()) return "2D Array";
        return "1D Array";
    }
    if (v->is_number()) return "Number";
    return "String";
}

}  // namespace

std::string EncodeFieldValue(const Json& value, const std::string& ftype) {
    if (value.is_null()) return "";
    if (ftype == "1D Array") {
        if (!value.is_array()) return value.is_string() ? value.get<std::string>() : value.dump();
        std::string out;
        for (size_t i = 0; i < value.size(); ++i) {
            if (i) out += ", ";
            out += value[i].is_string() ? value[i].get<std::string>() : value[i].dump();
        }
        return out;
    }
    if (ftype == "2D Array") {
        if (!value.is_array()) return value.is_string() ? value.get<std::string>() : value.dump();
        std::string out;
        for (size_t i = 0; i < value.size(); ++i) {
            if (i) out += "; ";
            const Json& row = value[i];
            if (row.is_array()) {
                for (size_t j = 0; j < row.size(); ++j) {
                    if (j) out += ", ";
                    out += row[j].is_string() ? row[j].get<std::string>() : row[j].dump();
                }
            } else {
                out += row.is_string() ? row.get<std::string>() : row.dump();
            }
        }
        return out;
    }
    if (value.is_object() || value.is_array()) return value.dump();
    return value.is_string() ? value.get<std::string>() : value.dump();
}

namespace {

bool IsIntText(const std::string& s) {
    size_t b = 0;
    if (b < s.size() && (s[b] == '-' || s[b] == '+')) ++b;
    if (b >= s.size()) return false;
    for (size_t i = b; i < s.size(); ++i)
        if (s[i] < '0' || s[i] > '9') return false;
    return true;
}

bool IsFloatText(const std::string& s) {
    // ^-?\d+\.\d+$ (the Alpha's float regex)
    size_t b = 0;
    if (b < s.size() && s[b] == '-') ++b;
    size_t dot = std::string::npos;
    for (size_t i = b; i < s.size(); ++i) {
        if (s[i] == '.') {
            if (dot != std::string::npos) return false;
            dot = i;
        } else if (s[i] < '0' || s[i] > '9') {
            return false;
        }
    }
    return dot != std::string::npos && dot > b && dot + 1 < s.size();
}

}  // namespace

Json DecodeFieldValue(const std::string& text, const std::string& ftype) {
    // strip (Python .strip())
    size_t b = text.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) {
        if (ftype == "String") return Json("");
        if (ftype == "Number") return Json(0);
        return Json::array();
    }
    size_t e = text.find_last_not_of(" \t\r\n");
    std::string t = text.substr(b, e - b + 1);
    if (ftype == "Number") {
        if (IsIntText(t)) {
            try {
                return Json(static_cast<long long>(std::stoll(t)));
            } catch (...) {
                return Json(0);
            }
        }
        if (IsFloatText(t)) {
            try {
                return Json(std::stod(t));
            } catch (...) {
                return Json(0);
            }
        }
        return Json(0);
    }
    if (ftype == "String") {
        // Typed display text lands verbatim; a JSON-quoted literal (the
        // no-code suggestions inject `"10"`-style codes) is unwrapped.
        if (t.size() >= 2 && t.front() == '"' && t.back() == '"') {
            Json quoted = Json::parse(t, nullptr, false);
            if (!quoted.is_discarded()) return quoted;
        }
        return Json(t);
    }
    auto scalar = [](const std::string& p) -> Json {
        if (IsIntText(p)) {
            try {
                return Json(static_cast<long long>(std::stoll(p)));
            } catch (...) {
                return Json(p);
            }
        }
        if (IsFloatText(p)) {
            try {
                return Json(std::stod(p));
            } catch (...) {
                return Json(p);
            }
        }
        return Json(p);
    };
    if (ftype == "1D Array") {
        Json out = Json::array();
        for (const auto& p : SplitFields(t)) {
            if (p.empty()) continue;
            out.push_back(scalar(p));
        }
        return out;
    }
    if (ftype == "2D Array") {
        Json out = Json::array();
        // Rows split on ASCII ; and newline only (the Alpha's [;\n]+).
        std::vector<std::string> lines;
        std::string line;
        for (char c : t) {
            if (c == ';' || c == '\n') {
                if (!line.empty()) lines.push_back(line);
                line.clear();
            } else if (c != '\r') {
                line += c;
            }
        }
        if (!line.empty()) lines.push_back(line);
        for (const auto& l : lines) {
            // Columns split on , ， ; (the Alpha's [,，]+ within a row).
            Json row = Json::array();
            for (const auto& p : SplitFields(l)) {
                if (p.empty()) continue;
                row.push_back(scalar(p));
            }
            out.push_back(std::move(row));
        }
        return out;
    }
    // Unknown type: try JSON, fall back to a plain string.
    Json parsed = Json::parse(t, nullptr, false);
    return parsed.is_discarded() ? Json(t) : parsed;
}

std::vector<FormRow> FormLayout(const std::string& cfg, const std::string& raw,
                                const Json& schema, const Json& key_maps) {
    std::vector<FormRow> out;
    Json rec = Json::parse(raw, nullptr, /*allow_exceptions=*/false);
    if (rec.is_discarded() || !rec.is_object()) return out;
    Json schema_cfg = schema.is_object() && schema.contains(cfg) && schema.at(cfg).is_object()
                          ? schema.at(cfg)
                          : Json::object();
    auto push_field = [&](const std::string& key) {
        Json value = rec.contains(key) ? rec.at(key) : Json();
        FormRow row;
        row.kind = FormRow::Kind::Field;
        row.key = key;
        row.label = FieldLabel(cfg, key, key_maps);
        row.type = FieldTypeOf(schema_cfg, rec, key);
        row.value = EncodeFieldValue(value, row.type);
        auto h = FieldHints().find(key);
        if (h != FieldHints().end()) row.hint = h->second;
        row.dict = FieldDictPool(cfg, key);
        out.push_back(std::move(row));
    };
    auto push_section = [&](const std::string& title) {
        FormRow row;
        row.kind = FormRow::Kind::Section;
        row.section = title;
        out.push_back(std::move(row));
    };
    if (cfg == "TalkCfg") {
        std::set<std::string> special;
        for (const auto& [title, keys] : TalkSections())
            for (const auto& key : keys) special.insert(key);
        for (const auto& [title, keys] : TalkSections()) {
            // A section with no keys in the record renders as an empty header —
            // skip it so the cursor never lands on a bare title.
            std::vector<std::string> present;
            for (const auto& key : keys)
                if (rec.contains(key)) present.push_back(key);
            if (present.empty()) continue;
            push_section(title);
            for (const auto& key : present) push_field(key);
        }
        std::vector<std::string> remaining;
        for (auto it = rec.begin(); it != rec.end(); ++it)
            if (!special.count(it.key())) remaining.push_back(it.key());
        std::sort(remaining.begin(), remaining.end());
        if (!remaining.empty()) {
            push_section("高级属性 " + std::to_string(remaining.size()) + " 项");
            for (const auto& key : remaining) push_field(key);
        }
        return out;
    }
    std::vector<std::string> keys;
    for (auto it = rec.begin(); it != rec.end(); ++it) keys.push_back(it.key());
    std::sort(keys.begin(), keys.end());
    // id first (the Alpha moved it to the top of the ungrouped forms).
    for (size_t i = 0; i < keys.size(); ++i) {
        if (keys[i] == "id") {
            keys.erase(keys.begin() + static_cast<long>(i));
            keys.insert(keys.begin(), "id");
            break;
        }
    }
    for (const auto& key : keys) push_field(key);
    return out;
}

std::vector<std::string> ChooseColumns(const std::string& cfg, const Json& schema_cfg,
                                       const std::vector<std::string>& sample_rows) {
    // Parse a bounded sample (schema-driven fields always exist in practice).
    std::vector<Json> records;
    records.reserve(std::min(sample_rows.size(), size_t{50}));
    for (size_t i = 0; i < sample_rows.size() && records.size() < 50; ++i) {
        Json r = Json::parse(sample_rows[i], nullptr, false);
        if (!r.is_discarded() && r.is_object()) records.push_back(std::move(r));
    }
    auto appears = [&](const std::string& col) {
        for (const auto& r : records)
            if (r.contains(col)) return true;
        return false;
    };
    std::vector<std::string> cols{"ID"};
    std::vector<std::string> candidates;
    auto add_candidate = [&](const std::string& k) {
        if (k == "id") return;
        for (const auto& c : candidates)
            if (c == k) return;
        if (candidates.size() < 6) candidates.push_back(k);
    };
    static const char* kPreferred[] = {"title", "name", "desc",  "label", "type",
                                       "group", "cost", "effect", "cond"};
    if (schema_cfg.is_object()) {
        for (const char* p : kPreferred)
            if (schema_cfg.contains(p)) add_candidate(p);
        for (auto it = schema_cfg.begin(); it != schema_cfg.end(); ++it) add_candidate(it.key());
    }
    std::vector<std::string> chosen;
    for (const auto& c : candidates) {
        if (appears(c)) chosen.push_back(c);
        if (chosen.size() >= 3) break;
    }
    if (chosen.empty()) {
        cols.push_back("预览");
    } else {
        for (auto& c : chosen) cols.push_back(c);
        if (cols.size() < 4) cols.push_back("预览");
    }
    (void)cfg;
    return cols;
}

std::string TableCellText(const Json& record, const std::string& col, size_t max_chars) {
    if (col == "ID") {
        // The row key is the ID by definition; callers pass the record too.
        if (record.is_object()) {
            auto id = record.find("id");
            if (id != record.end() && !id->is_null()) return ValuePreview(*id, max_chars);
        }
        return "";
    }
    if (col == "预览") {
        std::string out;
        size_t n = 0;
        for (auto it = record.begin(); it != record.end() && n < 3; ++it, ++n) {
            if (n) out += ", ";
            out += it.key() + "=" +
                   (it.value().is_string() ? it.value().get<std::string>() : it.value().dump());
        }
        return out;
    }
    auto v = record.find(col);
    if (v == record.end() || v->is_null()) return "";
    std::string s = v->is_string() ? v->get<std::string>() : v->dump();
    if (TruncateUtf8(s, max_chars) != s) return TruncateUtf8(s, max_chars) + "…";
    return s;
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

std::string FieldDictPool(const std::string& cfg, const std::string& field) {
    // The Alpha's SuggestDropdown pools: identity-ish fields suggest from the
    // matching game_dicts pool ("ID · 名称" candidates).
    static const std::map<std::string, std::string> kByField = {
        {"roleIds", "roles"},   {"roleName", "roles"}, {"role", "roles"},
        {"speaker", "roles"},   {"npcId", "roles"},    {"npc", "roles"},
        {"bg", "bgs"},          {"bgId", "bgs"},
        {"audio", "audios"},    {"audioId", "audios"}, {"sound", "sound"},
        {"mapId", "maps"},      {"map", "maps"},
        {"itemId", "items"},    {"item", "items"},
        {"jobId", "jobs"},      {"job", "jobs"},
        {"attrId", "attrs"},    {"attr", "attrs"},
        {"icon", "icons"},      {"faceId", "icons"},
    };
    (void)cfg;
    auto it = kByField.find(field);
    return it == kByField.end() ? std::string() : it->second;
}

}  // namespace p8
