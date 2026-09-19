// server/services/deleted_routes.cpp — /api/cfg/deleted_talks endpoint.
// P8 Tombstone Semantics: Query all tombstone entries.
#include <algorithm>
#include <set>
#include <string>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "server/api_router.h"
#include "server/state.h"
#include "server/deleted_talks_manager.h"

namespace sa {

void register_deleted_routes(Router& r) {
    // GET /api/cfg/deleted_talks — Return all tombstone entries for UI rendering.
    r.get(R"(/api/cfg/deleted_talks)", [](const Req&) -> Resp {
        std::string mod_root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            mod_root = STATE().mod_root;
        }
        
        if (mod_root.empty()) {
            return Resp::Json(400, json{{"error", "no mod selected"}});
        }
        
        deleted_talks_manager::set_workspace_root(mod_root);
        auto tombstones = deleted_talks_manager::load_all();
        
        // Convert to ordered JSON object (preserve insertion order)
        json result = json::object();
        for (const auto& [old_id, replacements] : tombstones) {
            if (replacements.empty()) {
                // Permanent tombstone (null)
                result[old_id] = json();
            } else {
                // Redirect array
                json arr = json::array();
                for (const auto& r : replacements) {
                    arr.push_back(r);
                }
                result[old_id] = std::move(arr);
            }
        }
        
        json body;
        body["tombstones"] = std::move(result);
        body["count"] = static_cast<long long>(tombstones.size());
        return Resp::Json(200, std::move(body));
    });
}

}  // namespace sa
