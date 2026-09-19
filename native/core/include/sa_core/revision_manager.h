// sa_core/include/revision_manager.h
// Content fingerprint revision mechanism with SHA-256 + NTFS ChangeTime support
// Prevents external modification bypass via mtime spoofing

#ifndef SA_CORE_REVISION_MANAGER_H
#define SA_CORE_REVISION_MANAGER_H

#include <string>
#include <vector>
#include <path>
#include <mutex>
#include "sa_core/status.h"

namespace sa {

/**
 * @brief Revision manager for detecting content modifications
 * 
 * Implementation details:
 * - Computes SHA-256 hash of all cfg.json + manifest.json + editor-state.json
 * - On Windows: reads NTFS ChangeTime via USN Journal for tamper detection
 * - Returns 20-character short hash (SHA-256[:20])
 * - Uses streaming chunked reading to avoid memory overflow on large workspaces
 */
class RevisionManager {
public:
    explicit RevisionManager(const path& workspace);
    
    /**
     * @brief Compute current workspace revision fingerprint
     * @return Status with short hash string on success, empty string on error
     * 
     * Algorithm:
     * 1. Recursively collect all cfg.json, manifest.json, editor-state.json files
     * 2. Sort paths for deterministic order
     * 3. Stream-read each file in 64KB chunks, update SHA-256 context
     * 4. On Windows: read CTE (ChangeTime) from USN Journal or CallNtfsViewFileUsnJournal
     * 5. Merge ChangeTime into final hash (4 bytes per file, nanoseconds)
     * 6. Return first 20 chars of hex-encoded SHA-256
     */
    StatusOr<std::string> ComputeRevision();
    
    /**
     * @brief Verify client-provided revision matches current state
     * @param client_revision Client's last known revision
     * @return true if revisions match (optimistic lock OK), false if 409 Conflict
     * 
     * Usage: PUT /api/save/{path}?revision={client_revision}
     */
    bool VerifyRevision(const std::string& client_revision);
    
    /**
     * @brief Get full SHA-256 hash for integrity verification
     * @return 64-char hex string
     */
    std::string GetFullHash() const;
    
private:
    path workspace_;
    mutable std::mutex mutex_;
    std::string cached_full_hash_;
    bool hash_computed_ = false;
    
    // File list collection with deterministic ordering
    StatusOr<std::vector<path>> CollectConfigFiles();
    
    // Chunked SHA-256 computation (64KB chunks)
    void UpdateSha256FromFile(sha256_context* ctx, const path& file);
    
    // Windows-specific NTFS ChangeTime extraction
#ifdef _WIN32
    StatusOr<uint64_t> ReadChangeTimeNanos(const path& file);
#endif
    
    // Cache management: update internal state after successful save
    void UpdateCache();
};

} // namespace sa

#endif // SA_CORE_REVISION_MANAGER_H
