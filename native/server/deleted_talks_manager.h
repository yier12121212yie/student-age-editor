// server/deleted_talks_manager: Tombstone-based deletion semantics for TalkCfg/EvtCfg.
//
// Why? Current hard-delete causes ID jumps and orphaned references across sessions.
// Solution: Track deleted IDs in <mod>/StudentAgeEditor/deleted-talks.json with mapping:
//   "original_id": ["replacement_id"]  (redirect to new ID)
//   "original_id": null                 (permanent tombstone/inert_talk placeholder)
//
// On save/load: resolve_next_talk() follows tombstones, preserving reference integrity.
#pragma once

#include <string>
#include <optional>
#include <vector>
#include <unordered_map>
#include <nlohmann/json.hpp>

namespace sa {
namespace deleted_talks_manager {

using json = nlohmann::ordered_json;

// Structure for tombstone entry: {old_id -> [new_ids] | null}
struct TombstoneEntry {
    std::vector<std::string> replacement_ids;  // empty = permanent tombstone
};

// Set workspace root for tombstone file path resolution
void set_workspace_root(const std::string& root);

// Load all tombstones from disk (cached until next write).
// Returns map of old_id -> replacement_ids
std::unordered_map<std::string, std::vector<std::string>> load_all();

// Get a single tombstone entry for a specific ID
std::optional<std::vector<std::string>> get(const std::string& old_id);

// Register a new tombstone (called after delete operation):
//   - If replacement_ids is non-empty: maps old_id -> [new_id, ...]
//   - If empty: creates permanent tombstone (null entry)
bool register_tombstone(const std::string& old_id, const std::vector<std::string>& replacement_ids);

// Resolve next_talk through tombstones (e.g., if current_id points to deleted node, redirect to new one).
std::optional<std::string> resolve_next_talk(const std::string& current_id);

// Check if an ID was deleted (without returning the mapping).
bool is_deleted(const std::string& id);

// Persist tombstones to disk (called after writes complete).
bool persist();

// Clear all tombstones (used when merging mods or bulk operations).
void clear_all();

// Debug helpers
size_t count();  // Total number of tombstone entries
bool has_pending_changes();  // True if tombstones modified but not persisted yet

}  // namespace deleted_talks_manager
}  // namespace sa
