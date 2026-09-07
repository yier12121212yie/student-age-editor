#include "server/cfg_cache.h"

#include <algorithm>
#include <deque>
#include <map>
#include <memory>
#include <shared_mutex>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/cfg_store.h"
#include "server/perf.h"
#include "server/state.h"

namespace sa {
namespace {

namespace cs = sa_core::paths;

// ---------------------------------------------------------------------------
// _TABLE_CACHE (api.py:466-591, CONVENTIONS 5.1 / S1 免序列化三零)
// ---------------------------------------------------------------------------

constexpr size_t kTableCacheMax = 3;                // _TABLE_CACHE_MAX
constexpr size_t kTableCacheMinBody = 256 * 1024;   // _TABLE_CACHE_MIN_BODY

struct TableEntry {
    std::string key;  // path_key of the absolute path
    long long mtime_ns = 0;
    long long size = 0;
    std::shared_ptr<const json> data;
    std::string body;  // pre-serialized GET payload (bytes 直发 source)
    bool lossy = false;
};

std::shared_mutex g_table_mu;  // L3
std::deque<TableEntry> g_table;

// Byte-identical to py_dumps({"cfg","data","exists","mtime_ns"[,"lossy"]}) but
// without materializing a second copy of the (40MB) data tree: the response
// body is assembled from pieces. Field order matches the Python dict literal.
std::string build_table_body(const std::string& cfg_name, const json& data, long long mtime_ns,
                             bool lossy) {
    std::string out;
    out.reserve(256);
    out += "{\"cfg\": ";
    out += sa_core::py_dumps(json(cfg_name));
    out += ", \"data\": ";
    out += sa_core::py_dumps(data);
    out += ", \"exists\": true, \"mtime_ns\": ";
    out += std::to_string(mtime_ns);
    if (lossy) out += ", \"lossy\": true";
    out += "}";
    return out;
}

void table_store(const std::string& key, long long mtime_ns, long long size,
                 std::shared_ptr<const json> data, std::string body, bool lossy) {
    std::unique_lock<std::shared_mutex> lk(g_table_mu);
    for (auto& e : g_table) {
        if (e.key == key) {  // in-place refresh keeps FIFO insertion position
            e.mtime_ns = mtime_ns;
            e.size = size;
            e.data = std::move(data);
            e.body = std::move(body);
            e.lossy = lossy;
            return;
        }
    }
    TableEntry e;
    e.key = key;
    e.mtime_ns = mtime_ns;
    e.size = size;
    e.data = std::move(data);
    e.body = std::move(body);
    e.lossy = lossy;
    g_table.push_back(std::move(e));
    while (g_table.size() > kTableCacheMax) g_table.pop_front();  // FIFO, not LRU
}

// ---------------------------------------------------------------------------
// _MOD_CFGS_CACHE (api.py:333-456, CONVENTIONS 5.2)
// ---------------------------------------------------------------------------

std::shared_mutex g_mod_cfgs_mu;  // L4
std::map<std::string, std::shared_ptr<const json>> g_mod_cfgs_cache;  // cfg_name -> table
std::map<std::string, std::pair<long long, long long>> g_mod_cfgs_fp;  // "X.json" -> (mtime,size)
bool g_mod_cfgs_fp_valid = false;  // _MOD_CFGS_FP is None until first full load
std::string g_mod_cfgs_dir;        // the cfg_dir these fingerprints belong to
std::map<std::string, std::string> g_mod_cfgs_broken;  // B16 ledger

}  // namespace

// ---------------------------------------------------------------------------
// table cache public API
// ---------------------------------------------------------------------------

std::optional<TableFingerprint> stat_fp(const std::string& path) {
    auto st = cs::stat(path);
    if (!st) return std::nullopt;
    return TableFingerprint{st->mtime_ns, st->size};
}

TableLoad load_table_cached(const std::string& path, const std::string& cfg_name) {
    TableLoad missing;
    missing.state = "missing";
    if (!cs::is_file(path)) return missing;
    auto fp = stat_fp(path);
    if (!fp) return missing;

    const std::string key = cs::path_key(path);
    {
        std::shared_lock<std::shared_mutex> lk(g_table_mu);
        for (const auto& e : g_table) {
            if (e.key == key && e.mtime_ns == fp->mtime_ns && e.size == fp->size) {
                TableLoad hit;
                hit.state = "ok";
                hit.data = e.data;
                hit.mtime_ns = fp->mtime_ns;
                hit.lossy = e.lossy;
                return hit;
            }
        }
    }

    // Miss: one real read, strict decode then lenient (B2), parse, serialize.
    auto raw = cs::read_bytes(path);
    if (!raw) return missing;  // read raced with deletion -> "missing"
    sa::bump(lc::kCfgReadBytes, static_cast<long long>(raw->size()));
    std::string content;
    bool lossy = false;
    auto strict = sa_core::decode_utf8_sig_strict(*raw);
    if (strict) {
        content = std::move(*strict);
    } else {
        content = sa_core::decode_utf8_sig_replace(*raw);
        lossy = true;
    }
    content = sa_core::str::trim(content);
    json data;
    if (content.empty()) {
        data = json::object();
    } else {
        json parsed = json::parse(content, nullptr, false);
        if (parsed.is_discarded()) {
            TableLoad err;
            err.state = "error";
            err.mtime_ns = fp->mtime_ns;
            err.error = "JSON parse failed: 文件内容不是合法 JSON";
            err.lossy = lossy;
            return err;
        }
        sa::bump(lc::kCfgParses);  // every REAL parse counts 1 (hot GET == 0)
        // api.py:572-573: non-object top level behaves like {}
        data = parsed.is_object() ? std::move(parsed) : json::object();
    }

    auto shared = std::make_shared<const json>(std::move(data));
    std::string body;
    try {
        body = build_table_body(cfg_name, *shared, fp->mtime_ns, lossy);
        sa::bump(lc::kCfgDumps);  // real serialization only; bytes 直发 never bumps
        if (body.size() >= kTableCacheMinBody) {
            table_store(key, fp->mtime_ns, fp->size, shared, std::move(body), lossy);
        }
    } catch (const std::exception&) {
        // dumps failure: api.py:587 swallows it; the caller answers from data
    }
    TableLoad ok;
    ok.state = "ok";
    ok.data = shared;
    ok.mtime_ns = fp->mtime_ns;
    ok.lossy = lossy;
    return ok;
}

void seed_table_cache(const std::string& path, const std::string& cfg_name, const json& data,
                      std::optional<long long> mtime_ns, bool lossy) {
    // api.py:488-506: after a successful write the body is built from the known
    // data so the next GET hits the cache cold-free. Fingerprint = post-write
    // stat, so any external touch after us still invalidates naturally.
    auto st = cs::stat(path);
    if (!st || !mtime_ns) return;
    try {
        std::string body = build_table_body(cfg_name, data, *mtime_ns, lossy);
        sa::bump(lc::kCfgDumps);  // it IS a real json.dumps (Python bumps too)
        if (body.size() >= kTableCacheMinBody) {
            auto shared = std::make_shared<const json>(data);
            table_store(cs::path_key(path), *mtime_ns, st->size, shared, std::move(body), lossy);
        }
    } catch (const std::exception&) {
        // OSError/TypeError/ValueError equivalent: seeding is best-effort.
    }
}

void invalidate_table_cache(const std::string& abs_path) {
    const std::string key = cs::path_key(abs_path);
    std::unique_lock<std::shared_mutex> lk(g_table_mu);
    std::erase_if(g_table, [&](const TableEntry& e) { return e.key == key; });
}

void invalidate_table_cache_all() {
    std::unique_lock<std::shared_mutex> lk(g_table_mu);
    g_table.clear();
}

size_t table_cache_size() {
    std::shared_lock<std::shared_mutex> lk(g_table_mu);
    return g_table.size();
}

std::optional<std::string> table_cache_body_for(const std::string& path, long long mtime_ns) {
    // cfg_read's bytes 直发 check (api.py:1004-1009): entry present, matching
    // mtime, non-empty body. NO cfg.dumps bump here — that's the S1 point.
    const std::string key = cs::path_key(path);
    std::shared_lock<std::shared_mutex> lk(g_table_mu);
    for (const auto& e : g_table) {
        if (e.key == key && e.mtime_ns == mtime_ns && !e.body.empty()) return e.body;
    }
    return std::nullopt;
}

std::optional<cfg_store::ProviderHit> cfgstore_parse_provider(const std::string& abs_path) {
    // api.py:1021-1035: fingerprint must still match the disk, else None.
    auto fp = stat_fp(abs_path);
    if (!fp) return std::nullopt;
    const std::string key = cs::path_key(abs_path);
    std::shared_lock<std::shared_mutex> lk(g_table_mu);
    for (const auto& e : g_table) {
        if (e.key == key && e.mtime_ns == fp->mtime_ns && e.size == fp->size) {
            cfg_store::ProviderHit hit;
            hit.data = e.data;
            hit.lossy = e.lossy;
            hit.mtime_ns = fp->mtime_ns;
            return hit;
        }
    }
    return std::nullopt;
}

void install_parse_provider() {
    cfg_store::set_parse_provider(&cfgstore_parse_provider);
}

// ---------------------------------------------------------------------------
// mod-cfgs cache
// ---------------------------------------------------------------------------

ModCfgsView load_mod_cfgs() {
    ModCfgsView view;
    std::string cfg = cfg_dir();
    if (cfg.empty() || !cs::is_dir(cfg)) {
        std::unique_lock<std::shared_mutex> lk(g_mod_cfgs_mu);
        g_mod_cfgs_cache.clear();
        g_mod_cfgs_broken.clear();
        g_mod_cfgs_fp_valid = false;
        return view;
    }

    // stat the whole directory once per request (A10); no parsing unless a
    // fingerprint changed.
    std::map<std::string, std::pair<long long, long long>> stats;
    bool ok = false;
    auto names = cs::listdir_sorted(cfg, &ok);
    if (ok) {
        for (const auto& f : names) {
            if (f.size() < 5 || f.compare(f.size() - 5, 5, ".json") != 0) continue;
            if (f == "CustomKeyMap.json") continue;  // api.py:383
            auto st = cs::stat(cs::join(cfg, f));
            stats[f] = st ? std::pair{st->mtime_ns, st->size} : std::pair{0LL, 0LL};
        }
    } else {
        stats.clear();
    }

    bool full_hit = false;
    {
        std::shared_lock<std::shared_mutex> lk(g_mod_cfgs_mu);
        full_hit = ok && g_mod_cfgs_fp_valid && g_mod_cfgs_dir == cfg && stats == g_mod_cfgs_fp &&
                   !g_mod_cfgs_cache.empty();
    }
    if (full_hit) {
        // G3/B1: hand out shared_ptr<const json> — in-place edits are UB by type.
        std::shared_lock<std::shared_mutex> lk(g_mod_cfgs_mu);
        view.tables = g_mod_cfgs_cache;
        view.broken = g_mod_cfgs_broken;
        return view;
    }

    std::map<std::string, std::shared_ptr<const json>> out;
    std::map<std::string, std::string> broken;
    if (ok) {
        for (const auto& [f, fp_item] : stats) {
            std::string name = f.substr(0, f.size() - 5);  // strip .json
            bool reuse = false;
            {
                std::shared_lock<std::shared_mutex> lk(g_mod_cfgs_mu);
                if (g_mod_cfgs_fp_valid && g_mod_cfgs_dir == cfg) {
                    auto fpit = g_mod_cfgs_fp.find(f);
                    if (fpit != g_mod_cfgs_fp.end() && fpit->second == fp_item) {
                        auto bit = g_mod_cfgs_broken.find(name);
                        if (bit != g_mod_cfgs_broken.end()) {
                            broken[name] = bit->second;  // fingerprint unchanged -> stays broken
                            reuse = true;
                        } else {
                            auto cit = g_mod_cfgs_cache.find(name);
                            if (cit != g_mod_cfgs_cache.end()) {
                                out[name] = cit->second;
                                reuse = true;
                            }
                        }
                    }
                }
            }
            if (reuse) continue;
            auto raw = cs::read_bytes(cs::join(cfg, f));
            if (!raw) {
                broken[name] = "OSError: cannot read file";
                continue;
            }
            auto text = sa_core::decode_utf8_sig_strict(*raw);
            if (!text) text = sa_core::decode_utf8_sig_replace(*raw);
            json parsed = json::parse(*text, nullptr, false);
            if (parsed.is_discarded()) {
                broken[name] = "JSONDecodeError: file is not valid JSON";
                continue;
            }
            out[name] = std::make_shared<const json>(parsed.is_object() ? std::move(parsed)
                                                                        : json::object());
        }
    }

    {
        std::unique_lock<std::shared_mutex> lk(g_mod_cfgs_mu);
        g_mod_cfgs_cache = out;
        g_mod_cfgs_broken = broken;
        g_mod_cfgs_fp = stats;
        g_mod_cfgs_fp_valid = ok;
        g_mod_cfgs_dir = cfg;
    }
    view.tables = std::move(out);
    view.broken = std::move(broken);
    return view;
}

json fork_mod_table(const std::string& cfg_name) {
    // api.py:433-456: writers fork a PRIVATE copy from disk — never mutate the
    // shared cache objects (B1 half-written-cache regression).
    std::string path;
    try {
        path = cfg_path(cfg_name);
    } catch (const SandboxError&) {
        path.clear();
    }
    if (!path.empty()) {
        auto lr = cfg_store::read_lossy(path);
        if (lr.text) {
            std::string stripped = sa_core::str::trim(*lr.text);
            json parsed =
                json::parse(stripped.empty() ? "{}" : stripped, nullptr, false);
            if (!parsed.is_discarded() && parsed.is_object()) return parsed;
        }
    }
    auto view = load_mod_cfgs();
    auto it = view.tables.find(cfg_name);
    if (it == view.tables.end() || !it->second || it->second->empty()) return json::object();
    return *it->second;  // json copy == deep copy (cache object untouched)
}

void note_mod_cfgs_write(const std::string& cfg_name, const json& data, const std::string& path) {
    // api.py:346-359 (A10): refresh only the written table + its fingerprint.
    std::string abs_path = path.empty() ? [&] {
        try {
            return cfg_path(cfg_name);
        } catch (const SandboxError&) {
            return std::string();
        }
    }() : path;
    auto st = abs_path.empty() ? std::nullopt : cs::stat(abs_path);
    std::unique_lock<std::shared_mutex> lk(g_mod_cfgs_mu);
    g_mod_cfgs_cache[cfg_name] = std::make_shared<const json>(data.is_object() ? data
                                                                                : json::object());
    g_mod_cfgs_broken.erase(cfg_name);  // B16: a successful rewrite clears the ledger
    if (st && g_mod_cfgs_fp_valid) {
        g_mod_cfgs_fp[cfg_name + ".json"] = {st->mtime_ns, st->size};
    }
}

void invalidate_mod_cfgs_cache() {
    std::unique_lock<std::shared_mutex> lk(g_mod_cfgs_mu);
    g_mod_cfgs_fp_valid = false;
}

}  // namespace sa
