// server/deleted_talks_manager.cpp: Implementation of tombstone-based deletion semantics.

#include "server/deleted_talks_manager.h"

#include <algorithm>
#include <fstream>
#include <mutex>
#include <set>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "server/state.h"

namespace sa {
namespace deleted_talks_manager {
namespace {

using sa_core::paths;

std::string g_workspace_root;
std::mutex g_mutex;

// In-memory tombstone cache (loaded once per session, modified on delete)
std::unordered_map<std::string, std::vector<std::string>> g_tombstones;
bool g_has_pending_changes = false;

std::string tombstone_file_path() {
    return g_workspace_root + "/StudentAgeEditor/deleted-talks.json";
}

}  // namespace

void set_workspace_root(const std::string& root) {
    std::lock_guard<std::mutex> lk(g_mutex);
    g_workspace_root = root;
}

std::unordered_map<std::string, std::vector<std::string>> load_all() {
    std::lock_guard<std::mutex> lk(g_mutex);

    if (!g_workspace_root.empty() && !g_has_pending_changes) {
        // Try loading from disk only once, unless explicitly reloaded
        std::string path = tombstone_file_path();
        auto raw = paths::read_bytes(path);
        if (raw) {
            try {
                json data = json::parse(*raw);
                for (auto it = data.begin(); it != data.end(); ++it) {
                    const std::string& old_id = it.key();
                    const json& value = it.value();
                    if (value.is_array()) {
                        std::vector<std::string> replacements;
                        for (const auto& item : value) {
                            if (item.is_string()) {
                                replacements.push_back(item.get<std::string>());
                            }
                        }
                        g_tombstones[old_id] = std::move(replacements);
                    } else if (value.is_null()) {
                        // Permanent tombstone (null = inert_talk placeholder)
                        g_tombstones[old_id] = {};  // Empty vector = null
                    }
                }
            } catch (...) {
                // Malformed JSON -> ignore and start fresh
            }
        }
    }

    return g_tombstones;
}

std::optional<std::vector<std::string>> get(const std::string& old_id) {
    std::lock_guard<std::mutex> lk(g_mutex);
    auto it = g_tombstones.find(old_id);
    if (it != g_tombstones.end()) {
        return it->second;
    }
    return std::nullopt;
}

bool register_tombstone(const std::string& old_id, const std::vector<std::string>& replacement_ids) {
    std::lock_guard<std::mutex> lk(g_mutex);
    
    // Check if already registered (no-op if exists)
    auto existing = g_tombstones.find(old_id);
    if (existing != g_tombstones.end()) {
        // Update if different
        if (existing->second != replacement_ids) {
            existing->second = replacement_ids;
            g_has_pending_changes = true;
        }
        return true;
    }
    
    // New tombstone entry
    g_tombstones[old_id] = replacement_ids;
    g_has_pending_changes = true;
    return true;
}

std::optional<std::string> resolve_next_talk(const std::string& current_id) {
    std::lock_guard<std::mutex> lk(g_mutex);
    
    auto it = g_tombstones.find(current_id);
    if (it != g_tombstones.end()) {
        // If has replacements, return the first one
        if (!it->second.empty()) {
            return it->second[0];
        }
        // Otherwise, this is a permanent tombstone (inert_talk) - return nullopt
        return std::nullopt;
    }
    
    // Not deleted, return original ID
    return current_id;
}

bool is_deleted(const std::string& id) {
    std::lock_guard<std::mutex> lk(g_mutex);
    return g_tombstones.find(id) != g_tombstones.end();
}

bool persist() {
    std::lock_guard<std::mutex> lk(g_mutex);

    if (!g_has_pending_changes || g_workspace_root.empty()) {
        return true;  // Nothing to write
    }

    // Convert map to JSON object
    json data = json::object();
    for (const auto& [old_id, replacements] : g_tombstones) {
        if (replacements.empty()) {
            // Permanent tombstone -> null
            data[old_id] = json();
        } else {
            // Redirect array
            json arr = json::array();
            for (const auto& r : replacements) {
                arr.push_back(r);
            }
            data[old_id] = std::move(arr);
        }
    }

    // Ensure parent directory exists
    std::string dir = paths::dirname(tombstone_file_path());
    paths::make_dirs(dir);

    // Write atomically
    std::string json_str = data.dump(4);  // Pretty-print with indent=2

    try {
        paths::write_bytes_atomic(tombstone_file_path(), json_str);
        g_has_pending_changes = false;
        return true;
    } catch (...) {
        return false;
    }
}

void clear_all() {
    std::lock_guard<std::mutex> lk(g_mutex);
    g_tombstones.clear();
    g_has_pending_changes = true;
}

size_t count() {
    std::lock_guard<std::mutex> lk(g_mutex);
    return g_tombstones.size();
}

bool has_pending_changes() {
    std::lock_guard<std::mutex> lk(g_mutex);
    return g_has_pending_changes;
}

}  // namespace deleted_talks_manager
}  // namespace sa
