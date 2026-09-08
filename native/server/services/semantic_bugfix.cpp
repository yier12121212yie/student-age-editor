// wip/P1/semantic_bugfix.cpp — port of bugfix_service.py (scan/apply) plus the
// format_to_display / parse_from_display round-trip helpers it leans on.
#include "semantic_logic.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
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

bool digit(const std::string& s) {
    if (s.empty()) return false;
    for (char c : s) if (c < '0' || c > '9') return false;
    return true;
}
std::string lstrip(const std::string& s) {
    size_t i = 0;
    while (i < s.size() && s[i] == '-') ++i;
    return s.substr(i);
}

std::string field_type(const std::string& key, const std::string& cfg) {
    const json& gs = game_schema();
    if (gs.contains(cfg) && gs[cfg].is_object() && gs[cfg].contains(key))
        return gs[cfg][key].get<std::string>();
    return "";
}

// Python bool(v): non-empty container / nonzero number / non-empty string is true.
bool py_truthy(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get<std::string>().empty();
    if (v.is_array() || v.is_object()) return !v.empty();
    return true;
}

void extract_1d(const json& arr, json& out) {    for (const auto& item : arr) {
        if (!item.is_array()) continue;
        bool flat = !item.empty();
        for (const auto& x : item)
            if (x.is_array()) { flat = false; break; }
        if (flat) out.push_back(item);
        else extract_1d(item, out);
    }
}

bool check_overflow(const json& v) {
    if (v.is_number_integer() && !v.is_boolean()) {
        long long n = v.get<long long>();
        return n > 2147483647LL || n < -2147483648LL;
    }
    if (v.is_array()) {
        for (const auto& x : v) if (check_overflow(x)) return true;
    }
    return false;
}

std::vector<std::string> split_commas_strip(const std::string& text) {
    std::vector<std::string> out;
    size_t pos = 0;
    while (true) {
        size_t c = text.find(',', pos);
        std::string piece = str::trim(text.substr(pos, c == std::string::npos ? std::string::npos : c - pos));
        if (!piece.empty()) out.push_back(piece);
        if (c == std::string::npos) break;
        pos = c + 1;
    }
    return out;
}

void flatten_to_2d(const json& raw, json& out) {
    for (const auto& item : raw) {
        if (item.is_array()) {
            bool any_nested = false;
            for (const auto& x : item) if (x.is_array()) { any_nested = true; break; }
            if (any_nested) flatten_to_2d(item, out);
            else if (!item.empty()) out.push_back(item);
        } else {
            json one = json::array();
            one.push_back(item);
            out.push_back(one);
        }
    }
}

bool list_contains_1(const json& opts) {
    if (!opts.is_array()) return false;
    for (const auto& o : opts) {
        if (o == json(1) || o == json("1")) return true;
        if (o.is_array() && o.size() == 1 && (o[0] == json(1) || o[0] == json("1"))) return true;
    }
    return false;
}

json option_values(const json& talk) {
    json val = talk.is_object() && talk.contains("option") ? talk.at("option") : json();
    if (val.is_array()) return val;
    if (val.is_null() || val.is_object()) return json::array();
    json a = json::array();
    a.push_back(val);
    return a;
}

std::optional<long long> try_int(const std::string& id) {
    try { return std::stoll(str::trim(id)); } catch (...) { return std::nullopt; }
}
std::string int_key_str(const std::string& id) {
    auto n = try_int(id);
    return n ? std::to_string(*n) : std::string();
}
// _row_key: try _id, int(_id), str(int(_id)) — first present key in bucket.
std::string row_key(const json& bucket, const std::string& id) {
    if (!bucket.is_object()) return std::string();
    for (const std::string& cand : {id, int_key_str(id)}) {
        if (!cand.empty() && bucket.contains(cand)) return cand;
        if (cand == id) continue;  // numeric form already tried via str
    }
    // Python also tests the raw int object against a str-keyed dict (always miss);
    // str(int) is the only form that can match, so the two candidates above cover it.
    return std::string();
}

int next_option_suffix(const json& opt_cfg, const std::string& evt_id) {
    long long maxv = 0;
    bool any = false;
    for (auto it = opt_cfg.begin(); it != opt_cfg.end(); ++it) {
        if (it.key().rfind(evt_id, 0) != 0) continue;
        std::string tail = it.key().substr(evt_id.size());
        if (!tail.empty() && digit(tail)) {
            // Python 任意精度：超长位数必然 >99，直接顶爆让调用方放弃（B9）。
            long long v = tail.size() > 18 ? 1000 : std::stoll(tail);
            if (!any || v > maxv) maxv = v;
            any = true;
        }
    }
    return any ? static_cast<int>(maxv > 99 ? 1000 : maxv + 1) : 1;
}

json safe_array_value(const json& value, const std::string& cfg, const std::string& id,
                      const std::string& key, json& bugs,
                      std::set<std::string>& array_shape_seen) {
    if (value.is_array()) return value;
    if (value.is_null() || value.is_object()) {
        std::string bk = cfg + "\x1f" + id + "\x1f" + key;
        if (array_shape_seen.count(bk)) return json::array();
        array_shape_seen.insert(bk);
        std::string bad = value.is_null() ? "null" : "object";
        json b;
        b["cfg"] = cfg; b["id"] = id; b["key"] = key; b["val"] = value; b["healed"] = json::array();
        b["desc"] = std::string("Field '") + key + "' should be an array [], but is " + bad + ".";
        b["flag"] = "SCHEMA_HEAL";
        bugs.push_back(b);
        return json::array();
    }
    json a = json::array();
    a.push_back(value);
    return a;
}

void add_logic_bug(json& bugs, const std::string& cfg, const std::string& id,
                   const std::string& bug_level, const std::string& detail) {
    json b;
    b["cfg"] = cfg; b["id"] = id; b["key"] = bug_level; b["val"] = detail; b["healed"] = nullptr;
    b["desc"] = detail; b["flag"] = "LOGIC";
    bugs.push_back(b);
}
void add_heal_bug(json& bugs, const std::string& cfg, const std::string& id, const std::string& key,
                  const json& original, const json& healed, const std::string& desc,
                  const std::string& flag) {
    json b;
    b["cfg"] = cfg; b["id"] = id; b["key"] = key; b["val"] = original; b["healed"] = healed;
    b["desc"] = desc; b["flag"] = flag;
    bugs.push_back(b);
}

AvailableMap build_available(const json& m, const json& b) {
    AvailableMap av;
    auto seed = [&](const std::string& key) -> std::map<std::string, std::string>& {
        auto& mp = av[key];
        for (const auto& kv : pool_by_key(key)) mp[kv.first] = kv.second;
        return mp;
    };
    seed("ATTR");
    auto merge_table = [&](const std::string& pool, const std::string& table) {
        auto& mp = av[pool];
        for (const json* src : {&m, &b})
            if (src->contains(table) && (*src)[table].is_object())
                for (auto it = (*src)[table].begin(); it != (*src)[table].end(); ++it)
                    mp.try_emplace(it.key(), "");
    };
    // ROLE/RELATION/ITEM/MAP/JOB/etc. seeded from their dicts, then table keys.
    seed("ROLE"); merge_table("ROLE", "PersonCfg");
    seed("JOB"); merge_table("JOB", "JobCfg");
    seed("RELATION"); merge_table("RELATION", "RelationCfg");
    seed("ITEM"); merge_table("ITEM", "ItemCfg");
    seed("MAP"); merge_table("MAP", "MapCfg"); merge_table("MAP", "BgCfg");
    seed("STATE"); merge_table("STATE", "PersonStateCfg");
    seed("TEXT"); merge_table("TEXT", "TextCfg");
    seed("NEGOTIATION_SKILL"); merge_table("NEGOTIATION_SKILL", "NegotiationSkillCfg");
    seed("NEGOTIATION_BUFF"); merge_table("NEGOTIATION_BUFF", "NegotiationBuffCfg");
    seed("GAME"); merge_table("GAME", "GameCfg");
    seed("KZONE_POST"); merge_table("KZONE_POST", "KZoneContentCfg"); merge_table("KZONE_POST", "AnimeKzoneContentCfg");
    seed("KZONE_MESSAGE"); merge_table("KZONE_MESSAGE", "KZoneMessageBoardCfg");
    seed("PHONE_MSG"); merge_table("PHONE_MSG", "PhoneMsgCfg");
    return av;
}

}  // namespace

std::string format_to_display(const json& val, const std::string& key, const std::string& cfg_name) {
    if (val.is_null()) return "";
    std::string ft = field_type(key, cfg_name);
    if (ft == "String" || ft == "Number") return pys(val);
    if (ft == "2D Array" && val.is_array()) {
        json flat = json::array();
        extract_1d(val, flat);
        if (flat.empty()) return "";
        std::string out;
        for (size_t i = 0; i < flat.size(); ++i) {
            if (i) out += ", ";
            out += sa_core::py_dumps(flat[i]);
        }
        return out;
    }
    if (val.is_array() && val.size() == 1 && val[0].is_string()) return val[0].get<std::string>();
    std::string s = sa_core::py_dumps(val);
    if (!s.empty() && s.front() == '[' && s.back() == ']') {
        std::string inner = s.substr(1, s.size() - 2);
        return str::trim(inner);
    }
    return s;
}

json parse_from_display(const std::string& text_in, const std::string& key, const json& original,
                        const std::string& cfg_name) {
    std::string text = str::trim(text_in);
    while (!text.empty() && (text.back() == ',' || text.back() == ';' || text.back() == ' ')) text.pop_back();
    if (str::lower(text) == "null" || text == "missing_key") text.clear();
    std::string ft = field_type(key, cfg_name);
    if (ft == "String") {
        if (text.empty()) return original.is_string() && original.get<std::string>().empty() ? json("") : json();
        return json(text);
    }
    if (text.empty()) {
        if (ft == "2D Array" || ft == "1D Array") return json::array();
        if (ft == "Number") return json(0);
        return original.is_null() ? json("") : original;
    }
    json res;
    res = json::parse(text, nullptr, false);
    if (res.is_discarded()) {
        res = json::parse("[" + text + "]", nullptr, false);
        if (res.is_discarded()) res = json::array();
    }
    if (!res.is_array()) { json a = json::array(); a.push_back(res); res = a; }

    // Python int(v) 语义：bool→0/1、int 原样、float 向零截断、纯整数串（含前导
    // 负号/两侧空白）、其余抛错回 0。to_int_loose 会多收 "12.0"，不可用。
    auto py_int_cast = [](const json& v) -> std::optional<long long> {
        if (v.is_boolean()) return v.get<bool>() ? 1 : 0;
        if (v.is_number_integer()) return v.get<long long>();
        if (v.is_number_unsigned()) return static_cast<long long>(v.get<unsigned long long>());
        if (v.is_number_float()) return static_cast<long long>(std::trunc(v.get<double>()));
        if (v.is_string()) {
            std::string s = str::trim(v.get<std::string>());
            size_t i = (!s.empty() && (s[0] == '-' || s[0] == '+')) ? 1 : 0;
            if (i < s.size()) {
                bool all_digit = true;
                for (size_t j = i; j < s.size(); ++j)
                    if (s[j] < '0' || s[j] > '9') { all_digit = false; break; }
                if (all_digit) { try { return std::stoll(s); } catch (...) { return std::nullopt; } }
            }
        }
        return std::nullopt;
    };
    if (!original.is_null() && ft != "1D Array" && ft != "2D Array" && ft != "Number") {
        if (original.is_number_integer() && !original.is_boolean()) {
            json v = res.empty() ? json() : res[0];
            if (v.is_array() && !v.empty()) v = v[0];
            auto n = py_int_cast(v);
            return n ? json(*n) : json(0);
        }
        if (original.is_array()) {
            json out = json::array();
            if (!original.empty() && original[0].is_array()) {
                for (auto& item : res) {
                    if (item.is_array()) out.push_back(item);
                    else { json o = json::array(); o.push_back(item); out.push_back(o); }
                }
                return out;
            }
            for (auto& item : res) {
                if (item.is_array()) for (auto& x : item) out.push_back(x);
                else out.push_back(item);
            }
            return out;
        }
    }
    if (ft == "1D Array") {
        bool is_path_style = original.is_null() ||
                             (original.is_array() && std::all_of(original.begin(), original.end(),
                                                                  [](const json& x) { return x.is_string(); }));
        if (res.empty() && is_path_style) {
            json a = json::array();
            for (auto& p : split_commas_strip(text)) a.push_back(p);
            return a;
        }
        json flat = json::array();
        for (auto& item : res) {
            if (item.is_array()) for (auto& x : item) flat.push_back(x);
            else flat.push_back(item);
        }
        return flat;
    }
    if (ft == "2D Array") {
        if (!res.empty()) {
            bool all_nonlist = std::all_of(res.begin(), res.end(), [](const json& x) { return !x.is_array(); });
            if (all_nonlist) { json a = json::array(); a.push_back(res); return a; }
        }
        json out = json::array();
        flatten_to_2d(res, out);
        return out;
    }
    if (ft == "Number") {
        if (!res.empty()) {
            json v = res[0];
            if (v.is_array() && !v.empty()) v = v[0];
            if (v.is_number()) return v;
            if (v.is_string() && digit(lstrip(v.get<std::string>()))) {
                auto n = to_int_loose(v);
                if (n) return json(*n);
            }
            auto f = to_float(v);
            if (f) return json(*f);
        }
        return json(0);
    }
    return res.empty() ? json(0) : res[0];
}

json scan_bugs(const json& mod_data, const json& base_data, const std::set<std::string>* only_tables,
               bool read_only_view) {
    json bugs = json::array();
    if (game_schema().empty()) {
        json b;
        b["cfg"] = ""; b["id"] = ""; b["key"] = ""; b["val"] = nullptr; b["healed"] = nullptr;
        b["desc"] = "未能加载 game_schema.py，无法进行深入扫描！"; b["flag"] = "ERROR";
        bugs.push_back(b);
        return bugs;
    }
    const json& m = mod_data;
    json b = base_data.is_object() ? base_data : json::object();
    std::set<std::string> array_shape_seen;
    auto skip = [&](const std::string& cfg) { return only_tables && !only_tables->count(cfg); };

    auto keys_of = [](const json& src, const std::string& cfg) {
        std::set<std::string> out;
        if (src.contains(cfg) && src[cfg].is_object())
            for (auto it = src[cfg].begin(); it != src[cfg].end(); ++it) out.insert(it.key());
        return out;
    };
    std::set<std::string> all_talks = keys_of(m, "TalkCfg"), all_options = keys_of(m, "OptionCfg");
    for (auto& k : keys_of(b, "TalkCfg")) all_talks.insert(k);
    for (auto& k : keys_of(b, "OptionCfg")) all_options.insert(k);

    AvailableMap av = build_available(m, b);
    auto pool_keys = [&](const std::string& name) {
        std::set<std::string> s;
        for (auto& kv : av[name]) s.insert(kv.first);
        return s;
    };
    std::set<std::string> valid_roles = pool_keys("ROLE"), valid_maps = pool_keys("MAP"),
                         valid_items = pool_keys("ITEM"), valid_states = pool_keys("STATE");

    auto is_in = [&](const std::set<std::string>& s, const std::string& v) { return s.count(v); };

    // S1+S2：Python 里 `isinstance(cfg_dict, dict)` 门——只读代理输入整段空转。
    for (auto it = read_only_view ? m.end() : m.begin(); it != m.end(); ++it) {
        const std::string& cfg = it.key();
        if (!it.value().is_object() || skip(cfg)) continue;
        for (auto ri = it.value().begin(); ri != it.value().end(); ++ri) {
            if (!ri.value().is_object()) continue;
            std::string id = ri.key();
            for (const char* key : {"talkId", "talkId2", "nextTalk", "nextTalk2"}) {
                if (!ri.value().contains(key)) continue;
                json tids = safe_array_value(ri.value()[key], cfg, id, key, bugs, array_shape_seen);
                for (auto& tid : tids) {
                    std::string ts = pys(tid);
                    std::string cleaned;
                    for (char c : ts) if (c != '[' && c != ']') cleaned += c;
                    cleaned = str::trim(cleaned);
                    if (!cleaned.empty() && cleaned != "0" && digit(lstrip(cleaned)) && !is_in(all_talks, cleaned))
                        add_logic_bug(bugs, cfg, id, "致命断层", std::string("[") + key + "] 指向了不存在的对话节点: " + cleaned);
                }
            }
            for (const char* ak : {"cond", "effect", "effect2", "precondition", "condition", "stateCond"}) {
                if (!ri.value().contains(ak)) continue;
                json arr2d = ri.value()[ak];
                if (arr2d.is_null() || arr2d.is_object()) {
                    safe_array_value(arr2d, cfg, id, ak, bugs, array_shape_seen);
                    continue;
                }
                if (arr2d.is_array() && !arr2d.empty() && !arr2d[0].is_array()) {
                    if (digit(lstrip(pys(arr2d[0])))) {
                        json wrapped = json::array();
                        wrapped.push_back(arr2d);
                        add_heal_bug(bugs, cfg, id, ak, arr2d, wrapped,
                                     "💥降维异常：缺少外层方括号，引擎必须要求二维数组格式！", "SCHEMA_HEAL");
                        arr2d = wrapped;
                    }
                }
                if (!arr2d.is_array()) continue;
                const SecondaryIndex& sidx = (std::string(ak) == "effect" || std::string(ak) == "effect2")
                                                 ? effect_secondary_index()
                                                 : condition_secondary_index();
                for (auto& sub : arr2d) {
                    if (!sub.is_array() || sub.empty()) continue;
                    auto result = validate_secondary_item(sub, sidx, av);
                    for (auto& er : result.at("errors"))
                        add_logic_bug(bugs, cfg, id, "严重越界",
                                      std::string("[") + ak + "] " + er.get<std::string>());
                }
            }
        }
    }

    // 3. special talk validation
    // Python talk.get("option", []) / get("roles", []) —— 缺键是 [] 合法值，不得当 null 报 bug
    if (!skip("TalkCfg") && m.contains("TalkCfg") && m["TalkCfg"].is_object())
        for (auto it = m["TalkCfg"].begin(); it != m["TalkCfg"].end(); ++it) {
            if (!it.value().is_object()) continue;
            json opts = safe_array_value(it.value().contains("option") ? it.value()["option"]
                                                                       : json::array(),
                                         "TalkCfg", it.key(), "option", bugs, array_shape_seen);
            for (auto& opt : opts) {
                std::string os = pys(opt);
                std::string cleaned;
                for (char c : os) if (c != '[' && c != ']') cleaned += c;
                cleaned = str::trim(cleaned);
                if (!cleaned.empty() && cleaned != "0" && digit(lstrip(cleaned)) && !is_in(all_options, cleaned))
                    add_logic_bug(bugs, "TalkCfg", it.key(), "致命断层", "选项数组包含不存在的 OptionCfg ID: " + cleaned);
            }
            json roles = safe_array_value(it.value().contains("roles") ? it.value()["roles"]
                                                                       : json::array(),
                                          "TalkCfg", it.key(), "roles", bugs, array_shape_seen);
            for (auto& r : roles) {
                if (!r.is_array() || r.empty()) continue;
                std::string role_id = pys(r[0]);
                std::string cleaned;
                for (char c : role_id) if (c != '[' && c != ']') cleaned += c;
                cleaned = str::trim(cleaned);
                if (!cleaned.empty() && cleaned != "0" && cleaned != "-1" && digit(lstrip(cleaned)) &&
                    !is_in(valid_roles, cleaned))
                    add_logic_bug(bugs, "TalkCfg", it.key(), "角色异常", "发言人指向了不存在的人物ID: " + cleaned);
            }
        }

    // 4. format & spec
    if (!skip("OptionCfg") && m.contains("OptionCfg") && m["OptionCfg"].is_object() &&
        (m["OptionCfg"].contains("1")))
        add_heal_bug(bugs, "OptionCfg", "1", "id", json(1), nullptr,
                     "💥恶性异常：发现由官方编辑器引发的选项ID为1报错，会使游戏引擎字典冲突卡死！",
                     "FIX_OPTION_1");
    if (!skip("TalkCfg") && m.contains("TalkCfg") && m["TalkCfg"].is_object())
        for (auto it = m["TalkCfg"].begin(); it != m["TalkCfg"].end(); ++it) {
            if (!it.value().is_object()) continue;
            json opts = safe_array_value(it.value().contains("option") ? it.value()["option"]
                                                                       : json::array(),
                                         "TalkCfg", it.key(), "option", bugs, array_shape_seen);
            if (list_contains_1(opts))
                add_heal_bug(bugs, "TalkCfg", it.key(), "option", opts, nullptr,
                             "💥恶性异常：引用的对话选项ID为1，将导致游戏读取字典冲突卡死！", "FIX_TALK_1");
        }
    if (!skip("GiftEvtCfg") && m.contains("GiftEvtCfg") && m["GiftEvtCfg"].is_object())
        for (auto it = m["GiftEvtCfg"].begin(); it != m["GiftEvtCfg"].end(); ++it) {
            if (!it.value().is_object()) continue;
            if (it.value().contains("npcId"))
                add_heal_bug(bugs, "GiftEvtCfg", it.key(), "npcId", it.value()["npcId"], nullptr,
                             "旧版数据 'npcId' 需要升级为 'npc'", "RENAME_NPC");
            if (it.value().contains("condition"))
                add_heal_bug(bugs, "GiftEvtCfg", it.key(), "condition", it.value()["condition"], nullptr,
                             "旧版数据 'condition' 需要升级为 'cond'", "RENAME_COND");
        }

    // S4-format：同样的 `isinstance(cfg_data, dict)` 门（只读代理下整段空转）。
    const json& gs = game_schema();
    for (auto it = read_only_view ? m.end() : m.begin(); it != m.end(); ++it) {
        const std::string& cfg = it.key();
        if (!gs.contains(cfg) || !it.value().is_object() || skip(cfg)) continue;
        const json& rules = gs[cfg];
        for (auto ri = it.value().begin(); ri != it.value().end(); ++ri) {
            if (!ri.value().is_object()) continue;
            std::string id = ri.key();
            std::vector<std::string> field_names;
            for (auto f = ri.value().begin(); f != ri.value().end(); ++f) field_names.push_back(f.key());
            for (const std::string& key : field_names) {
                if (!rules.contains(key)) continue;
                json original = ri.value()[key];
                std::string ft = rules[key].get<std::string>();
                try {
                    if ((ft == "1D Array" || ft == "2D Array") && (original.is_null() || original.is_object())) {
                        safe_array_value(original, cfg, id, key, bugs, array_shape_seen);
                        continue;
                    }
                    std::string text = format_to_display(original, key, cfg);
                    json healed = parse_from_display(text, key, original, cfg);
                    if (check_overflow(healed) || check_overflow(original)) {
                        add_heal_bug(bugs, cfg, id, key, original, nullptr,
                                     "💥 数值过大！超过引擎极限 2147483647 将直接崩溃！", "ERROR");
                        continue;
                    }
                    if (pys(original) != pys(healed))
                        add_heal_bug(bugs, cfg, id, key, original, healed,
                                     "格式错乱或冗余。底层要求为 " + ft + " 格式。", "SCHEMA_HEAL");
                } catch (const std::exception& e) {
                    add_heal_bug(bugs, cfg, id, key, original, nullptr,
                                 std::string("引擎解析失败: ") + e.what(), "ERROR");
                }
            }
        }
    }

    // 5. cross-table reference integrity (ref_rules). base keys via lazy sets ->
    // build arrays of string keys per target table for check_refs.
    json extra_ids = json::object();
    for (auto it = b.begin(); it != b.end(); ++it) {
        json arr = json::array();
        if (it.value().is_object()) for (auto k = it.value().begin(); k != it.value().end(); ++k) arr.push_back(k.key());
        extra_ids[it.key()] = arr;
    }
    try {
        // S5：check_refs 的 `isinstance(data, dict)` 门在只读代理下全表空转
        // （实测 ref_rules.check_refs(MappingProxyType 包装) == []）→ 跳过整段。
        for (auto& ref : read_only_view ? json::array() : check_refs(m, extra_ids)) {
            if (skip(ref.value("cfg", ""))) continue;
            std::string desc = ref.value("desc", "");
            bool has_healed = ref.contains("healed") && !ref["healed"].is_null();
            if (has_healed)
                add_heal_bug(bugs, ref.value("cfg", ""), ref.value("rid", ""), ref.value("field", ""),
                             ref["value"], ref["healed"], desc + "（可一键修复：剔除悬挂引用）", "REF");
            else
                add_heal_bug(bugs, ref.value("cfg", ""), ref.value("rid", ""), ref.value("field", ""),
                             ref["value"], nullptr, desc, "REF");
        }
    } catch (const std::exception& e) {
        json errb;
        errb["cfg"] = ""; errb["id"] = ""; errb["key"] = ""; errb["val"] = nullptr; errb["healed"] = nullptr;
        errb["desc"] = std::string("引用完整性校验未完成（扫描器异常，非无问题）: ") + e.what();
        errb["flag"] = "ERROR";
        bugs.push_back(errb);
    }

    (void)valid_items; (void)valid_states;
    return bugs;
}

bool apply_fix(json& mod_data, const json& bug) {
    std::string cfg = bug.value("cfg", "");
    std::string id = pys(bug.contains("id") ? bug.at("id") : json());
    std::string key = bug.value("key", "");
    std::string flag = bug.value("flag", "");
    if (flag == "LOGIC" || flag == "ERROR") return false;

    json cfg_bucket = mod_data.contains(cfg) ? mod_data[cfg] : json::object();
    std::string rk = row_key(cfg_bucket, id);
    if (rk.empty() && flag != "FIX_OPTION_1" && flag != "FIX_TALK_1") return false;

    bool changed = false;
    if (flag == "FIX_OPTION_1" || flag == "FIX_TALK_1") {
        // Python: mod_data.get("TalkCfg", {}) —— 是活引用，重指 option 的写回必须落进
        // mod_data（路由对 FIX_* 恒先 fork TalkCfg/OptionCfg，键必在）。缺键时退化为
        // 局部空对象（Python 同样丢失写入）。
        json orphan_talk = json::object();
        json& talk_cfg =
            (mod_data.contains("TalkCfg") && mod_data["TalkCfg"].is_object())
                ? mod_data["TalkCfg"]
                : orphan_talk;
        json orphan_opt = json::object();
        json& opt_cfg =
            (mod_data.contains("OptionCfg") && mod_data["OptionCfg"].is_object())
                ? mod_data["OptionCfg"]
                : orphan_opt;
        std::string evt_id;
        for (auto it = talk_cfg.begin(); it != talk_cfg.end(); ++it) {
            if (list_contains_1(option_values(it.value()))) {
                std::string tid = it.key();
                evt_id = tid.size() > 3 ? tid.substr(0, tid.size() - 3) : tid;
                break;
            }
        }
        if (evt_id.empty()) return false;
        int suffix = next_option_suffix(opt_cfg, evt_id);
        if (suffix > 99) return false;  // B9
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%s%02d", evt_id.c_str(), suffix);
        long long new_opt_id = std::stoll(buf);

        std::string one_key = row_key(opt_cfg, "1");
        if (!one_key.empty()) {
            json opt_data = opt_cfg[one_key];
            opt_data["id"] = new_opt_id;
            opt_cfg.erase(one_key);
            opt_cfg[std::to_string(new_opt_id)] = opt_data;
            changed = true;
        }
        for (auto it = talk_cfg.begin(); it != talk_cfg.end(); ++it) {
            json opts = option_values(it.value());
            if (list_contains_1(opts)) {
                json newopt = json::array();
                for (auto& x : opts) {
                    std::string sx = pys(x);
                    std::string stripped;
                    for (char c : sx) if (c != '[' && c != ']') stripped += c;
                    stripped = str::trim(stripped);
                    if (stripped == "1") newopt.push_back(new_opt_id);
                    else newopt.push_back(x);
                }
                if (it.value().is_object()) it.value()["option"] = newopt;
                changed = true;
            }
        }
        return changed;
    }
    if (flag == "RENAME_NPC" || flag == "RENAME_COND") {
        std::string target = flag == "RENAME_NPC" ? "npc" : "cond";
        json old_val = json::array();
        if (cfg_bucket.is_object() && cfg_bucket.contains(rk) && cfg_bucket[rk].contains(key)) {
            old_val = cfg_bucket[rk][key];
            cfg_bucket[rk].erase(key);
        }
        std::string text = format_to_display(old_val, target, cfg);
        cfg_bucket[rk][target] = parse_from_display(text, target, old_val, cfg);
        mod_data[cfg] = cfg_bucket;
        return true;
    }
    if (bug.contains("healed") && !bug["healed"].is_null()) {
        cfg_bucket[rk][key] = bug["healed"];
        mod_data[cfg] = cfg_bucket;
        return true;
    }
    return changed;
}

}  // namespace p1
}  // namespace sa
