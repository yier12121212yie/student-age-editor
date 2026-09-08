// wip/P3b — see p3b_domain_service.h for the contract (port of
// ai_domain_service.py). Line refs are to the Python original.
#include "p3b_domain_service.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <set>
#include <string_view>
#include <vector>

#include "p3b_domain_table.h"
#include "p3b_fs_tools.h"
#include "p3b_support.h"
#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/httpd.h"
#include "server/state.h"

namespace sa {
namespace p3b {
namespace {

namespace cs = sa_core::paths;

bool py_truthy(const json& v) { return json_truthy(v); }

// str(v): see p3b_support::json_str deviation note.
std::string py_json_str(const json& v) { return json_str(v); }

// v or fallback (Python `x or y`). Returned by value: callers feed
// temporaries (json("")) as the fallback.
json py_or(const json& v, const json& fallback) { return py_truthy(v) ? v : fallback; }

std::string ascii_lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// float(str) with CPython tolerance (shared helper).
std::optional<double> py_float(std::string_view sv) { return py_float_str(sv); }

// json.dumps(obj, ensure_ascii=False, sort_keys=True) — the update_domain_item
// before/after fingerprint. Recursive key sort, CPython float repr via
// py_dumps leaves.
std::string canon_dump(const json& v) {
    if (v.is_object()) {
        std::vector<std::string> keys;
        for (auto it = v.begin(); it != v.end(); ++it) keys.push_back(it.key());
        std::sort(keys.begin(), keys.end());
        std::string out = "{";
        bool first = true;
        for (const auto& k : keys) {
            if (!first) out += ", ";
            first = false;
            out += sa_core::py_dumps(json(k)) + ": " + canon_dump(v.at(k));
        }
        return out + "}";
    }
    if (v.is_array()) {
        std::string out = "[";
        for (size_t i = 0; i < v.size(); ++i) {
            if (i) out += ", ";
            out += canon_dump(v[i]);
        }
        return out + "]";
    }
    return sa_core::py_dumps(v);
}

// ---- _cfg_path / load / save ------------------------------------------------

// ai_domain_service._cfg_path: STATE cfg dir + _norm(cfg + ".json"); the
// no-mod error text here is the service's own ("未选择模组", NOT api.py's
// English "no mod selected" — two distinct helpers in Python).
std::string domain_cfg_path(const std::string& cfg_name) {
    const std::string d = sa::cfg_dir();
    if (d.empty()) throw SandboxError("未选择模组");
    const std::string rel = norm_rel(cfg_name + ".json");
    return cs::join(d, rel);
}

SandboxError missing_cfg_error(const std::string& cfg) {
    return SandboxError(
        "当前模组还没有 " + cfg +
        " 配置表（" + cfg +
        ".json 不存在，通常是因为还没有创建过任何条目）。"
        "如需新建条目请用 create_domain_item（会自动创建该表）；"
        "如需确认已有条目可先用 list_domain_items 查看。");
}

std::string table_not_in_domain_error(const std::string& cfg, const std::string& dom_name) {
    return "表 " + cfg + " 不属于领域 " + dom_name;
}

// cfg -> cn accumulated across domains (setdefault semantics, domain order).
const std::map<std::string, std::string>& table_cn() {
    static const std::map<std::string, std::string> kMap = [] {
        std::map<std::string, std::string> m;
        for (const auto& d : ai_domains()) {
            for (const auto& kv : d.tables) m.emplace(kv.first, kv.second);
        }
        return m;
    }();
    return kMap;
}

const std::set<std::string>& assigned_cfgs() {
    static const std::set<std::string> kSet = [] {
        std::set<std::string> s;
        for (const auto& d : ai_domains()) {
            for (const auto& kv : d.tables) s.insert(kv.first);
        }
        return s;
    }();
    return kSet;
}

std::string table_cn_for(const std::string& cfg) {
    const auto& m = table_cn();
    auto it = m.find(cfg);
    return it != m.end() ? it->second : auto_cn(cfg);
}

// _field_cn(cfg, field)
std::string field_cn_for(const std::string& cfg, const std::string& field) {
    const auto& fc = field_cn();
    auto it = fc.find(field);
    if (it != fc.end()) return it->second;
    const json& schema = game_schema();
    if (schema.is_object() && schema.contains(cfg) && schema.at(cfg).is_object() &&
        schema.at(cfg).contains(field) && schema.at(cfg).at(field).is_string()) {
        return schema.at(cfg).at(field).get<std::string>();
    }
    return field;
}

// _match_role_id_by_name: ROLE_DICT + mod PersonCfg overlay, exact name hit.
std::optional<json> match_role_id_by_name(const std::string& raw_name) {
    const std::string name = py_strip(raw_name);
    if (name.empty()) return std::nullopt;
    std::vector<std::pair<std::string, std::string>> candidates;  // ordered dict
    auto set_candidate = [&](const std::string& rid, const std::string& rname) {
        for (auto& c : candidates) {
            if (c.first == rid) {
                c.second = rname;
                return;
            }
        }
        candidates.emplace_back(rid, rname);
    };
    const json& rd = role_dict();
    if (rd.is_object()) {
        for (auto it = rd.begin(); it != rd.end(); ++it) {
            set_candidate(it.key(), py_json_str(it.value()));
        }
    }
    try {
        if (cfg_exists("PersonCfg")) {
            const json data = load_cfg("PersonCfg");
            for (auto it = data.begin(); it != data.end(); ++it) {
                if (!it.value().is_object()) continue;
                const json nv = it.value().contains("name") ? it.value().at("name") : json();
                const std::string s = py_strip(py_json_str(py_or(nv, json(""))));
                if (!s.empty()) set_candidate(it.key(), s);
            }
        }
    } catch (const SandboxError&) {
        // except SandboxError: pass
    }
    for (const auto& c : candidates) {
        if (c.second == name) {
            bool all_digits = !c.first.empty();
            for (char ch : c.first) {
                if (ch < '0' || ch > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                auto iv = sa_core::py_int(c.first);
                if (iv && std::to_string(*iv) == c.first) return json(*iv);
            }
            return json(c.first);
        }
    }
    return std::nullopt;
}

// _ensure_content_role(cfg, record) — content-ownership backstop.
void ensure_content_role(const std::string& cfg, json& record) {
    if (!record.is_object()) return;
    if (cfg == "TalkCfg") {
        const json rn = record.contains("roleName") ? record.at("roleName") : json();
        const std::string role_name = py_strip(py_json_str(py_or(rn, json(""))));
        const json ri = record.contains("roleIds") ? record.at("roleIds") : json();
        if (role_name.empty() || py_truthy(ri)) return;
        auto matched = match_role_id_by_name(role_name);
        if (!matched) {
            throw SandboxError(
                "对白（TalkCfg）的说话人群组 roleIds 为必填，不能只填 roleName（自定义名字）。"
                "你填的自定义名字「" +
                role_name +
                "」不在角色字典中：请先用 get_game_dicts(name=roles, q=" +
                role_name +
                ") 查询该角色的 ID 并补上 roleIds=[ID]；若想新增角色请先创建 PersonCfg 条目，"
                "或用已有角色 ID 配合 roleName 显示自定义名字。");
        }
        record["roleIds"] = json::array({*matched});
        return;
    }
    std::string role_field;
    if (cfg == "PhoneMsgCfg" || cfg == "KZoneContentCfg") {
        role_field = "role";
    } else if (cfg == "KZoneCommentCfg") {
        role_field = "roles";
    } else {
        return;
    }
    const json content_v = record.contains("content") ? record.at("content") : json();
    const bool has_content = !py_strip(py_json_str(py_or(content_v, json("")))).empty();
    const json role_v = record.contains(role_field) ? record.at(role_field) : json();
    const bool role_empty = role_v.is_null() || (role_v.is_string() && role_v.empty()) ||
                            (role_v.is_array() && role_v.empty());
    if (!has_content || !role_empty) return;
    throw SandboxError("条目（" + cfg + "）的 " + role_field +
                       "（发送者/发布者角色）为必填，不能只填内容。"
                       "请先用 get_game_dicts(name=roles, q=角色名) 查询发送角色的 ID，再补上 " +
                       role_field + "=ID。");
}

// _entry_summary(cfg, key, record)
json entry_summary(const std::string& cfg, const std::string& key, const json& record) {
    json out = json::object();
    out["cfg"] = cfg;
    out["id"] = key;
    if (!record.is_object()) {
        out["name"] = utf8_head(py_json_str(record), 60);
        out["summary"] = "";
        return out;
    }
    std::string name;
    for (const char* nf : {"name", "title", "content", "desc", "girlTalk", "text", "boyTalk"}) {
        if (!record.contains(nf) || !record.at(nf).is_string()) continue;
        const std::string stripped = py_strip(record.at(nf).get<std::string>());
        if (!stripped.empty()) {
            name = stripped;
            break;
        }
    }
    std::string summary;
    for (const char* sf : {"desc", "note", "content", "text", "talk"}) {
        if (!record.contains(sf) || !record.at(sf).is_string()) continue;
        std::string stripped = py_strip(record.at(sf).get<std::string>());
        if (!stripped.empty()) {
            summary = utf8_head(sa_core::str::replace_all(stripped, "\n", " "), 120);
            break;
        }
    }
    out["name"] = utf8_head(name, 80);
    out["summary"] = summary;
    return out;
}

}  // namespace

// ---------------------------------------------------------------------------
// _split_camel / _auto_cn
// ---------------------------------------------------------------------------

std::string split_camel(const std::string& name) {
    // re.findall(r"[A-Z][a-z0-9]*|[a-z0-9]+", name) joined by " ", lowered.
    std::string out;
    size_t i = 0;
    while (i < name.size()) {
        const char c = name[i];
        if (c >= 'A' && c <= 'Z') {
            size_t j = i + 1;
            while (j < name.size() &&
                   ((name[j] >= 'a' && name[j] <= 'z') || (name[j] >= '0' && name[j] <= '9')))
                ++j;
            if (!out.empty()) out += ' ';
            out += name.substr(i, j - i);
            i = j;
        } else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            size_t j = i + 1;
            while (j < name.size() &&
                   ((name[j] >= 'a' && name[j] <= 'z') || (name[j] >= '0' && name[j] <= '9')))
                ++j;
            if (!out.empty()) out += ' ';
            out += name.substr(i, j - i);
            i = j;
        } else {
            ++i;  // regex drops anything else (underscores, CJK, ...)
        }
    }
    return ascii_lower(sa_core::str::trim(out));
}

std::string auto_cn(const std::string& cfg_name) {
    std::string base = cfg_name;
    // Both suffix passes run in order ("Cfg" then "Define") — no early break:
    // a "FooDefineCfg" style name loses both endings in Python.
    for (const char* suffix : {"Cfg", "Define"}) {
        const size_t sl = std::string_view(suffix).size();
        if (base.size() > sl && base.compare(base.size() - sl, sl, suffix) == 0) {
            base = base.substr(0, base.size() - sl);
        }
    }
    if (base.empty()) return cfg_name;
    return split_camel(base) + "配置";
}

// ---------------------------------------------------------------------------
// get_domains / get_domain / _cfg_in_domain
// ---------------------------------------------------------------------------

json get_domains() {
    json out = json::array();
    for (const auto& d : ai_domains()) {
        json tables = json::object();
        std::vector<std::pair<std::string, std::string>> sorted_tables(d.tables.begin(),
                                                                       d.tables.end());
        std::sort(sorted_tables.begin(), sorted_tables.end(),
                  [](const auto& a, const auto& b) { return a.first < b.first; });
        for (const auto& kv : sorted_tables) tables[kv.first] = table_cn_for(kv.first);
        json dom = json::object();
        dom["id"] = d.id;
        dom["name"] = d.name;
        dom["desc"] = d.desc;
        dom["tables"] = std::move(tables);
        out.push_back(std::move(dom));
    }
    json fb_tables = json::object();
    const json& schema = game_schema();
    std::vector<std::string> remaining;
    if (schema.is_object()) {
        for (auto it = schema.begin(); it != schema.end(); ++it) {
            if (assigned_cfgs().count(it.key()) == 0) remaining.push_back(it.key());
        }
    }
    std::sort(remaining.begin(), remaining.end());
    for (const auto& cfg : remaining) fb_tables[cfg] = table_cn_for(cfg);
    json fb = json::object();
    fb["id"] = "table";
    fb["name"] = "通用配置";
    fb["desc"] = "未归入上述领域的其他配置表（兜底）";
    fb["tables"] = std::move(fb_tables);
    out.push_back(std::move(fb));
    return out;
}

json get_domain(const std::string& domain_id) {
    const json doms = get_domains();
    for (const auto& d : doms) {
        if (d.value("id", "") == domain_id) return d;
    }
    throw SandboxError("未知领域: " + domain_id + "（可用领域见 /api/ai/domains）");
}

bool cfg_in_domain(const std::string& domain_id, const std::string& cfg) {
    if (domain_id == "table") {
        const json& schema = game_schema();
        return schema.is_object() && schema.contains(cfg) && assigned_cfgs().count(cfg) == 0;
    }
    const json dom = get_domain(domain_id);
    return dom.at("tables").contains(cfg);
}

// ---------------------------------------------------------------------------
// load_cfg / cfg_exists / save_cfg
// ---------------------------------------------------------------------------

json load_cfg(const std::string& cfg_name) {
    const std::string path = domain_cfg_path(cfg_name);
    if (!cs::is_file(path)) {
        throw SandboxError("配置表不存在: " + cfg_name + ".json");
    }
    auto raw = cs::read_bytes(path);
    if (!raw) {
        throw SandboxError("配置表 " + cfg_name + " 读取失败: [Errno 2] No such file or directory");
    }
    // open(encoding="utf-8-sig"): BOM stripped, strict utf-8; failure and
    // parse failure both funnel into "读取失败: %s" (message text approximated:
    // Python embeds the ValueError/UnicodeDecodeError str).
    auto text = sa_core::decode_utf8_sig_strict(*raw);
    if (!text) {
        throw SandboxError("配置表 " + cfg_name + " 读取失败: 'utf-8' codec can't decode byte");
    }
    json parsed = json::parse(*text, nullptr, false);
    if (parsed.is_discarded()) {
        throw SandboxError("配置表 " + cfg_name + " 读取失败: JSON parse error");
    }
    if (!parsed.is_object()) {
        throw SandboxError("配置表 " + cfg_name + " 结构异常：顶层应为 JSON 对象");
    }
    return parsed;
}

bool cfg_exists(const std::string& cfg_name) {
    return cs::is_file(domain_cfg_path(cfg_name));
}

void save_cfg(const std::string& cfg_name, const json& data) {
    const std::string path = domain_cfg_path(cfg_name);
    // 滚动 1 份 .bak（双保险；备份失败不阻塞写入）
    if (cs::is_file(path)) {
        if (auto cur = cs::read_bytes(path)) {
            cs::write_bytes_simple(path + ".bak", *cur);  // best-effort like Python
        }
    }
    json result = cfg_store::write_cfg(path, data, std::nullopt, nullptr, false, true);
    if (!result.value("ok", false)) {
        std::string err = result.value("error", std::string());
        // save_cfg raises OSError on a failed write_cfg result.
        throw ApiError("OSError", err.empty() ? "配置表写入失败" : err);
    }
    // AI 改模安全底线：与 /api/cfg PUT 同款的写成功四连（简报 §2），保证
    // 大表缓存与 mod 全表视图在 AI 通路下同样即时一致。
    const std::optional<long long> mtime =
        result.contains("mtime_ns") && result.at("mtime_ns").is_number()
            ? std::optional<long long>(result.at("mtime_ns").get<long long>())
            : std::nullopt;
    invalidate_table_cache(path);
    seed_table_cache(path, cfg_name, data, mtime);
    note_mod_cfgs_write(cfg_name, data, path);
    invalidate_preview_cache();
}

// ---------------------------------------------------------------------------
// _coerce_patch
// ---------------------------------------------------------------------------

json coerce_patch(const std::string& cfg, const json& patch) {
    const json& schema = game_schema();
    const json* entry = nullptr;
    if (schema.is_object() && schema.contains(cfg) && schema.at(cfg).is_object()) {
        entry = &schema.at(cfg);
    }
    if (entry == nullptr || entry->empty()) {
        const bool meta_like =
            sa_core::str::ends_with(cfg, "Define") || sa_core::str::ends_with(cfg, "Attribute");
        throw SandboxError("表 " + cfg +
                           " 在游戏 schema 中无字段定义（" +
                           std::string(meta_like ? "元数据/空表" : "全局配置表") +
                           "），无法安全校验字段，请勿通过 AI 直接修改");
    }
    json out = json::object();
    for (auto it = patch.begin(); it != patch.end(); ++it) {
        const std::string& k = it.key();
        const json& v = it.value();
        if (!entry->contains(k)) {
            std::vector<std::string> keys;
            for (auto s = entry->begin(); s != entry->end(); ++s) keys.push_back(s.key());
            std::sort(keys.begin(), keys.end());
            if (keys.size() > 30) keys.resize(30);
            std::string joined;
            for (size_t i = 0; i < keys.size(); ++i) {
                if (i) joined += "、";
                joined += keys[i];
            }
            throw SandboxError("表 " + cfg + " 的字段 " + k + " 不在 schema 中（允许字段: " +
                               (joined.empty() ? std::string("无") : joined) + "）");
        }
        const json& tv = entry->at(k);
        const std::string ftype = tv.is_string() ? tv.get<std::string>() : py_json_str(tv);
        if (ftype == "Number") {
            if (v.is_boolean() || !(v.is_number() || v.is_string())) {
                throw SandboxError("字段 " + k + " 应为数值，收到: " + py_repr(v));
            }
            if (v.is_number()) {
                out[k] = v;
            } else {
                auto f = py_float(v.get<std::string>());
                if (!f) throw SandboxError("字段 " + k + " 应为数值，收到: " + py_repr(v));
                out[k] = *f;
            }
        } else if (ftype == "String") {
            if (v.is_boolean() || v.is_object() || v.is_array()) {
                throw SandboxError("字段 " + k + " 应为字符串，收到: " + py_repr(v));
            }
            out[k] = v;  // Python keeps non-str scalars as-is (code, not docstring)
        } else if (ftype.find("Array") != std::string::npos) {
            json val = v;
            if (val.is_string()) {
                auto parsed = json::parse(val.get<std::string>(), nullptr, false);
                if (parsed.is_discarded()) {
                    throw SandboxError("字段 " + k + " 应为数组（JSON），收到: " + py_repr(v));
                }
                val = std::move(parsed);
            }
            if (!val.is_array()) {
                throw SandboxError("字段 " + k + " 应为数组，收到: " + py_repr(val));
            }
            out[k] = std::move(val);
        } else {
            out[k] = v;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// entry-level ops
// ---------------------------------------------------------------------------

json list_domain_items(const std::string& domain_id, const json& q_arg, const json& limit_arg,
                       const json& table_arg) {
    const json dom = get_domain(domain_id);
    const bool table_given = !table_arg.is_null();
    const bool table_used = table_given && table_arg.is_string() && py_truthy(table_arg);
    std::string table_name;
    std::vector<std::string> cfgs;
    if (table_used) {
        table_name = table_arg.get<std::string>();
        cfgs.push_back(table_name);
    } else {
        for (auto it = dom.at("tables").begin(); it != dom.at("tables").end(); ++it) {
            cfgs.push_back(it.key());
        }
        // Python: `table is not None and not _cfg_in_domain(domain, table)` —
        // an EMPTY string table still runs the membership check and fails.
        if (table_given) table_name = table_arg.is_string() ? table_arg.get<std::string>()
                                                            : py_json_str(table_arg);
    }
    if (table_given && !cfg_in_domain(domain_id, table_name)) {
        throw SandboxError(table_not_in_domain_error(table_name, dom.value("name", "")));
    }
    // limit = max(1, min(int(limit or 50), 200)); int() failure -> ValueError 500.
    long long limit = 50;
    if (py_truthy(limit_arg)) {
        long long parsed = -1;
        bool ok = false;
        if (limit_arg.is_number()) {
            parsed = static_cast<long long>(limit_arg.get<double>());
            ok = true;
        } else {
            auto iv = sa_core::py_int(py_json_str(limit_arg));
            if (iv) {
                parsed = *iv;
                ok = true;
            }
        }
        if (!ok) {
            throw ApiError("ValueError", "invalid literal for int() with base 10: " +
                                             py_repr(limit_arg));
        }
        limit = parsed;
    }
    limit = std::max(1LL, std::min(limit, 200LL));
    const std::string q = ascii_lower(py_strip(py_json_str(py_or(q_arg, json("")))));

    json out_items = json::array();
    bool capped = false;
    for (const auto& cfg : cfgs) {
        json data;
        try {
            data = load_cfg(cfg);
        } catch (const SandboxError&) {
            continue;  // 表不存在时跳过（模组通常只带部分表）
        }
        for (auto it = data.begin(); it != data.end(); ++it) {
            const json item = entry_summary(cfg, it.key(), it.value());
            if (!q.empty()) {
                bool hit = ascii_lower(item.value("id", "")).find(q) != std::string::npos ||
                           ascii_lower(item.value("name", "")).find(q) != std::string::npos ||
                           ascii_lower(item.value("summary", "")).find(q) != std::string::npos;
                if (!hit && it.value().is_object()) {
                    size_t seen = 0;
                    for (auto vt = it.value().begin(); vt != it.value().end() && seen < 8;
                         ++vt, ++seen) {
                        if (ascii_lower(py_json_str(vt.value())).find(q) != std::string::npos) {
                            hit = true;
                            break;
                        }
                    }
                }
                if (!hit) continue;
            }
            out_items.push_back(item);
            if (static_cast<long long>(out_items.size()) >= limit) {
                capped = true;
                break;  // Python returns from inside the loop
            }
        }
        if (capped) break;
    }
    json out = json::object();
    out["domain"] = dom.value("id", "");
    out["q"] = q;
    out["items"] = std::move(out_items);
    return out;
}

json get_domain_item(const std::string& domain_id, const std::string& cfg, const json& key_arg) {
    if (!cfg_in_domain(domain_id, cfg)) {
        throw SandboxError(table_not_in_domain_error(cfg, get_domain(domain_id).value("name", "")));
    }
    if (!cfg_exists(cfg)) throw missing_cfg_error(cfg);
    const json data = load_cfg(cfg);
    const std::string key = py_json_str(key_arg);
    if (!data.contains(key)) {
        throw SandboxError("表 " + cfg + " 中不存在 id=" + key + "（可用 list_domain_items 查看）");
    }
    const json record = data.at(key);
    json fields = json::array();
    if (record.is_object()) {
        for (auto it = record.begin(); it != record.end(); ++it) {
            fields.push_back(field_cn_for(cfg, it.key()));
        }
    }
    json out = json::object();
    out["domain"] = domain_id;
    out["cfg"] = cfg;
    out["cfg_cn"] = table_cn_for(cfg);
    out["id"] = key;
    out["data"] = record;
    out["fields"] = std::move(fields);
    return out;
}

json update_domain_item(const std::string& domain_id, const std::string& cfg, const json& key_arg,
                        const json& patch) {
    if (!patch.is_object() || patch.empty()) {
        throw SandboxError("patch 必须是非空对象");
    }
    if (!cfg_in_domain(domain_id, cfg)) {
        throw SandboxError(table_not_in_domain_error(cfg, get_domain(domain_id).value("name", "")));
    }
    if (!cfg_exists(cfg)) throw missing_cfg_error(cfg);
    json data = load_cfg(cfg);
    const std::string key = py_json_str(key_arg);
    if (!data.contains(key)) {
        throw SandboxError("表 " + cfg + " 中不存在 id=" + key);
    }
    json& record = data[key];
    if (!record.is_object()) {
        throw SandboxError("表 " + cfg + " 的 id=" + key + " 不是对象，无法字段级修改");
    }
    const json coerced = coerce_patch(cfg, patch);
    const std::string before = canon_dump(record);
    for (auto it = coerced.begin(); it != coerced.end(); ++it) record[it.key()] = it.value();
    ensure_content_role(cfg, record);  // may raise before the write happens
    const std::string after = canon_dump(record);
    json out = json::object();
    out["domain"] = domain_id;
    out["cfg"] = cfg;
    out["id"] = key;
    if (before == after) {
        out["changed"] = false;
        out["data"] = record;
        out["note"] = "patch 与原内容一致，未写入";
        return out;
    }
    save_cfg(cfg, data);
    std::vector<std::string> patched_keys;
    for (auto it = coerced.begin(); it != coerced.end(); ++it) patched_keys.push_back(it.key());
    std::sort(patched_keys.begin(), patched_keys.end());
    out["changed"] = true;
    out["patched_fields"] = patched_keys;
    out["data"] = record;
    return out;
}

json create_domain_item(const std::string& domain_id, const std::string& cfg, const json& key_arg,
                        const json& data_arg) {
    if (!data_arg.is_object()) {
        throw SandboxError("data 必须是非空对象");
    }
    if (!cfg_in_domain(domain_id, cfg)) {
        throw SandboxError(table_not_in_domain_error(cfg, get_domain(domain_id).value("name", "")));
    }
    // 表不存在时自动建空表（新建条目本身就该能建表）
    json table = cfg_exists(cfg) ? load_cfg(cfg) : json::object();
    json key_v = key_arg;
    if (key_v.is_null()) key_v = data_arg.contains("id") ? data_arg.at("id") : json();
    if (key_v.is_null()) {
        long long best = 0;
        bool any = false;
        for (auto it = table.begin(); it != table.end(); ++it) {
            bool digits = !it.key().empty();
            for (char c : it.key()) {
                if (c < '0' || c > '9') {
                    digits = false;
                    break;
                }
            }
            if (!digits) continue;
            auto iv = sa_core::py_int(it.key());
            if (!iv) continue;
            if (!any || *iv > best) {
                best = *iv;
                any = true;
            }
        }
        key_v = json(std::to_string((any ? best + 1 : 1)));
    }
    const std::string key = py_json_str(key_v);
    if (table.contains(key)) {
        throw SandboxError("表 " + cfg + " 已存在 id=" + key + "，请用 update 修改或换一个 id");
    }
    json coerced = coerce_patch(cfg, data_arg);
    ensure_content_role(cfg, coerced);
    table[key] = coerced;
    save_cfg(cfg, table);
    json out = json::object();
    out["domain"] = domain_id;
    out["cfg"] = cfg;
    out["id"] = key;
    out["created"] = true;
    out["data"] = std::move(coerced);
    return out;
}

json delete_domain_item(const std::string& domain_id, const std::string& cfg,
                        const json& key_arg) {
    if (!cfg_in_domain(domain_id, cfg)) {
        throw SandboxError(table_not_in_domain_error(cfg, get_domain(domain_id).value("name", "")));
    }
    if (!cfg_exists(cfg)) throw missing_cfg_error(cfg);
    json table = load_cfg(cfg);
    const std::string key = py_json_str(key_arg);
    if (!table.contains(key)) {
        throw SandboxError("表 " + cfg + " 中不存在 id=" + key);
    }
    json removed = table.at(key);
    table.erase(key);
    save_cfg(cfg, table);
    json out = json::object();
    out["domain"] = domain_id;
    out["cfg"] = cfg;
    out["id"] = key;
    out["deleted"] = true;
    out["data"] = std::move(removed);
    return out;
}

}  // namespace p3b
}  // namespace sa
