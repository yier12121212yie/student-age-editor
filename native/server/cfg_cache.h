// server/cfg_cache: the three-layer read caches (port of api.py:333-604).
//
//  * _TABLE_CACHE  — hot big-table bodies for the zero-parse/zero-dump GET path
//    (api.py:466-591, CONVENTIONS 5.1): key = absolute path, value =
//    {mtime_ns, size, data, body_bytes, lossy}; max 3 entries, only bodies
//    >= 256KB are stored, FIFO eviction, write-after seeding (S1).
//  * _MOD_CFGS_CACHE — per-table fingerprint whole-mod cache (api.py:333-456,
//    CONVENTIONS 5.2): read-only views (shared_ptr<const json>), per-table
//    (mtime_ns,size) fingerprints so one write only re-parses one table, B16
//    broken-table ledger, CustomKeyMap.json excluded.
//  * The cfg_store parse provider glue (api.py:1021-1037).
//
// Lock discipline (CONVENTIONS 6): L3 = table cache, L4 = mod-cfgs cache;
// independent shared_mutexes, never nested. Shared lock for reads, exclusive
// for writes, and no disk IO while a cache lock is held.
#pragma once

#include <memory>
#include <optional>
#include <string>

#include <nlohmann/json.hpp>

#include "server/cfg_store.h"

namespace sa {

using json = nlohmann::ordered_json;

struct TableFingerprint {
    long long mtime_ns = 0;
    long long size = 0;
};

std::optional<TableFingerprint> stat_fp(const std::string& path);

// api.py:521-591 _load_table_cached result
struct TableLoad {
    std::string state;  // "ok" | "missing" | "error"
    std::shared_ptr<const json> data;
    std::optional<long long> mtime_ns;
    std::string error;
    bool lossy = false;
};

// Reads through the table cache: hit = zero read_bytes / parses / dumps;
// miss reads the file once (bump cfg.read_bytes), parses (cfg.parses) and
// serializes the full payload (cfg.dumps). Bodies >= 256KB get cached.
TableLoad load_table_cached(const std::string& path, const std::string& cfg_name);

// api.py:488-506 _seed_table_cache: after a successful write, build the cached
// body from the known data so the next GET is a pure cache hit. Bumps cfg.dumps
// (it IS a real serialization) but not reads/parses.
void seed_table_cache(const std::string& path, const std::string& cfg_name, const json& data,
                      std::optional<long long> mtime_ns, bool lossy = false);

// api.py:480-486 _invalidate_table_cache(abs_path=None clears all).
void invalidate_table_cache(const std::string& abs_path);
void invalidate_table_cache_all();

// api.py:333-456 mod-cfgs cache ------------------------------------------------

// Read-only whole-mod view: {cfg_name: const data}. Fingerprint-matched tables
// are reused with zero parsing (A10). Broken tables go to `broken` (B16).
struct ModCfgsView {
    std::map<std::string, std::shared_ptr<const json>> tables;
    std::map<std::string, std::string> broken;  // cfg_name -> error text
};
ModCfgsView load_mod_cfgs();

// api.py:433-456 _fork_mod_table: private writable copy for writers (G3/B1).
json fork_mod_table(const std::string& cfg_name);

// api.py:346-359 _note_mod_cfgs_write: refresh one table + its fingerprint.
void note_mod_cfgs_write(const std::string& cfg_name, const json& data, const std::string& path);

// api.py:459-463 _invalidate_mod_cfgs_cache (fingerprints drop; select_mod and
// undo/redo call it).
void invalidate_mod_cfgs_cache();

// cfg_store parse-provider view (api.py:1021-1035): hit -> (data, lossy,
// mtime_ns); registered on the cfg_store side at startup.
std::optional<cfg_store::ProviderHit> cfgstore_parse_provider(const std::string& abs_path);

// Install the provider into cfg_store (idempotent, called once from
// register_cfg_routes / test setup).
void install_parse_provider();

// Debug helpers for tests.
size_t table_cache_size();

// The bytes-direct hit for GET /api/cfg/<name> (api.py:1004-1009): cache entry
// with matching mtime and a non-empty body. Returns the stored body WITHOUT any
// cfg.dumps bump — that absence is the S1 acceptance metric.
std::optional<std::string> table_cache_body_for(const std::string& path, long long mtime_ns);

}  // namespace sa
