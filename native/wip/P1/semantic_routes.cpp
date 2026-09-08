// wip/P1/semantic_routes.cpp — wave-2 P1: schema/dicts/validate/cfg_ids/base_ids/
// effect_suggest/effect_validate/bugfix scan+fix. Port of api.py:1219-1615 +
// 2567-2631 over the semantic engines in semantic_core/semantic_bugfix.
#include "semantic_routes.h"

#include <algorithm>
#include <cstdint>
#include <regex>
#include <set>
#include <string>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "semantic_assets.h"
#include "semantic_logic.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/perf.h"
#include "server/services/stores_api.h"
#include "server/state.h"

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

    std::vector<json> out;
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
        if (!has_text && chunks.empty() && qn.empty()) {
            // keep
        } else if (!has_text && !nums.empty()) {
            bool any = false;
            for (auto& n : nums) if (target.find(n) != std::string::npos) { any = true; break; }
            if (!any && count_upper_alpha(code) == 0) continue;
        }
        out.push_back(item);
        if (static_cast<int>(out.size()) >= limit) break;
    }
    if (out.empty() && !qn.empty()) {
        out.clear();
        for (size_t i = 0; i < db->size() && i < 15; ++i) out.push_back((*db)[i]);
    }

    bool skip_render = (mode == "action" || mode == "screen");
    json rendered = json::array();
    for (auto& mi : out) {
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

// scan/fix 共用：只读视图 → 普通 json 表集（scan_bugs 纯读，拷贝即 G3 隔离）。
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
        const json& body = req.body.is_object() ? req.body : json::object();
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
        auto data = read_mod_table(cfg_name);
        if (data && data->is_object()) {
            std::vector<std::string> keys;
            for (auto k = data->begin(); k != data->end(); ++k) keys.push_back(k.key());
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
                const json& rec = (*data)[k];
                if (rec.is_object()) {
                    for (const char* fld : {"title", "content", "showTxt", "desc"}) {
                        if (!rec.contains(fld) || rec[fld].is_null()) continue;
                        std::string sv = sa_core::py_str(rec[fld]);
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

    // POST /api/effect_validate — api.py:1482-1582.
    r.post(R"(/api/effect_validate)", [](const Req& req) -> Resp {
        const json& body = req.body.is_object() ? req.body : json::object();
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
        // read_only_view=true：复刻 Python 生产路径 MappingProxyType 输入下的
        // isinstance(dict) 门（见 semantic_logic.h 注释），与 api.py 行为逐条等价。
        json bugs = p1::scan_bugs(mod_tables_json(view), base_tables_json(), nullptr, true);
        for (auto& [cfg, err] : view.broken) bugs.push_back(broken_bug(cfg, err));
        // view.broken is a std::map (sorted by cfg already).
        json out;
        out["bugs"] = bugs;
        out["count"] = static_cast<long long>(bugs.size());
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
        const json body = req.body.is_object() ? req.body : json::object();
        ModCfgsView view = load_mod_cfgs();
        json base_data = base_tables_json();
        // 首次扫描同 scan 路由（只读代理门）；A11 的 touched 重扫用私有 fork
        // （Python 里是普通 dict，全语义生效）——见 semantic_logic.h 注释。
        json bugs = p1::scan_bugs(mod_tables_json(view), base_data, nullptr, true);
        // D10：Python 在索引/匹配/remaining 之前就把坏表 ERROR 条目并入 bugs
        // （_report_broken_tables(bugs)），随后 remaining 末尾**再**并入一次——
        // remaining 里 broken 条目出现两次是 api.py 的真实行为，照抄。
        for (auto& [cfg, err] : view.broken) bugs.push_back(broken_bug(cfg, err));

        json targets =
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
        json matched = json::array();
        if (targets.is_array())
            for (const auto& bug : targets) {
                if (!bug.is_object()) continue;
                auto it = by_key.find(bug_key(bug));
                if (it != by_key.end()) matched.push_back(bugs[it->second]);
            }

        std::set<std::string> fix_cfgs, touched;
        bool need_pair = false;
        for (const auto& mbug : matched) {
            std::string c = mbug.value("cfg", "");
            if (!c.empty()) fix_cfgs.insert(c);
            std::string flag = mbug.value("flag", "");
            if (flag == "FIX_OPTION_1" || flag == "FIX_TALK_1") need_pair = true;
        }
        if (need_pair) { fix_cfgs.insert("TalkCfg"); fix_cfgs.insert("OptionCfg"); }
        json private_tables = json::object();
        for (const auto& c : fix_cfgs) private_tables[c] = fork_mod_table(c);

        long long fixed = 0;
        for (const auto& mbug : matched) {
            if (p1::apply_fix(private_tables, mbug)) {
                fixed++;
                std::string c = mbug.value("cfg", "");
                if (!c.empty()) touched.insert(c);
                std::string flag = mbug.value("flag", "");
                if (flag == "FIX_OPTION_1" || flag == "FIX_TALK_1") {
                    touched.insert("TalkCfg");
                    touched.insert("OptionCfg");
                }
            }
        }
        for (const auto& cfg : touched) {
            std::string path = try_cfg_path(cfg);
            if (path.empty()) continue;
            json data = private_tables.contains(cfg) ? private_tables[cfg] : json::object();
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
        for (const auto& b : bugs)
            if (b.is_object() && !touched.count(b.value("cfg", ""))) remaining.push_back(b);
        if (!touched.empty()) {
            // A11: only rescan touched tables against their (already forked) data.
            json re = p1::scan_bugs(private_tables, base_data, &touched);
            for (auto& b : re) remaining.push_back(b);
        }
        for (auto& [cfg, err] : view.broken) remaining.push_back(broken_bug(cfg, err));
        json out;
        out["fixed"] = fixed;
        out["remaining"] = remaining;
        out["remaining_count"] = static_cast<long long>(remaining.size());
        return Resp::Json(200, std::move(out));
    });
}

}  // namespace sa
