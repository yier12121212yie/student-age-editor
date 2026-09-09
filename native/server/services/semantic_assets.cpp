// wip/P1/semantic_assets.cpp — see semantic_assets.h for the Python sources.
#include "semantic_assets.h"

#include <algorithm>
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

}  // namespace

const json& game_schema() {
    std::call_once(g_schema_once, [] { g_schema = load_asset("schema.json"); });
    return g_schema;
}

const json& dicts() {
    std::call_once(g_dicts_once, [] { g_dicts = load_asset("dicts.json"); });
    return g_dicts;
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

std::string find_asset(const std::string& filename) {
    return sa_core::assets::find_asset(filename);
}

void set_assets_root_for_test(const std::string& root) {
    sa_core::assets::set_assets_root_override(root);
}

}  // namespace p1
}  // namespace sa
