// wip/P1/semantic_assets.cpp — see semantic_assets.h for the Python sources.
#include "semantic_assets.h"

#include <algorithm>
#include <cstring>
#include <mutex>

#include "sa_core/assets.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "semantic_db_data.h"

namespace sa {
namespace p1 {
namespace {

namespace paths = sa_core::paths;

std::optional<std::string> read_json_text(const std::string& path) {
    auto raw = paths::read_bytes(path);
    if (!raw) return std::nullopt;
    auto strict = sa_core::decode_utf8_sig_strict(*raw);
    if (strict) return strict;
    return sa_core::decode_utf8_sig_replace(*raw);
}

// R1 unification: the candidate list itself moved to sa_core/assets.cpp so
// every layer resolves assets identically without cross-service includes.
json load_asset(const std::string& filename) {
    for (const auto& p : sa_core::assets::candidate_paths(filename)) {
        auto text = read_json_text(p);
        if (!text) continue;
        json parsed = json::parse(*text, nullptr, false);
        if (!parsed.is_discarded() && parsed.is_object()) return parsed;
    }
    return json::object();
}

// ---- schema.json / dicts.json singletons ---------------------------------
std::once_flag g_schema_once;
json g_schema;
std::once_flag g_dicts_once;
json g_dicts;
// assets/PersonCfg.json — 官方人物表；仅作 /api/roles 在工作区/base 数据都没有
// PersonCfg 时的兜底（含 id/name/gender/url/url2）。
std::once_flag g_person_cfg_once;
json g_person_cfg;
// assets/BgCfg.json — 官方背景表；作 /api/preview/meta 在工作区/base 数据都没有
// BgCfg 时的兜底（含 id/url 等）。
std::once_flag g_bg_cfg_once;
json g_bg_cfg;

// Convert a {str:str} JSON object into a std::map (non-string values skipped).
std::map<std::string, std::string> to_str_map(const json& obj) {
    std::map<std::string, std::string> m;
    if (!obj.is_object()) return m;
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        if (it.value().is_string())
            m[it.key()] = it.value().get<std::string>();
        else
            m[it.key()] = sa_core::py_str(it.value());
    }
    return m;
}

// ref_rules._DICT_POOL_MAP: target table -> pool key (data_dicts dict name).
const std::map<std::string, std::string>& target_pool_map() {
    static const std::map<std::string, std::string> m = {
        {"PersonCfg", "ROLE"},        {"RelationCfg", "RELATION"},
        {"ItemCfg", "ITEM"},          {"MapCfg", "MAP"},
        {"BgCfg", "BG"},              {"PersonStateCfg", "STATE"},
        {"TextCfg", "TEXT"},          {"NegotiationSkillCfg", "NEGOTIATION_SKILL"},
        {"NegotiationBuffCfg", "NEGOTIATION_BUFF"},
        {"GameCfg", "GAME"},          {"KZoneContentCfg", "KZONE_POST"},
        {"AnimeKzoneContentCfg", "KZONE_POST"},
        {"KZoneMessageBoardCfg", "KZONE_MESSAGE"},
        {"PhoneMsgCfg", "PHONE_MSG"},
    };
    return m;
}

std::once_flag g_pool_once;
// pool key -> map; only the 14 names above are populated (empty for the
// CSV-derived ones, matching this repo's csv-dict-less runtime).
std::map<std::string, std::map<std::string, std::string>> g_pools;

const std::map<std::string, std::string>& pool_for_key(const std::string& key) {
    static const std::map<std::string, std::string> kEmpty;
    std::call_once(g_pool_once, [] {
        const json& gd = dicts().value("game_dicts", json::object());
        g_pools["ROLE"] = to_str_map(gd.value("roles", json::object()));
        g_pools["ATTR"] = to_str_map(gd.value("attrs", json::object()));
        g_pools["ITEM"] = to_str_map(gd.value("items", json::object()));
        g_pools["RELATION"] = to_str_map(gd.value("relations", json::object()));
        g_pools["MAP"] = to_str_map(gd.value("maps", json::object()));
        g_pools["JOB"] = to_str_map(gd.value("jobs", json::object()));
        g_pools["BG"] = to_str_map(gd.value("bgs", json::object()));
        for (const char* empty : {"STATE", "TEXT", "NEGOTIATION_SKILL", "NEGOTIATION_BUFF",
                                  "GAME", "KZONE_POST", "KZONE_MESSAGE", "PHONE_MSG"})
            g_pools[empty];  // default-construct empty
    });
    auto it = g_pools.find(key);
    return it == g_pools.end() ? g_pools["ROLE"] : it->second;  // never null ref
}

// ---- embedded template DBs -----------------------------------------------
std::once_flag g_db_once;
json g_db;  // parsed kSemanticDb

const json& db_root() {
    std::call_once(g_db_once, [] {
        g_db = json::parse(sa::p1::kSemanticDb, nullptr, false);
        if (g_db.is_discarded()) g_db = json::object();
    });
    return g_db;
}

std::once_flag g_editor_db_once;
json g_editor_db;

// ---- A1 元数据：模板串归一化工具 -------------------------------------------
// 全部按 UTF-8 字节串处理：分隔符/算符都是确定字节序列，逐字节替换安全。

bool starts_at(const std::string& s, size_t i, const char* lit) {
    return s.compare(i, std::strlen(lit), lit) == 0;
}

// 比较算符归一成（两侧带空格）记号：文本形态 + 全角/半角符号 + ASCII。
std::string canon_ops(const std::string& s) {
    std::string t = s;
    auto rep = [&t](const char* a, const char* b) {
        const size_t n = std::strlen(a), m = std::strlen(b);
        size_t p = 0;
        while ((p = t.find(a, p)) != std::string::npos) {
            t.replace(p, n, b);
            p += m;
        }
    };
    // 文本形态先行（"大于等于" 必须先于 "大于"/"等于"），再符号，ASCII 里 ">=" 先于 ">" "="。
    rep("\xE5\xA4\xA7\xE4\xBA\x8E\xE7\xAD\x89\xE4\xBA\x8E", " \xE2\x89\xA5 ");  // 大于等于
    rep("\xE5\xB0\x8F\xE4\xBA\x8E\xE7\xAD\x89\xE4\xBA\x8E", " \xE2\x89\xA4 ");  // 小于等于
    rep("\xE5\xA4\xA7\xE4\xBA\x8E", " > ");  // 大于
    rep("\xE5\xB0\x8F\xE4\xBA\x8E", " < ");  // 小于
    rep("\xE7\xAD\x89\xE4\xBA\x8E", " = ");  // 等于
    rep("\xE2\x89\xA5", " \xE2\x89\xA5 ");    // ≥
    rep("\xE2\x89\xA4", " \xE2\x89\xA4 ");    // ≤
    rep("\xEF\xBC\x9E", " > ");               // ＞
    rep("\xEF\xBC\x9C", " < ");               // ＜
    rep("\xE2\x89\xA0", " \xE2\x89\xA0 ");    // ≠
    rep("!=", " \xE2\x89\xA0 ");
    rep(">=", " \xE2\x89\xA5 ");
    rep("<=", " \xE2\x89\xA4 ");
    rep(">", " > ");
    rep("<", " < ");
    rep("=", " = ");
    return t;
}

// 全角/半角标点、括注符号、空白统一成空格（@PLACEHOLDER@ 无分隔符，不受影响）。
std::string to_spaces(const std::string& s) {
    std::string t;
    t.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        static const char* kSeps[] = {
            "\xEF\xBC\x8C",  // ，
            "\xE3\x80\x81",  // 、
            "\xEF\xBC\x9B",  // ；
            "\xEF\xBC\x9A",  // ：
            "\xEF\xBC\x88",  // （
            "\xEF\xBC\x89",  // ）
            "\xE3\x80\x90",  // 【
            "\xE3\x80\x91",  // 】
            "\xE3\x80\x80",  // 全角空格
            ",", ";", ":",
        };
        bool hit = false;
        for (const char* sep : kSeps) {
            if (starts_at(s, i, sep)) {
                t += ' ';
                i += std::strlen(sep);
                hit = true;
                break;
            }
        }
        if (hit) continue;
        char c = s[i];
        if (c == '(' || c == ')' || c == '\t' || c == '\n' || c == '\r') {
            t += ' ';
            ++i;
            continue;
        }
        t += c;
        ++i;
    }
    return t;
}

std::vector<std::string> split_ws(const std::string& s) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == ' ') {
            if (!cur.empty()) {
                out.push_back(cur);
                cur.clear();
            }
        } else {
            cur += c;
        }
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

bool is_op_tok(const std::string& t) {
    return t == "=" || t == ">" || t == "<" || t == "\xE2\x89\xA5" ||
           t == "\xE2\x89\xA4" || t == "\xE2\x89\xA0";
}

// 紧值记号：单个大写字母 + 可选数字（V/X/Y/N/A1/V2…）。BGM/Buff/Npc/MAX 等
// 多字母词是概念词，不算值记号（避免骨架误伤概念名）。
bool is_tight_value_tok(const std::string& t) {
    if (t.empty() || t[0] < 'A' || t[0] > 'Z') return false;
    for (size_t i = 1; i < t.size(); ++i)
        if (t[i] < '0' || t[i] > '9') return false;
    return true;
}

// 纯数字记号：0 / -1 / 101 / 0.5 / 50%（骨架与标签都要跳过）。
bool is_ascii_num_tok(const std::string& t) {
    size_t i = 0;
    if (i < t.size() && (t[i] == '-' || t[i] == '+')) ++i;
    bool dig = false, dot = false;
    for (; i < t.size(); ++i) {
        char c = t[i];
        if (c >= '0' && c <= '9') { dig = true; continue; }
        if (c == '.' && !dot) { dot = true; continue; }
        if (c == '%' && i + 1 == t.size()) continue;
        return false;
    }
    return dig;
}

bool is_placeholder_tok(const std::string& t) {
    if (t.size() < 3 || t.front() != '@' || t.back() != '@') return false;
    for (size_t i = 1; i + 1 < t.size(); ++i)
        if (!((t[i] >= 'A' && t[i] <= 'Z') || t[i] == '_')) return false;
    return true;
}

bool is_pure_punct_tok(const std::string& t) {
    if (t.empty()) return false;
    for (unsigned char c : t) {
        if (c >= 0x80) return false;
        if (std::strchr("-+~%*/.,", c) == nullptr) return false;
    }
    return true;
}

// 连接词/助词：取标签时跳过（"数量 V" 取 数量；"有 V" 不取 有）。
bool is_connector_tok(const std::string& t) {
    static const std::set<std::string> kStop = {
        "\xE7\x9A\x84",  // 的
        "\xE6\x9C\x89",  // 有
        "\xE5\x8F\x8A",  // 及
        "\xE4\xB8\x8E",  // 与
        "\xE5\x92\x8C",  // 和
        "\xE5\x9C\xA8",  // 在
        "\xE4\xB8\xBA",  // 为
        "\xE6\x97\xB6",  // 时
        "\xE8\x87\xB3",  // 至
        "\xE5\x88\xB0",  // 到
    };
    return kStop.count(t) != 0;
}

// 去括注：()/（）/【】整段（含内容）丢弃；只用于折叠行标题（family 键保留括号提示）。
std::string strip_parens(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    int depth = 0;
    for (size_t i = 0; i < s.size();) {
        static const char* kOpen[] = {"(", "\xEF\xBC\x88", "\xE3\x80\x90"};
        static const char* kClose[] = {")", "\xEF\xBC\x89", "\xE3\x80\x91"};
        bool hit = false;
        for (const char* o : kOpen) {
            if (starts_at(s, i, o)) {
                ++depth;
                i += std::strlen(o);
                hit = true;
                break;
            }
        }
        if (hit) continue;
        for (const char* c : kClose) {
            if (starts_at(s, i, c)) {
                if (depth > 0) --depth;
                i += std::strlen(c);
                hit = true;
                break;
            }
        }
        if (hit) continue;
        if (depth == 0) out += s[i];
        ++i;
    }
    return out;
}

// 与 semantic_core.parse_template_parts / semantic_graph 同语义：trim → 剥首尾 [] →
// 逗号拆 → 每段 trim → 丢空。下标口径与 /api/effect/parse 的 template.parts 一致。
std::vector<std::string> code_parts(const std::string& code) {
    auto trim = [](const std::string& s) {
        size_t b = 0, e = s.size();
        while (b < e && (s[b] == ' ' || s[b] == '\t')) ++b;
        while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t')) --e;
        return s.substr(b, e - b);
    };
    std::string s = trim(code);
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == '[' || s[b] == ']')) ++b;
    while (e > b && (s[e - 1] == '[' || s[e - 1] == ']')) --e;
    s = s.substr(b, e - b);
    std::vector<std::string> parts;
    size_t pos = 0;
    while (true) {
        size_t comma = s.find(',', pos);
        std::string piece = trim(s.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos));
        if (!piece.empty()) parts.push_back(piece);
        if (comma == std::string::npos) break;
        pos = comma + 1;
    }
    return parts;
}

// code 段里的合法值槽：字母开头 + 字母数字（V/X/N/Bg/Emoji…；"EFFECTS*" 带 * 不算）。
bool is_loose_value_tok(const std::string& t) {
    if (t.empty()) return false;
    char c0 = t[0];
    if (!((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z'))) return false;
    for (size_t i = 1; i < t.size(); ++i) {
        char c = t[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) return false;
    }
    return true;
}

struct TmplMeta {
    std::string family, label, op;
    long long value_index = -1, upper_index = -1;
    std::map<std::string, std::string> labels;  // 裸字母槽名 -> 人话标签
};

TmplMeta build_meta(const std::string& desc, const std::string& code) {
    TmplMeta m;
    const std::vector<std::string> toks = split_ws(to_spaces(canon_ops(desc)));
    std::vector<size_t> op_pos;
    for (size_t i = 0; i < toks.size(); ++i)
        if (is_op_tok(toks[i])) op_pos.push_back(i);
    const bool is_range = op_pos.size() >= 2;
    if (is_range) m.op = "\xE8\x8C\x83\xE5\x9B\xB4";  // 范围
    else if (op_pos.size() == 1) m.op = toks[op_pos[0]];

    // 骨架：去算符 / 紧值 / 纯数字 / 纯标点后的词串（保留 @PLACEHOLDER@ 与括号提示）。
    auto skeleton = [](const std::vector<std::string>& ts) {
        std::string out;
        for (const auto& t : ts) {
            if (is_op_tok(t) || is_tight_value_tok(t) || is_ascii_num_tok(t) || is_pure_punct_tok(t))
                continue;
            if (!out.empty()) out += ' ';
            out += t;
        }
        return out;
    };
    const std::string key = skeleton(toks);
    const std::string clean = skeleton(split_ws(to_spaces(canon_ops(strip_parens(desc)))));
    m.label = !clean.empty() ? clean : key;

    std::string key_fallback;
    for (const auto& t : toks) {
        if (!key_fallback.empty()) key_fallback += ' ';
        key_fallback += t;
    }
    const std::vector<std::string> parts = code_parts(code);
    const std::string primary = parts.empty() ? std::string() : parts[0];
    m.family = primary + "|" + (key.empty() ? key_fallback : key);

    // 值与上下限名：范围取首算符前的紧值（下限）/末算符后的紧值（上限）；
    // 单算符取首个紧值；全无则空（下标再退回 code 首个合法值槽）。
    std::string lower_name, upper_name;
    if (!op_pos.empty())
        for (size_t i = 0; i < op_pos[0]; ++i)
            if (is_tight_value_tok(toks[i])) { lower_name = toks[i]; break; }
    if (is_range)
        for (size_t i = op_pos.back() + 1; i < toks.size(); ++i)
            if (is_tight_value_tok(toks[i])) { upper_name = toks[i]; break; }
    if (lower_name.empty())
        for (const auto& t : toks)
            if (is_tight_value_tok(t)) { lower_name = t; break; }
    auto idx_of = [&parts](const std::string& n) -> long long {
        if (n.empty()) return -1;
        for (size_t i = 0; i < parts.size(); ++i)
            if (parts[i] == n) return static_cast<long long>(i);
        return -1;
    };
    m.value_index = idx_of(lower_name);
    if (m.value_index < 0)
        for (size_t i = 0; i < parts.size(); ++i)
            if (is_loose_value_tok(parts[i])) { m.value_index = static_cast<long long>(i); break; }
    m.upper_index = is_range ? idx_of(upper_name) : -1;

    // 槽标签：范围 → 下限/上限；其余取 desc 中该值最近的上文词（跳过算符/值/数字/
    // 占位符/连接词的第一个词；无上文取下文），兜底 "数值"。
    auto walk_label = [&toks](const std::string& name) -> std::string {
        size_t pos = std::string::npos;
        for (size_t i = 0; i < toks.size(); ++i)
            if (toks[i] == name) { pos = i; break; }
        auto usable = [](const std::string& t) {
            return !is_op_tok(t) && !is_tight_value_tok(t) && !is_ascii_num_tok(t) &&
                   !is_placeholder_tok(t) && !is_pure_punct_tok(t) && !is_connector_tok(t);
        };
        if (pos != std::string::npos) {
            for (size_t i = pos; i-- > 0;)
                if (usable(toks[i])) return toks[i];
            for (size_t i = pos + 1; i < toks.size(); ++i)
                if (usable(toks[i])) return toks[i];
        }
        return "\xE6\x95\xB0\xE5\x80\xBC";  // 数值
    };
    for (const auto& p : parts) {
        if (!is_loose_value_tok(p)) continue;
        if (is_range && p == upper_name) m.labels[p] = "\xE4\xB8\x8A\xE9\x99\x90";       // 上限
        else if (is_range && p == lower_name) m.labels[p] = "\xE4\xB8\x8B\xE9\x99\x90";  // 下限
        else m.labels[p] = walk_label(p);
    }
    return m;
}

}  // namespace

const json& game_schema() {
    std::call_once(g_schema_once, [] { g_schema = load_asset("schema.json"); });
    return g_schema;
}

const json& dicts() {
    std::call_once(g_dicts_once, [] { g_dicts = load_asset("dicts.json"); });
    return g_dicts;
}

const json& person_cfg() {
    std::call_once(g_person_cfg_once, [] { g_person_cfg = load_asset("PersonCfg.json"); });
    return g_person_cfg;
}

const json& bg_cfg() {
    std::call_once(g_bg_cfg_once, [] { g_bg_cfg = load_asset("BgCfg.json"); });
    return g_bg_cfg;
}

json schema_response() {
    const json& gs = game_schema();
    json field_types = json::object();
    for (auto it = gs.begin(); it != gs.end(); ++it) {
        if (!it.value().is_object()) continue;
        for (auto f = it.value().begin(); f != it.value().end(); ++f)
            field_types[f.key()] = f.value();
    }
    std::vector<std::string> names;
    for (auto it = gs.begin(); it != gs.end(); ++it) names.push_back(it.key());
    std::sort(names.begin(), names.end());
    json cfg_names = json::array();
    for (auto& n : names) cfg_names.push_back(n);
    json body;
    body["game_schema"] = gs;
    body["field_types"] = std::move(field_types);
    body["cfg_names"] = std::move(cfg_names);
    return body;
}

const std::map<std::string, std::string>* dict_pool(const std::string& name) {
    const auto& m = target_pool_map();
    return m.count(name) ? &pool_for_key(m.at(name)) : nullptr;
}

std::set<std::string> dict_pool_keys(const std::string& name) {
    const auto* p = dict_pool(name);
    if (!p) return {};
    std::set<std::string> s;
    for (const auto& kv : *p) s.insert(kv.first);
    return s;
}

const std::map<std::string, std::string>* ref_pool_for_target(const std::string& target) {
    return dict_pool(target);
}

const std::map<std::string, std::string>& pool_by_key(const std::string& key) {
    return pool_for_key(key);
}

const json& condition_db() { return db_root().at("CONDITION_DB"); }
const json& effect_db() { return db_root().at("EFFECT_DB"); }
const json& cost_db() { return db_root().at("COST_DB"); }
const json& screen_effect_db() { return db_root().at("SCREEN_EFFECT_DB"); }
const json& action_cmd_db() { return db_root().at("ACTION_CMD_DB"); }
const json& secondary_placeholder_map() { return db_root().at("SECONDARY_PLACEHOLDER_MAP"); }

// data_dicts._build_effect_editor_db: drop [7,2,...] and [7,3,...] entries, then
// prepend the two curated state rows (index 0 remove, index 1 gain).
const json& effect_editor_db() {
    std::call_once(g_editor_db_once, [] {
        g_editor_db = json::array();
        for (const auto& item : effect_db()) {
            std::string code = item.value("code", "");
            std::string nospace;
            for (char c : code) if (c != ' ') nospace += c;
            if (nospace.rfind("[7,2,", 0) == 0 || nospace.rfind("[7,3,", 0) == 0) continue;
            g_editor_db.push_back(item);
        }
        json gain;
        gain["desc"] = "获取状态 @STATE@";
        gain["code"] = "[7, 2, @STATE@]";
        json rm;
        rm["desc"] = "移除状态 @STATE@";
        rm["code"] = "[7, 3, @STATE@]";
        // Python: insert(0, gain); insert(0, remove) → 最终 [移除, 获取, ...]
        // （golden api_effect_suggest_mode_effect_q_ 首条即「移除状态」）。
        g_editor_db.insert(g_editor_db.begin(), gain);
        g_editor_db.insert(g_editor_db.begin(), rm);
    });
    return g_editor_db;
}

const json& mode_db(const std::string& mode) {
    if (mode == "condition") return condition_db();
    if (mode == "cost") return cost_db();
    if (mode == "action") return action_cmd_db();
    if (mode == "screen") return screen_effect_db();
    return effect_editor_db();  // effect（未知 mode 同口径兜底，与 effect_suggest 一致）
}

json code_slots(const std::string& code) {
    json slots = json::array();
    std::map<std::string, size_t> index;  // slot name -> position in `slots`
    for (size_t i = 0; i < code.size();) {
        char c = code[i];
        if (c == '@') {
            size_t j = i + 1;
            std::string name;
            while (j < code.size() && ((code[j] >= 'A' && code[j] <= 'Z') || code[j] == '_'))
                name += code[j++];
            if (j < code.size() && code[j] == '@' && !name.empty()) {
                std::string key = "@" + name + "@";
                std::string dict, label;
                const json& sp = secondary_placeholder_map();
                if (sp.contains(key) && sp[key].is_array() && sp[key].size() >= 2) {
                    if (sp[key][0].is_string()) dict = sp[key][0].get<std::string>();
                    if (sp[key][1].is_string()) label = sp[key][1].get<std::string>();
                }
                auto it = index.find(name);
                if (it == index.end()) {
                    index[name] = slots.size();
                    slots.push_back(json{{"kind", "dict"}, {"name", name},
                                         {"dict", dict}, {"label", label}, {"count", 1}});
                } else {
                    slots[it->second]["count"] = slots[it->second]["count"].get<int>() + 1;
                }
                i = j + 1;
                continue;
            }
        }
        if (c >= 'A' && c <= 'Z') {
            std::string name(1, c);
            auto it = index.find(name);
            if (it == index.end()) {
                index[name] = slots.size();
                slots.push_back(json{{"kind", "number"}, {"name", name}, {"count", 1}});
            } else {
                slots[it->second]["count"] = slots[it->second]["count"].get<int>() + 1;
            }
            ++i;
            continue;
        }
        ++i;
    }
    return slots;
}

json template_meta(const std::string& desc, const std::string& code) {
    const TmplMeta m = build_meta(desc, code);
    json out;
    out["family"] = m.family;
    out["family_label"] = m.label;
    out["description"] = desc;
    out["op"] = m.op;
    out["value_index"] = m.value_index;
    out["upper_index"] = m.upper_index;
    json labels = json::object();
    for (const auto& kv : m.labels) labels[kv.first] = kv.second;
    out["labels"] = std::move(labels);
    return out;
}

json family_ops(const std::string& mode, const std::string& desc, const std::string& code) {
    static std::once_flag once;
    static std::map<std::string, json> table;  // "<mode>\x1f<family>" -> ops array
    std::call_once(once, [] {
        // 行内算符循环序（与前端展示一致）：= > ≥ < ≤ ≠ 范围，无算符殿后。
        static const std::vector<std::string> kCycle = {
            "=", ">", "\xE2\x89\xA5", "<", "\xE2\x89\xA4", "\xE2\x89\xA0",
            "\xE8\x8C\x83\xE5\x9B\xB4", ""};
        auto rank = [](const std::string& op) {
            for (size_t i = 0; i < kCycle.size(); ++i)
                if (kCycle[i] == op) return i;
            return kCycle.size();
        };
        for (const char* mode_name : {"condition", "effect", "cost", "action", "screen"}) {
            for (const auto& e : mode_db(mode_name)) {
                const std::string c = e.value("code", "");
                const TmplMeta t = build_meta(e.value("desc", ""), c);
                json item;
                item["op"] = t.op;
                item["code"] = c;
                item["value_index"] = t.value_index;
                item["upper_index"] = t.upper_index;
                json slots = code_slots(c);
                for (auto& s : slots)
                    if (s.value("kind", "") == "number") {
                        auto lab = t.labels.find(s.value("name", ""));
                        if (lab != t.labels.end()) s["label"] = lab->second;
                    }
                item["slots"] = std::move(slots);
                json& arr = table[std::string(mode_name) + "\x1f" + t.family];
                if (!arr.is_array()) arr = json::array();
                arr.push_back(std::move(item));
            }
        }
        for (auto& [key, arr] : table) {
            std::stable_sort(arr.begin(), arr.end(), [&rank](const json& a, const json& b) {
                int ra = rank(a.value("op", "")), rb = rank(b.value("op", ""));
                if (ra != rb) return ra < rb;
                return a.value("code", "") < b.value("code", "");
            });
            json out = json::array();
            for (const auto& it : arr) {
                // 同码重复条目（理论上无）去重，保持排序后相邻即同码。
                if (!out.empty() && out.back().value("code", "") == it.value("code", "")) continue;
                out.push_back(it);
            }
            arr = std::move(out);
        }
    });
    const TmplMeta self = build_meta(desc, code);
    auto it = table.find(mode + "\x1f" + self.family);
    if (it != table.end()) return it->second;
    json one = json::array();  // DB 外模板（异常输入）兜底：只含自身
    json item;
    item["op"] = self.op;
    item["code"] = code;
    item["value_index"] = self.value_index;
    item["upper_index"] = self.upper_index;
    json slots = code_slots(code);
    for (auto& s : slots)
        if (s.value("kind", "") == "number") {
            auto lab = self.labels.find(s.value("name", ""));
            if (lab != self.labels.end()) s["label"] = lab->second;
        }
    item["slots"] = std::move(slots);
    one.push_back(std::move(item));
    return one;
}

std::string find_asset(const std::string& filename) {
    return sa_core::assets::find_asset(filename);
}

void set_assets_root_for_test(const std::string& root) {
    sa_core::assets::set_assets_root_override(root);
}

}  // namespace p1
}  // namespace sa
