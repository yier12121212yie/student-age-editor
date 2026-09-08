// wip/P3a/content_routes.cpp —— POST /api/story/export|import、POST /api/preview/event、
// GET /api/search/talk、/api/ai/stage/{dicts,roles,encode}（api.py 路由体逐一移植）。
//
// 错误信封（CONVENTIONS 2.1）：SandboxError -> 400 {"error": msg}；服务内
// ApiError(type,msg) 经 Router::dispatch 转 500 {"error":"type: msg"}，与 Python
// `except Exception: 500 {"error":"%s: %s" % (type(e).__name__, e)}` 同形。
#include "content_routes.h"

#include <algorithm>
#include <string>
#include <vector>

#include "preview_service.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/util.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/services/stores_api.h"
#include "server/state.h"
#include "stage_service.h"
#include "story_service.h"

namespace sa {
namespace {

using content::json;

// Python `_body or {}`：null/{}/[]/"" 均视作 {}；对象取自身；其他真值对象
// （数组/字符串）按 dict 访问语义 getattr -> AttributeError。
const json& body_obj(const Req& req) {
    static const json kEmpty = json::object();
    const json& b = req.body;
    if (b.is_object()) return b;
    if (!content::py_truthy(b)) return kEmpty;
    // 真值非对象 body：Python `.get` -> AttributeError -> 500
    throw sa::ApiError("AttributeError",
                       std::string("'") + content::py_type_name(b) + "' object has no attribute 'get'");
}

json bget(const json& body, const char* key) {
    if (body.is_object() && body.contains(key)) return body.at(key);
    return json();
}
std::string bstr(const json& body, const char* key) {
    json v = bget(body, key);
    if (!content::py_truthy(v)) return "";
    return content::story_str(v);
}

// api.py:_save_mod_cfg（594-603）写回管线 + 简报要求的 cfg_store「四连」（抄
// cfg_routes.cpp:131-138）。Python 的 _save_mod_cfg 本身不带预览失效（只在
// /api/cfg PUT 与 undo/redo 路由层，api.py:1088）；预览缓存有 mtime/size 指纹
// 自愈，补第 4 连只强制即时重读、语义不变。
void save_mod_cfg(const std::string& cfg_name, const json& data) {
    std::string path = cfg_path(cfg_name);  // SandboxError 传播（400/500 由路由层）
    json result = cfg_store::write_cfg(path, data, std::nullopt, nullptr, false, true);
    if (!result.value("ok", false)) {
        std::string msg = result.value("error", std::string());
        throw sa::ApiError("OSError", msg.empty() ? "配置表写入失败" : msg);
    }
    invalidate_table_cache(path);
    seed_table_cache(path, cfg_name, data,
                     result.contains("mtime_ns") && result.at("mtime_ns").is_number()
                         ? std::optional<long long>(result.at("mtime_ns").get<long long>())
                         : std::nullopt);
    note_mod_cfgs_write(cfg_name, data, path);
    sa::invalidate_preview_cache();
}

// api.py:2461-2464 / 2489-2492：ROLE_DICT + mod PersonCfg 的 name 合并。
json story_role_dict(const ModCfgsView& mod_cfgs) {
    json role_dict = content::role_dict();
    auto it = mod_cfgs.tables.find("PersonCfg");
    if (it != mod_cfgs.tables.end() && it->second->is_object()) {
        for (auto pit = it->second->begin(); pit != it->second->end(); ++pit) {
            const json& v = pit.value();
            if (v.is_object() && v.contains("name") && content::py_truthy(v.at("name")))
                role_dict[pit.key()] = v.at("name");
        }
    }
    return role_dict;
}

const json* mod_table(const ModCfgsView& mod_cfgs, const std::string& name) {
    auto it = mod_cfgs.tables.find(name);
    return it == mod_cfgs.tables.end() ? nullptr : it->second.get();
}

std::vector<std::string> strs_of_iter(const json& v) {
    std::vector<std::string> out;
    if (v.is_array()) {
        for (const auto& x : v) {
            if (content::py_truthy(x)) out.push_back(content::story_str(x));
        }
    } else if (v.is_object()) {
        for (auto it = v.begin(); it != v.end(); ++it) {
            if (content::py_truthy(json(it.key()))) out.push_back(it.key());
        }
    } else if (v.is_string()) {
        for (uint32_t cp : content::to_codepoints(v.get_ref<const std::string&>())) {
            out.push_back(content::cp_to_utf8(cp));
        }
    } else if (!content::py_truthy(v)) {
        return out;  // `x or []` 短路
    } else {
        throw sa::ApiError("TypeError", std::string("'") + content::py_type_name(v) +
                                            "' object is not iterable");
    }
    return out;
}

// ---------------------------------------------------------------------------
// /api/search/talk（base_service.search_talks 路由体）
// ---------------------------------------------------------------------------

std::string cp_rstrip_n(const std::string& s, size_t n) {
    size_t l = content::cp_len(s);
    return l > n ? content::cp_prefix(s, l - n) : s;
}

std::pair<std::string, json> infer_evt_id(const std::string& tid, const json& evt_dict) {
    std::string guess = cp_rstrip_n(tid, 3);
    if (evt_dict.is_object() && evt_dict.contains(guess)) {
        const json& rec = evt_dict.at(guess);
        if (!rec.is_object())
            throw sa::ApiError("AttributeError",
                               std::string("'") + content::py_type_name(rec) +
                                   "' object has no attribute 'get'");
        return {guess, rec.contains("title") ? rec.at("title") : json("未知")};
    }
    std::string guess2 = cp_rstrip_n(tid, 2);
    if (evt_dict.is_object() && evt_dict.contains(guess2)) {
        const json& rec = evt_dict.at(guess2);
        if (!rec.is_object())
            throw sa::ApiError("AttributeError",
                               std::string("'") + content::py_type_name(rec) +
                                   "' object has no attribute 'get'");
        return {guess2, rec.contains("title") ? rec.at("title") : json("未知")};
    }
    return {guess, json("未知/通用")};
}

Resp search_talk(const Req& req) {
    auto qit = req.query.find("q");
    std::string kw = qit == req.query.end() ? std::string() : qit->second;
    auto lit = req.query.find("limit");
    long long limit = 150;
    if (lit != req.query.end() && !lit->second.empty()) {
        auto v = content::int_digits_str(content::py_strip(lit->second));
        if (v)
            limit = *v < 1 ? 1 : *v;  // max(1, int(...))
        else
            limit = 150;  // ValueError -> 150
    }

    json results = json::array();
    kw = content::py_strip(kw);
    if (!kw.empty()) {
        bool has_mod;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            has_mod = !STATE().mod_root.empty();
        }
        ModCfgsView mod_cfgs = has_mod ? load_mod_cfgs() : ModCfgsView{};
        const json* m_talk = mod_table(mod_cfgs, "TalkCfg");
        const json* m_evt = mod_table(mod_cfgs, "EvtCfg");
        static const json kEmpty = json::object();
        const json m_talk_empty = json::object(), m_evt_empty = json::object();

        auto store = base_store();
        std::shared_ptr<const json> b_talk, b_evt;
        if (store->available()) {
            b_talk = store->table("TalkCfg");
            b_evt = store->table("EvtCfg");
        }
        struct Src {
            const char* name;
            const json* evt;
            const json* talk;
        };
        Src srcs[2] = {
            {"本体", b_evt ? b_evt.get() : &kEmpty, b_talk ? b_talk.get() : &kEmpty},
            {"Mod", m_evt ? m_evt : &m_evt_empty, m_talk ? m_talk : &m_talk_empty},
        };
        struct Hit {
            std::string content;
            size_t key_len;
            bool exact;
            json row;
        };
        std::vector<Hit> hits;
        for (const Src& s : srcs) {
            if (!s.talk->is_object()) continue;
            for (auto it = s.talk->begin(); it != s.talk->end(); ++it) {
                const json& tdata = it.value();
                if (!tdata.is_object()) continue;
                std::string content_str;
                {
                    json v = tdata.contains("content") ? tdata.at("content") : json("");
                    if (content::py_truthy(v)) content_str = content::story_str(v);
                }
                if (content_str.empty() || content_str == "None") continue;
                if (content_str.find(kw) == std::string::npos) continue;
                auto [eid, title] = infer_evt_id(it.key(), *s.evt);
                json row = json::object();
                row["src"] = s.name;
                row["evt_id"] = eid;
                row["evt_title"] = title;
                row["talk_id"] = it.key();
                row["content"] = content_str;
                size_t l = content::cp_len(content_str);
                hits.push_back({content_str, l, content_str == kw, std::move(row)});
            }
        }
        // results.sort(key=lambda x: (0 if x["content"]==kw else len(x["content"]))) 稳定
        std::stable_sort(hits.begin(), hits.end(), [](const Hit& a, const Hit& b) {
            long long ka = a.exact ? 0 : static_cast<long long>(a.key_len);
            long long kb = b.exact ? 0 : static_cast<long long>(b.key_len);
            return ka < kb;
        });
        for (size_t i = 0; i < hits.size() && static_cast<long long>(results.size()) < limit; ++i)
            results.push_back(std::move(hits[i].row));
    }
    json out = json::object();
    out["results"] = std::move(results);
    return Resp::Json(200, std::move(out));
}

}  // namespace

void register_content_routes(Router& r) {
    // 波次 1 在写路径埋的 sa::invalidate_preview_cache() 调用点由此接通。
    set_preview_invalidator_hook([] { preview::invalidate_cache(); });

    // POST /api/story/export —— api.py:2452-2475
    r.post(R"(/api/story/export)", [](const Req& req) -> Resp {
        const json& body = body_obj(req);
        std::vector<std::string> evt_ids = strs_of_iter(bget(body, "evt_ids"));
        if (evt_ids.empty()) return Resp::Json(400, json{{"error", "evt_ids required"}});
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            if (STATE().mod_root.empty())
                return Resp::Json(400, json{{"error", "no mod selected"}});
        }
        ModCfgsView mod_cfgs = load_mod_cfgs();
        static const json kEmpty = json::object();
        const json* evt = mod_table(mod_cfgs, "EvtCfg");
        const json* talk = mod_table(mod_cfgs, "TalkCfg");
        const json* opt = mod_table(mod_cfgs, "OptionCfg");
        json role_dict = story_role_dict(mod_cfgs);
        json opts = bget(body, "opts");
        std::string dual = content::py_truthy(bget(body, "dual_choice"))
                               ? content::story_str(bget(body, "dual_choice"))
                               : std::string("both");
        json ids_j = json::array();
        try {
            std::string text = story::export_story(evt ? *evt : kEmpty, talk ? *talk : kEmpty,
                                                   opt ? *opt : kEmpty, role_dict, evt_ids,
                                                   content::py_truthy(opts) ? opts : json(), dual);
            for (const auto& s : evt_ids) ids_j.push_back(s);
            json out = json::object();
            out["text"] = std::move(text);
            out["evt_ids"] = std::move(ids_j);
            return Resp::Json(200, std::move(out));
        } catch (const sa::SandboxError& e) {
            return Resp::Json(500, json{{"error", std::string("SandboxError: ") + e.what()}});
        }
    });

    // POST /api/story/import —— api.py:2477-2539
    r.post(R"(/api/story/import)", [](const Req& req) -> Resp {
        const json& body = body_obj(req);
        std::string start_id = bstr(body, "start_id");
        std::string text = bstr(body, "text");
        bool write = content::py_truthy(bget(body, "write"));
        bool append = content::py_truthy(bget(body, "append"));
        bool has_mod;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            has_mod = !STATE().mod_root.empty();
        }
        if (start_id.empty() || content::py_strip(text).empty())
            return Resp::Json(400, json{{"error", "start_id and text required"}});
        if (write && !has_mod) return Resp::Json(400, json{{"error", "no mod selected"}});
        ModCfgsView mod_cfgs;
        if (write || has_mod) mod_cfgs = load_mod_cfgs();
        json role_dict = story_role_dict(mod_cfgs);
        // {名字: int(id)}：首个名字出现序决定映射（重复名跳后到者）
        json name_to_id = json::object();
        for (auto it = role_dict.begin(); it != role_dict.end(); ++it) {
            const json& rname = it.value();
            if (!content::py_truthy(rname)) continue;
            std::string key = content::story_str(rname);
            if (name_to_id.contains(key)) continue;
            auto iv = content::int_digits_str(it.key());
            name_to_id[key] = iv ? json(*iv) : json(it.key());
        }
        json parsed;
        try {
            parsed = story::parse_script(start_id, text, name_to_id);
        } catch (const sa::SandboxError& e) {
            return Resp::Json(500, json{{"error", std::string("SandboxError: ") + e.what()}});
        }
        if (write) {
            static const json kEmpty = json::object();
            const json* talk = mod_table(mod_cfgs, "TalkCfg");
            json bucket = talk && talk->is_object() ? *talk : kEmpty;
            if (!append) {
                std::vector<std::string> doomed;
                for (auto it = bucket.begin(); it != bucket.end(); ++it) {
                    const std::string& ts = it.key();
                    if ((content::cp_len(ts) > 3 && cp_rstrip_n(ts, 3) == start_id) ||
                        (content::cp_len(ts) > 2 && cp_rstrip_n(ts, 2) == start_id) ||
                        ts == start_id)
                        doomed.push_back(ts);
                }
                for (const auto& k : doomed) bucket.erase(k);
            }
            for (auto it = parsed.begin(); it != parsed.end(); ++it) bucket[it.key()] = it.value();
            save_mod_cfg("TalkCfg", bucket);
            const json* evt = mod_table(mod_cfgs, "EvtCfg");
            json evt_bucket = evt && evt->is_object() ? *evt : kEmpty;
            if (evt_bucket.contains(start_id) && evt_bucket.at(start_id).is_object()) {
                json e2 = evt_bucket.at(start_id);
                bool empty_talkid = !e2.contains("talkId") || !content::py_truthy(e2.at("talkId"));
                if (!append || empty_talkid) {
                    long long base_v = content::int_digits_str(start_id).value_or(0);
                    e2["talkId"] = json::array({base_v * 1000 + 1});
                    evt_bucket[start_id] = std::move(e2);
                    save_mod_cfg("EvtCfg", evt_bucket);
                }
            }
        }
        // B14 预览排序：数字键升序在前，非数字键按字符串序排最后
        std::vector<std::pair<std::string, const json*>> entries;
        for (auto it = parsed.begin(); it != parsed.end(); ++it) entries.emplace_back(it.key(), &it.value());
        std::stable_sort(entries.begin(), entries.end(),
                         [](const std::pair<std::string, const json*>& a,
                            const std::pair<std::string, const json*>& b) {
                             auto ia = content::int_digits_str(a.first);
                             auto ib = content::int_digits_str(b.first);
                             if (ia && ib) return *ia < *ib;
                             if (ia) return true;
                             if (ib) return false;
                             return a.first < b.first;
                         });
        json preview = json::array();
        for (size_t i = 0; i < entries.size() && i < 200; ++i) {
            json row = json::array();
            row.push_back(entries[i].first);
            row.push_back(*entries[i].second);
            preview.push_back(std::move(row));
        }
        json out = json::object();
        out["ok"] = true;
        out["write"] = write;
        out["count"] = static_cast<long long>(parsed.size());
        out["preview"] = std::move(preview);
        return Resp::Json(200, std::move(out));
    });

    // POST /api/preview/event —— api.py:2542-2555（简报写 GET，api.py 实为 POST，
    // 以 api.py 为准）
    r.post(R"(/api/preview/event)", [](const Req& req) -> Resp {
        const json& body = body_obj(req);
        std::string evt_id = content::py_strip(bstr(body, "evt_id"));
        if (evt_id.empty()) return Resp::Json(400, json{{"error", "evt_id required"}});
        try {
            json data = preview::preview_event(evt_id);
            return Resp::Json(200, std::move(data));
        } catch (const sa::SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    // GET /api/search/talk —— api.py:2434-2449
    r.get(R"(/api/search/talk)", [](const Req& req) -> Resp { return search_talk(req); });

    // ---------- /api/ai/stage/* —— api.py:1972-1994 ----------
    r.get(R"(/api/ai/stage/dicts)",
          [](const Req&) -> Resp { return Resp::Json(200, stage::get_stage_dicts()); });

    r.get(R"(/api/ai/stage/roles)", [](const Req& req) -> Resp {
        auto it = req.query.find("talk_id");
        std::string talk_id = it == req.query.end() ? std::string() : it->second;
        try {
            return Resp::Json(200, stage::get_talk_stage(talk_id));
        } catch (const sa::SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });

    r.post(R"(/api/ai/stage/encode)", [](const Req& req) -> Resp {
        const json& body = body_obj(req);
        std::string talk_id = bstr(body, "talk_id");
        try {
            return Resp::Json(200,
                              stage::encode_talk_stage(talk_id, bget(body, "commands"),
                                                       content::py_truthy(bget(body, "clear"))));
        } catch (const sa::SandboxError& e) {
            return Resp::Json(400, json{{"error", e.what()}});
        }
    });
}

}  // namespace sa
