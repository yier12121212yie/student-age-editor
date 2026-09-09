// wip/P3a/preview_service.cpp —— port of server/preview_service.py。
#include "preview_service.h"

#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "sa_core/paths.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "aa.h"  // sa::active_pack_dir() — decoded-pack base-table fallback
#include "server/httpd.h"
#include "server/services/stores_api.h"
#include "server/state.h"

namespace sa {
namespace preview {
namespace {

using content::json;
namespace cs = sa_core::paths;

constexpr size_t kMaxTalks = 800;  // _MAX_TALKS

// ---------------------------------------------------------------------------
// 三缓存（preview_service.py:43-49）
// ---------------------------------------------------------------------------
std::mutex g_mu;

struct StatFp {
    long long mtime_ns = 0;
    long long size = 0;
    bool operator==(const StatFp& o) const {
        return mtime_ns == o.mtime_ns && size == o.size;
    }
};

// _mod_fp_cache: cfg名 -> (fp|None, data|None)。data=nullptr 表示「读到过但顶层
// 不是对象」（Python 缓存 None 值，避免反复解析坏文件）。
struct ModFpEntry {
    std::optional<StatFp> fp;
    std::shared_ptr<const json> data;
};
std::map<std::string, ModFpEntry> g_mod_fp_cache;

// _table_cache: 无指纹——本体/包兜底结果缓存，全靠 invalidate_cache 清。
std::map<std::string, std::shared_ptr<const json>> g_table_cache;

// _meta_cache / _meta_fp：meta 指纹 = mod 在否 + (PersonCfg fp, BgCfg fp)。
struct MetaFp {
    bool has_mod = false;
    std::optional<StatFp> person;
    std::optional<StatFp> bg;
    bool operator==(const MetaFp& o) const {
        return has_mod == o.has_mod && person == o.person && bg == o.bg;
    }
};
std::shared_ptr<const json> g_meta_cache;
std::optional<MetaFp> g_meta_fp;

std::optional<StatFp> mod_file_fp(const std::string& path) {
    auto st = cs::stat(path);
    if (!st) return std::nullopt;
    return StatFp{st->mtime_ns, st->size};
}

// _norm_tex_key（preview_service.py:52-62）：os.path.splitext 去扩展名、
// 去 " #" 后缀、strip、小写。ntpath.splitext 语义（跳过去扩展名前的整串点号）。
std::string py_splitext_root(const std::string& p) {
    size_t sep = p.find_last_of("/\\:");
    size_t dot = p.find_last_of('.');
    if (dot != std::string::npos && dot > (sep == std::string::npos ? (size_t)-1 : sep)) {
        size_t head_idx = (sep == std::string::npos ? 0 : sep + 1);
        for (size_t i = head_idx; i < dot; ++i) {
            if (p[i] != '.') return p.substr(0, dot);  // 有非点开头 -> 有点头
        }
        return p;  // 文件名全是点 -> 无扩展
    }
    return p;
}

std::string norm_tex_key(const std::string& k) {
    if (k.empty()) return k;  // `if not k: return k`
    std::string s = py_splitext_root(k);
    size_t hash_sp = s.find(" #");
    if (hash_sp != std::string::npos) s = s.substr(0, hash_sp);
    return content::py_lower(content::py_strip(s));
}

// ---------------------------------------------------------------------------
// 表加载
// ---------------------------------------------------------------------------

// _load_mod_cfg：mod 优先 + 指纹缓存；None（未选/缺失/非对象/读炸）返 nullptr。
std::shared_ptr<const json> load_mod_cfg(const std::string& name) {
    std::string mod_root;
    {
        std::lock_guard<std::mutex> lk(sa::STATE().mu_);
        mod_root = sa::STATE().mod_root;
    }
    if (mod_root.empty()) return nullptr;
    std::string cfg_dir = sa::cfg_dir();
    std::string path = cs::join(cfg_dir, name + ".json");
    if (!cs::is_file(path)) {
        std::lock_guard<std::mutex> lk(g_mu);
        g_mod_fp_cache.erase(name);
        return nullptr;
    }
    auto fp = mod_file_fp(path);
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_mod_fp_cache.find(name);
        if (it != g_mod_fp_cache.end() && it->second.fp == fp) return it->second.data;
    }
    // 读/解码/解析任一失败 -> None 且**不写缓存**（Python 外层 except）；
    // 解析成功但顶层非对象 -> 缓存 None（避免坏文件反复解析）。
    std::shared_ptr<const json> data;
    auto raw = cs::read_bytes(path);
    auto text = raw ? sa_core::decode_utf8_sig_strict(*raw) : std::optional<std::string>();
    json parsed;
    bool parsed_ok = false;
    if (text) {
        parsed = json::parse(*text, nullptr, false);
        parsed_ok = !parsed.is_discarded();
    }
    if (!parsed_ok) return nullptr;
    if (parsed.is_object()) data = std::make_shared<const json>(std::move(parsed));
    std::lock_guard<std::mutex> lk(g_mu);
    g_mod_fp_cache[name] = {fp, data};
    return data;
}

// _load_aa_cfg：本体 TextAsset 等价物 = base_store 接缝（P4 注册前恒 None；
// _load_pack_cfg 资源包路径同归 P4/P6 域，此处按「无包」返回 None）。
// Wave-2 merge: the pack branch (_rp2.get_active_dir() reads at
// preview_service.py:129-145 — Cfgs/zh-cn/<k>.json, Cfgs/<k>.json, then
// base_data.json[k]) is wired here via P4's DecodedPack so the base tables
// resolve without an explicit POST /api/base/load — matching how the Python
// selftests' base-structure cases pass on a provisioned box.
std::shared_ptr<const json> load_pack_cfg(const std::string& name) {
    static std::mutex pmu;
    static std::map<std::string, std::shared_ptr<const json>> pcache;
    static std::string pcache_dir;
    const std::string dir = sa::active_pack_dir();  // "" when no pack configured
    if (dir.empty()) return nullptr;
    {
        std::lock_guard<std::mutex> lk(pmu);
        if (pcache_dir != dir) { pcache.clear(); pcache_dir = dir; }
        auto it = pcache.find(name);
        if (it != pcache.end()) return it->second;
    }
    std::shared_ptr<const json> data;
    for (const char* sub : {"Cfgs/zh-cn/", "Cfgs/"}) {
        if (auto raw = cs::read_bytes(cs::join(cs::join(dir, sub), name + ".json"))) {
            auto parsed = json::parse(*raw, nullptr, false);
            if (!parsed.is_discarded() && parsed.is_object())
                data = std::make_shared<const json>(std::move(parsed));
            break;
        }
    }
    if (!data) {
        if (auto raw = cs::read_bytes(cs::join(dir, "base_data.json"))) {
            auto parsed = json::parse(*raw, nullptr, false);
            if (!parsed.is_discarded() && parsed.is_object() && parsed.contains(name) &&
                parsed.at(name).is_object()) {
                data = std::make_shared<const json>(parsed.at(name));
            }
        }
    }
    std::lock_guard<std::mutex> lk(pmu);
    pcache[name] = data;
    return data;
}

std::shared_ptr<const json> load_base_cfg(const std::string& name) {
    auto store = sa::base_store();
    if (store && store->available()) {
        auto t = store->table(name);
        if (t && t->is_object()) return t;
    }
    return load_pack_cfg(name);
}

// load_table：mod -> _table_cache -> 本体/包 -> {}。
std::shared_ptr<const json> load_table(const std::string& name) {
    static const std::shared_ptr<const json> kEmpty =
        std::make_shared<const json>(json::object());
    if (auto mod = load_mod_cfg(name)) return mod;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_table_cache.find(name);
        if (it != g_table_cache.end()) return it->second;
    }
    std::shared_ptr<const json> data;
    if (auto base = load_base_cfg(name); base && !base->empty()) data = base;
    if (!data) data = kEmpty;
    std::lock_guard<std::mutex> lk(g_mu);
    g_table_cache[name] = data;
    return data;
}

// load_table_merged：mod + 本体合并（mod 覆盖同名 id）。
std::shared_ptr<const json> load_table_merged(const std::string& name) {
    static const std::shared_ptr<const json> kEmpty =
        std::make_shared<const json>(json::object());
    auto mod = load_mod_cfg(name);
    if (!mod) {
        // 与 load_table 的区别：本体为空时**不**再查资源包（Python 原样）。
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_table_cache.find(name);
        if (it != g_table_cache.end()) return it->second;
        std::shared_ptr<const json> data;
        if (auto base = load_base_cfg(name); base && !base->empty()) data = base;
        if (!data) data = kEmpty;
        g_table_cache[name] = data;
        return data;
    }
    std::shared_ptr<const json> base;
    if (auto b = load_base_cfg(name); b && !b->empty()) base = b;
    json out = base ? *base : json::object();
    for (auto it = mod->begin(); it != mod->end(); ++it) out[it.key()] = it.value();
    return std::make_shared<const json>(std::move(out));
}

// _record：table[str(rid)]，非对象 -> None。
const json* record_at_table(const json& table, const std::string& rid) {
    if (!table.is_object()) return nullptr;
    auto it = table.find(rid);
    if (it == table.end() || !it->is_object()) return nullptr;
    return &*it;
}

// ---------------------------------------------------------------------------
// meta
// ---------------------------------------------------------------------------

const json& dict_pool(const char* key) {
    static const json kEmpty = json::object();
    // 陷阱（坑点 N1，见 CONVENTIONS §10）：nlohmann value(key, json 默认值)
    // 的返回类型是 std::decay<ValueType> —— **按值拷贝**（json.hpp:21517
    // value_return_type）。旧写法把该拷贝绑到 const json& 再返回其子对象引用，
    // 拷贝随本函数作用域结束而析构 → 调用方拿到悬垂引用（Release 靠陈旧堆字节
    // "碰巧"通过；Debug 堆投毒 0xDD 下 meta.bgs/evtTypes 序列化即断言崩溃，
    // 波次3 P8 首报）。改为全程引用单例本体，永不物化拷贝。
    const json& all = content::dicts_json();
    if (!all.is_object() || !all.contains("game_dicts")) return kEmpty;
    const json& gd = all.at("game_dicts");
    if (!gd.is_object() || !gd.contains(key)) return kEmpty;
    const json& v = gd.at(key);
    return v.is_object() ? v : kEmpty;
}

std::shared_ptr<const json> build_meta() {
    std::string mod_root;
    {
        std::lock_guard<std::mutex> lk(sa::STATE().mu_);
        mod_root = sa::STATE().mod_root;
    }
    MetaFp fp;
    if (!mod_root.empty()) {
        fp.has_mod = true;
        std::string cfg_dir = sa::cfg_dir();
        fp.person = mod_file_fp(cs::join(cfg_dir, "PersonCfg.json"));
        fp.bg = mod_file_fp(cs::join(cfg_dir, "BgCfg.json"));
        std::lock_guard<std::mutex> lk(g_mu);
        if (g_meta_cache && g_meta_fp == fp) return g_meta_cache;
    }
    // 无 mod（fp=None）时 Python 不查缓存、每次重建（preview_service.py:331-344
    // 的早退只在 mod_root 分支内）——保持一致：下面直接重建，末尾仍写缓存。

    auto person = load_table_merged("PersonCfg");
    auto bg = load_table_merged("BgCfg");

    json roles = content::role_dict();  // dict(_ROLE_DICT)
    for (auto it = person->begin(); it != person->end(); ++it) {
        const json& rec = it.value();
        if (!rec.is_object()) continue;
        if (rec.contains("name") && content::py_truthy(rec.at("name")))
            roles[it.key()] = rec.at("name");
    }

    json bgs = dict_pool("bgs");
    json bg_keys = json::object();
    for (auto it = bg->begin(); it != bg->end(); ++it) {
        const json& rec = it.value();
        const json* url = rec.is_object() && rec.contains("url") ? &rec.at("url") : nullptr;
        if (!url || !content::py_truthy(*url)) continue;
        std::string key = content::story_str(*url);
        if (key.rfind("bg/", 0) == 0) key = key.substr(3);
        bg_keys[it.key()] = key;
        if (rec.is_object() && rec.contains("id") && !rec.at("id").is_null()) {
            std::string id_s = content::story_str(rec.at("id"));
            if (!bgs.contains(id_s)) bgs[id_s] = key;
        }
    }

    json char_keys = json::object();
    for (auto it = person->begin(); it != person->end(); ++it) {
        const json& rec = it.value();
        if (!rec.is_object()) continue;
        auto first_str = [&rec](const char* k) -> std::string {
            if (!rec.contains(k)) return std::string();
            const json& u = rec.at(k);
            if (u.is_array() && !u.empty() && u.front().is_string())
                return u.front().get<std::string>();
            return std::string();
        };
        std::string base = first_str("url");
        std::string base2 = first_str("url2");
        if (base.empty() && base2.empty()) continue;
        json ck = json::object();
        ck["base"] = base;
        ck["base2"] = base2;
        ck["l2d"] = rec.contains("l2d") && rec.at("l2d").is_array() ? rec.at("l2d")
                                                                    : json::array();
        char_keys[it.key()] = std::move(ck);
    }

    json out = json::object();
    out["roles"] = std::move(roles);
    out["bgs"] = std::move(bgs);
    out["bgKeys"] = std::move(bg_keys);
    out["charKeys"] = std::move(char_keys);
    out["evtTypes"] = dict_pool("evt_types");
    auto sp = std::make_shared<const json>(std::move(out));
    std::lock_guard<std::mutex> lk(g_mu);
    g_meta_cache = sp;
    g_meta_fp = fp;
    return sp;
}

// ---------------------------------------------------------------------------
// 舞台
// ---------------------------------------------------------------------------

// _pick_char_tex（preview_service.py:404-432）。AA 索引经 P4 的进程级
// ensure_aa_index() 接入：索引可用时按 表情变体 → 基础立绘 → 变体前缀 逐候选
// has_tex 命中返回（超范围表情回退 base，selftest char_tex_fallback 契约）；
// 索引不可得时与 Python idx=None 分支一致，返回首个候选。
std::string pick_char_tex(const json& ck, const json& expr) {
    std::string base = ck.is_object() && ck.contains("base") ? content::story_str(ck.at("base"))
                                                             : std::string();
    std::string base2 = ck.is_object() && ck.contains("base2")
                            ? content::story_str(ck.at("base2"))
                            : std::string();
    // Python `ck.get("base") or ""` —— 非字符串 truthy 值也会进候选；
    // url[0] 建 meta 时已限定为 string，故 story_str 等价。
    std::vector<std::string> cands;
    if (content::py_truthy(expr) && !base2.empty()) cands.push_back(base2 + "_" + content::story_str(expr));
    if (!base.empty()) cands.push_back(base);
    if (!base2.empty() && base.empty()) cands.push_back(base2);
    if (cands.empty()) return "";
    auto idx = sa::ensure_aa_index();
    if (idx) {
        for (const auto& t : cands)
            if (idx->has_tex(t)) return norm_tex_key(t);
    }
    return norm_tex_key(cands[0]);
}

struct StageOut {
    json chars;
    json state;
};

// Python `int(x)` 失败的异常复刻（_build_stage 入场 pos 未捕获 -> 500）。
[[noreturn]] void throw_int_fail(const json& v) {
    if (v.is_string())
        throw sa::ApiError("ValueError",
                           content::value_error_int_repr_quoted(v.get<std::string>()));
    throw sa::ApiError("TypeError",
                       "int() argument must be a string, a bytes-like object or a "
                       "real number, not '" +
                           std::string(content::py_type_name(v)) + "'");
}

// Python int(x)（TypeError/ValueError -> nullopt）。bool 视作 0/1。
std::optional<long long> py_int_val(const json& v) {
    if (v.is_boolean()) return v.get<bool>() ? 1LL : 0LL;
    if (v.is_number_integer()) return v.get<long long>();
    if (v.is_number_unsigned()) return static_cast<long long>(v.get<unsigned long long>());
    if (v.is_number_float()) {
        double d = v.get<double>();
        return static_cast<long long>(d);  // 截断
    }
    if (v.is_string()) {
        std::string s = content::py_strip(v.get_ref<const std::string&>());
        return content::int_digits_str(s);
    }
    return std::nullopt;
}

// 「可迭代为序列」的 Python 语义展开（list -> 元素；dict -> 键；str -> 字符；
// null/False/0/""/[] 由调用方 `or []` 先行短路）。
std::vector<json> py_iterate(const json& v) {
    std::vector<json> out;
    if (v.is_array()) {
        for (const auto& x : v) out.push_back(x);
    } else if (v.is_object()) {
        for (auto it = v.begin(); it != v.end(); ++it) out.push_back(json(it.key()));
    } else if (v.is_string()) {
        for (uint32_t cp : content::to_codepoints(v.get_ref<const std::string&>()))
            out.push_back(json(content::cp_to_utf8(cp)));
    } else {
        throw sa::ApiError("TypeError",
                           std::string("'") + content::py_type_name(v) + "' object is not iterable");
    }
    return out;
}

StageOut build_stage(const json& talk, const json& char_keys, const json& prev_state) {
    json state = prev_state.is_object() ? prev_state : json::object();

    json roles = json::array();
    if (talk.is_object() && talk.contains("roles")) {
        const json& r = talk.at("roles");
        roles = content::py_truthy(r) ? r : json::array();
    }
    for (const json& item : py_iterate(roles)) {
        if (!item.is_array() || item.size() < 2) continue;
        auto tid_opt = py_int_val(item[1]);
        if (!tid_opt) continue;  // except (TypeError, ValueError): continue
        long long tid = *tid_opt;
        auto touch = [&state](const std::string& rid) -> json& {
            if (!state.contains(rid)) {
                json fresh = json::object();
                fresh["pos"] = "center";
                fresh["expr"] = 0;
                fresh["flip"] = false;
                state[rid] = std::move(fresh);
            }
            return state[rid];  // ordered_json 引用：改值不动键位
        };
        if (tid == 1001 || tid == 1002 || tid == 1003) {
            std::string rid = content::clean_id(item[0]);
            long long pos_key = 3;
            if (item.size() > 3) {
                auto p = py_int_val(item[3]);
                if (!p) throw_int_fail(item[3]);
                pos_key = *p;
            }
            const char* pos = pos_key == 1 ? "left" : pos_key == 2 ? "right" : "center";
            json& st = touch(rid);
            st["pos"] = pos;
            st["present"] = true;
        } else if (tid == 2001 || tid == 2002) {
            std::string rid = content::clean_id(item[0]);
            if (state.contains(rid)) state[rid]["present"] = false;
        } else if (tid == 3000) {
            std::string rid = content::clean_id(item[0]);
            long long expr = 0;
            if (item.size() > 2) {
                auto e = py_int_val(item[2]);
                if (e) expr = *e;  // except (TypeError, ValueError): expr = 0
            }
            touch(rid)["expr"] = expr;
        } else if (tid == 3006) {
            std::string rid = content::clean_id(item[0]);
            touch(rid)["cloth"] = true;
        } else if (tid == 3007) {
            std::string rid = content::clean_id(item[0]);
            json& st = touch(rid);
            bool cur = st.contains("flip") && content::py_truthy(st.at("flip"));
            st["flip"] = !cur;
        }
    }

    json chars = json::array();
    for (auto it = state.begin(); it != state.end(); ++it) {
        const json& st = it.value();
        if (!st.is_object() || !st.contains("present") || !content::py_truthy(st.at("present")))
            continue;
        json ck = json::object();
        if (char_keys.is_object() && char_keys.contains(it.key()) &&
            char_keys.at(it.key()).is_object())
            ck = char_keys.at(it.key());
        json expr = st.contains("expr") ? st.at("expr") : json(0);
        json c = json::object();
        c["roleId"] = content::clean_id(it.key());
        c["tex"] = pick_char_tex(ck, expr);
        c["pos"] = st.contains("pos") ? st.at("pos") : json("center");
        c["expr"] = expr;
        c["flip"] = st.contains("flip") ? json(content::py_truthy(st.at("flip"))) : json(false);
        chars.push_back(std::move(c));
    }
    return {std::move(chars), std::move(state)};
}

// 或默认：`x or default` 语义（null/false/0/""/[]/{} -> default）。
const json& or_default(const json& v, const json& def) {
    return content::py_truthy(v) ? v : def;
}
static const json kEmptyArr = json::array();

json bg_snapshot(const json* bg_id, const json& meta) {
    if (!bg_id || !content::py_truthy(*bg_id)) return json();
    std::string rid = content::story_str(*bg_id);
    auto pool_get = [&rid](const json& pool) -> json {
        if (pool.is_object() && pool.contains(rid)) return pool.at(rid);
        return json("");
    };
    json out = json::object();
    out["id"] = rid;
    out["name"] = pool_get(meta.contains("bgs") ? meta.at("bgs") : json::object());
    out["key"] = pool_get(meta.contains("bgKeys") ? meta.at("bgKeys") : json::object());
    return out;
}

}  // namespace

json preview_event(const std::string& evt_id_in) {
    std::string evt_id = content::py_strip(evt_id_in);
    if (evt_id.empty()) throw sa::SandboxError("evt_id 不能为空");

    auto evt_cfg = load_table("EvtCfg");
    auto talk_cfg = load_table("TalkCfg");
    auto opt_cfg = load_table("OptionCfg");
    const json* event = record_at_table(*evt_cfg, evt_id);
    if (!event)
        throw sa::SandboxError("事件 " + evt_id + " 不存在（当前模组与本体的 EvtCfg 中均未找到）");

    auto meta_sp = build_meta();
    const json& meta = *meta_sp;

    std::vector<std::string> starts;
    {
        const json& talk_ids =
            event->contains("talkId") ? or_default(event->at("talkId"), kEmptyArr) : kEmptyArr;
        for (const json& x : py_iterate(talk_ids)) {
            if (content::py_truthy(x)) starts.push_back(content::story_str(x));
        }
    }

    json talks = json::object();
    json options = json::object();
    json stage_state = json::object();
    std::deque<std::string> queue(starts.begin(), starts.end());
    std::set<std::string> seen;
    while (!queue.empty() && talks.size() < kMaxTalks) {
        std::string tid = queue.front();
        queue.pop_front();
        if (seen.count(tid)) continue;
        seen.insert(tid);
        const json* rec = record_at_table(*talk_cfg, tid);
        if (!rec) continue;
        json talk = *rec;
        talk["id"] = tid;
        if (talk.is_object() && talk.contains("roleIds") && talk.at("roleIds").is_array()) {
            json ids = json::array();
            for (const auto& x : talk.at("roleIds")) ids.push_back(content::clean_id(x));
            talk["roleIds"] = std::move(ids);
        }
        talk.erase("roles");  // 原始指令折叠进 stage

        auto stage = build_stage(*rec, meta.contains("charKeys") ? meta.at("charKeys")
                                                                 : json::object(),
                                 stage_state);
        stage_state = std::move(stage.state);
        json st = json::object();
        st["bg"] = bg_snapshot(talk.contains("bg") ? &talk.at("bg") : nullptr, meta);
        st["chars"] = std::move(stage.chars);
        talk["stage"] = std::move(st);
        talks[tid] = std::move(talk);

        // 选项分支入队
        if (rec->contains("option")) {
            const json& opts = or_default(rec->at("option"), kEmptyArr);
            for (const json& oid_v : py_iterate(opts)) {
                std::string oid = content::story_str(oid_v);
                if (options.contains(oid)) continue;
                const json* orec = record_at_table(*opt_cfg, oid);
                if (!orec) continue;
                json oc = *orec;
                oc["id"] = oid;
                for (const char* branch : {"talkId", "talkId2"}) {
                    if (!orec->contains(branch)) continue;
                    const json& bl = or_default(orec->at(branch), kEmptyArr);
                    for (const json& b : py_iterate(bl)) {
                        if (content::py_truthy(b)) queue.push_back(content::story_str(b));
                    }
                }
                options[oid] = std::move(oc);
            }
        }
        // 下一对白
        json next_all = json::array();
        if (rec->contains("nextTalk")) {
            const json& v = or_default(rec->at("nextTalk"), kEmptyArr);
            if (!v.is_array())
                throw sa::ApiError("TypeError", "can only concatenate list (not \"" +
                                                    std::string(content::py_type_name(v)) +
                                                    "\") to list");
            for (const auto& x : v) next_all.push_back(x);
        }
        if (rec->contains("nextTalk2")) {
            const json& v = or_default(rec->at("nextTalk2"), kEmptyArr);
            if (!v.is_array())
                throw sa::ApiError("TypeError", "can only concatenate list (not \"" +
                                                    std::string(content::py_type_name(v)) +
                                                    "\") to list");
            for (const auto& x : v) next_all.push_back(x);
        }
        for (const auto& n : next_all) {
            if (content::py_truthy(n)) queue.push_back(content::story_str(n));
        }
    }

    std::string event_title;
    {
        const json& t = event->contains("title") ? event->at("title") : json();
        if (content::py_truthy(t)) {
            event_title = content::story_str(t);
        }
    }
    if (event_title.empty()) event_title = "事件 " + evt_id;

    json out = json::object();
    out["ok"] = true;
    out["evt_id"] = evt_id;
    out["event"] = *event;
    out["event_title"] = event_title;
    json starts_j = json::array();
    for (auto& s : starts) starts_j.push_back(s);
    out["starts"] = std::move(starts_j);
    const long long talk_count = static_cast<long long>(talks.size());
    out["talks"] = std::move(talks);
    out["options"] = std::move(options);
    out["talk_count"] = talk_count;
    out["meta"] = meta;
    return out;
}

void invalidate_cache() {
    std::lock_guard<std::mutex> lk(g_mu);
    g_table_cache.clear();
    g_mod_fp_cache.clear();
    g_meta_cache.reset();
    g_meta_fp.reset();
}

namespace test_hooks {
std::size_t table_cache_size() {
    std::lock_guard<std::mutex> lk(g_mu);
    return g_table_cache.size();
}
std::size_t mod_fp_cache_size() {
    std::lock_guard<std::mutex> lk(g_mu);
    return g_mod_fp_cache.size();
}
bool meta_cached() {
    std::lock_guard<std::mutex> lk(g_mu);
    return g_meta_cache != nullptr;
}
}  // namespace test_hooks

}  // namespace preview
}  // namespace sa
