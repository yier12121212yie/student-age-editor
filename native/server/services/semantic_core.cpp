// wip/P1/semantic_core.cpp — scalar helpers + secondary index + guide_rules +
// ref_rules. See semantic_logic.h for the Python sources.
#include "semantic_logic.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <regex>
#include <set>

#include "sa_core/json_wire.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "semantic_assets.h"

namespace sa {
namespace p1 {
namespace {

namespace str = sa_core::str;

std::string pys(const json& v) { return sa_core::py_str(v); }

// Python repr() for a scalar cell (used by the %r error messages).
std::string pyr(const json& v) {
    if (v.is_string()) return sa_core::py_repr_str(v.get<std::string>());
    return sa_core::py_str(v);
}

bool digit_only(const std::string& s) {
    if (s.empty()) return false;
    for (char c : s)
        if (c < '0' || c > '9') return false;
    return true;
}
std::string lstrip_minus(const std::string& s) {
    size_t i = 0;
    while (i < s.size() && s[i] == '-') ++i;
    return s.substr(i);
}
// Python str.isdigit() on an already-built ascii substring (bool result only).
bool py_isdigit(const std::string& s) { return digit_only(s); }

// Replace the first "." occurrence (Python str.replace('.', '', 1)).
std::string replace_first_dot(const std::string& s) {
    std::string out = s;
    auto pos = out.find('.');
    if (pos != std::string::npos) out.erase(pos, 1);
    return out;
}

json issue(const char* level, const std::string& msg) {
    json p = json::array();
    p.push_back(level);
    p.push_back(msg);
    return p;
}

const std::set<std::string>& exempt() {
    static const std::set<std::string> s = {"0", "-1", "-2"};
    return s;
}

// Flatten a field value (Number / 1D / 2D) into a list of ints (ref_rules._norm_ids).
void norm_ids_walk(const json& v, std::vector<long long>& out) {
    if (v.is_null()) return;
    if (v.is_array()) {
        for (const auto& x : v) norm_ids_walk(x, out);
        return;
    }
    auto n = to_int_loose(v);
    if (n) out.push_back(*n);
}

std::set<std::string> table_id_strs(const json* table_data, const json* extra) {
    std::set<std::string> ids;
    if (table_data && table_data->is_object()) {
        for (auto it = table_data->begin(); it != table_data->end(); ++it) {
            auto n = to_int_loose(json(it.key()));
            ids.insert(n ? std::to_string(*n) : it.key());
            if (it.value().is_object() && it.value().contains("id")) {
                auto rid = to_int_loose(it.value().at("id"));
                if (rid) ids.insert(std::to_string(*rid));
            }
        }
    }
    if (extra && extra->is_array()) {
        for (const auto& k : *extra) {
            json kj = k.is_string() ? k : k;  // keys may arrive as str or num
            std::string ks = k.is_string() ? k.get<std::string>() : pys(k);
            auto n = to_int_loose(kj);
            ids.insert(n ? std::to_string(*n) : ks);
        }
    }
    return ids;
}

// ---------------------------------------------------------------------------
// secondary index helpers
// ---------------------------------------------------------------------------
const std::regex kVarRe(R"(^(?:@[A-Z_]+@|[A-Z][A-Z0-9*]*)$)");

bool is_variable_token(const std::string& s) {
    return std::regex_match(s, kVarRe) && !is_numeric_token(s);
}
bool is_rest_token(const std::string& s) {
    return !s.empty() && s.back() == '*' && is_variable_token(s);
}
std::vector<std::string> parse_template_parts(const std::string& code) {
    std::string s = code;
    // Python str(code).strip().strip("[]"): trim whitespace then trim [] both ends.
    s = str::trim(s);
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == '[' || s[b] == ']')) ++b;
    while (e > b && (s[e - 1] == '[' || s[e - 1] == ']')) --e;
    s = s.substr(b, e - b);
    std::vector<std::string> parts;
    size_t pos = 0;
    while (true) {
        size_t comma = s.find(',', pos);
        std::string piece = str::trim(s.substr(
            pos, comma == std::string::npos ? std::string::npos : comma - pos));
        if (!piece.empty()) parts.push_back(piece);
        if (comma == std::string::npos) break;
        pos = comma + 1;
    }
    return parts;
}

// build_rule_map (data_dicts.build_rule_map): key "cmd1_cmd2" -> {idx: TYPE}.
std::map<std::string, std::map<int, std::string>> build_rule_map(const json& entries) {
    static const std::vector<std::pair<std::string, std::string>> kPlaceholders = {
        {"@ATTR@", "ATTR"}, {"@ROLE@", "ROLE"}, {"@ITEM@", "ITEM"},
        {"@RELATION@", "RELATION"}, {"@MAP@", "MAP"}, {"@JOB@", "JOB"},
        {"@STATE@", "STATE"}, {"@TEXT@", "TEXT"},
        {"@NEGOTIATION_SKILL@", "NEGOTIATION_SKILL"},
        {"@NEGOTIATION_BUFF@", "NEGOTIATION_BUFF"}, {"@GAME@", "GAME"},
        {"@KZONE_POST@", "KZONE_POST"}, {"@KZONE_MESSAGE@", "KZONE_MESSAGE"},
        {"@PHONE_MSG@", "PHONE_MSG"},
    };
    std::map<std::string, std::map<int, std::string>> rule_map;
    for (const auto& entry : entries) {
        std::string code = entry.value("code", "");
        auto parts = parse_template_parts(code);
        if (parts.empty() || !py_isdigit(lstrip_minus(parts[0]))) continue;
        std::string cmd1 = parts[0];
        std::string cmd2 = (parts.size() > 1 && py_isdigit(lstrip_minus(parts[1]))) ? parts[1] : "*";
        std::map<int, std::string> mapping;
        for (size_t idx = 0; idx < parts.size(); ++idx)
            for (const auto& ph : kPlaceholders)
                if (parts[idx].find(ph.first) != std::string::npos) {
                    mapping[static_cast<int>(idx)] = ph.second;
                    break;
                }
        if (cmd1 == "60" && (cmd2 == "1" || cmd2 == "-1" || cmd2 == "2" || cmd2 == "-2" ||
                             cmd2 == "3" || cmd2 == "30"))
            mapping[2] = "ITEM";
        if (!mapping.empty()) rule_map[cmd1 + "_" + cmd2] = mapping;
    }
    return rule_map;
}

bool allows_length(const json& tmpl, size_t actual) {
    const json& parts = tmpl.at("parts");
    if (!parts.empty() && is_rest_token(parts.back().get<std::string>()))
        return actual >= parts.size();
    return parts.size() == actual;
}
std::string length_hint(const json& tmpl) {
    const json& parts = tmpl.at("parts");
    if (!parts.empty() && is_rest_token(parts.back().get<std::string>()))
        return ">= " + std::to_string(parts.size());
    return std::to_string(parts.size());
}

// Python str.join over normalized scalars of a json array.
std::string join_norm(const json& arr) {
    std::string out;
    bool first = true;
    for (const auto& x : arr) {
        if (!first) out += ", ";
        out += normalize_scalar(x);
        first = false;
    }
    return out;
}

std::optional<std::string> lookup_name(const std::string& type, const std::string& value,
                                       const AvailableMap& available) {
    auto it = available.find(type);
    if (it == available.end()) return std::nullopt;
    auto kv = it->second.find(value);
    if (kv == it->second.end()) return std::nullopt;
    return kv->second;  // present (display may be empty)
}

std::string render_template(const json& tmpl, const json& params, const AvailableMap& available) {
    std::string desc = tmpl.value("desc", "");
    const json& pmap = secondary_placeholder_map();
    for (auto it = params.begin(); it != params.end(); ++it) {
        const std::string& token = it.key();
        const json& value = it.value();
        if (value.is_array()) {
            std::string rep = "[" + join_norm(value) + "]";
            desc = str::replace_all(desc, token, rep);
            continue;
        }
        std::string pretty = normalize_scalar(value);
        if (pmap.contains(token)) {
            std::string etype = pmap[token][0].get<std::string>();
            std::string fallback = pmap[token][1].get<std::string>();
            auto resolved = lookup_name(etype, pretty, available);
            std::string rep = (resolved && !resolved->empty()) ? *resolved : (fallback + "(" + pretty + ")");
            desc = str::replace_all(desc, token, rep);
        } else if (is_variable_token(token)) {
            desc = str::replace_all(desc, token, pretty);
        }
    }
    return desc;
}

}  // namespace

// ---------------------------------------------------------------------------
// public scalar helpers
// ---------------------------------------------------------------------------
std::optional<long long> to_int(const json& v) {
    if (v.is_boolean()) return std::nullopt;
    if (v.is_number_integer()) return v.get<long long>();
    if (v.is_number_unsigned()) return static_cast<long long>(v.get<unsigned long long>());
    if (v.is_number_float()) {
        double d = v.get<double>();
        double r = std::trunc(d);
        if (r == d) return static_cast<long long>(r);
        return std::nullopt;
    }
    if (v.is_string()) {
        std::string s = str::trim(v.get<std::string>());
        if (py_isdigit(lstrip_minus(s)) && !s.empty()) {
            try { return std::stoll(s); } catch (...) { return std::nullopt; }
        }
    }
    return std::nullopt;
}

std::optional<long long> to_int_loose(const json& v) {
    if (v.is_boolean()) return std::nullopt;
    if (v.is_number_integer()) return v.get<long long>();
    if (v.is_number_unsigned()) return static_cast<long long>(v.get<unsigned long long>());
    if (v.is_number_float()) {
        double d = v.get<double>();
        double r = std::trunc(d);
        if (r == d) return static_cast<long long>(r);
        return std::nullopt;
    }
    if (v.is_string()) {
        std::string s = str::trim(v.get<std::string>());
        if (py_isdigit(s)) {
            try { return std::stoll(s); } catch (...) { return std::nullopt; }
        }
        if (s.size() > 2 && s.compare(s.size() - 2, 2, ".0") == 0 && py_isdigit(s.substr(0, s.size() - 2))) {
            try { return std::stoll(s.substr(0, s.size() - 2)); } catch (...) { return std::nullopt; }
        }
    }
    return std::nullopt;
}

std::optional<double> to_float(const json& v) {
    if (v.is_boolean()) return std::nullopt;
    if (v.is_number()) return v.get<double>();
    if (v.is_string()) {
        std::string s = str::trim(v.get<std::string>());
        try { size_t i = 0; double d = std::stod(s, &i); if (i == s.size()) return d; }
        catch (...) {}
    }
    return std::nullopt;
}

std::string normalize_scalar(const json& v) {
    if (v.is_boolean()) return v.get<bool>() ? "1" : "0";
    if (v.is_number_integer()) return std::to_string(v.get<long long>());
    if (v.is_number_unsigned()) return std::to_string(v.get<unsigned long long>());
    if (v.is_number_float()) {
        double d = v.get<double>();
        double r = std::trunc(d);
        if (r == d && std::abs(d) < 9.2e18) return std::to_string(static_cast<long long>(r));
        return sa_core::py_str(v);  // repr-like for fractional floats
    }
    std::string text;
    if (v.is_string()) text = str::trim(v.get<std::string>());
    else if (v.is_null()) return "None";
    else text = str::trim(pys(v));
    try {
        size_t i = 0;
        double num = std::stod(text, &i);
        if (i == text.size()) {
            double r = std::trunc(num);
            if (r == num && std::abs(num) < 9.2e18) return std::to_string(static_cast<long long>(r));
            return text;
        }
    } catch (...) {}
    return text;
}

bool is_numeric_token(const std::string& s) {
    std::string t = lstrip_minus(s);
    t = replace_first_dot(t);
    return py_isdigit(t);
}

// ---------------------------------------------------------------------------
// secondary index
// ---------------------------------------------------------------------------
SecondaryIndex build_secondary_index(const json& entries) {
    SecondaryIndex idx;
    auto rule_map = build_rule_map(entries);
    // signatures preserve insertion order like Python's list append before sort.
    std::map<std::string, std::map<std::string, std::vector<json>>> by_sig;
    std::map<std::string, std::vector<json>> by_pri;
    for (const auto& entry : entries) {
        auto parts = parse_template_parts(entry.value("code", ""));
        if (parts.size() < 2 || !is_numeric_token(parts[0]) || !is_numeric_token(parts[1])) continue;
        std::string primary = normalize_scalar(json(parts[0]));
        std::string secondary = normalize_scalar(json(parts[1]));
        json tmpl = json::object();
        tmpl["code"] = entry.value("code", "");
        tmpl["desc"] = entry.value("desc", "");
        json parr = json::array();
        for (auto& p : parts) parr.push_back(p);
        tmpl["parts"] = parr;
        tmpl["primary_code"] = primary;
        tmpl["secondary_code"] = secondary;
        tmpl["primary_name"] = primary;  // no type_rows in this repo
        tmpl["source_file"] = "";
        json rm = json::object();
        auto rmit = rule_map.find(primary + "_" + secondary);
        if (rmit != rule_map.end())
            for (auto& [idx2, type] : rmit->second) rm[std::to_string(idx2)] = type;
        tmpl["rule_mapping"] = rm;
        by_sig[primary][secondary].push_back(tmpl);
        by_pri[primary].push_back(tmpl);
    }
    for (auto& [p, secmap] : by_sig)
        for (auto& [s, lst] : secmap)
            std::sort(lst.begin(), lst.end(), [](const json& a, const json& b) {
                if (a.at("parts").size() != b.at("parts").size())
                    return a.at("parts").size() > b.at("parts").size();
                return a.value("code", "") < b.value("code", "");
            });
    for (auto& [p, lst] : by_pri)
        std::sort(lst.begin(), lst.end(), [](const json& a, const json& b) {
            if (a.value("secondary_code", "") != b.value("secondary_code", ""))
                return a.value("secondary_code", "") < b.value("secondary_code", "");
            if (a.at("parts").size() != b.at("parts").size())
                return a.at("parts").size() < b.at("parts").size();
            return a.value("code", "") < b.value("code", "");
        });
    idx.by_signature = std::move(by_sig);
    idx.by_primary = std::move(by_pri);
    return idx;
}

const SecondaryIndex& condition_secondary_index() {
    static SecondaryIndex idx = build_secondary_index(condition_db());
    return idx;
}
const SecondaryIndex& effect_secondary_index() {
    static SecondaryIndex idx = build_secondary_index(effect_db());
    return idx;
}
const SecondaryIndex& effect_editor_secondary_index() {
    static SecondaryIndex idx = build_secondary_index(effect_editor_db());
    return idx;
}

json validate_secondary_item(const json& item_arr, const SecondaryIndex& idx,
                             const AvailableMap& available) {
    // Python 的失败分支一律 translation = str(item_arr)（repr 风格，字符串元素带引号），
    // 而不是成功路径的 normalize-join 形态。
    auto wrap = [&](std::vector<std::string> errs) {
        json r;
        r["translation"] = pys(item_arr);
        json e = json::array();
        for (auto& s : errs) e.push_back(s);
        r["errors"] = e;
        return r;
    };
    if (!item_arr.is_array()) return wrap({"该行不是有效数组。"});
    if (item_arr.size() < 2) return wrap({"每条二次代码至少需要 2 项，前两项必须是一级代码和二级代码。"});

    std::string primary = normalize_scalar(item_arr[0]);
    std::string secondary = normalize_scalar(item_arr[1]);
    if (!is_numeric_token(primary)) return wrap({"第 1 项 [" + primary + "] 不是有效的一级代码数字。"});
    if (!is_numeric_token(secondary)) return wrap({"第 2 项 [" + secondary + "] 不是有效的二级代码数字。"});

    // ---- match_secondary_template ----
    auto pri_it = idx.by_primary.find(primary);
    std::vector<json> primary_templates;
    if (pri_it != idx.by_primary.end()) primary_templates = pri_it->second;
    if (primary_templates.empty()) {
        // type_name_map empty -> always unknown_primary
        json r;
        r["translation"] = "[" + join_norm(item_arr) + "]";
        r["errors"] = json::array({"一级代码 [" + primary + "] 不在二次代码字典中。"});
        return r;
    }
    std::vector<json> exact;
    auto s0 = idx.by_signature.find(primary);
    if (s0 != idx.by_signature.end()) {
        auto s1 = s0->second.find(secondary);
        if (s1 != s0->second.end()) exact = s1->second;
    }
    if (exact.empty()) {
        std::set<std::string> uniq;
        for (auto& t : primary_templates) uniq.insert(t.value("secondary_code", ""));
        std::vector<std::string> known(uniq.begin(), uniq.end());
        std::sort(known.begin(), known.end(), [](const std::string& a, const std::string& b) {
            bool da = py_isdigit(lstrip_minus(a)), db = py_isdigit(lstrip_minus(b));
            if (da != db) return da;  // (0,int) < (1,str)
            if (da && db) {
                try { return std::stoll(a) < std::stoll(b); } catch (...) {}
            }
            return a < b;
        });
        std::string hint = known.empty() ? "当前没有找到对应的二级模板。"
                                         : "已知二级代码: " + [&] {
                                               std::string o;
                                               for (size_t i = 0; i < known.size() && i < 12; ++i) {
                                                   if (i) o += ", ";
                                                   o += known[i];
                                               }
                                               return o;
                                           }();
        json r;
        r["translation"] = "[" + join_norm(item_arr) + "]";
        r["errors"] = json::array({primary + " 的二级代码 [" + secondary + "] 不存在。" + hint});
        return r;
    }

    struct Cand {
        int fixed;
        json tmpl;
        json params;
    };
    std::vector<Cand> matched;
    for (const json& tmpl : exact) {
        if (!allows_length(tmpl, item_arr.size())) continue;
        json params = json::object();
        int fixed = 0;
        bool valid = true;
        const json& parts = tmpl.at("parts");
        for (size_t i = 0; i < parts.size(); ++i) {
            std::string token = parts[i].get<std::string>();
            if (is_rest_token(token)) {
                json lst = json::array();
                for (size_t j = i; j < item_arr.size(); ++j) lst.push_back(normalize_scalar(item_arr[j]));
                params[token] = lst;
                break;
            }
            if (i >= item_arr.size()) { valid = false; break; }
            std::string nv = normalize_scalar(item_arr[i]);
            if (is_numeric_token(token)) {
                if (nv != normalize_scalar(json(token))) { valid = false; break; }
                fixed++;
            } else {
                params[token] = nv;
            }
        }
        if (valid) matched.push_back({fixed, tmpl, params});
    }
    if (matched.empty()) {
        std::vector<json> same_len;
        for (auto& t : exact)
            if (allows_length(t, item_arr.size())) same_len.push_back(t);
        json r;
        r["translation"] = "[" + join_norm(item_arr) + "]";
        if (!same_len.empty()) {
            r["errors"] = json::array({same_len[0].value("primary_name", "") + " " + secondary +
                                       " 的固定参数不符合任何已知模板。"});
        } else {
            std::set<std::string> hints;
            for (auto& t : exact) hints.insert(length_hint(t));
            std::vector<std::string> hv(hints.begin(), hints.end());
            std::sort(hv.begin(), hv.end());
            std::string expected;
            for (size_t i = 0; i < hv.size(); ++i) {
                if (i) expected += " / ";
                expected += hv[i];
            }
            std::string pname = exact[0].value("primary_name", "");
            r["errors"] = json::array({pname + " " + secondary + " 的参数数量不匹配，当前 " +
                                       std::to_string(item_arr.size()) + " 项，常见模板需要 " + expected +
                                       " 项。"});
        }
        return r;
    }
    std::sort(matched.begin(), matched.end(), [](const Cand& a, const Cand& b) {
        if (a.fixed != b.fixed) return a.fixed > b.fixed;
        if (a.tmpl.at("parts").size() != b.tmpl.at("parts").size())
            return a.tmpl.at("parts").size() > b.tmpl.at("parts").size();
        return a.tmpl.value("code", "") < b.tmpl.value("code", "");
    });
    const json& tmpl = matched[0].tmpl;
    const json& params = matched[0].params;

    std::vector<std::string> errors;
    auto pool_empty = [](const std::map<std::string, std::string>& m, const std::string& k) {
        return !m.count(k);
    };
    static const std::map<std::string, std::string> kLabels = {
        {"ROLE", "人物"}, {"RELATION", "关系"}, {"ATTR", "属性"}, {"ITEM", "物品"},
        {"MAP", "地点"}, {"JOB", "职业"}, {"STATE", "状态"}, {"TEXT", "文本"},
        {"NEGOTIATION_SKILL", "谈判技能"}, {"NEGOTIATION_BUFF", "谈判Buff"},
        {"GAME", "游戏"}, {"KZONE_POST", "空间动态"}, {"KZONE_MESSAGE", "空间留言"},
        {"PHONE_MSG", "手机消息"},
    };
    for (auto& rm : tmpl.at("rule_mapping").items()) {
        int idx2 = std::stoi(rm.key());
        std::string etype = rm.value().get<std::string>();
        if (idx2 >= static_cast<int>(item_arr.size())) continue;
        std::string value = normalize_scalar(item_arr[idx2]);
        if (value.empty() || value == "0" || value == "-1" || !is_numeric_token(value)) continue;
        if (!available.count(etype) || pool_empty(available.at(etype), value)) {
            std::string label = kLabels.count(etype) ? kLabels.at(etype) : etype;
            errors.push_back(label + "ID [" + value + "] 字典中不存在。");
        }
    }
    std::string translation = render_template(tmpl, params, available);
    if (tmpl.value("primary_code", "") == "998") {
        std::string key;
        for (auto& p : tmpl.at("parts")) {
            std::string s = p.get<std::string>();
            if (is_rest_token(s)) { key = s; break; }
        }
        if (!key.empty() && params.contains(key) && params[key].is_array() && !params[key].empty()) {
            json nested = json::array();
            // nested values were normalized to strings during params build.
            for (auto& x : params[key]) nested.push_back(x);
            auto nested_result = validate_secondary_item(nested, effect_secondary_index(), available);
            std::string raw_nested = "[" + join_norm(params[key]) + "]";
            std::string ntr = nested_result.value("translation", "");
            // replace first occurrence only
            auto pos = translation.find(raw_nested);
            if (pos != std::string::npos)
                translation = translation.substr(0, pos) + ntr + translation.substr(pos + raw_nested.size());
            for (auto& e : nested_result.at("errors")) errors.push_back("嵌套效果 -> " + e.get<std::string>());
        }
    }
    json r;
    r["translation"] = translation;
    json earr = json::array();
    for (auto& s : errors) earr.push_back(s);
    r["errors"] = earr;
    r["template"] = tmpl;
    return r;
}

// ---------------------------------------------------------------------------
// guide_rules: id checks
// ---------------------------------------------------------------------------
std::string norm_cfg_name(const std::string& raw_in) {
    std::string raw = str::trim(raw_in);
    if (raw.empty()) return raw;
    auto slash = raw.find_last_of("/\\");
    std::string base = slash == std::string::npos ? raw : raw.substr(slash + 1);
    if (base.size() >= 5 && str::lower(base.substr(base.size() - 5)) == ".json")
        base = base.substr(0, base.size() - 5);
    const json& gs = game_schema();
    if (gs.contains(base)) return base;
    std::string low = str::lower(base);
    for (auto it = gs.begin(); it != gs.end(); ++it)
        if (str::lower(it.key()) == low) return it.key();
    return base;
}

static std::string check_event_id(const json& value) {
    auto n = to_int(value);
    if (!n) return "";
    std::string s = std::to_string(*n);
    if (s.size() != 7 || s[0] != '1')
        return "事件ID " + s +
               " 不符合指南规则（须为7位数且首位为1，如 1314170）；非法示例：123（不足7位）、"
               "7123456（首位非1）、12345678（超过7位）";
    return "";
}
static std::string check_dialog_id(const json& value, const json* event_id) {
    auto n = to_int(value);
    if (!n) return "";
    std::string s = std::to_string(*n);
    if (s.size() != 10)
        return "对话ID " + s + " 不是10位数（前7位为事件ID，后3位为001~999，如 1234567001）";
    std::string last3 = s.substr(7);
    if (!(std::string("001") <= last3 && last3 <= std::string("999")))
        return "对话ID " + s + " 的后3位应为 001~999";
    if (event_id) {
        auto e = to_int(*event_id);
        if (e && s.substr(0, 7) != std::to_string(*e))
            return "对话ID " + s + " 的前7位（" + s.substr(0, 7) + "）应等于事件ID " + std::to_string(*e);
    }
    return "";
}
static std::string check_option_id(const json& value, const json* event_id) {
    auto n = to_int(value);
    if (!n) return "";
    std::string s = std::to_string(*n);
    if (s.size() != 9)
        return "选项ID " + s + " 不是9位数（前7位为事件ID，后两位为01~99）";
    std::string last2 = s.substr(7);
    if (!(std::string("01") <= last2 && last2 <= std::string("99")))
        return "选项ID " + s + " 的后两位应为 01~99";
    if (event_id) {
        auto e = to_int(*event_id);
        if (e && s.substr(0, 7) != std::to_string(*e))
            return "选项ID " + s + " 的前7位（" + s.substr(0, 7) + "）应等于事件ID " + std::to_string(*e);
    }
    return "";
}

// ---------------------------------------------------------------------------
// describe_screen_row / describe_action_row
// ---------------------------------------------------------------------------
struct Spec { const char* name; int lo; int hi; };
static const std::map<long long, Spec>& screen_spec() {
    static const std::map<long long, Spec> m = {
        {4001, {"屏幕抖动", 0, 1}}, {4002, {"背景模糊", 0, 0}}, {4003, {"清空背景特效", 0, 0}},
        {4004, {"展示物品", 1, 1}}, {4006, {"黑屏片刻后恢复", 0, 0}}, {4007, {"打电话", 2, 2}},
        {4008, {"挂断电话", 0, 0}}, {4009, {"背景陈旧", 0, 0}}, {4010, {"背景反色", 0, 0}},
        {4011, {"闭眼程度(0睁眼~1全闭)", 1, 1}}, {4012, {"闪白屏(0不抖,X为抖X下)", 0, 1}},
        {4015, {"播放CG", 1, 1}}, {4017, {"结束播放CG", 0, 0}},
    };
    return m;
}
static const std::map<long long, std::tuple<const char*, int, int, const char*>>& action_spec() {
    static const std::map<long long, std::tuple<const char*, int, int, const char*>> m = {
        {1001, {"滑动入场", 2, 2, ""}}, {1002, {"渐变出现入场", 2, 2, ""}},
        {1003, {"从底下钻出入场", 2, 2, ""}}, {2001, {"滑出退场", 0, 0, ""}},
        {2002, {"原地退场(渐变)", 0, 0, ""}}, {3000, {"设置表情", 1, 1, ""}},
        {3001, {"跳一跳", 0, 1, ""}}, {3002, {"抖动", 0, 1, ""}},
        {3004, {"水平移动", 1, 1, ""}}, {3005, {"水平翻转", 0, 0, ""}},
        {3006, {"设置服饰", 1, 1, ""}}, {3007, {"镜像", 0, 0, ""}},
        {3008, {"垂直移动", 1, 1, ""}}, {3009, {"设置Emoji", 1, 1, ""}},
    };
    return m;
}
static const std::map<long long, std::string>& expression_dict() {
    static const std::map<long long, std::string> m = {
        {0, "无表情"}, {1, "高兴"}, {2, "生气"}, {3, "伤心"}, {4, "害羞"}, {5, "喜欢"},
        {6, "认真"}, {7, "疑惑"}, {8, "惊讶"}, {9, "得意"}, {10, "微笑"}, {11, "坏笑"},
        {12, "担心"}, {13, "害怕"}, {14, "难过"}, {15, "咆哮"}, {16, "窘迫"}, {17, "不满"},
        {18, "冷笑"}, {19, "无语"}, {20, "苦笑"}, {21, "挫败"}, {22, "喜极而泣"},
        {23, "迷茫"}, {24, "嫌弃"}, {25, "俏皮"}, {26, "尴尬"},
    };
    return m;
}
static std::string role_name(const json& rid) {
    auto* p = ref_pool_for_target("PersonCfg");
    auto it = p->find(pys(rid));
    return it == p->end() ? std::string() : it->second;
}
static std::string bg_name(const json& bgid) {
    auto* p = ref_pool_for_target("BgCfg");
    auto it = p->find(pys(bgid));
    return it == p->end() ? std::string() : it->second;
}

json describe_screen_row(const json& row) {
    json out;
    out["errors"] = json::array();
    if (!row.is_array() || row.empty()) { out["desc"] = ""; return out; }
    auto code = to_int(row[0]);
    std::vector<std::string> errs;
    if (!code || !screen_spec().count(*code)) {
        out["desc"] = "";
        std::string shown = code ? pyr(json(*code)) : pyr(row[0]);
        errs.push_back("不认识的屏幕效果代码 " + shown + "（指南第六节定义了 4001~4017 中的部分代码）");
        out["errors"] = errs;
        return out;
    }
    Spec spec = screen_spec().at(*code);
    int nargs = static_cast<int>(row.size()) - 1;
    std::string args_txt;
    for (int i = 1; i <= nargs; ++i) { if (i > 1) args_txt += ", "; args_txt += pys(row[i]); }
    std::string desc = spec.name;
    if (nargs > 0) {
        if (*code == 4001 && nargs >= 1) desc = "屏幕抖动 " + pys(row[1]) + " 秒";
        else if (*code == 4004 && nargs >= 1) desc = "展示物品/书籍 " + pys(row[1]);
        else if (*code == 4007 && nargs >= 2) {
            std::string bg = bg_name(row[1]); if (bg.empty()) bg = pys(row[1]);
            std::string npc = role_name(row[2]); if (npc.empty()) npc = pys(row[2]);
            desc = "与背景图(" + bg + ")中的 " + npc + " 打电话";
        } else if (*code == 4011 && nargs >= 1) desc = "闭眼程度 " + pys(row[1]) + " (0睁眼~1全闭)";
        else if (*code == 4015 && nargs >= 1) desc = "播放CG " + pys(row[1]);
        else desc = std::string(spec.name) + " (" + args_txt + ")";
    }
    if (nargs < spec.lo || nargs > spec.hi) {
        std::string expected = spec.lo == spec.hi
            ? (spec.lo ? "应填 " + std::to_string(spec.lo) + " 个参数" : "不需参数")
            : "参数个数应为 " + std::to_string(spec.lo) + "~" + std::to_string(spec.hi);
        errs.push_back("屏幕效果 " + std::to_string(*code) + " " + expected + "（当前 " +
                       std::to_string(nargs) + " 个）");
    }
    out["desc"] = desc;
    out["errors"] = errs;
    return out;
}

json describe_action_row(const json& row) {
    json out;
    out["errors"] = json::array();
    if (!row.is_array() || row.size() < 2) {
        out["desc"] = "";
        out["errors"] = json::array({"动作指令应为数组 [人物ID, 指令, 参数...]（如 [0, 3000, 1]）"});
        return out;
    }
    auto npc = to_int(row[0]);
    auto cmd = to_int(row[1]);
    if (!npc) { out["desc"] = ""; out["errors"] = json::array({"首项人物ID " + pyr(row[0]) + " 不是数字"}); return out; }
    if (!cmd || !action_spec().count(*cmd)) {
        out["desc"] = "";
        std::string shown = cmd ? pyr(json(*cmd)) : pyr(row[1]);
        out["errors"] = json::array({"不认识的指令代码 " + shown + "（指南第五节定义了 1001~3009 中的部分指令）"});
        return out;
    }
    auto [name, lo, hi, _note] = action_spec().at(*cmd);
    int nargs = static_cast<int>(row.size()) - 2;
    std::vector<std::string> errs;
    if (*cmd >= 1001 && *cmd <= 1003) {
        if (nargs != 2) errs.push_back("入场指令 " + std::to_string(*cmd) + " 格式为 [人物ID, " +
                                        std::to_string(*cmd) + ", 0, S]（S=1左/2右/3中）");
        else if (!(row[2] == json(0) || row[2] == json("0")))
            errs.push_back("入场指令 " + std::to_string(*cmd) + " 第3位应为 0（如 [0, " +
                           std::to_string(*cmd) + ", 0, 1]）");
        else {
            auto s = to_int(row[3]);
            if (!s || (*s != 1 && *s != 2 && *s != 3))
                errs.push_back("入场指令 " + std::to_string(*cmd) + " 的S（第4位）应为 1左/2右/3中");
        }
    } else if (nargs < lo || nargs > hi) {
        std::string expected = lo == hi ? (lo ? "应填 " + std::to_string(lo) + " 个参数" : "不需参数")
                                        : "参数个数应为 " + std::to_string(lo) + "~" + std::to_string(hi);
        errs.push_back("指令 " + std::to_string(*cmd) + " " + expected + "（当前 " + std::to_string(nargs) + " 个）");
    }
    if (*cmd == 3000 && nargs >= 1) {
        auto e = to_int(row[2]);
        if (e && *e != 0 && !expression_dict().count(*e))
            errs.push_back("表情ID " + std::to_string(*e) + " 不在指南内置表（0默认/1-26常用；自定义差分ID可忽略此提示）");
    }
    if (*cmd == 3004 && nargs >= 1 && !to_float(row[2]))
        errs.push_back("水平移动参数应为像素数值（屏宽2560，向右为正）");
    if (*cmd == 3008 && nargs >= 1 && !to_float(row[2]))
        errs.push_back("垂直移动参数应为像素数值（屏高1440，向上为正）");
    // Python: _role_name(npc) or str(npc) —— npc 是 _to_int 归一后的 int，非原始单元格
    std::string npc_txt = role_name(json(*npc));
    if (npc_txt.empty()) npc_txt = std::to_string(*npc);
    std::string desc = npc_txt + " " + name;
    if (nargs >= 1) {
        if (*cmd == 3000) {
            auto e = to_int(row[2]);
            std::string en = e && expression_dict().count(*e) ? expression_dict().at(*e) : pys(row[2]);
            desc = npc_txt + " 设置表情 " + en;
        } else if (*cmd == 3006) {
            auto c = to_int(row[2]);
            std::string cname = (c && *c == 0) ? "常服" : (c && *c == 1) ? "校服" : pys(row[2]);
            desc = npc_txt + " 设置服饰 " + cname;
        } else if (*cmd == 3001 || *cmd == 3002) {
            desc = npc_txt + " " + name + " (" + pys(row[2]) + ")";
        } else if (*cmd == 3004 || *cmd == 3008) {
            desc = npc_txt + " " + name + " " + pys(row[2]) + " 像素";
        } else if (*cmd == 3009) {
            desc = npc_txt + " 设置Emoji " + pys(row[2]);
        }
    }
    out["desc"] = desc;
    json earr = json::array();
    for (auto& s : errs) earr.push_back(s);
    out["errors"] = earr;
    return out;
}

// ---------------------------------------------------------------------------
// validate_record
// ---------------------------------------------------------------------------
json validate_record(const std::string& cfg_name_in, const std::string& rid, const json& record) {
    json out = json::array();
    if (!record.is_object()) return out;
    std::string cfg = norm_cfg_name(cfg_name_in);
    auto push = [&](const char* l, const std::string& m) { out.push_back(issue(l, m)); };

    if (cfg == "EvtCfg") {
        auto eid = to_int(record.contains("id") ? record.at("id") : json());
        if (!eid) {
            push("warn", rid + ": 事件缺少数字 ID（指南要求事件ID为7位数 1XXXXXX）");
        } else {
            std::string msg = check_event_id(json(*eid));
            if (!msg.empty()) push("error", rid + ".id: " + msg);
            auto kid = to_int(json(rid));
            if (kid && *kid != *eid)
                push("warn", rid + ": 记录键名与 id 字段（" + std::to_string(*eid) + "）不一致，游戏按 id 读取");
        }
        if (record.contains("rate")) {
            auto fv = to_float(record.at("rate"));
            if (fv && *fv != 0.0 && (*fv < 0 || *fv > 1))
                // Python 打的是 float 值（"%s" % fv，如 "2"→"2.0"），不是原始单元格。
                push("warn", rid + ".rate: 发生概率 " + pys(json(*fv)) +
                                 " 超出 0~1（指南：1 为 100% 发生，0 为绝对不发生）");
        }
        auto type = to_int(record.contains("type") ? record.at("type") : json());
        auto npc = to_int(record.contains("npc") ? record.at("npc") : json());
        if (type && *type == 2 && !(npc && *npc != 0))  // Python not int(npc)：0 也算未指定
            push("warn", rid + ".npc: 社交触发事件（类型2）应指定人物ID，否则无法在对应人物身上发生剧情");
        if (!record.contains("talkId") || !record.at("talkId").is_array() || record.at("talkId").empty()) {
            push("warn", rid + ".talkId: 事件缺少首句对话ID，游戏内将无法预览剧情");
        } else {
            json eidj = eid ? json(*eid) : json();
            for (const auto& t : record.at("talkId")) {
                std::string msg = check_dialog_id(t, eid ? &eidj : nullptr);
                if (!msg.empty()) push("error", rid + ".talkId: " + msg);
            }
        }
    } else if (cfg == "TalkCfg") {
        json tidj = record.contains("id") ? record.at("id") : json();
        std::string msg = check_dialog_id(tidj, nullptr);
        if (tidj.is_null())
            push("warn", rid + ": 对话缺少数字 ID（指南要求对话ID为10位数，后3位为001~999）");
        else if (!msg.empty())
            push("error", rid + ".id: " + msg);
        if (record.contains("screenEffect") && record.at("screenEffect").is_array() &&
            !record.at("screenEffect").empty()) {
            auto r = describe_screen_row(record.at("screenEffect"));
            for (auto& e : r.at("errors")) push("warn", rid + ".screenEffect: " + e.get<std::string>());
        }
        if (record.contains("roles") && record.at("roles").is_array()) {
            const json& roles = record.at("roles");
            for (size_t i = 0; i < roles.size(); ++i) {
                if (!roles[i].is_array()) {
                    push("warn", rid + ".roles[" + std::to_string(i) +
                                     "]: 应为数组 [人物ID, 指令, 参数...]");
                    continue;
                }
                auto r = describe_action_row(roles[i]);
                for (auto& e : r.at("errors"))
                    push("warn", rid + ".roles[" + std::to_string(i) + "]: " + e.get<std::string>());
            }
        }
        if (record.contains("highlights") && record.at("highlights").is_array())
            for (auto& h : record.at("highlights"))
                if (role_name(h).empty())
                    push("warn", rid + ".highlights: 人物ID " + pys(h) + " 不在人物字典中");
        if (record.contains("bg")) {
            auto bi = to_int(record.at("bg"));
            if (!bi)
                push("warn", rid + ".bg: 背景ID应为数字（0=保留原背景，-1/-2=切换）");
            else if (*bi != 0 && *bi != -1 && *bi != -2 && bg_name(json(*bi)).empty())
                push("warn", rid + ".bg: 背景图ID " + std::to_string(*bi) +
                                 " 不在背景字典中（0=保留原背景，-1/-2=切换）");
        }
    } else if (cfg == "OptionCfg") {
        auto oid = to_int(record.contains("id") ? record.at("id") : json());
        if (!oid) {
            push("warn", rid + ": 选项缺少数字 ID（指南要求选项ID为9位数）");
        } else {
            std::string msg = check_option_id(json(*oid), nullptr);
            if (!msg.empty()) push("error", rid + ".id: " + msg);
            auto kid = to_int(json(rid));
            if (kid && *kid != *oid)
                push("warn", rid + ": 记录键名与 id 字段（" + std::to_string(*oid) + "）不一致");
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// validate_cross
// ---------------------------------------------------------------------------
static std::set<long long> id_set(const json& tables, const std::string& cfg, const json& base_ids) {
    std::set<long long> ids;
    json data = tables.contains(cfg) ? tables.at(cfg) : json();
    if (data.is_object()) {
        for (auto it = data.begin(); it != data.end(); ++it) {
            auto n = to_int(json(it.key()));
            if (!n && it.value().is_object() && it.value().contains("id")) n = to_int(it.value().at("id"));
            if (n) ids.insert(*n);
        }
    }
    if (base_ids.is_object() && base_ids.contains(cfg) && base_ids.at(cfg).is_array())
        for (auto& b : base_ids.at(cfg)) {
            auto n = to_int(b);
            if (n) ids.insert(*n);
        }
    return ids;
}
// guide_rules._ref_entries: 1D field (int/str/list) -> iterable of nonzero ints.
static std::vector<long long> ref_entries(const json& value) {
    std::vector<long long> out;
    if (value.is_null()) return out;
    if (value.is_number_integer() || value.is_string() || value.is_number_unsigned()) {
        auto n = to_int(value);
        if (n) out.push_back(*n);
        return out;
    }
    if (value.is_array()) {
        for (auto& x : value) {
            auto n = to_int(x);
            if (n && *n != 0) out.push_back(*n);
        }
    }
    return out;
}

json validate_cross(const json& tables, const json& base_ids) {
    json out = json::array();
    auto push = [&](const char* l, const std::string& m) { out.push_back(issue(l, m)); };
    auto evt_ids = id_set(tables, "EvtCfg", base_ids);
    auto talk_ids = id_set(tables, "TalkCfg", base_ids);
    auto opt_ids = id_set(tables, "OptionCfg", base_ids);

    json evt_data = tables.contains("EvtCfg") ? tables.at("EvtCfg") : json();
    if (evt_data.is_object()) {
        for (auto it = evt_data.begin(); it != evt_data.end(); ++it) {
            if (!it.value().is_object()) continue;
            auto eid = to_int(it.value().contains("id") ? it.value().at("id") : json());
            if (eid && base_ids.is_object() && base_ids.contains("EvtCfg") && base_ids.at("EvtCfg").is_array()) {
                for (auto& b : base_ids.at("EvtCfg")) {
                    auto bn = to_int(b);
                    if (bn && *bn == *eid) {
                        push("info", "事件 " + it.key() + ": 事件ID " + std::to_string(*eid) +
                                          " 与原版事件相同，实机加载时将覆盖原版事件");
                        break;
                    }
                }
            }
            for (auto& t : ref_entries(it.value().contains("talkId") ? it.value().at("talkId") : json()))
                if (!talk_ids.count(t))
                    push("error", "事件 " + it.key() + ": 首句对话ID " + std::to_string(t) +
                                      " 在本Mod与原版中均不存在，无法预览剧情");
            for (auto& o : ref_entries(it.value().contains("options") ? it.value().at("options") : json()))
                if (!opt_ids.count(o))
                    push("warn", "事件 " + it.key() + ": 引用的选项ID " + std::to_string(o) +
                                     " 不存在（本Mod与原版均未找到）");
        }
    }
    json talk_data = tables.contains("TalkCfg") ? tables.at("TalkCfg") : json();
    if (talk_data.is_object()) {
        for (auto it = talk_data.begin(); it != talk_data.end(); ++it) {
            if (!it.value().is_object()) continue;
            auto tid = to_int(it.value().contains("id") ? it.value().at("id") : json());
            if (tid) {
                std::string s = std::to_string(*tid);
                if (s.size() >= 7) {
                    std::string prefix = s.substr(0, 7);
                    long long pv = std::stoll(prefix);
                    if (!evt_ids.count(pv))
                        push("warn", "对话 " + it.key() + ": 对话ID " + s + " 的前7位（" + prefix +
                                         "）不对应任何事件ID");
                }
            }
            // Python: _ref_entries(nextTalk) + _ref_entries(nextTalk2) — 先 nextTalk 后 nextTalk2
            auto nt = ref_entries(it.value().contains("nextTalk") ? it.value().at("nextTalk") : json());
            auto nt2 = ref_entries(it.value().contains("nextTalk2") ? it.value().at("nextTalk2") : json());
            for (auto& x : nt2) nt.push_back(x);
            for (auto& x : nt)
                if (!talk_ids.count(x))
                    push("warn", "对话 " + it.key() + ": 下一句对话ID " + std::to_string(x) +
                                     " 不存在（本Mod与原版均未找到）");
            for (auto& o : ref_entries(it.value().contains("option") ? it.value().at("option") : json()))
                if (!opt_ids.count(o))
                    push("warn", "对话 " + it.key() + ": 引用的选项ID " + std::to_string(o) +
                                     " 不存在（本Mod与原版均未找到）");
        }
    }
    json opt_data = tables.contains("OptionCfg") ? tables.at("OptionCfg") : json();
    if (opt_data.is_object()) {
        for (auto it = opt_data.begin(); it != opt_data.end(); ++it) {
            if (!it.value().is_object()) continue;
            auto oid = to_int(it.value().contains("id") ? it.value().at("id") : json());
            if (oid) {
                std::string s = std::to_string(*oid);
                if (s.size() >= 7) {
                    std::string prefix = s.substr(0, 7);
                    long long pv = std::stoll(prefix);
                    if (!evt_ids.count(pv))
                        push("warn", "选项 " + it.key() + ": 选项ID " + s + " 的前7位（" + prefix +
                                         "）不对应任何事件ID");
                }
            }
            auto tt = ref_entries(it.value().contains("talkId") ? it.value().at("talkId") : json());
            auto tt2 = ref_entries(it.value().contains("talkId2") ? it.value().at("talkId2") : json());
            for (auto& x : tt2) tt.push_back(x);
            for (auto& x : tt)
                if (!talk_ids.count(x))
                    push("warn", "选项 " + it.key() + ": 跳转对话ID " + std::to_string(x) +
                                     " 不存在（本Mod与原版均未找到）");
            auto ne = to_int(it.value().contains("nextEvtId") ? it.value().at("nextEvtId") : json());
            if (ne && *ne != 0 && !evt_ids.count(*ne))
                push("warn", "选项 " + it.key() + ": 下一事件ID " + std::to_string(*ne) +
                                 " 不存在（本Mod与原版均未找到）");
        }
    }

    for (auto& it : check_refs(tables, base_ids)) {
        push("warn", it.value("cfg", "") + " " + it.value("rid", "") + ": " + it.value("desc", ""));
    }
    return out;
}

// ---------------------------------------------------------------------------
// ref_rules.check_refs
// ---------------------------------------------------------------------------
json check_refs(const json& tables, const json& extra_ids) {
    json out = json::array();
    static const json kRules = json::parse(R"JSON([
      {"cfg":"EvtCfg","field":"npc","target":"PersonCfg"},
      {"cfg":"EvtCfg","field":"mapId","target":"MapCfg"},
      {"cfg":"EvtCfg","field":"miniGame","target":"MinigameCfg","array":true},
      {"cfg":"TalkCfg","field":"audio","target":"AudioCfg"},
      {"cfg":"TalkCfg","field":"roleIds","target":"PersonCfg","array":true},
      {"cfg":"TalkCfg","field":"miniGame","target":"MinigameCfg","array":true},
      {"cfg":"ActionCfg","field":"evtId","target":"EvtCfg"},
      {"cfg":"ActionCfg","field":"map","target":"MapCfg"},
      {"cfg":"ActionCfg","field":"audio","target":"AudioCfg"},
      {"cfg":"ActionCfg","field":"bg","target":"BgCfg"},
      {"cfg":"ActionCfg","field":"next","target":"ActionCfg"},
      {"cfg":"ActionEvtCfg","field":"evts","target":"EvtCfg","array":true},
      {"cfg":"ItemCfg","field":"talkId","target":"TalkCfg"},
      {"cfg":"GiftEvtCfg","field":"item","target":"ItemCfg"},
      {"cfg":"GiftEvtCfg","field":"npc","target":"PersonCfg","array":true},
      {"cfg":"GiftEvtCfg","field":"talkId","target":"TalkCfg","array":true},
      {"cfg":"InteractCfg","field":"npc","target":"PersonCfg"},
      {"cfg":"InteractCfg","field":"map","target":"MapCfg","array":true},
      {"cfg":"InteractCfg","field":"talkId","target":"TalkCfg"},
      {"cfg":"LoveDrawCfg","field":"talkId","target":"TalkCfg","array":true},
      {"cfg":"LoveGreetingCfg","field":"talkId","target":"TalkCfg"},
      {"cfg":"TripSpotCfg","field":"evtId","target":"EvtCfg"},
      {"cfg":"ExpoEvtCfg","field":"evtId","target":"EvtCfg"},
      {"cfg":"AnimeConCfg","field":"evtId","target":"EvtCfg"},
      {"cfg":"NegotiationPlayerCfg","field":"npcId","target":"PersonCfg"},
      {"cfg":"RenshengguanMemoryCfg","field":"npcId","target":"PersonCfg","array":true},
      {"cfg":"NpcActivityCfg","field":"map","target":"MapCfg"},
      {"cfg":"NpcActivityCfg","field":"npc","target":"PersonCfg"},
      {"cfg":"NpcActivityCfg","field":"talkId","target":"TalkCfg","array":true},
      {"cfg":"TalkInputMinigameCfg","field":"talkId","target":"TalkCfg","array":true},
      {"cfg":"MapCfg","field":"bg","target":"BgCfg"},
      {"cfg":"BgCfg","field":"audio","target":"AudioCfg"},
      {"cfg":"MovieCfg","field":"talks","target":"TalkCfg","array":true},
      {"cfg":"NegotiationCfg","field":"talks","target":"TalkCfg","array":true}
    ])JSON");

    std::map<std::string, std::set<std::string>> table_ids_cache;
    for (const auto& rule : kRules) {
        std::string cfg = rule.value("cfg", ""), target = rule.value("target", "");
        json data = tables.contains(cfg) ? tables.at(cfg) : json();
        if (!data.is_object()) continue;
        const auto* pool = ref_pool_for_target(target);
        json extra = (extra_ids.is_object() && extra_ids.contains(target)) ? extra_ids.at(target) : json();
        if (!table_ids_cache.count(target)) {
            json target_data = tables.contains(target) ? tables.at(target) : json();
            table_ids_cache[target] = table_id_strs(
                target_data.is_object() ? &target_data : nullptr, extra.is_array() ? &extra : nullptr);
        }
        const std::set<std::string>& table_ids = table_ids_cache[target];
        std::set<std::string> valid = exempt();
        if (pool) for (auto& kv : *pool) valid.insert(kv.first);
        bool has_extra = extra.is_array() && !extra.empty();
        if (!table_ids.empty()) valid.insert(table_ids.begin(), table_ids.end());
        else if (pool == nullptr && !has_extra) continue;  // cannot judge -> skip

        bool is_arr = rule.value("array", false);
        std::string field = rule.value("field", "");
        for (auto it = data.begin(); it != data.end(); ++it) {
            if (!it.value().is_object()) continue;
            if (!it.value().contains(field)) continue;
            const json& raw = it.value().at(field);
            if (raw.is_null()) continue;
            if (raw.is_string() && raw.get<std::string>().empty()) continue;
            std::vector<long long> vals;
            norm_ids_walk(raw, vals);
            if (vals.empty()) continue;
            std::vector<long long> bad, healed;
            for (auto v : vals) {
                if (valid.count(std::to_string(v))) healed.push_back(v);
                else bad.push_back(v);
            }
            if (bad.empty()) continue;
            std::string bad_joined;
            for (size_t i = 0; i < bad.size(); ++i) { if (i) bad_joined += "、"; bad_joined += std::to_string(bad[i]); }
            json it_obj;
            it_obj["cfg"] = cfg;
            it_obj["rid"] = it.key();
            it_obj["field"] = field;
            it_obj["value"] = raw;
            it_obj["target"] = target;
            it_obj["array"] = is_arr;
            if (is_arr) {
                json h = json::array();
                for (auto v : healed) h.push_back(v);
                it_obj["healed"] = h;
            } else {
                it_obj["healed"] = nullptr;
            }
            it_obj["desc"] = std::string("字段'") + field +
                             "'引用了不存在的" + target + " id " + bad_joined;
            out.push_back(it_obj);
        }
    }
    return out;
}

}  // namespace p1
}  // namespace sa
