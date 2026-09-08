// wip/P4/base_store.h — original (base-game) config tables from resource_scan
// artifacts (P4 owns this; implements the `stores_api.h` seam for P1/P3a).
//
// Data source: base-tables产物 — a directory holding
//   base_data/<Table>.json   (row-id-keyed object, ids are STRINGS)
//   base_meta.json           (sources[] + tables{} + missing_expected[])
// produced by `py -m resource_scan base-tables --out <dir>`. C++ NEVER parses
// bundles or pickle (ARTIFACT_FORMAT §4/§5): it only reads these JSON files.
//
// Staleness (§5): re-stat each base_meta.sources[].files entry (top-level only,
// no recursion) against its recorded mtime_ns/size; any mismatch means the
// product is stale and a re-run of the CLI is required (we do not rescan).
//
// Artifact dir resolution (first non-empty wins):
//   1. set_base_artifact_dir() / EDITOR_BASE_ARTIFACT_DIR (test + integration
//      injection seam — matches the "temp artifact" test strategy);
//   2. editor_env.json "base_data_dir";
//   3. "" => no artifact => status stays "idle" (golden/recorder env).
#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "server/services/stores_api.h"

namespace sa {

using json = nlohmann::ordered_json;

// Set/override the artifact directory at runtime (tests; also the merge-time
// hook the orchestrator can point at the real product dir). Rescans on next
// load().
void set_base_artifact_dir(const std::string& dir);
std::string base_artifact_dir();  // resolved (env/editor_env/setter) current value

class BaseStore final : public BaseStoreApi {
  public:
    BaseStore();

    // BaseStoreApi seam -----------------------------------------------
    bool available() const override;
    std::shared_ptr<const std::set<int64_t>> table_ids(const std::string& cfg) const override;
    std::shared_ptr<const json> table(const std::string& cfg) const override;
    std::vector<std::string> loaded_tables() const override;

    // Synchronous load from the artifact dir. `force` reloads even if ready.
    // Returns true when the store reached "ready". Never throws.
    bool load(bool force = false);

    // base_service.status_dict (shape for /api/base/status + 409 envelope).
    json status_dict() const;

    // base_service queries (pure over self.data; EvtCfg npc single/array safe).
    json search_events(const std::string& keyword, const std::string& npc_id,
                       const std::string& evt_type, long long page, long long per_page) const;
    json search_talks(const std::string& keyword, const json& mod_talk, const json& mod_evt,
                      long long limit) const;
    json extract_event(const std::string& evt_id) const;

    // Current status string (idle | loading | ready | error).
    std::string status() const;

  private:
    struct RowIndex {
        // Precomputed EvtCfg index for search_events (title validity, lower,
        // npc set, type string). Sorted by _nat_key(id) at build time.
        std::string id;
        std::string title;
        std::string title_lower;
        std::set<std::string> npc_set;
        json npc;  // raw field, echoed verbatim
        std::string type;
    };

    void build_evt_index_locked() const;
    std::shared_ptr<const json> table_shared_locked(const std::string& cfg) const;

    mutable std::mutex mu_;
    std::string status_ = "idle";
    std::string error_;
    std::vector<std::string> dirs_;
    // table -> shared immutable rows object (ids are strings). Shared pointers
    // keep callers' references stable across a concurrent reload (G3/B1).
    std::map<std::string, std::shared_ptr<const json>> data_;
    std::vector<std::string> loaded_;    // sorted
    std::vector<std::string> missing_;   // sorted
    std::string artifact_dir_;

    // A13 id caches (cleared on every (re)load).
    mutable std::map<std::string, std::shared_ptr<const std::set<int64_t>>> ids_cache_;
    // Lazy EvtCfg search index (invalidated on load).
    mutable std::shared_ptr<const std::vector<RowIndex>> evt_index_;
};

// Process singleton + registration helper. register_p4_base_store() creates the
// store, points the stores_api seam at it, and (best-effort) performs an initial
// synchronous load. Called from register_base_routes / test setup.
std::shared_ptr<BaseStore> base_store_instance();
void register_p4_base_store();

}  // namespace sa
