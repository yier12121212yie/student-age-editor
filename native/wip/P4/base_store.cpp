// wip/P4/base_store.cpp — see base_store.h. Port of base_service.py query
// semantics over the base-tables JSON artifact (no pickle, no bundles).
#include "base_store.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>

#include "sa_core/env_store.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "server/state.h"
#include "p4_util.h"

namespace sa {
namespace {

namespace esp = sa_core::env_store;

// base_service._CFG_KEY_MAP.values() (§4 full table set) — used only to derive
// `missing` when base_meta.json omits missing_expected.
const std::vector<std::string>& expected_tables() {
    static const std::vector<std::string> kTables = {
        "ActionCfg",        "ActionEvtCfg",       "AudioCfg",
        "BadmintonModelCfg", "BgCfg",              "BookCfg",
        "CGCfg",            "EndingDatingCfg",    "EndingOptionCfg",
        "EndingPartCfg",    "EvtCfg",             "EvtTypeCfg",
        "ExploreCfg",       "FriendRequestCfg",   "IntentCfg",
        "InteractCfg",      "ItemCfg",            "JobCfg",
        "KZoneAvatarCfg",   "KZoneColorCfg",      "KZoneCommentCfg",
        "KZoneContentCfg",  "KZoneFontCfg",       "KZoneProfileCfg",
        "LoveBadmintonCfg", "LoveBreakfastCfg",   "LoveDrawCfg",
        "LoveRibbonCfg",    "LoveVindicateRateCfg", "MapCfg",
        "MinigameCfg",      "MinigameActionCfg",  "MovieCfg",
        "NegotiationPlayerCfg", "NegotiationTeammateCfg", "OptionCfg",
        "PaperCfg",         "PersonAttrCfg",      "PersonCfg",
        "PersonStateCfg",   "PhoneMsgCfg",        "RelationCfg",
        "ShopCfg",          "TalkCfg",            "TextCfg",
        "ToggleCfg",        "TvCfg",
    };
    return kTables;
}

// base_service._nat_key comparison. Each part of a value string is either a
// run of digits (compared numerically) or a run of non-digits (lexicographic),
// digit runs sort after non-digit runs at the same position ((1,*) > (0,*)).
// We compare two id strings directly.
bool nat_less(const std::string& a, const std::string& b) {
    size_t i = 0, j = 0;
    auto take = [](const std::string& s, size_t& k, bool& is_num, std::string& out) {
        out.clear();
        is_num = false;
        if (k >= s.size()) return false;
        if (std::isdigit(static_cast<unsigned char>(s[k]))) {
            is_num = true;
            while (k < s.size() && std::isdigit(static_cast<unsigned char>(s[k]))) out += s[k++];
        } else {
            while (k < s.size() && !std::isdigit(static_cast<unsigned char>(s[k]))) out += s[k++];
        }
        return true;
    };
    std::string pa, pb;
    bool na, nb;
    while (true) {
        bool ha = take(a, i, na, pa);
        bool hb = take(b, j, nb, pb);
        if (!ha && !hb) return false;   // equal
        if (!ha) return true;           // a exhausted -> a < b
        if (!hb) return false;          // b exhausted
        if (na != nb) {                 // (0,str) < (1,num) in Python tuple cmp
            // Python parts: digit -> (1,int), non-digit -> (0,str). So a numeric
            // part is GREATER than a text part.
            return !na && nb;           // text(a) < num(b) -> true
        }
        if (na) {  // both numeric
            long long va = std::strtoll(pa.c_str(), nullptr, 10);
            long long vb = std::strtoll(pb.c_str(), nullptr, 10);
            if (va != vb) return va < vb;
        } else {   // both text
            if (pa != pb) return pa < pb;
        }
    }
}

std::string table_env_path() {
    return esp::env_path(sa::editor_root());
}

}  // namespace

// ---- artifact-dir resolution ---------------------------------------------
std::mutex g_dir_mu;
std::string g_dir_override;

void set_base_artifact_dir(const std::string& dir) {
    std::lock_guard<std::mutex> lk(g_dir_mu);
    g_dir_override = dir;
}

std::string base_artifact_dir() {
    {
        std::lock_guard<std::mutex> lk(g_dir_mu);
        if (!g_dir_override.empty()) return g_dir_override;
    }
    if (const char* env = std::getenv("EDITOR_BASE_ARTIFACT_DIR"); env && *env) return env;
    // editor_env.json "base_data_dir".
    json env = esp::read_editor_env(sa::editor_root());
    if (env.contains("base_data_dir") && env.at("base_data_dir").is_string()) {
        std::string d = p4::strip(env.at("base_data_dir").get<std::string>());
        if (!d.empty()) return d;
    }
    return {};
}

// ---- BaseStore -----------------------------------------------------------
BaseStore::BaseStore() = default;

bool BaseStore::available() const {
    std::lock_guard<std::mutex> lk(mu_);
    return status_ == "ready";
}

std::string BaseStore::status() const {
    std::lock_guard<std::mutex> lk(mu_);
    return status_;
}

std::shared_ptr<const json> BaseStore::table_shared_locked(const std::string& cfg) const {
    auto it = data_.find(cfg);
    return it == data_.end() ? nullptr : it->second;
}

std::shared_ptr<const json> BaseStore::table(const std::string& cfg) const {
    std::lock_guard<std::mutex> lk(mu_);
    if (status_ != "ready") return std::make_shared<const json>(json::object());
    auto it = data_.find(cfg);
    if (it == data_.end()) return std::make_shared<const json>(json::object());
    return it->second;
}

std::shared_ptr<const std::set<int64_t>> BaseStore::table_ids(const std::string& cfg) const {
    std::lock_guard<std::mutex> lk(mu_);
    auto cached = ids_cache_.find(cfg);
    if (cached != ids_cache_.end()) return cached->second;
    auto ids = std::make_shared<std::set<int64_t>>();
    if (status_ == "ready") {
        auto t = table_shared_locked(cfg);
        if (t && t->is_object()) {
            for (auto it = t->begin(); it != t->end(); ++it) {
                auto v = sa_core::py_int(it.key());  // int(k) try/except
                if (v) ids->insert(static_cast<int64_t>(*v));
            }
        }
    }
    std::shared_ptr<const std::set<int64_t>> out(ids);
    ids_cache_[cfg] = out;
    return out;
}

std::vector<std::string> BaseStore::loaded_tables() const {
    std::lock_guard<std::mutex> lk(mu_);
    return loaded_;
}

json BaseStore::status_dict() const {
    std::lock_guard<std::mutex> lk(mu_);
    json dirs = json::array();
    for (const auto& d : dirs_) dirs.push_back(d);
    json loaded = json::array();
    for (const auto& k : loaded_) loaded.push_back(k);
    json missing = json::array();
    for (const auto& k : missing_) missing.push_back(k);
    const std::string env_path = table_env_path();
    json out;
    out["status"] = status_;
    out["error"] = error_;
    out["dirs"] = std::move(dirs);
    out["loaded"] = std::move(loaded);
    out["missing"] = std::move(missing);
    out["env_path"] = env_path;
    out["env_exists"] = sa_core::paths::is_file(env_path);
    return out;
}

// Reads a base_data/<table>.json into a shared immutable object.
static std::shared_ptr<const json> read_table_file(const std::string& path) {
    auto raw = sa_core::paths::read_bytes(path);
    if (!raw) return nullptr;
    // utf-8-sig tolerant (strip a leading BOM if any).
    std::string body = *raw;
    if (body.size() >= 3 && static_cast<unsigned char>(body[0]) == 0xEF &&
        static_cast<unsigned char>(body[1]) == 0xBB && static_cast<unsigned char>(body[2]) == 0xBF) {
        body = body.substr(3);
    }
    auto parsed = json::parse(body, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object()) return nullptr;
    return std::make_shared<const json>(std::move(parsed));
}

bool BaseStore::load(bool force) {
    std::lock_guard<std::mutex> lk(mu_);
    if (status_ == "ready" && !force) return true;

    const std::string dir = base_artifact_dir();
    error_.clear();
    dirs_.clear();
    loaded_.clear();
    missing_.clear();
    data_.clear();
    ids_cache_.clear();
    evt_index_.reset();

    if (dir.empty()) {
        status_ = "idle";
        return false;
    }
    const std::string meta_path = sa_core::paths::join(dir, "base_meta.json");
    auto meta_raw = sa_core::paths::read_bytes(meta_path);
    if (!meta_raw) {
        status_ = "idle";  // no artifact yet — matches Python "idle" not "error"
        return false;
    }
    std::string meta_body = *meta_raw;
    if (meta_body.size() >= 3 && static_cast<unsigned char>(meta_body[0]) == 0xEF)
        meta_body = meta_body.substr(3);
    auto meta = json::parse(meta_body, nullptr, false);
    if (meta.is_discarded() || !meta.is_object()) {
        status_ = "error";
        error_ = "base_meta.json 解析失败";
        return false;
    }

    // Staleness (§5): re-stat each source's top-level files vs recorded
    // mtime_ns/size. Any drift => product expired (we do not rescan bundles).
    if (meta.contains("sources") && meta.at("sources").is_array()) {
        for (const auto& src : meta.at("sources")) {
            if (!src.is_object() || !src.contains("files") || !src.at("files").is_array()) continue;
            std::string spath = src.value("path", std::string());
            for (const auto& f : src.at("files")) {
                if (!f.is_object()) continue;
                std::string name = f.value("name", std::string());
                long long want_m = f.contains("mtime_ns") ? f.at("mtime_ns").get<long long>() : -1;
                long long want_sz = f.contains("size") ? f.at("size").get<long long>() : -1;
                auto st = sa_core::paths::stat(sa_core::paths::join(spath, name));
                if (!st || st->mtime_ns != want_m || st->size != want_sz) {
                    status_ = "error";
                    error_ = "base 产物已过期（源文件变化），请重跑 resource_scan base-tables";
                    return false;
                }
            }
        }
    }

    dirs_.push_back(dir);
    const std::string data_dir = sa_core::paths::join(dir, "base_data");
    auto load_list = [&](const std::vector<std::string>& names) {
        for (const auto& table : names) {
            std::string fname = table + ".json";
            auto rows = read_table_file(sa_core::paths::join(data_dir, fname));
            if (rows) {
                data_[table] = rows;
                loaded_.push_back(table);
            }
        }
    };

    if (meta.contains("tables") && meta.at("tables").is_object()) {
        std::vector<std::string> names;
        for (auto it = meta.at("tables").begin(); it != meta.at("tables").end(); ++it)
            names.push_back(it.key());
        std::sort(names.begin(), names.end());
        load_list(names);
    } else {
        // No tables map: read whatever base_data/*.json files exist.
        std::vector<std::string> files = sa_core::paths::listdir_sorted(data_dir);
        std::vector<std::string> names;
        for (auto& f : files)
            if (sa_core::str::ends_with(f, ".json")) names.push_back(f.substr(0, f.size() - 5));
        load_list(names);
    }
    std::sort(loaded_.begin(), loaded_.end());

    // missing (§5 missing_expected, else full-set minus loaded).
    if (meta.contains("missing_expected") && meta.at("missing_expected").is_array()) {
        for (const auto& m : meta.at("missing_expected"))
            if (m.is_string()) missing_.push_back(m.get<std::string>());
    } else {
        std::set<std::string> have(loaded_.begin(), loaded_.end());
        for (const auto& t : expected_tables())
            if (!have.count(t)) missing_.push_back(t);
    }
    std::sort(missing_.begin(), missing_.end());

    if (loaded_.empty()) {
        // Artifact present but contributed no table => treat as error to make
        // /api/base/events honestly 409 rather than serve an empty "ready".
        status_ = "error";
        error_ = "base_data 目录无可用表";
        return false;
    }
    status_ = "ready";
    return true;
}

void BaseStore::build_evt_index_locked() const {
    auto evt = table_shared_locked("EvtCfg");
    auto idx = std::make_shared<std::vector<RowIndex>>();
    if (evt && evt->is_object()) {
        for (auto it = evt->begin(); it != evt->end(); ++it) {
            const json& obj = it.value();
            if (!obj.is_object()) continue;
            std::string title;
            if (obj.contains("title") && !obj.at("title").is_null()) title = sa_core::py_str(obj.at("title"));
            if (p4::strip(title).empty() || p4::strip(title) == "未命名") continue;
            RowIndex rec;
            rec.id = it.key();  // row keys are strings already (§4)
            rec.title = title;
            rec.title_lower = sa_core::str::lower(title);
            // npc_set: list -> items; else truthy single -> [that]; else [].
            if (obj.contains("npc")) {
                const json& npc = obj.at("npc");
                rec.npc = npc;
                if (npc.is_array()) {
                    for (const auto& x : npc) rec.npc_set.insert(sa_core::py_str(x));
                } else if (!npc.is_null()) {
                    bool truthy = !(npc.is_number() && npc.get<double>() == 0.0) &&
                                  !(npc.is_string() && npc.get<std::string>().empty()) &&
                                  !(npc.is_boolean() && !npc.get<bool>());
                    if (truthy) rec.npc_set.insert(sa_core::py_str(npc));
                }
            } else {
                rec.npc = json::array();
            }
            std::string type_str = "0";
            if (obj.contains("type") && !obj.at("type").is_null()) type_str = sa_core::py_str(obj.at("type"));
            rec.type = type_str;
            idx->push_back(std::move(rec));
        }
    }
    std::stable_sort(idx->begin(), idx->end(),
                     [](const RowIndex& a, const RowIndex& b) { return nat_less(a.id, b.id); });
    evt_index_ = idx;
}

json BaseStore::search_events(const std::string& keyword, const std::string& npc_id,
                              const std::string& evt_type, long long page, long long per_page) const {
    std::lock_guard<std::mutex> lk(mu_);
    if (!evt_index_) build_evt_index_locked();
    std::string kw = sa_core::str::lower(p4::strip(keyword));
    bool kw_is_digit = !kw.empty() &&
                       std::all_of(kw.begin(), kw.end(),
                                   [](char c) { return std::isdigit(static_cast<unsigned char>(c)); });
    bool filter_npc = !(npc_id.empty() || npc_id == "0");
    bool filter_type = !(evt_type.empty() || evt_type == "0");

    json out = json::array();
    long long p = std::max(1LL, page);
    long long pp = std::max(1LL, std::min(200LL, per_page));
    long long start = (p - 1) * pp;
    long long total = 0;   // index into the matched list (pagination basis)

    for (const RowIndex& rec : *evt_index_) {
        if (!kw.empty()) {
            if (kw_is_digit) {
                if (!sa_core::str::starts_with(rec.id, kw)) continue;
            } else if (rec.title_lower.find(kw) == std::string::npos) {
                continue;
            }
        }
        if (filter_npc && !rec.npc_set.count(npc_id)) continue;
        if (filter_type && rec.type != evt_type) continue;
        if (total >= start && total < start + pp) {
            json e;
            e["id"] = rec.id;
            e["title"] = rec.title;
            e["npc"] = rec.npc;
            e["type"] = rec.type;
            out.push_back(std::move(e));
        }
        ++total;
    }
    json body;
    body["total"] = total;
    body["page"] = p;
    body["per_page"] = pp;
    body["events"] = std::move(out);
    return body;
}

// base_service.infer_evt_id — standalone (evt_dict passed by const ref).
static std::pair<std::string, std::string> infer_evt_id(const std::string& talk_id,
                                                        const json& evt_dict) {
    const std::string& tid = talk_id;
    std::string guess = tid.size() > 3 ? tid.substr(0, tid.size() - 3) : tid;
    if (evt_dict.is_object() && evt_dict.contains(guess)) {
        std::string title = "未知";
        const json& g = evt_dict.at(guess);
        if (g.is_object() && g.contains("title") && !g.at("title").is_null())
            title = sa_core::py_str(g.at("title"));
        return {guess, title};
    }
    std::string guess2 = tid.size() > 2 ? tid.substr(0, tid.size() - 2) : tid;
    if (evt_dict.is_object() && evt_dict.contains(guess2)) {
        std::string title = "未知";
        const json& g = evt_dict.at(guess2);
        if (g.is_object() && g.contains("title") && !g.at("title").is_null())
            title = sa_core::py_str(g.at("title"));
        return {guess2, title};
    }
    return {guess, "未知/通用"};
}

json BaseStore::search_talks(const std::string& keyword, const json& mod_talk, const json& mod_evt,
                             long long limit) const {
    std::string kw = p4::strip(keyword);
    json out = json::array();
    if (kw.empty()) return out;
    std::lock_guard<std::mutex> lk(mu_);
    auto b_evt = table_shared_locked("EvtCfg");
    auto b_talk = table_shared_locked("TalkCfg");
    static const json kEmpty = json::object();
    const json& be = b_evt ? *b_evt : kEmpty;
    const json& bt = b_talk ? *b_talk : kEmpty;

    struct Hit { std::string content; size_t clen; int rank; json obj; };
    std::vector<Hit> hits;
    auto scan = [&](const std::string& src, const json& evt_dict, const json& talk_dict) {
        if (!talk_dict.is_object()) return;
        for (auto it = talk_dict.begin(); it != talk_dict.end(); ++it) {
            const json& tdata = it.value();
            if (!tdata.is_object()) continue;
            std::string content;
            if (tdata.contains("content") && !tdata.at("content").is_null())
                content = sa_core::py_str(tdata.at("content"));
            if (content.empty() || content == "None" || content.find(kw) == std::string::npos)
                continue;
            auto [eid, title] = infer_evt_id(it.key(), evt_dict);
            json rec;
            rec["src"] = src;
            rec["evt_id"] = eid;
            rec["evt_title"] = title;
            rec["talk_id"] = it.key();
            rec["content"] = content;
            hits.push_back({content, p4::utf8_len(content), content == kw ? 0 : 1, std::move(rec)});
        }
    };
    scan("本体", be, bt);
    scan("Mod", mod_evt, mod_talk);
    std::stable_sort(hits.begin(), hits.end(), [](const Hit& a, const Hit& b) {
        if (a.rank != b.rank) return a.rank < b.rank;
        return a.clen < b.clen;
    });
    long long lim = std::max(0LL, limit);
    for (size_t i = 0; i < hits.size() && static_cast<long long>(i) < lim; ++i)
        out.push_back(std::move(hits[i].obj));
    return out;
}

static bool id_belongs(const std::string& key, const std::string& evt_id, size_t suffix_len) {
    return key.size() == evt_id.size() + suffix_len && sa_core::str::starts_with(key, evt_id);
}

json BaseStore::extract_event(const std::string& evt_id_raw) const {
    std::string evt_id = evt_id_raw;  // ids are strings (§4)
    json delta = json::object();
    std::lock_guard<std::mutex> lk(mu_);
    auto b_evt = table_shared_locked("EvtCfg");
    static const json kEmpty = json::object();
    const json& be = b_evt ? *b_evt : kEmpty;
    if (!be.is_object() || !be.contains(evt_id)) return delta;
    delta["EvtCfg"] = json::object();
    delta["EvtCfg"][evt_id] = be.at(evt_id);

    auto b_talk = table_shared_locked("TalkCfg");
    const json& bt = b_talk ? *b_talk : kEmpty;
    if (bt.is_object()) {
        json talks = json::object();
        for (auto it = bt.begin(); it != bt.end(); ++it)
            if (id_belongs(it.key(), evt_id, 3)) talks[it.key()] = it.value();
        if (!talks.empty()) delta["TalkCfg"] = std::move(talks);
    }
    auto b_opt = table_shared_locked("OptionCfg");
    const json& bo = b_opt ? *b_opt : kEmpty;
    if (bo.is_object()) {
        json opts = json::object();
        for (auto it = bo.begin(); it != bo.end(); ++it)
            if (id_belongs(it.key(), evt_id, 2)) opts[it.key()] = it.value();
        if (!opts.empty()) delta["OptionCfg"] = std::move(opts);
    }
    return delta;
}

// ---- singleton + registration --------------------------------------------
std::shared_ptr<BaseStore> base_store_instance() {
    static std::once_flag once;
    static std::shared_ptr<BaseStore> inst;
    std::call_once(once, [] { inst = std::make_shared<BaseStore>(); });
    return inst;
}

void register_p4_base_store() {
    auto store = base_store_instance();
    sa::register_base_store(store);  // P1 (/api/base_ids) + P3a (/api/search/talk) seam
    store->load(false);              // best-effort initial load; idle when no artifact
}

}  // namespace sa
