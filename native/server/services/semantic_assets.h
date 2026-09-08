// wip/P1/semantic_assets.h — read-only loaders for schema.json / dicts.json and
// the data_dicts.py template DBs, plus the derived cross-reference pools.
//
// Everything here is a frozen mirror of the Python truth sources:
//   * GAME_SCHEMA            <- backend/editor/core/game_schema.py  (native/assets/schema.json)
//   * /api/dicts assembly    <- backend/editor/server/api.py:1584-1615
//   * CONDITION_DB / EFFECT_DB / EFFECT_EDITOR_DB / COST_DB /
//     SCREEN_EFFECT_DB / ACTION_CMD_DB / SECONDARY_PLACEHOLDER_MAP
//                            <- backend/editor/core/data_dicts.py
//
// After merge other wave-2 groups pull tables through sa::p1::game_schema() and
// the *_db() accessors, so they are process-wide singletons initialized on first
// use (thread-safe via std::call_once).
#pragma once

#include <map>
#include <set>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {
namespace p1 {

using json = nlohmann::ordered_json;

// GAME_SCHEMA (schema.json): {cfg_name: {field: type}} — 406 tables.
const json& game_schema();
// dicts.json: {key_maps, game_dicts, story_dicts} — /api/dicts backing store.
const json& dicts();

// /api/schema response assembly (api.py:1361-1368), field-by-field:
//   {game_schema, field_types, cfg_names} where field_types flattens every
//   table's fields (later tables win, matching Python's overwrite loop over the
//   insertion-ordered GAME_SCHEMA) and cfg_names is sorted(schema.keys()).
json schema_response();

// Referenced-field pools (ref_rules._DICT_POOL_MAP + bugfix valid_* sets).
// Backed by dicts.json game_dicts; the CSV-derived STATE/TEXT/NEGOTIATION/GAME/
// KZONE/PHONE pools are empty in this repo's runtime (no csv_dicts dir), which
// is exactly the environment the goldens were recorded against.
// Returns a pointer to a (possibly empty) {str key -> display} map. The pointer
// stays valid for the process lifetime.
const std::map<std::string, std::string>* dict_pool(const std::string& name);
// Convenience: sorted set of a pool's string keys (never null).
std::set<std::string> dict_pool_keys(const std::string& name);
// ref_rules._dict_keys(target): nullptr when the target table has no built-in
// pool (EvtCfg/TalkCfg/... -> check_refs may skip the rule), else a pointer to
// the (possibly empty) pool keyed by str id.
const std::map<std::string, std::string>* ref_pool_for_target(const std::string& target);
// The same pools keyed by the data_dicts dict name (ROLE/ATTR/ITEM/RELATION/
// MAP/JOB/BG/STATE/TEXT/NEGOTIATION_SKILL/NEGOTIATION_BUFF/GAME/KZONE_POST/
// KZONE_MESSAGE/PHONE_MSG). Never null; empty for the CSV-derived ones here.
const std::map<std::string, std::string>& pool_by_key(const std::string& key);

// The static template DBs (arrays of {desc, code}) and placeholder map.
const json& condition_db();
const json& effect_db();
const json& effect_editor_db();  // derived per data_dicts._build_effect_editor_db
const json& cost_db();
const json& screen_effect_db();
const json& action_cmd_db();
const json& secondary_placeholder_map();  // {"@ATTR@": ["ATTR","属性"], ...}

// Resolve assets/schema.json + assets/dicts.json. Lookup order honours the
// wave-0 pattern (system_routes.cpp) plus the brief's fallbacks:
//   EDITOR_ASSETS_ROOT, SA_NATIVE_SOURCE_DIR/assets,
//   exe_dir/{assets, ../assets, ../../assets ...} walking up,
//   cwd/{assets, native/assets}.
std::string find_asset(const std::string& filename);

// For tests / smoke: allow forcing the assets root (empty resets to auto).
void set_assets_root_for_test(const std::string& root);

}  // namespace p1

// 简报钉死的对外名（合并后其他波次按这两个名字取用；实现即 p1 单例转发）。
inline const nlohmann::ordered_json& game_schema() { return p1::game_schema(); }
inline const nlohmann::ordered_json& game_dicts() { return p1::dicts(); }

}  // namespace sa
