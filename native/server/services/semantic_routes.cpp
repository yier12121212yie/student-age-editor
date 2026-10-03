// wip/P1/semantic_routes.cpp — wave-2 P1: schema/dicts/validate/cfg_ids/base_ids/
// effect_suggest/effect_validate/bugfix scan+fix. Port of api.py:1219-1615 +
// 2567-2631 over the semantic engines in semantic_core/semantic_bugfix.
#include "semantic_routes.h"

#include <algorithm>
#include <cstdint>
#include <map>
#include <regex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "sa_core/env_store.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "semantic_assets.h"
#include "semantic_graph.h"
#include "semantic_logic.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/perf.h"
#include "server/services/stores_api.h"
#include "server/state.h"
#include "usage_store.h"

namespace sa {
namespace {

namespace cs = sa_core::paths;
namespace str = sa_core::str;
using sa::p1::json;
using sa::p1::AvailableMap;

std::string lstrip_neg(const std::string& s) {
    size_t i = 0;
    while (i < s.size() && s[i] == '-') ++i;
    return s.substr(i);
}

// Python bool(v) 真值（`x or y` 判定用）：null/False/0/""/[]/{} 为假。
// 注意与 _truthy（只认真 true）不同——api.py 里 str(body.get(...) or "") 用的是后者。
bool py_truthy(const json& v) {
    if (v.is_null()) return false;
    if (v.is_boolean()) return v.get<bool>();
    if (v.is_number()) return v.get<double>() != 0.0;
    if (v.is_string()) return !v.get<std::string>().empty();
    return !v.empty();
}

// Python `str(v or "")`：假值恒得 ""，真值 str()。
std::string py_str_or_empty(const json& v) {
    return py_truthy(v) ? (v.is_string() ? v.get<std::string>() : sa_core::py_str(v))
                        : std::string();
}

// 按 UTF-8 码点截前 n 个字符（Python [:n] 语义；逐字节会把多字节字符腰斩）。
std::string cp_prefix(const std::string& s, size_t n) {
    size_t chars = 0, i = 0;
    while (i < s.size() && chars < n) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t len = 1;
        if ((c >> 5) == 0x6) len = 2;
        else if ((c >> 4) == 0xE) len = 3;
        else if ((c >> 3) == 0x1E) len = 4;
        i = std::min(s.size(), i + len);
        ++chars;
    }
    return s.substr(0, i);
}

// Python `all(c in target for c in chars)` 的码点版（chars 是合法 UTF-8 序列：
// 数字/分隔符只可能是 ASCII，非 ASCII 字节全部原样保留）。
bool every_codepoint_in(const std::string& chars, const std::string& target) {
    size_t i = 0;
    while (i < chars.size()) {
        unsigned char c = static_cast<unsigned char>(chars[i]);
        size_t len = 1;
        if ((c >> 5) == 0x6) len = 2;
        else if ((c >> 4) == 0xE) len = 3;
        else if ((c >> 3) == 0x1E) len = 4;
        std::string cp = chars.substr(i, std::min(len, chars.size() - i));
        if (target.find(cp) == std::string::npos) return false;
        i += len;
    }
    return true;
}

// api.py:319-324 _cfg_path wrapper that yields "" (instead of throwing) so the
// read helpers can mirror Python's "SandboxError -> None" table reads.
std::string try_cfg_path(const std::string& cfg_name) {
    try {
        return cfg_path(cfg_name);
    } catch (const SandboxError&) {
        return std::string();
    }
}

// api.py:640-659 _read_mod_table (bypasses the whole-mod cache; reads the file).
std::optional<json> read_mod_table(const std::string& cfg_name) {
    if (cfg_name.empty()) return std::nullopt;
    std::string path = try_cfg_path(cfg_name);
    if (path.empty() || !cs::is_file(path)) return std::nullopt;
    auto rl = cfg_store::read_lossy(path);
    if (!rl.text) return std::nullopt;  // OSError analogue
    std::string content = str::trim(*rl.text);
    if (content.empty()) return json::object();
    json data = json::parse(content, nullptr, false);
    if (data.is_discarded()) return std::nullopt;
    if (!data.is_object()) return std::nullopt;
    return data;
}

// api.py:609-637 _base_table_ids (A13): int-keyed set via the base_store seam.
// Empty when base is not loaded (Python STATE.base is None).
std::vector<long long> base_table_ids(const std::string& cfg) {
    std::vector<long long> out;
    if (cfg.empty()) return out;
    auto store = base_store();
    if (!store || !store->available()) return out;
    auto ids = store->table_ids(cfg);
    if (!ids) return out;
    out.assign(ids->begin(), ids->end());
    return out;
}

json base_ids_json() {
    json bj = json::object();
    for (const char* t : {"EvtCfg", "TalkCfg", "OptionCfg"}) {
        json arr = json::array();
        for (auto id : base_table_ids(t)) arr.push_back(id);
        bj[t] = arr;
    }
    return bj;
}

// ---------------- /api/dicts ---------------------------------------------
// api.py:1345-1359 _build_audios.
json build_audios() {
    json out = json::object();
    auto store = base_store();
    if (!store || !store->available()) return out;
    auto tbl = store->table("AudioCfg");
    if (!tbl || !tbl->is_object()) return out;
    for (auto it = tbl->begin(); it != tbl->end(); ++it) {
        if (it.value().is_object()) {
            // Python: str(v.get("name") or "音频 %s" % k) —— 空串/0 也要兜底。
            const json* name = it.value().contains("name") ? &it.value().at("name") : nullptr;
            out[it.key()] = (name && py_truthy(*name)) ? sa_core::py_str(*name)
                                                       : ("音频 " + it.key());
        } else {
            out[it.key()] = sa_core::py_str(it.value());
        }
    }
    return out;
}
// api.py:1331-1343 _build_evt_types: start from the hardcoded dict, overlay base EvtTypeCfg.
json build_evt_types() {
    json gd = p1::dicts().value("game_dicts", json::object());
    json out = gd.contains("evt_types") ? gd["evt_types"] : json::object();
    auto store = base_store();
    if (!store || !store->available()) return out;
    auto tbl = store->table("EvtTypeCfg");
    if (!tbl || !tbl->is_object()) return out;
    for (auto it = tbl->begin(); it != tbl->end(); ++it) {
        bool numeric = !it.key().empty() && std::all_of(it.key().begin(), it.key().end(),
                                                        [](char c) { return c >= '0' && c <= '9'; });
        if (numeric && it.value().is_object()) {
            // Python: str(v.get("name") or "未知") —— 空串/0/None 一律回「未知」。
            const json* name = it.value().contains("name") ? &it.value().at("name") : nullptr;
            out[it.key()] = (name && py_truthy(*name)) ? sa_core::py_str(*name)
                                                       : std::string("未知");
        }
    }
    return out;
}

// ---------------- /api/effect_suggest ------------------------------------
std::string ascii_upper(const std::string& s) {
    std::string o = s;
    for (char& c : o) if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 32);
    return o;
}
std::vector<std::string> re_split_chunks(const std::string& s) {
    static const std::regex rx(R"([,，;；\s]+)");
    std::vector<std::string> out;
    // Python re.split yields empty pieces at boundaries; we filter empties inline.
    size_t pos = 0;
    auto it = std::sregex_iterator(s.begin(), s.end(), rx);
    for (auto x = it; x != std::sregex_iterator(); ++x) {
        std::string piece = s.substr(pos, static_cast<size_t>(x->position()) - pos);
        if (!piece.empty()) out.push_back(piece);
        pos = static_cast<size_t>(x->position() + x->length());
    }
    std::string tail = s.substr(pos);
    if (!tail.empty()) out.push_back(tail);
    return out;
}
std::vector<std::string> re_find_nums(const std::string& s) {
    static const std::regex rx(R"(-?\d+(?:\.\d+)?)");
    std::vector<std::string> out;
    for (auto x = std::sregex_iterator(s.begin(), s.end(), rx); x != std::sregex_iterator(); ++x)
        out.push_back(x->str());
    return out;
}
int count_upper_alpha(const std::string& s) {
    int n = 0;
    for (char c : s) if (c >= 'A' && c <= 'Z') ++n;
    return n;
}
// Python re.sub(r"[A-Z]", str(n), code, count=1): first A-Z run replaced.
std::string sub_first_upper(const std::string& s, const std::string& repl) {
    std::string o = s;
    for (char& c : o)
        if (c >= 'A' && c <= 'Z') { c = '\x01'; break; }
    std::string res;
    for (char c : o) {
        if (c == '\x01') res += repl;
        else res += c;
    }
    return res;
}

// Match-normalized view of a candidate/query: upper, spaces stripped, the
// math symbols the old path already folded (≥ ≤ ＞ ＜). Same shape the
// scoring compares on.
std::string norm_for_match(const std::string& s) {
    std::string o = ascii_upper(s);
    std::string t;
    for (char c : o) if (c != ' ') t += c;
    auto rep = [](std::string& x, const std::string& a, const std::string& b) {
        size_t p = 0;
        while ((p = x.find(a, p)) != std::string::npos) { x.replace(p, a.size(), b); p += b.size(); }
    };
    rep(t, "\xE2\x89\xA5", ">=");  // ≥
    rep(t, "\xE2\x89\xA4", "<=");  // ≤
    rep(t, "\xEF\xBC\x9E", ">");   // ＞
    rep(t, "\xEF\xBC\x9C", "<");   // ＜
    return t;
}

// Parameter slots inside a raw code template, so every frontend can build a
// fill-in form instead of forcing the user to hand-edit "@ATTR@"/"V":
//   "@NAME@"  -> {"kind":"dict", "name":NAME, "dict":<pool>, "label":<中文>}
//                 (resolved via SECONDARY_PLACEHOLDER_MAP; unknown pools get
//                  "dict":"" so the caller can still show the raw name)
//   lone A-Z  -> {"kind":"number", "name":<letter>}
// Repeated letters merge into one slot with a count (they take the same
// value when the row is assembled).
json parse_code_slots(const std::string& code) {
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
                const json& sp = p1::secondary_placeholder_map();
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

json effect_suggest_body(const std::string& q_in, const std::string& mode_in) {
    std::string mode = str::lower(str::trim(mode_in));
    if (mode.empty()) mode = "effect";
    static const std::set<std::string> kModes = {"effect", "condition", "cost", "action", "screen"};
    if (!kModes.count(mode)) mode = "effect";

    const json* db = nullptr;
    if (mode == "condition") db = &p1::condition_db();
    else if (mode == "cost") db = &p1::cost_db();
    else if (mode == "action") db = &p1::action_cmd_db();
    else if (mode == "screen") db = &p1::screen_effect_db();
    else db = &p1::effect_editor_db();

    const int limit = 40;
    std::string qn = str::trim(q_in);
    std::string qu = ascii_upper(qn);
    auto rep = [](std::string& s, const std::string& a, const std::string& b) {
        size_t p = 0;
        while ((p = s.find(a, p)) != std::string::npos) { s.replace(p, a.size(), b); p += b.size(); }
    };
    rep(qu, "\xE2\x89\xA5", ">=");  // ≥
    rep(qu, "\xE2\x89\xA4", "<=");  // ≤
    rep(qu, "\xE5\xA4\xA7\xE4\xBA\x8E\xE7\xAD\x89\xE4\xBA\x8E", ">=");  // 大于等于
    rep(qu, "\xE5\xB0\x8F\xE4\xBA\x8E\xE7\xAD\x89\xE4\xBA\x8E", "<=");  // 小于等于
    rep(qu, "\xE5\xA4\xA7\xE4\xBA\x8E", ">");  // 大于
    rep(qu, "\xE5\xB0\x8F\xE4\xBA\x8E", "<");  // 小于
    rep(qu, "\xE7\xAD\x89\xE4\xBA\x8E", "=");  // 等于

    std::vector<std::string> chunks = re_split_chunks(qu);
    std::vector<std::string> nums = re_find_nums(qu);

    struct SuggestHit { int score; const json* item; };
    std::vector<SuggestHit> hits;
    const bool empty_q = qn.empty();
    const std::string q_ns = norm_for_match(qn);
    // 三端上报的接受记录（key=raw code 模板）：非空 q 只作同分微调（≤5），
    // 不允许一个松命中盖掉精确前缀；空 q 则直接决定头部顺序。
    std::vector<std::string> recent_keys;
    for (const auto& e : sa::usage::top(sa::editor_root(), mode, 50))
        if (e.contains("key") && e["key"].is_string())
            recent_keys.push_back(e["key"].get<std::string>());
    auto recent_boost = [&](const std::string& code) -> int {
        for (size_t i = 0; i < recent_keys.size(); ++i)
            if (recent_keys[i] == code) return i < 10 ? 5 : (i < 30 ? 3 : 1);
        return 0;
    };

    for (const auto& item : *db) {
        std::string desc = item.value("desc", "");
        std::string code = item.value("code", "");
        std::string target = ascii_upper(desc + code);
        std::string target_ns;
        for (char c : target) if (c != ' ') target_ns += c;
        target = target_ns;
        rep(target, "\xE2\x89\xA5", ">=");
        rep(target, "\xE2\x89\xA4", "<=");
        rep(target, "\xEF\xBC\x9E", ">");  // ＞
        rep(target, "\xEF\xBC\x9C", "<");  // ＜

        bool ok = true, has_text = false;
        for (const std::string& ch : chunks) {
            std::string chars;
            for (unsigned char c : ch) {
                bool isdig = c >= '0' && c <= '9';
                bool issep = c == '-' || c == '+' || c == '.';
                if (!isdig && !issep) chars += static_cast<char>(c);
            }
            if (!chars.empty()) {
                has_text = true;
                // Python 逐码点判成员（逐字节会把中文拆成假命中的散字节）。
                if (!every_codepoint_in(chars, target)) ok = false;
                if (!ok) break;
            }
        }
        if (!ok) continue;
        if (!has_text && chunks.empty() && empty_q) {
            // keep
        } else if (!has_text && !nums.empty()) {
            bool any = false;
            for (auto& n : nums) if (target.find(n) != std::string::npos) { any = true; break; }
            if (!any && count_upper_alpha(code) == 0) continue;
        }
        // 打分：desc 前缀 > desc 包含 > code 前缀 > code 包含 > 码点松命中。
        int score = 10;
        if (!empty_q && !q_ns.empty()) {
            std::string d_ns = norm_for_match(desc), c_ns = norm_for_match(code);
            if (d_ns.rfind(q_ns, 0) == 0) score = 100;
            else if (d_ns.find(q_ns) != std::string::npos) score = 70;
            else if (c_ns.rfind(q_ns, 0) == 0) score = 60;
            else if (c_ns.find(q_ns) != std::string::npos) score = 40;
            else score = 10;
            score += recent_boost(code);
        }
        hits.push_back({score, &item});
    }

    std::vector<SuggestHit> picked;
    if (empty_q) {
        // 最近接受过的模板置顶（top 10），其余按码表原序补足 limit。
        std::set<const json*> used;
        for (size_t i = 0; i < recent_keys.size() && i < 10 && static_cast<int>(picked.size()) < limit;
             ++i) {
            for (const auto& h : hits)
                if (h.item->value("code", "") == recent_keys[i] && used.insert(h.item).second) {
                    picked.push_back(h);
                    break;
                }
        }
        for (const auto& h : hits) {
            if (static_cast<int>(picked.size()) >= limit) break;
            if (!used.insert(h.item).second) continue;
            picked.push_back(h);
        }
    } else {
        std::stable_sort(hits.begin(), hits.end(),
                         [](const SuggestHit& a, const SuggestHit& b) { return a.score > b.score; });
        for (const auto& h : hits) {
            if (static_cast<int>(picked.size()) >= limit) break;
            picked.push_back(h);
        }
    }
    if (picked.empty() && !empty_q) {
        for (size_t i = 0; i < db->size() && i < 15; ++i)
            picked.push_back({0, &(*db)[i]});  // 未命中回落：前 15 条目录
    }

    bool skip_render = (mode == "action" || mode == "screen");
    json rendered = json::array();
    for (const auto& h : picked) {
        const json& mi = *h.item;
        std::string tc = mi.value("code", ""), td = mi.value("desc", "");
        int ph = count_upper_alpha(mi.value("code", ""));
        if (ph && !nums.empty() && !skip_render) {
            int start = std::max(0, static_cast<int>(nums.size()) - ph);
            for (size_t i = static_cast<size_t>(start); i < nums.size(); ++i) {
                tc = sub_first_upper(tc, nums[i]);
                td = sub_first_upper(td, nums[i]);
            }
        }
        json r;
        r["desc"] = td; r["code"] = tc;
        r["raw_code"] = mi.value("code", ""); r["raw_desc"] = mi.value("desc", "");
        r["slots"] = parse_code_slots(mi.value("code", ""));
        r["score"] = h.score;
        rendered.push_back(r);
    }
    json body;
    body["items"] = rendered;
    body["mode"] = mode;
    body["q"] = qn;
    return body;
}

// api.py:679-693 _norm_effect_rows.
json norm_effect_rows(const json& arr) {
    if (!arr.is_array() || arr.empty()) return json::array();
    if (!arr[0].is_array()) { json a = json::array(); a.push_back(arr); return a; }
    if (!arr[0].empty() && arr[0][0].is_array()) return arr[0];
    return arr;
}

AvailableMap game_pools() {
    AvailableMap av;
    for (const char* key : {"ROLE", "ATTR", "ITEM", "RELATION", "MAP", "JOB", "STATE", "TEXT",
                            "NEGOTIATION_SKILL", "NEGOTIATION_BUFF", "GAME", "KZONE_POST",
                            "KZONE_MESSAGE", "PHONE_MSG"})
        for (const auto& kv : p1::pool_by_key(key)) av[key][kv.first] = kv.second;
    return av;
}

// Write quartet after a successful disk write (api.py:1083-1091).
void after_write(const std::string& cfg_name, const std::string& path, const json& data,
                 const json& result) {
    invalidate_table_cache(path);
    std::optional<long long> mt;
    if (result.contains("mtime_ns") && result.at("mtime_ns").is_number())
        mt = result.at("mtime_ns").get<long long>();
    seed_table_cache(path, cfg_name, data, mt);
    note_mod_cfgs_write(cfg_name, data, path);
    invalidate_preview_cache();
}

// api.py:2558-2565 _report_broken_tables 的单条形态（B16 如实上报）。
json broken_bug(const std::string& cfg, const std::string& err) {
    json b;
    b["cfg"] = cfg; b["id"] = ""; b["key"] = ""; b["val"] = nullptr; b["healed"] = nullptr;
    b["desc"] = "配置表 " + cfg + " 解析失败，未参与扫描（非无问题）: " + err;
    b["flag"] = "ERROR";
    return b;
}

// 共享只读空对象：让 `const json& body = cond ? req.body : kEmptyJson` 这类
// 绑定走真正的零拷贝 lvalue 组合。直接写 `: json::object()` 会让三目落回
// prvalue（lvalue 操作数被整树拷贝一次）——请求/响应路径都不该付这笔钱。
const json kEmptyJson = json::object();

// scan/fix 共用：只读视图 → 普通 json 表集。scan_bugs 的引擎接口是
// const json&（nlohmann 无引用语义的值类型），shared_ptr<const json> 视图
// 无法零拷贝传入，这里组一次普通表集是引擎接口成本，而非 G3 隔离需求
// （G3 fork-then-write 只对写者必要；scan_bugs 纯读，const 类型系统兜底）。
json mod_tables_json(const ModCfgsView& view) {
    json m = json::object();
    for (auto& [name, ptr] : view.tables) if (ptr) m[name] = *ptr;
    return m;
}
json base_tables_json() {
    json base_data = json::object();
    auto store = base_store();
    if (store && store->available()) {
        for (const auto& t : store->loaded_tables()) {
            auto tbl = store->table(t);
            if (tbl) base_data[t] = *tbl;
        }
    }
    return base_data;
}

const char* cross_msg_cfg(const std::string& msg) {
    static const std::pair<const char*, const char*> prefixes[] = {
        {"\xE4\xBA\x8B\xE4\xBB\xB6", "EvtCfg"},    // 事件
        {"\xE5\xAF\xB9\xE8\xAF\x9D", "TalkCfg"},   // 对话
        {"\xE9\x80\x89\xE9\xA1\xB9", "OptionCfg"}, // 选项
    };
    for (auto& p : prefixes)
        if (msg.rfind(p.first, 0) == 0) return p.second;
    return "";
}

}  // namespace

void register_semantic_routes(Router& r) {
    // GET /api/schema — api.py:1361-1368.
    r.get(R"(/api/schema)", [](const Req&) -> Resp {
        return Resp::Json(200, p1::schema_response());
    });

    // GET /api/dicts — api.py:1584-1615.
    r.get(R"(/api/dicts)", [](const Req&) -> Resp {
        const json& d = p1::dicts();
        json gd = d.value("game_dicts", json::object());
        json game;
        game["items"] = gd.value("items", json::object());
        game["roles"] = gd.value("roles", json::object());
        game["jobs"] = gd.value("jobs", json::object());
        game["bgm"] = json::object();
        game["sound"] = json::object();
        game["icons"] = json::object();
        game["maps"] = gd.value("maps", json::object());
        game["attrs"] = gd.value("attrs", json::object());
        game["relations"] = gd.value("relations", json::object());
        game["bgs"] = gd.value("bgs", json::object());
        game["turns"] = gd.value("turns", json::object());
        game["audios"] = build_audios();
        game["evt_types"] = build_evt_types();
        game["badminton_models"] = gd.value("badminton_models", json::object());
        json body;
        body["key_maps"] = d.value("key_maps", json::object());
        body["game_dicts"] = std::move(game);
        body["story_dicts"] = d.value("story_dicts", json::object());
        return Resp::Json(200, std::move(body));
    });

    // POST /api/validate — api.py:1219-1281.
    r.post(R"(/api/validate)", [](const Req& req) -> Resp {
        const json& body = req.body.is_object() ? req.body : kEmptyJson;
        // Python: cfg = str(body.get("cfg") or "") —— 假值（null/0/""/False）恒为 ""。
        std::string cfg = body.contains("cfg") ? py_str_or_empty(body.at("cfg")) : std::string();
        json data = body.contains("data") ? body.at("data") : json();
        if (!cfg.empty() && !data.is_object()) data = json::object();

        json issues = json::array();
        auto add_issue = [&](const std::string& level, const std::string& msg, const std::string& rid,
                             const std::string& icfg) {
            json it;
            it["level"] = level; it["msg"] = msg; it["rid"] = rid; it["cfg"] = icfg;
            issues.push_back(it);
        };
        if (data.is_object()) {
            for (auto it = data.begin(); it != data.end(); ++it) {
                try {
                    json rec_issues = p1::validate_record(cfg, it.key(), it.value());
                    for (auto& pair : rec_issues)
                        add_issue(pair[0].get<std::string>(), pair[1].get<std::string>(), it.key(), cfg);
                } catch (const std::exception& e) {
                    add_issue("info",
                              "记录 " + it.key() + " 单表校验失败（已跳过该记录）: " + e.what(), it.key(), cfg);
                }
            }
        }
        json tables = json::object();
        for (const char* tname : {"EvtCfg", "TalkCfg", "OptionCfg"}) {
            if (cfg == tname && data.is_object()) { tables[tname] = data; continue; }
            std::string path = try_cfg_path(tname);
            if (path.empty()) continue;
            auto res = load_table_cached(path, tname);
            if (res.state == "ok" && res.data && res.data->is_object()) tables[tname] = *res.data;
        }
        json bj = base_ids_json();
        json cross;
        try {
            cross = p1::validate_cross(tables, bj);
        } catch (const std::exception& e) {
            cross = json::array();
            add_issue("info", "跨表校验失败（已跳过）: " + std::string(e.what()), "", "");
        }
        for (auto& pair : cross) {
            std::string level = pair[0].get<std::string>(), msg = pair[1].get<std::string>();
            add_issue(level, msg, "", cross_msg_cfg(msg));
        }
        json counts;
        counts["error"] = 0; counts["warn"] = 0; counts["info"] = 0;
        for (auto& it : issues) {
            std::string lv = it.value("level", "");
            if (lv == "error" || lv == "warn" || lv == "info") counts[lv] = counts[lv].get<int>() + 1;
            else counts["info"] = counts["info"].get<int>() + 1;
        }
        json out;
        out["cfg"] = cfg;
        out["issues"] = issues;
        out["counts"] = counts;
        return Resp::Json(200, std::move(out));
    });

    // GET /api/cfg_ids?name= — api.py:1283-1311.
    r.get(R"(/api/cfg_ids)", [](const Req& req) -> Resp {
        std::string name;
        auto it = req.query.find("name");
        if (it != req.query.end()) name = it->second;
        std::string cfg_name = cfg_name_of(name);
        json items = json::array();
        
        // P7 FIX: 模组有了自己的 cfg 后要合并游戏原版 cfg，让无代码模式能选原版数据
        // 1. 先读模组表
        auto mod_data = read_mod_table(cfg_name);
        // 2. 再读本体表（base_store），未加载则空指针，语义同 Python STATE.base is None
        auto store = base_store();
        std::shared_ptr<const json> base_data;
        if (store && store->available()) {
            auto t = store->table(cfg_name);
            if (t && t->is_object()) base_data = t;
        }
        // 3. 合并：base 在前，mod 在后覆盖（mod 新增或修改的记录优先）
        std::map<std::string, const json*> merged_map;
        if (base_data && base_data->is_object()) {
            for (auto it_base = base_data->begin(); it_base != base_data->end(); ++it_base)
                merged_map[it_base.key()] = &it_base.value();
        }
        if (mod_data && mod_data->is_object()) {
            for (auto it_mod = mod_data->begin(); it_mod != mod_data->end(); ++it_mod)
                merged_map[it_mod.key()] = &it_mod.value();  // mod 覆盖 base
        }
        
        if (!merged_map.empty()) {
            std::vector<std::string> keys;
            keys.reserve(merged_map.size());
            for (const auto& kv : merged_map) keys.push_back(kv.first);
            auto sk = [](const std::string& a, const std::string& b) {
                auto ia = sa_core::py_int(a), ib = sa_core::py_int(b);
                // Python key: (0,int(k),"") for numeric, (1,0,str(k)) otherwise.
                // 同 int 值的两个不同键（"5"/"05"）在 Python 里判等 → 稳定序；
                // 这里返回 false 交给 stable_sort 保插入序，不得再比字符串。
                bool na = ia.has_value(), nb = ib.has_value();
                if (na && nb) return *ia < *ib;
                if (na != nb) return na;  // numeric sorts before non-numeric
                return a < b;
            };
            std::stable_sort(keys.begin(), keys.end(), sk);
            if (keys.size() > 500) keys.resize(500);
            for (auto& k : keys) {
                std::string preview;
                const json* rec = merged_map[k];
                if (rec && rec->is_object()) {
                    for (const char* fld : {"title", "content", "showTxt", "desc"}) {
                        if (!rec->contains(fld) || rec->at(fld).is_null()) continue;
                        std::string sv = sa_core::py_str(rec->at(fld));
                        std::string cleaned;
                        for (char c : sv) if (c != '\r' && c != '\n') cleaned += c;
                        if (!str::trim(cleaned).empty()) {
                            // Python sv[:20] 按码点截，中文 preview 不得腰斩。
                            preview = cp_prefix(cleaned, 20);
                            break;
                        }
                    }
                }
                json entry;
                entry["id"] = k;
                entry["preview"] = preview;
                items.push_back(entry);
            }
        }
        json out;
        out["cfg"] = cfg_name;
        out["items"] = items;
        return Resp::Json(200, std::move(out));
    });

    // GET /api/base_ids?cfg= — api.py:1313-1327.
    r.get(R"(/api/base_ids)", [](const Req& req) -> Resp {
        std::string cfg;
        auto it = req.query.find("cfg");
        if (it != req.query.end()) cfg = it->second;
        auto ids = base_table_ids(cfg);
        std::sort(ids.begin(), ids.end());
        json idarr = json::array();
        for (auto id : ids) idarr.push_back(id);
        bool loaded = false;
        auto store = base_store();
        if (store && store->available()) {
            auto tables = store->loaded_tables();
            loaded = !tables.empty();
        }
        json out;
        out["cfg"] = cfg;
        out["ids"] = idarr;
        out["loaded"] = loaded;
        return Resp::Json(200, std::move(out));
    });

    // GET /api/effect_suggest — api.py:1370-1480.
    r.get(R"(/api/effect_suggest)", [](const Req& req) -> Resp {
        std::string q, mode;
        if (auto it = req.query.find("q"); it != req.query.end()) q = it->second;
        if (auto it = req.query.find("mode"); it != req.query.end()) mode = it->second;
        return Resp::Json(200, effect_suggest_body(q, mode));
    });

    // ---------------- editor shared settings (no-code / appearance / accent) --
    // GET/PUT /api/settings/editor — editor-level switches ALL three frontends
    // consume. `noCodeMode` (bool), `appearanceMode` ("system"|"light"|
    // "dark", 白日模式) and `themeColor` ("#rrggbb" 用户主题色)，persisted as
    // editor_env.json keys `no_code_mode` / `appearance_mode` / `theme_color`
    // (same store as oobe_completed/cli_selected_mod). Unknown
    // or off-whitelist values are ignored — whitelist-strict, env_store_ai style.
    // `meta.appearanceModeExplicit` / `meta.themeColorExplicit` tell a frontend
    // whether the key was ever written: the GUI uses them to seed the backend
    // from a local-only choice instead of overwriting that choice with the
    // default.
    auto appearance_enum = [](const json& env, bool* explicit_out) {
        std::string v = "dark";
        bool explicit_set = false;
        if (env.contains("appearance_mode") && env["appearance_mode"].is_string()) {
            const std::string raw = env["appearance_mode"].get<std::string>();
            if (raw == "system" || raw == "light" || raw == "dark") {
                v = raw;
                explicit_set = true;
            }
        }
        if (explicit_out) *explicit_out = explicit_set;
        return v;
    };
    // 用户主题色：#rrggbb（大小写均收，落盘统一小写）；默认品牌紫。
    auto theme_hex = [](const json& env, bool* explicit_out) {
        std::string v = "#6c5ce7";
        bool explicit_set = false;
        if (env.contains("theme_color") && env["theme_color"].is_string()) {
            const std::string raw = str::lower(env["theme_color"].get<std::string>());
            if (raw.size() == 7 && raw[0] == '#' &&
                raw.substr(1).find_first_not_of("0123456789abcdef") == std::string::npos) {
                v = raw;
                explicit_set = true;
            }
        }
        if (explicit_out) *explicit_out = explicit_set;
        return v;
    };
    auto editor_settings = [appearance_enum, theme_hex] {
        json env = sa_core::env_store::read_editor_env(sa::editor_root());
        bool explicit_appearance = false;
        bool explicit_theme = false;
        json s = json::object();
        s["noCodeMode"] = (env.contains("no_code_mode") && env["no_code_mode"].is_boolean())
                              ? env["no_code_mode"].get<bool>()
                              : false;
        s["appearanceMode"] = appearance_enum(env, &explicit_appearance);
        s["themeColor"] = theme_hex(env, &explicit_theme);
        json out;
        out["settings"] = std::move(s);
        out["meta"] = json{{"appearanceModeExplicit", explicit_appearance},
                           {"themeColorExplicit", explicit_theme}};
        return out;
    };
    r.get(R"(/api/settings/editor)", [editor_settings](const Req&) -> Resp {
        return Resp::Json(200, editor_settings());
    });
    r.put(R"(/api/settings/editor)", [editor_settings, appearance_enum, theme_hex](const Req& req) -> Resp {
        json patch = json::object();
        if (req.body.is_object()) {
            if (req.body.contains("settings") && req.body["settings"].is_object())
                patch = req.body["settings"];
            else
                patch = req.body;
        }
        if (patch.contains("noCodeMode") && patch["noCodeMode"].is_boolean()) {
            sa_core::env_store::merge_editor_env(sa::editor_root(),
                                                 json{{"no_code_mode", patch["noCodeMode"]}});
        }
        if (patch.contains("appearanceMode") && patch["appearanceMode"].is_string()) {
            const std::string want = patch["appearanceMode"].get<std::string>();
            // 只认枚举值：非法写入不改库，但也不报错（与 noCodeMode 同风格）。
            json env = sa_core::env_store::read_editor_env(sa::editor_root());
            const std::string before = appearance_enum(env, nullptr);
            if (want == "system" || want == "light" || want == "dark") {
                if (want != before)
                    sa_core::env_store::merge_editor_env(sa::editor_root(),
                                                         json{{"appearance_mode", want}});
            }
        }
        if (patch.contains("themeColor") && patch["themeColor"].is_string()) {
            const std::string norm =
                str::lower(str::trim(patch["themeColor"].get<std::string>()));
            // 只认 #rrggbb（大小写均收，落盘小写）：非法值同风格静默忽略。
            bool valid = norm.size() == 7 && norm[0] == '#' &&
                         norm.substr(1).find_first_not_of("0123456789abcdef") == std::string::npos;
            if (valid) {
                json env = sa_core::env_store::read_editor_env(sa::editor_root());
                if (norm != theme_hex(env, nullptr))
                    sa_core::env_store::merge_editor_env(sa::editor_root(),
                                                         json{{"theme_color", norm}});
            }
        }
        json out = editor_settings();
        out["ok"] = true;
        return Resp::Json(200, std::move(out));
    });

    // ---------------- usage stats (候选高频/最近使用 backend) ----------------
    // POST /api/usage {kind, key} — one "accepted/executed" bump. kind is
    // whitelisted (see usage::valid_kind); key is trimmed, capped at 200B.
    r.post(R"(/api/usage)", [](const Req& req) -> Resp {
        const json& body = req.body.is_object() ? req.body : kEmptyJson;
        auto gs = [&body](const char* k) -> std::string {
            if (!body.contains(k)) return "";
            const json& v = body[k];
            if (v.is_string()) return str::trim(v.get<std::string>());
            if (v.is_number()) return sa_core::py_str(v);
            return "";
        };
        std::string kind = str::lower(str::trim(gs("kind")));
        std::string key = gs("key");
        if (!usage::valid_kind(kind))
            return Resp::Json(400, json{{"error", "unknown kind: " + kind}});
        if (key.empty()) return Resp::Json(400, json{{"error", "key required"}});
        if (key.size() > 200) key = cp_prefix(key, 200);
        json rec = usage::record(sa::editor_root(), kind, key);
        json out;
        out["ok"] = true;
        out["count"] = rec.contains("count") ? rec["count"] : json(0);
        out["last_ts"] = rec.contains("last_ts") ? rec["last_ts"] : json(0);
        return Resp::Json(200, std::move(out));
    });
    // GET /api/usage?kind=&limit= — {key,count,last_ts} entries, count desc /
    // last_ts desc. limit clamps to [1,200], default 10.
    r.get(R"(/api/usage)", [](const Req& req) -> Resp {
        std::string kind;
        if (auto it = req.query.find("kind"); it != req.query.end())
            kind = str::lower(str::trim(it->second));
        if (!usage::valid_kind(kind))
            return Resp::Json(400, json{{"error", "unknown kind: " + kind}});
        size_t limit = 10;
        if (auto it = req.query.find("limit"); it != req.query.end()) {
            if (auto n = sa_core::py_int(it->second))
                limit = static_cast<size_t>(std::max<long long>(1, std::min<long long>(200, *n)));
        }
        json out;
        out["kind"] = kind;
        out["limit"] = limit;
        out["items"] = usage::top(sa::editor_root(), kind, limit);
        return Resp::Json(200, std::move(out));
    });

    // GET /api/roles?q= — 人物目录：game_dicts.roles（id→中文名）合并工作区
    // PersonCfg（gender + 立绘 key：url2 首项优先，否则 url 首项）。q 按
    // 名字包含 / id 全等过滤；数值 id 按 int 升序在前，其余按字符串序。
    r.get(R"(/api/roles)", [](const Req& req) -> Resp {
        std::string q;
        if (auto it = req.query.find("q"); it != req.query.end()) q = str::trim(it->second);
        const std::string ql = str::lower(q);
        const json& d = p1::dicts();
        json base = d.value("game_dicts", json::object()).value("roles", json::object());
        std::map<std::string, json> by_id;
        for (auto it = base.begin(); it != base.end(); ++it) {
            json r = json::object();
            r["id"] = it.key();
            r["name"] = it.value().is_string() ? it.value() : json(sa_core::py_str(it.value()));
            r["gender"] = nullptr;
            // portrait = 兼容旧字段（url2 优先，否则 url）；portrait1/portrait2
            // 分别对应「小学立绘」(url) 与「中学立绘」(url2)，供人物资源库分阶段展示。
            r["portrait"] = "";
            r["portrait1"] = "";
            r["portrait2"] = "";
            by_id[it.key()] = std::move(r);
        }
        // PersonCfg 分层合并：随包官方表（最低）→ base 抽取表 → 工作区 mod 行
        // （最高），按 id 覆盖整行。网页/托管环境常没有本地 mod；而角色线 mod
        // 往往只带自己改动的少数人物（如「雾起回廊」只含 105 等）。旧实现
        // 「首个非空表整表胜出」会让其余角色的立绘键（portrait*）全空，人物
        // 选择器/人物资源库因此整片显示占位图，且因 key 为空根本不发
        // /api/aa/preview 取图。
        std::map<std::string, json> merged;
        auto add_person_layer = [&](const json& table) {
            if (!table.is_object()) return;
            for (auto it = table.begin(); it != table.end(); ++it) {
                if (it.value().is_object()) merged[it.key()] = it.value();
            }
        };
        add_person_layer(p1::person_cfg());
        if (auto store = base_store(); store && store->available()) {
            auto t = store->table("PersonCfg");
            if (t && t->is_object()) add_person_layer(*t);
        }
        if (auto mod = read_mod_table("PersonCfg"); mod && mod->is_object())
            add_person_layer(*mod);
        {
            auto first_str = [](const json& v) -> std::string {
                if (v.is_array() && !v.empty() && v[0].is_string()) return v[0].get<std::string>();
                return "";
            };
            for (auto& kv : merged) {
                const json& row = kv.second;
                json& slot = by_id[kv.first];
                if (!slot.is_object()) slot = json::object();
                if (!slot.contains("id")) slot["id"] = kv.first;
                if (!slot.contains("name")) slot["name"] = "";
                if (!slot.contains("portrait")) slot["portrait"] = "";
                if (!slot.contains("portrait1")) slot["portrait1"] = "";
                if (!slot.contains("portrait2")) slot["portrait2"] = "";
                if (row.contains("name") && py_truthy(row["name"]))
                    slot["name"] = py_str_or_empty(row["name"]);
                if (row.contains("gender") && row["gender"].is_number()) slot["gender"] = row["gender"];
                std::string p2 = row.contains("url2") ? first_str(row["url2"]) : "";
                std::string p1 = row.contains("url") ? first_str(row["url"]) : "";
                slot["portrait1"] = p1;
                slot["portrait2"] = p2;
                std::string portrait = !p2.empty() ? p2 : p1;
                if (!portrait.empty()) slot["portrait"] = portrait;
                if (!slot.contains("portrait")) slot["portrait"] = "";
            }
        }
        json roles = json::array();
        for (auto& kv : by_id) {
            const json& r = kv.second;
            if (!q.empty()) {
                std::string name_l = str::lower(r.value("name", ""));
                if (kv.first != q && (name_l.empty() || name_l.find(ql) == std::string::npos))
                    continue;
            }
            roles.push_back(r);
        }
        std::sort(roles.begin(), roles.end(), [](const json& a, const json& b) {
            auto keyf = [](const std::string& id) {
                if (auto n = sa_core::py_int(id)) return std::make_tuple(0, *n, std::string());
                return std::make_tuple(1, 0LL, id);
            };
            return keyf(a.value("id", "")) < keyf(b.value("id", ""));
        });
        json out;
        out["roles"] = std::move(roles);
        out["total"] = out["roles"].size();
        return Resp::Json(200, std::move(out));
    });

    // POST /api/effect_validate — api.py:1482-1582.
    r.post(R"(/api/effect_validate)", [](const Req& req) -> Resp {
        const json& body = req.body.is_object() ? req.body : kEmptyJson;
        // Python: str(body.get("text") or "") —— 假值 → ""。
        std::string text = body.contains("text") ? py_str_or_empty(body.at("text"))
                                                 : std::string();
        std::string mode = str::lower(str::trim(
            body.contains("mode") && body.at("mode").is_string() ? body.at("mode").get<std::string>()
                                                                  : std::string("effect")));
        if (mode.empty()) mode = "effect";
        if (!std::set<std::string>{"effect", "condition", "cost", "action", "screen"}.count(mode))
            mode = "effect";
        std::string t = str::trim(text);
        while (!t.empty() && (t.back() == ',' || t.back() == ';' || t.back() == ' ' || t.back() == '\n' ||
                              t.back() == '\t')) t.pop_back();
        json out;
        if (t.empty()) {
            out["valid"] = true; out["translations"] = json::array(); out["errors"] = json::array();
            out["status"] = "empty";
            return Resp::Json(200, out);
        }
        json arr = json::parse("[" + t + "]", nullptr, false);
        if (arr.is_discarded()) {
            out["valid"] = false; out["status"] = "json_error";
            out["message"] = "括号或逗号不匹配"; out["detail"] = "invalid json";
            return Resp::Json(200, out);
        }
        if (mode != "screen" && mode != "action" && arr.is_array() && !arr.empty() && !arr[0].is_array()) {
            std::string s0 = sa_core::py_str(arr[0]);
            std::string d = lstrip_neg(s0);
            bool numeric = std::all_of(d.begin(), d.end(), [](char c) { return c >= '0' && c <= '9'; }) &&
                           !d.empty();
            if (numeric) {
                out["valid"] = false; out["status"] = "missing_outer_bracket";
                out["message"] = "缺少外层方括号，请改为: [ [" + t + "] ]";
                return Resp::Json(200, out);
            }
        }
        json translations = json::array(), errors = json::array();
        if (mode == "cost") {
            for (auto& row : arr) {
                if (!row.is_array()) continue;
                std::string s;
                for (size_t i = 0; i < row.size(); ++i) { if (i) s += ", "; s += sa_core::py_str(row[i]); }
                translations.push_back(s);
            }
            out["valid"] = true; out["translations"] = translations; out["errors"] = errors;
            return Resp::Json(200, out);
        }
        if (mode == "screen" || mode == "action") {
            json rows = norm_effect_rows(arr);
            if (mode == "screen" && rows.is_array() && rows.size() > 1)
                errors.push_back("第 1 行 👉 一句话只能填写一个屏幕效果");
            size_t i = 0;
            for (auto& row : rows) {
                ++i;
                if (!row.is_array()) continue;
                json d = mode == "screen" ? p1::describe_screen_row(row) : p1::describe_action_row(row);
                std::string desc = d.value("desc", "");
                if (desc.empty()) {
                    for (size_t j = 0; j < row.size(); ++j) {
                        if (j) desc += ", ";
                        desc += sa_core::py_str(row[j]);
                    }
                }
                translations.push_back(desc);
                for (auto& er : d.at("errors"))
                    errors.push_back("第 " + std::to_string(i) + " 行 👉 " + er.get<std::string>());
            }
            out["valid"] = errors.empty();
            out["translations"] = translations;
            out["errors"] = errors;
            out["status"] = errors.empty() ? "ok" : "logic_error";
            return Resp::Json(200, out);
        }
        const p1::SecondaryIndex& idx =
            mode == "effect" ? p1::effect_editor_secondary_index() : p1::condition_secondary_index();
        AvailableMap av = game_pools();
        size_t i = 0;
        for (auto& item : arr) {
            ++i;
            if (!item.is_array()) continue;
            json res = p1::validate_secondary_item(item, idx, av);
            translations.push_back(res.value("translation", sa_core::py_str(item)));
            for (auto& er : res.at("errors"))
                errors.push_back("第 " + std::to_string(i) + " 行 👉 " + er.get<std::string>());
        }
        out["valid"] = errors.empty();
        out["translations"] = translations;
        out["errors"] = errors;
        out["status"] = errors.empty() ? "ok" : "logic_error";
        return Resp::Json(200, out);
    });

    // POST /api/bugfix/scan — api.py:2567-2575.
    r.post(R"(/api/bugfix/scan)", [](const Req&) -> Resp {
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            if (STATE().mod_root.empty())
                return Resp::Json(400, json{{"error", "no mod selected"}});
        }
        ModCfgsView view = load_mod_cfgs();
        // D16 FIXED（用户拍板）：Python 生产路径的 MappingProxyType 门已放宽为
        // Mapping（bugfix_service/ref_rules），本侧同步走全语义扫描。
        json bugs = p1::scan_bugs(mod_tables_json(view), base_tables_json(), nullptr);
        for (auto& [cfg, err] : view.broken) bugs.push_back(broken_bug(cfg, err));
        // view.broken is a std::map (sorted by cfg already).
        // 响应路径零拷贝：count 先取，bugs（可达 ~40MB 的响应体）整树 move 进
        // 响应，不再 `out["bugs"] = bugs` 深拷一次；键序保持 bugs→count 不变，
        // wire 上的 json→string 序列化由 httpd 恰好做一次（py_dumps）。
        const long long count = static_cast<long long>(bugs.size());
        json out;
        out["bugs"] = std::move(bugs);
        out["count"] = count;
        return Resp::Json(200, std::move(out));
    });

    // POST /api/bugfix/fix — api.py:2577-2630 (A11 scan once; B9 in apply_fix;
    // G3/B1 fork-then-write; write-back strictly via cfg_store).
    r.post(R"(/api/bugfix/fix)", [](const Req& req) -> Resp {
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            if (STATE().mod_root.empty())
                return Resp::Json(400, json{{"error", "no mod selected"}});
        }
        // 零拷贝读请求体：绑定共享只读空对象（写 json::object() 会让三目退回
        // prvalue，客户端回传的 bugs 列表会被整树拷贝一次）。
        const json& body = req.body.is_object() ? req.body : kEmptyJson;
        ModCfgsView view = load_mod_cfgs();
        json base_data = base_tables_json();
        // 首次扫描同 scan 路由（D16 修复后全语义）；A11 的 touched 重扫用私有
        // fork ——两条路径现在语义一致，见 semantic_logic.h 注释。
        json bugs = p1::scan_bugs(mod_tables_json(view), base_data, nullptr);
        // D10：Python 在索引/匹配/remaining 之前就把坏表 ERROR 条目并入 bugs
        // （_report_broken_tables(bugs)），随后 remaining 末尾**再**并入一次——
        // remaining 里 broken 条目出现两次是 api.py 的真实行为，照抄。
        for (auto& [cfg, err] : view.broken) bugs.push_back(broken_bug(cfg, err));

        // targets 只读：两个分支都是 lvalue，const& 绑定零拷贝（客户端列表不
        // 拷、本地扫描结果也不拷）。
        const json& targets =
            (body.contains("bugs") && !body.at("bugs").is_null()) ? body.at("bugs") : bugs;
        // A11: pre-index (cfg,id,key) -> bug once (later dup overwrites, dict-comp 语义).
        // 客户端回传 bug 的字段可能是 null/数字（不受控），逐字段取原始值再 str()，
        // 不能用 json::value(key,"")——类型不符会抛 type_error 变 500。
        std::map<std::string, size_t> by_key;
        auto field_str = [](const json& b, const char* k) -> std::string {
            if (!b.is_object() || !b.contains(k)) return std::string();
            const json& v = b.at(k);
            if (v.is_null()) return std::string();
            return v.is_string() ? v.get<std::string>() : sa_core::py_str(v);
        };
        auto bug_key = [&](const json& b) {
            return field_str(b, "cfg") + "\x1f" + field_str(b, "id") + "\x1f" +
                   field_str(b, "key");
        };
        for (size_t i = 0; i < bugs.size(); ++i)
            if (bugs[i].is_object()) by_key[bug_key(bugs[i])] = i;
        // matched 只是指向 bugs 元素的只读指针（A11 索引阶段之后 bugs 不再
        // 变异），逐条 push_back 拷贝纯浪费。
        std::vector<const json*> matched;
        if (targets.is_array())
            for (const auto& bug : targets) {
                if (!bug.is_object()) continue;
                auto it = by_key.find(bug_key(bug));
                if (it != by_key.end()) matched.push_back(&bugs[it->second]);
            }

        std::set<std::string> fix_cfgs, touched;
        bool need_pair = false;
        for (const json* mbug : matched) {
            std::string c = mbug->value("cfg", "");
            if (!c.empty()) fix_cfgs.insert(c);
            std::string flag = mbug->value("flag", "");
            if (flag == "FIX_OPTION_1" || flag == "FIX_TALK_1") need_pair = true;
        }
        if (need_pair) { fix_cfgs.insert("TalkCfg"); fix_cfgs.insert("OptionCfg"); }
        json private_tables = json::object();
        for (const auto& c : fix_cfgs) private_tables[c] = fork_mod_table(c);

        long long fixed = 0;
        for (const json* mbug : matched) {
            if (p1::apply_fix(private_tables, *mbug)) {
                fixed++;
                std::string c = mbug->value("cfg", "");
                if (!c.empty()) touched.insert(c);
                std::string flag = mbug->value("flag", "");
                if (flag == "FIX_OPTION_1" || flag == "FIX_TALK_1") {
                    touched.insert("TalkCfg");
                    touched.insert("OptionCfg");
                }
            }
        }
        for (const auto& cfg : touched) {
            std::string path = try_cfg_path(cfg);
            if (path.empty()) continue;
            // 零拷贝读 fork 表：write_cfg/after_write 都只收 const&，无需把整张
            // fork 表再深拷一次（缺表时绑共享空对象，不落 prvalue）。
            const json& data =
                private_tables.contains(cfg) ? private_tables[cfg] : kEmptyJson;
            json result = cfg_store::write_cfg(path, data, std::nullopt, nullptr, false, true);
            // D11：_save_mod_cfg 失败 raise OSError → 传输层 500（不静默吞写失败）。
            if (!result.value("ok", false)) {
                std::string msg = result.contains("error") ? sa_core::py_str(result.at("error"))
                                                           : std::string();
                if (msg.empty()) msg = "配置表写入失败";
                throw ApiError("OSError", msg);
            }
            after_write(cfg, path, data, result);
        }

        json remaining = json::array();
        // bugs 之后不再使用（A11 重扫读的是 private_tables）：留下来的条目直接
        // move 进 remaining，免掉逐条深拷。
        for (auto& b : bugs)
            if (b.is_object() && !touched.count(b.value("cfg", ""))) remaining.push_back(std::move(b));
        if (!touched.empty()) {
            // A11: only rescan touched tables against their (already forked) data.
            json re = p1::scan_bugs(private_tables, base_data, &touched);
            for (auto& b : re) remaining.push_back(std::move(b));
        }
        for (auto& [cfg, err] : view.broken) remaining.push_back(broken_bug(cfg, err));
        // 响应路径零拷贝：count 先取，remaining 整树 move 进响应；键序保持
        // fixed→remaining→remaining_count 与 api.py 字典序一致。
        const long long remaining_count = static_cast<long long>(remaining.size());
        json out;
        out["fixed"] = fixed;
        out["remaining"] = std::move(remaining);
        out["remaining_count"] = remaining_count;
        return Resp::Json(200, std::move(out));
    });

    // 只读分析三端点（/api/effect/parse、/api/graph/relations、/api/graph/timeline）
    // 实现在 semantic_graph.cpp；此处统一挂进 P1 语义族（api_router.cpp 不动）。
    register_semantic_graph(r);
}

}  // namespace sa
