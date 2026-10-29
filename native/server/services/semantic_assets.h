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
// assets/PersonCfg.json: 官方人物表（id -> {name,gender,url,url2}）。作 /api/roles
// 在工作区 mod 与已加载 base 数据都没有 PersonCfg 时的兜底。
const json& person_cfg();
// assets/BgCfg.json: 官方背景表（id -> {id,url,...}）。作 /api/preview/meta
// 与剧情流在工作区 mod 与已加载 base 数据都没有 BgCfg 时的兜底。
const json& bg_cfg();

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

// ---- A1 模板语义元数据（概念折叠 / 行内算符 / 参数标签） --------------------
// 纯函数：仅由模板串 (desc, code) 派生，/api/effect_suggest 与 /api/effect/parse
// 共用同一实现（两端模板串同源），因此「同一概念返回一致的 family/ops」由构造保证。
//
// template_meta 返回：
//   family        概念键 "一级代码|骨架"。骨架 = desc 去算符（≥/≤/</范围…）、
//                 去裸值记号（V/X/Y…）、去纯数字后的词串，保留 @PLACEHOLDER@ 与
//                 括号提示——同键即可折叠成一条概念（≥/≤/范围 等多变体同键）。
//   label         折叠行标题（骨架另去括号提示；空则回退 family 骨架）。
//   description   原 desc（模板的白话说明，逐字）。
//   op            本模板算符：= > ≥ < ≤ ≠ 范围 之一，无则 ""。
//   value_index   code 逗号段中「值」的下标（范围=下限），-1 表示无。
//   upper_index   范围模板中「上限值」的下标，非范围恒 -1。
//   labels        裸字母槽名 -> 人话标签（范围=下限/上限；否则取 desc 中该值
//                 最近的上文词，兜底 "数值"）。
json template_meta(const std::string& desc, const std::string& code);

// 同概念全部变体（含自身），按 = > ≥ < ≤ ≠ 范围 循环序、无算符殿后：
//   [{op, code, value_index, upper_index, slots:[…code_slots…]}, …]
// slots 内嵌使前端切换算符后无需回查即可重排参数表单。
// mode ∈ effect|condition|cost|action|screen，与 /api/effect_suggest 同口径
// （effect 走 EFFECT_EDITOR_DB，与 effect_editor_secondary_index 同源）。
json family_ops(const std::string& mode, const std::string& desc, const std::string& code);

// mode -> 静态码表；effect = EFFECT_EDITOR_DB，condition/cost/action/screen 同名。
const json& mode_db(const std::string& mode);

// code 模板里的参数槽（原 /api/effect_suggest 实现，迁此共享）：
//   "@NAME@" -> dict 槽 {kind,name,dict,label,count}（dict/label 来自
//               SECONDARY_PLACEHOLDER_MAP；未知池 dict=""）
//   裸字母   -> number 槽 {kind,name,count}；重复字母合并为一个槽并计 count。
json code_slots(const std::string& code);

// Resolve assets/schema.json + assets/dicts.json. Thin forward to
// sa_core::assets::find_asset — the single resolver for the whole backend
// (candidate list documented in sa_core/assets.h).
std::string find_asset(const std::string& filename);

// For tests / smoke: allow forcing the assets root (empty resets to auto).
// Forwards to sa_core::assets::set_assets_root_override.
void set_assets_root_for_test(const std::string& root);

}  // namespace p1

// 简报钉死的对外名（合并后其他波次按这两个名字取用；实现即 p1 单例转发）。
inline const nlohmann::ordered_json& game_schema() { return p1::game_schema(); }
inline const nlohmann::ordered_json& game_dicts() { return p1::dicts(); }

}  // namespace sa
