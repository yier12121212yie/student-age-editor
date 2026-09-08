// wip/P3b AI domain service — port of backend/editor/server/ai_domain_service.py.
//
// Every table mutation goes through cfg_store::write_cfg (snapshot=True) and
// the wave-1 write-success quartet (invalidate table cache -> seed ->
// _note_mod_cfgs_write -> preview invalidate): the "AI 改模安全底线" of the
// brief. Sandbox refusal = sa::SandboxError -> 400 {"error": ...}.
//
// Official layout at merge: server/services/ai_domain_p3b.*
#pragma once

#include <string>

#include <nlohmann/json.hpp>

namespace sa {
namespace p3b {

using json = nlohmann::ordered_json;

// ai_domain_service.get_domains() — the 14 static domains + the `table`
// fallback rebuilt from game_schema() at runtime (golden-verified).
json get_domains();

// get_domain(domain_id); throws SandboxError("未知领域: ...").
json get_domain(const std::string& domain_id);

// _cfg_in_domain
bool cfg_in_domain(const std::string& domain_id, const std::string& cfg);

// load_cfg / cfg_exists (throws SandboxError like the Python originals;
// _cfg_path here means "未选择模组", the ai_domain flavour, not api.py's).
json load_cfg(const std::string& cfg_name);
bool cfg_exists(const std::string& cfg_name);

// save_cfg: .bak rolling copy + cfg_store::write_cfg + the write quartet.
void save_cfg(const std::string& cfg_name, const json& data);

// Entry-level ops (route layer wraps SandboxError -> 400).
json list_domain_items(const std::string& domain_id, const json& q, const json& limit,
                       const json& table);
json get_domain_item(const std::string& domain_id, const std::string& cfg, const json& key);
json update_domain_item(const std::string& domain_id, const std::string& cfg, const json& key,
                        const json& patch);
json create_domain_item(const std::string& domain_id, const std::string& cfg, const json& key,
                        const json& data);
json delete_domain_item(const std::string& domain_id, const std::string& cfg, const json& key);

// Exposed for [p3b] tests.
std::string auto_cn(const std::string& cfg_name);  // _auto_cn
std::string split_camel(const std::string& name);  // _split_camel
json coerce_patch(const std::string& cfg, const json& patch);  // _coerce_patch

}  // namespace p3b
}  // namespace sa
