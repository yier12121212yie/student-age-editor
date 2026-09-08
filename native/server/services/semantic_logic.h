// wip/P1/semantic_logic.h — ports of the guide/ref/bugfix semantic engines.
//
//   guide_rules.py  -> validate_record / validate_cross / describe_screen_row /
//                      describe_action_row / check_*_id / _norm_cfg_name
//   ref_rules.py    -> check_refs (declarative cross-table reference rules)
//   data_dicts.py   -> build_secondary_template_index / match_secondary_template /
//                      render_secondary_template / validate_secondary_item
//   bugfix_service.py-> format_to_display / parse_from_display / scan_bugs / apply_fix
//
// All take/return Python-shaped nlohmann::ordered_json so the HTTP layer can
// forward them verbatim. Issues are the same (level, msg) tuples / dicts the
// Python code produces — do NOT reshape.
#pragma once

#include <map>
#include <set>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {
namespace p1 {

using json = nlohmann::ordered_json;

// ---------------------------------------------------------------------------
// shared scalar helpers (mirrors of the Python one-liners)
// ---------------------------------------------------------------------------
// guide_rules._to_int: bool/str-digit/float-integer -> value; else null.
std::optional<long long> to_int(const json& v);
// ref_rules._to_int_loose: also accepts "123.0" strings.
std::optional<long long> to_int_loose(const json& v);
std::optional<double> to_float(const json& v);
// data_dicts._normalize_scalar -> canonical str for a scalar cell.
std::string normalize_scalar(const json& v);
// data_dicts._is_numeric_token.
bool is_numeric_token(const std::string& s);

// ---------------------------------------------------------------------------
// secondary template index (data_dicts.build_secondary_template_index)
// ---------------------------------------------------------------------------
struct SecondaryIndex {
    // type_name_map is empty in this repo (no csv_dicts); kept for parity.
    std::map<std::string, std::string> type_name_map;
    std::map<std::string, std::string> type_source_map;
    // by_primary[p] and by_signature[p][s] hold template dicts.
    std::map<std::string, std::vector<json>> by_primary;
    std::map<std::string, std::map<std::string, std::vector<json>>> by_signature;
};

// Build once per DB (entries reference the same {desc,code} objects).
SecondaryIndex build_secondary_index(const json& entries);
const SecondaryIndex& condition_secondary_index();
const SecondaryIndex& effect_secondary_index();
const SecondaryIndex& effect_editor_secondary_index();

// data_dicts.validate_secondary_item. available: pool-name -> {str key ->
// display}. Membership-only pools with an unknown display use an empty string.
// Returns {"translation": str, "errors": [str...], "template": obj?}.
using AvailableMap = std::map<std::string, std::map<std::string, std::string>>;
json validate_secondary_item(const json& item_arr, const SecondaryIndex& idx,
                             const AvailableMap& available);

// ---------------------------------------------------------------------------
// guide_rules.py
// ---------------------------------------------------------------------------
std::string norm_cfg_name(const std::string& raw);

// [(level, msg)] as a JSON array of [level, msg] pairs (Python tuple list).
json validate_record(const std::string& cfg_name, const std::string& rid, const json& record);
// tables: {cfg: {rid: rec}}; base_ids: {cfg: set-like iterable of ids (json array)}.
json validate_cross(const json& tables, const json& base_ids);

// (desc, [errors]) as {"desc": str, "errors": [str...]}
json describe_screen_row(const json& row);
json describe_action_row(const json& row);

// ---------------------------------------------------------------------------
// ref_rules.py
// ---------------------------------------------------------------------------
// check_refs -> issues array of dicts {cfg,rid,field,value,target,array,healed,desc}.
json check_refs(const json& tables, const json& extra_ids);

// ---------------------------------------------------------------------------
// bugfix_service.py
// ---------------------------------------------------------------------------
std::string format_to_display(const json& val, const std::string& key, const std::string& cfg_name);
json parse_from_display(const std::string& text, const std::string& key, const json& original_val,
                        const std::string& cfg_name);
// scan_bugs(mod_cfgs, base_cfgs, only_tables|null) -> bugs array.
// read_only_view：历史遗留——D16 缺陷（api.py 生产路径 MappingProxyType 过
// isinstance(dict) 门导致 S1/S2/S4/REF 段空转）已于两侧修复：Python 侧门放宽为
// Mapping（bugfix_service.py/ref_rules.py），路由侧恒传 false 走全语义。
// 参数保留仅为对照历史行为，波次 3 归一时删除。
json scan_bugs(const json& mod_data, const json& base_data,
               const std::set<std::string>* only_tables, bool read_only_view = false);
// apply_fix mutates mod_data in place (private fork). Returns whether changed.
bool apply_fix(json& mod_data, const json& bug);

}  // namespace p1
}  // namespace sa
