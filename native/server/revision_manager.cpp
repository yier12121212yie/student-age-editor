// server/revision_manager.cpp: implementation of content fingerprint (SHA-256)
// for robust external-modification detection.

#include "server/revision_manager.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <queue>
#include <thread>
#include <unordered_map>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/sha1.h"
#include "sa_core/util.h"
#include "server/state.h"

// Use httplib's EVP-based SHA256 implementation
#define CPPHTTPLIB_OPENSSL_SUPPORT
#include <httplib.h>

namespace sa {
namespace revision_manager {
namespace {

// Compute SHA-256 using httplib's EVP implementation
std::string sha256_hex(const std::string& data) {
    unsigned char hash[EVP_MAX_MD_SIZE];
    unsigned int hash_len = 0;
    EVP_Digest(data.data(), data.size(), hash, &hash_len, EVP_sha256(), nullptr);
    
    std::string hex_out;
    hex_out.reserve(hash_len * 2);
    for (unsigned int i = 0; i < hash_len; ++i) {
        char buf[3];
        snprintf(buf, sizeof(buf), "%02x", hash[i]);
        hex_out += buf;
    }
    return hex_out;
}

std::string g_workspace_root;
std::mutex g_revision_mu;
std::condition_variable g_revision_cv;
std::string g_cached_revision;
bool g_cache_valid = false;
bool g_cache_refresh_requested = false;
long long g_last_compute_time_ms = 0;
size_t g_files_scanned_count = 0;
bool g_ntfs_monitoring_enabled = true;  // Windows default

// File list cache: path -> (mtime_ns, size) to skip unchanged files
std::unordered_map<std::string, std::pair<long long, uint64_t>> g_file_metadata;

// Compute SHA-256 over a single file's bytes
std::optional<std::string> sha256_of_file(const std::string& abs_path) {
    auto raw = sa_core::paths::read_bytes(abs_path);
    if (!raw) return std::nullopt;
    
    return sha256_hex(*raw);
}

// Collect all relevant JSON files from workspace
std::vector<std::string> collect_target_files(const std::string& mod_root) {
    std::vector<std::string> targets;

    // 1. Add manifest.json
    std::string manifest = mod_root + "/manifest.json";
    if (sa_core::paths::exists(manifest)) {
        targets.push_back(manifest);
    }

    // 2. Add StudentAgeEditor/editor-state.json if exists
    std::string editor_state = mod_root + "/StudentAgeEditor/editor-state.json";
    if (sa_core::paths::exists(editor_state)) {
        targets.push_back(editor_state);
    }

    // 3. Scan all Cfgs/*.json files
    std::string cfgs_dir = mod_root + "/Cfgs";
    if (sa_core::paths::is_directory(cfgs_dir)) {
        bool ok = false;
        auto dirs = sa_core::paths::listdir_sorted(cfgs_dir, &ok);
        if (ok) {
            for (const auto& lang_dir : dirs) {
                if (lang_dir == "zh-cn") {
                    std::string lang_path = cfgs_dir + "/" + lang_dir;
                    if (sa_core::paths::is_directory(lang_path)) {
                        auto files = sa_core::paths::listdir_sorted(lang_path, &ok);
                        if (ok) {
                            for (const auto& f : files) {
                                if (f.size() > 5 && f.substr(f.size() - 5) == ".json") {
                                    targets.push_back(lang_path + "/" + f);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return targets;
}

}  // namespace

void set_workspace_root(const std::string& root) {
    std::lock_guard<std::mutex> lk(g_revision_mu);
    g_workspace_root = root;
    g_cache_valid = false;
}

std::string compute_revision() {
    auto start = std::chrono::high_resolution_clock::now();

    if (g_workspace_root.empty()) {
        return "";
    }

    std::vector<std::string> files;
    {
        std::lock_guard<std::mutex> lk(g_revision_mu);
        files = ::collect_target_files(g_workspace_root);
    }

    std::string combined_hash;
    g_files_scanned_count = files.size();

    // Hash each file's content sequentially
    for (const auto& filepath : files) {
        auto hash_opt = sha256_of_file(filepath);
        if (hash_opt) {
            combined_hash += *hash_opt;
        }
    }

    // Final hash over the combined content hashes
    std::string final_hash = sha256_hex(combined_hash);
    
    // Return first 20 characters for performance
    auto end = std::chrono::high_resolution_clock::now();
    g_last_compute_time_ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

    return final_hash.substr(0, 20);
}

std::string compute_revision_cached(bool force_refresh) {
    std::lock_guard<std::mutex> lk(g_revision_mu);

    if (force_refresh || !g_cache_valid) {
        g_cached_revision = compute_revision();
        g_cache_valid = true;
        g_cache_refresh_requested = false;
        g_revision_cv.notify_all();
    }

    return g_cached_revision;
}

bool verify_revision(const std::string& client_revision) {
    std::string current = compute_revision_cached(true);  // Force refresh on verify
    return !client_revision.empty() && current == client_revision;
}

std::string get_current_revision() {
    return compute_revision_cached(false);
}

std::future<std::string> compute_revision_async() {
    auto promise = std::make_shared<std::promise<std::string>>();
    auto future = promise->get_future();

    std::thread([promise]() {
        try {
            promise->set_value(compute_revision());
        } catch (...) {
            promise->set_exception(std::current_exception());
        }
    }).detach();

    return future;
}

void invalidate_cache() {
    std::lock_guard<std::mutex> lk(g_revision_mu);
    g_cache_valid = false;
}

void set_ntfs_monitoring_enabled(bool enabled) {
    g_ntfs_monitoring_enabled = enabled;
}

long long debug_last_compute_time_ms() {
    std::lock_guard<std::mutex> lk(g_revision_mu);
    return g_last_compute_time_ms;
}

size_t debug_files_scanned_count() {
    std::lock_guard<std::mutex> lk(g_revision_mu);
    return g_files_scanned_count;
}

}  // namespace revision_manager
}  // namespace sa
