// server/revision_manager: workspace content fingerprint (SHA-256) + NTFS ChangeTime
// for robust external-modification detection (CONVENTIONS 5.7).
//
// Why? Current mtime_ns only misses "same-size re-timestamp" attacks.
// Solution: compute SHA-256 over ALL cfg.json + manifest.json + editor-state.json,
// optionally include Windows NTFS UsnJournal change timestamp to detect size-restored edits.
//
// Usage pattern:
//   - Client calls GET /api/workspace/revision → gets current_hash (e.g., "a1b2c3d4...")
//   - Frontend caches hash in memory before save operation
//   - PUT requests carry header X-Revision or body field "revision": client_side_hash
//   - Server verifies hash matches; on mismatch return 409 Conflict with fresh hash
//
// Performance budget: compute_revision ≤ 500ms for workspace ≤ 500MB (chunked reading).
#pragma once

#include <string>
#include <optional>
#include <future>
#include <atomic>

#include <nlohmann/json.hpp>

namespace sa {
namespace revision_manager {

using json = nlohmann::ordered_json;

// Workspace root directory (from state.mod_root). Used to scan all cfg files.
void set_workspace_root(const std::string& root);

// Compute current workspace SHA-256 hash of:
//   1. All *.json files in Cfgs/zh-cn/ (cfg tables)
//   2. manifest.json at mod root
//   3. StudentAgeEditor/editor-state.json if exists
// Returns 20-char hex digest (truncated from full SHA-256) or empty on error.
std::string compute_revision();

// Optimize by computing only changed subdirs (for incremental scans).
// If last_known_revision is provided, scan only modified paths since that revision.
// For now, full scan is acceptable (≤500ms).
std::string compute_revision_cached(bool force_refresh = false);

// Verify client-provided revision matches current; returns true if match.
// Also updates internal cache with latest hash.
bool verify_revision(const std::string& client_revision);

// Get current revision without cache update (read-only).
std::string get_current_revision();

// Async computation: returns future<string>; useful for background warmup.
std::future<std::string> compute_revision_async();

// Cache invalidation: called when local write succeeds (to invalidate any cached state).
void invalidate_cache();

// NTFS-specific: enable/disable ChangeTime monitoring (Windows only).
// Default: enabled on Windows, disabled on other platforms.
void set_ntfs_monitoring_enabled(bool enabled);

// Debug helpers
long long debug_last_compute_time_ms();
size_t debug_files_scanned_count();

}  // namespace revision_manager
}  // namespace sa
