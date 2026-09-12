#include "server/cfg_store.h"

#include <algorithm>
#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <vector>

#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/sha1.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/perf.h"

namespace sa {
namespace cfg_store {
namespace {

namespace cs = sa_core::paths;
using sa_core::kBom;

// ---------------------------------------------------------------------------
// module state (cfg_store.py:52-61)
// ---------------------------------------------------------------------------

struct StackEntry {
    std::optional<std::string> snap;  // disk snapshot file name, or None
    std::optional<std::string> text;  // fallback in-memory text (utf-8-sig decoded)
    bool existed = false;             // file existed before the write
    bool had_bom = false;
    bool lossy = false;
};

struct StackPair {
    std::vector<StackEntry> undo;
    std::vector<StackEntry> redo;
};

std::mutex g_reg_mu;  // _STACK_LOCK: guards the registries below
std::map<std::string, StackPair> g_stacks;
std::map<std::string, std::shared_ptr<std::recursive_mutex>> g_path_locks;
ParseProvider g_provider;

void trim_keep_last(std::vector<StackEntry>& v, size_t limit) {
    // Python `del entry["undo"][:-HISTORY_LIMIT]` keeps the newest `limit`.
    if (v.size() > limit) v.erase(v.begin(), v.end() - static_cast<long>(limit));
}

std::shared_ptr<std::recursive_mutex> path_lock_for(const std::string& key) {
    std::lock_guard<std::mutex> lk(g_reg_mu);
    auto it = g_path_locks.find(key);
    if (it != g_path_locks.end()) return it->second;
    auto m = std::make_shared<std::recursive_mutex>();
    g_path_locks[key] = m;
    return m;
}

void put_opt_mtime(json& out, const char* key, const std::optional<long long>& v) {
    out[key] = v.has_value() ? json(*v) : json();
}

// ---------------------------------------------------------------------------
// helpers mirroring cfg_store.py module functions
// ---------------------------------------------------------------------------

std::string path_key(const std::string& abs_path) { return cs::path_key(abs_path); }

// cfg_store.py:89-96 _read_text_from: utf-8-sig, replace on failure.
std::optional<std::string> read_text_from(const std::optional<std::string>& raw) {
    if (!raw) return std::nullopt;
    auto strict = sa_core::decode_utf8_sig_strict(*raw);
    if (strict) return strict;
    return sa_core::decode_utf8_sig_replace(*raw);
}

// cfg_store.py:133-141 _parse_json_text: lenient text -> object dict.
// Empty/whitespace-only content parses to {}; failures and non-objects None.
std::optional<json> parse_json_text(const std::optional<std::string>& text) {
    if (!text) return std::nullopt;
    std::string stripped = sa_core::str::trim(*text);
    if (stripped.empty()) return json::object();
    json parsed = json::parse(stripped, nullptr, false);
    if (parsed.is_discarded()) return std::nullopt;
    if (!parsed.is_object()) return std::nullopt;
    return parsed;
}

// cfg_store.py:144-153 _mod_root_of
std::string mod_root_of(const std::string& abs_path) {
    std::string d = cs::dirname(cs::abs_path(abs_path));
    if (sa_core::str::lower(cs::basename(d)) == "zh-cn") d = cs::dirname(d);
    return cs::dirname(d);
}

// cfg_store.py:156-161 _cfg_stem
std::string cfg_stem(const std::string& abs_path) {
    std::string base = cs::basename(abs_path);
    if (base.size() >= 5 && base.compare(base.size() - 5, 5, ".json") == 0) {
        base = base.substr(0, base.size() - 5);
    }
    return base;
}

std::string history_dir(const std::string& abs_path) {
    return cs::join(mod_root_of(abs_path), kHistoryDir);
}

// cfg_store.py:168-186 _history_entries: (ts, name) ascending; bad ts -> 0.
std::vector<std::pair<long long, std::string>> history_entries(const std::string& hdir,
                                                               const std::string& stem) {
    std::vector<std::pair<long long, std::string>> out;
    std::string prefix = stem + "_";
    bool ok = false;
    auto names = cs::listdir_sorted(hdir, &ok);
    if (!ok) return out;  // directory unreadable -> []
    for (const auto& name : names) {
        if (name.size() < prefix.size() || name.compare(0, prefix.size(), prefix) != 0) continue;
        if (name.size() < 5 || name.compare(name.size() - 5, 5, ".json") != 0) continue;
        std::string tail = name.substr(prefix.size(), name.size() - prefix.size() - 5);
        size_t underscore = tail.find('_');
        std::string head = underscore == std::string::npos ? tail : tail.substr(0, underscore);
        long long ts = sa_core::py_int(head).value_or(0);
        out.emplace_back(ts, name);
    }
    std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) {
        if (a.first != b.first) return a.first < b.first;
        return a.second < b.second;
    });
    return out;
}

// cfg_store.py:189-211 _write_snapshot: raw bytes (BOM included) into
// .editor_history/<stem>_<ms>_<seq>.json; failure never blocks the write.
std::optional<std::string> write_snapshot(const std::string& abs_path, const std::string& raw) {
    std::string hdir = history_dir(abs_path);
    std::string stem = cfg_stem(abs_path);
    long long ms = sa_core::now_ms();
    int seq = 0;
    std::string name;
    for (;;) {  // same-millisecond collisions bump seq
        name = stem + "_" + std::to_string(ms) + "_" + std::to_string(seq) + ".json";
        if (!cs::exists(cs::join(hdir, name))) break;
        ++seq;
        if (seq > 1000000) break;  // paranoia against infinite spin
    }
    try {
        sa_core::write_bytes_atomic(cs::join(hdir, name), raw);
    } catch (const sa_core::FsError&) {
        return std::nullopt;
    }
    sa::bump("cfg.snapshots_written");
    sa::bump("cfg.snapshot_bytes", static_cast<long long>(raw.size()));
    return name;
}

// cfg_store.py:214-222 _prune_history (A9: rolling keep=10 per table)
void prune_history(const std::string& abs_path) {
    std::string hdir = history_dir(abs_path);
    auto entries = history_entries(hdir, cfg_stem(abs_path));
    if (static_cast<long long>(entries.size()) <= kHistoryKeep) return;
    for (size_t i = 0; i < entries.size() - static_cast<size_t>(kHistoryKeep); ++i) {
        cs::remove_file(cs::join(hdir, entries[i].second));  // OSError swallowed
    }
}

std::optional<long long> stat_mtime_ns(const std::string& abs_path) {
    auto st = cs::stat(abs_path);
    if (!st) return std::nullopt;
    return st->mtime_ns;
}

// cfg_store.py:232-242 _serialize + _encode_with_bom
std::string encode_with_bom(const std::string& text, bool had_bom) {
    std::string out;
    if (had_bom) out.append(kBom);
    out += text;
    return out;
}

// ---------------------------------------------------------------------------
// _commit — the frozen seven-step pipeline (cfg_store.py:245-301).
// Caller holds the path lock (L2); this takes L1 for stack registration only.
// raw/lossy come from the single disk read (A7).
// ---------------------------------------------------------------------------
json commit(const std::string& abs_path, const json& data, const std::optional<std::string>& raw,
            bool lossy, std::optional<long long> expect_mtime_ns,
            const std::string* expect_digest, bool force, bool snapshot) {
    const bool exists = raw.has_value();
    std::optional<long long> cur_mtime = exists ? stat_mtime_ns(abs_path) : std::nullopt;

    // (1) conflict detection — digest first (B6: mtime granularity misses
    // same-tick external edits), mtime only when no digest was given.
    if (!force && exists) {
        std::optional<std::string> reason;
        if (expect_digest != nullptr) {
            if (sa_core::sha1_hex(*raw) != *expect_digest) reason = "digest";
        } else if (expect_mtime_ns.has_value() && cur_mtime.has_value() &&
                   *cur_mtime != *expect_mtime_ns) {
            reason = "mtime";
        }
        if (reason) {
            json out;
            out["ok"] = false;
            out["conflict"] = true;
            out["reason"] = *reason;
            put_opt_mtime(out, "mtime_ns", cur_mtime);
            out["lossy"] = lossy;
            out["data"] = parse_json_text(read_text_from(raw)).value_or(json());
            return out;
        }
    }

    // (2) serialize (ensure_ascii=False + indent=2) + source BOM preserved (B5).
    const bool had_bom = exists && sa_core::starts_with_bom(*raw);
    const std::string new_bytes = encode_with_bom(sa_core::py_dumps_indent(data), had_bom);

    // (3) unchanged short-circuit: no snapshot, no write, no stack touch,
    // and cfg.writes is NOT bumped (CONVENTIONS 7).
    if (exists && new_bytes == *raw) {
        json out;
        out["ok"] = true;
        put_opt_mtime(out, "mtime_ns", cur_mtime);
        out["snapshot"] = nullptr;
        out["unchanged"] = true;
        out["lossy"] = lossy;
        return out;
    }

    // (4) snapshot the OLD raw bytes before overwriting an existing file.
    std::optional<std::string> snap_name;
    if (exists && snapshot) snap_name = write_snapshot(abs_path, *raw);

    // (5) atomic write (transient-lock retry inside atomic_io).
    try {
        sa_core::write_bytes_atomic(abs_path, new_bytes);
    } catch (const sa_core::FsError& e) {
        json out;
        out["ok"] = false;
        out["error"] = std::string("写入失败: ") + e.what();
        out["lossy"] = lossy;
        return out;
    }
    sa::bump("cfg.writes");
    sa::bump("cfg.write_bytes", static_cast<long long>(new_bytes.size()));
    std::optional<long long> new_mtime = stat_mtime_ns(abs_path);

    // (6) undo stack: snapshot-backed entries never store table text (A8).
    // g_reg_mu must cover the lookup AND the mutation in one critical section:
    // forget() erases the same map entry under only g_reg_mu (cloud_sync calls
    // it after downloading a /Cfgs/*.json), so holding a reference past the
    // unlock would dangle and make the push_back a use-after-free.
    {
        std::lock_guard<std::mutex> lk(g_reg_mu);
        StackPair& entry = g_stacks[path_key(abs_path)];
        StackEntry item;
        item.snap = snap_name;
        if (!snap_name) item.text = read_text_from(raw);  // in-memory fallback
        item.existed = exists;
        item.had_bom = had_bom;
        item.lossy = lossy;
        entry.undo.push_back(std::move(item));
        trim_keep_last(entry.undo, static_cast<size_t>(kHistoryLimit));
        entry.redo.clear();  // a new write invalidates the redo line
    }

    // (7) rolling prune of disk snapshots (A9).
    if (snap_name) prune_history(abs_path);

    json out;
    out["ok"] = true;
    put_opt_mtime(out, "mtime_ns", new_mtime);
    out["snapshot"] = snap_name ? json(*snap_name) : json();
    out["unchanged"] = false;
    out["lossy"] = lossy;
    return out;
}

// undo/redo helpers (cfg_store.py:390-437)
std::optional<std::string> snapshot_bytes(const std::string& abs_path,
                                          const std::optional<std::string>& snap_name) {
    if (!snap_name) return std::nullopt;
    return cs::read_bytes(cs::join(history_dir(abs_path), *snap_name));
}

// content==None means "restore to file-missing"; Bytes keeps the BOM verbatim
// (the text path would re-encode and shift bytes — B4's whole point).
std::optional<long long> restore(const std::string& abs_path,
                                 const std::optional<std::string>& content) {
    if (test_hooks::fail_next_restore.exchange(false)) {
        throw sa_core::FsError("[WinError 5] Access is denied: '" + abs_path + "'");
    }
    if (!content) {
        cs::remove_file(abs_path);  // OSError ignored (cfg_store.py:408-411)
        return stat_mtime_ns(abs_path);
    }
    sa_core::write_bytes_atomic(abs_path, *content);
    return stat_mtime_ns(abs_path);
}

std::optional<std::string> current_text(const std::string& abs_path) {
    if (!cs::is_file(abs_path)) return std::nullopt;
    return read_text_from(read_raw(abs_path));
}

json result_with_data(const std::string& abs_path, std::optional<long long> mtime_ns) {
    auto lr = read_lossy(abs_path);
    json out;
    out["ok"] = true;
    put_opt_mtime(out, "mtime_ns", mtime_ns);
    out["data"] = parse_json_text(lr.text).value_or(json());
    return out;
}

}  // namespace

namespace test_hooks {
std::atomic<bool> fail_next_restore{false};
}  // namespace test_hooks

// ---------------------------------------------------------------------------
// public API
// ---------------------------------------------------------------------------

void set_parse_provider(ParseProvider fn) {
    std::lock_guard<std::mutex> lk(g_reg_mu);
    g_provider = std::move(fn);  // cfg_store.py:64-68 set_parse_provider
}

std::optional<std::string> read_raw(const std::string& abs_path) {
    return cs::read_bytes(abs_path);  // read_raw: OSError -> None
}

LossyRead read_lossy(const std::string& abs_path) {
    LossyRead out;
    out.raw = cs::read_bytes(abs_path);
    if (!out.raw) return out;  // (None, None, False)
    auto strict = sa_core::decode_utf8_sig_strict(*out.raw);
    if (strict) {
        out.text = std::move(strict);
    } else {
        out.text = sa_core::decode_utf8_sig_replace(*out.raw);
        out.lossy = true;
    }
    return out;
}

json write_cfg(const std::string& abs_path, const json& data,
               std::optional<long long> expect_mtime_ns, const std::string* expect_digest,
               bool force, bool snapshot) {
    const std::string abs = cs::abs_path(abs_path);
    std::lock_guard<std::recursive_mutex> lk(*path_lock_for(path_key(abs)));
    auto lr = read_lossy(abs);  // the single disk read (A7)
    return commit(abs, data, lr.raw, lr.lossy, expect_mtime_ns, expect_digest, force, snapshot);
}

json apply_patch(const std::string& abs_path, const json& set, const json& remove,
                 const json* if_match, std::optional<long long> expect_mtime_ns,
                 const std::string* expect_digest, bool force) {
    const std::string abs = cs::abs_path(abs_path);
    std::lock_guard<std::recursive_mutex> lk(*path_lock_for(path_key(abs)));

    // (1) current data: S1 parse provider first (40MB parse saving), falling
    // back to the local lenient read. Provider call runs WITHOUT the registry
    // lock: it takes L3 (table cache) and lock order is L2 -> L3.
    std::shared_ptr<const json> cached;
    ParseProvider provider;
    {
        std::lock_guard<std::mutex> lk(g_reg_mu);
        provider = g_provider;
    }
    if (provider) {
        try {
            auto hit = provider(abs);
            if (hit) cached = hit->data;
        } catch (...) {
            cached = nullptr;  // provider errors fall through to the disk read
        }
    }

    // raw ALWAYS comes from disk: _commit's existed/conflict/BOM/snapshot
    // semantics only trust bytes (cfg_store.py:351-354 — the regression that
    // silently disabled table-level locks and made undo delete whole tables).
    auto lr = read_lossy(abs);

    json data;
    if (cached && cached->is_object()) {
        data = *cached;  // top-level copy; inner values are never mutated
    } else {
        data = parse_json_text(lr.text).value_or(json::object());
    }
    if (!data.is_object()) data = json::object();

    // (2) row-level optimistic lock: if_match deep compare (JSON value equality
    // like Python's ==; iteration in client order -> conflicting_keys order).
    std::vector<std::string> conflicts;
    if (if_match && if_match->is_object() && !if_match->empty()) {
        for (auto it = if_match->begin(); it != if_match->end(); ++it) {
            if (!data.contains(it.key()) || !(data[it.key()] == it.value())) {
                conflicts.push_back(it.key());
            }
        }
    }
    std::optional<long long> cur_mtime = stat_mtime_ns(abs);
    if (!conflicts.empty() && !force) {
        json out;
        out["ok"] = false;
        out["conflict"] = true;
        out["reason"] = "rows";
        json keys = json::array();
        for (const auto& k : conflicts) keys.push_back(k);
        out["conflicting_keys"] = keys;
        put_opt_mtime(out, "mtime_ns", cur_mtime);
        out["lossy"] = lr.lossy;
        return out;  // row conflicts NEVER return the full table
    }

    // (3) apply: remove first, then set (Python order; counts for applied_set).
    long long n_set = 0, n_remove = 0;
    if (remove.is_array()) {
        for (const auto& k : remove) {
            if (k.is_string() && data.contains(k.get<std::string>())) {
                data.erase(k.get<std::string>());
                ++n_remove;
            }
        }
    }
    if (set.is_object()) {
        for (auto it = set.begin(); it != set.end(); ++it) {
            data[it.key()] = it.value();  // values copied: callers can't alias in
            ++n_set;
        }
    }

    // (4) reuse the exact same write pipeline.
    json result = commit(abs, data, lr.raw, lr.lossy, expect_mtime_ns, expect_digest, force, true);
    if (result.value("ok", false)) {
        json applied;
        applied["set"] = n_set;
        applied["remove"] = n_remove;
        result["applied"] = applied;
        result["data"] = data;  // merged table for the api cache refresh only
    }
    return result;
}

json undo(const std::string& abs_path) {
    const std::string abs = cs::abs_path(abs_path);
    const std::string key = path_key(abs);
    std::lock_guard<std::recursive_mutex> lk(*path_lock_for(key));

    StackEntry item;
    {
        std::lock_guard<std::mutex> lk(g_reg_mu);
        auto it = g_stacks.find(key);
        if (it == g_stacks.end() || it->second.undo.empty()) {
            return json{{"ok", false}, {"error", "nothing to undo"}};
        }
        item = it->second.undo.back();  // peek first, pop only after success (B3)
    }

    std::optional<std::string> restore_bytes;  // None == "restore to missing"
    if (item.existed) {
        restore_bytes = snapshot_bytes(abs, item.snap);
        if (!restore_bytes) {
            if (item.lossy) {
                // B2: the fallback text holds U+FFFD placeholders; writing them
                // back would permanently corrupt the source. Fail safe instead.
                return json{{"ok", false},
                            {"error", "历史快照缺失且该表为有损读取，无法撤销"}};
            }
            if (item.text) {
                restore_bytes = (item.had_bom ? std::string(kBom) : std::string()) + *item.text;
            }
        }
        if (!restore_bytes) {
            return json{{"ok", false}, {"error", "history snapshot missing"}};
        }
    }

    std::optional<std::string> cur_text = current_text(abs);
    std::optional<long long> mtime_ns;
    try {
        mtime_ns = restore(abs, restore_bytes);
    } catch (const sa_core::FsError& e) {
        return json{{"ok", false}, {"error", std::string("撤销失败: ") + e.what()}};
    }

    {
        std::lock_guard<std::mutex> lk(g_reg_mu);
        // find, not operator[]: a concurrent forget() (e.g. cloud sync replacing
        // the table) may have erased the entry while we were restoring; re-creating
        // an empty entry here would make pop_back() on an empty vector UB. The
        // restore has already been applied, so we still report success — only the
        // redo bookkeeping is lost with the forgotten stack.
        auto it = g_stacks.find(key);
        if (it != g_stacks.end() && !it->second.undo.empty()) {
            StackPair& entry = it->second;
            entry.undo.pop_back();  // ...only now the stack moves
            StackEntry pushed;
            pushed.snap = std::nullopt;
            pushed.text = cur_text;
            pushed.existed = true;
            pushed.had_bom = restore_bytes && sa_core::starts_with_bom(*restore_bytes);
            pushed.lossy = false;
            entry.redo.push_back(std::move(pushed));
            trim_keep_last(entry.redo, static_cast<size_t>(kHistoryLimit));
        }
    }
    return result_with_data(abs, mtime_ns);
}

json redo(const std::string& abs_path) {
    const std::string abs = cs::abs_path(abs_path);
    const std::string key = path_key(abs);
    std::lock_guard<std::recursive_mutex> lk(*path_lock_for(key));

    StackEntry item;
    {
        std::lock_guard<std::mutex> lk(g_reg_mu);
        auto it = g_stacks.find(key);
        if (it == g_stacks.end() || it->second.redo.empty()) {
            return json{{"ok", false}, {"error", "nothing to redo"}};
        }
        item = it->second.redo.back();  // peek (B3)
    }

    // Redo entries have no disk snapshot: text path re-adds the BOM as stored.
    std::optional<std::string> restore_bytes;
    if (item.existed && item.text) {
        restore_bytes = (item.had_bom ? std::string(kBom) : std::string()) + *item.text;
    }

    std::optional<std::string> cur_text = current_text(abs);
    std::optional<long long> mtime_ns;
    try {
        mtime_ns = restore(abs, restore_bytes);
    } catch (const sa_core::FsError& e) {
        return json{{"ok", false}, {"error", std::string("重做失败: ") + e.what()}};
    }

    {
        std::lock_guard<std::mutex> lk(g_reg_mu);
        // find + non-empty check: same concurrent-forget() race as undo().
        auto it = g_stacks.find(key);
        if (it != g_stacks.end() && !it->second.redo.empty()) {
            StackPair& entry = it->second;
            entry.redo.pop_back();
            StackEntry pushed;
            pushed.snap = std::nullopt;
            pushed.text = cur_text;
            pushed.existed = true;
            pushed.had_bom = restore_bytes && sa_core::starts_with_bom(*restore_bytes);
            pushed.lossy = false;
            entry.undo.push_back(std::move(pushed));
            trim_keep_last(entry.undo, static_cast<size_t>(kHistoryLimit));
        }
    }
    return result_with_data(abs, mtime_ns);
}

json list_history(const std::string& abs_path) {
    std::string abs = cs::abs_path(abs_path);
    std::string hdir = history_dir(abs);
    auto entries = history_entries(hdir, cfg_stem(abs));
    // newest -> oldest (cfg_store.py:531: sort key (ts, file), reverse=True)
    std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
        if (a.first != b.first) return a.first > b.first;
        return a.second > b.second;
    });
    json out = json::array();
    for (const auto& [ts, name] : entries) {
        long long size = 0;
        auto st = cs::stat(cs::join(hdir, name));
        if (st) size = st->size;
        json e;
        e["file"] = name;
        e["ts"] = ts;
        e["size"] = size;
        out.push_back(std::move(e));
    }
    return out;
}

void forget(const std::string& abs_path) {
    std::lock_guard<std::mutex> lk(g_reg_mu);
    g_stacks.erase(path_key(cs::abs_path(abs_path)));
}

long long debug_stack_bytes() {
    // Snapshot-backed entries count 0 (A8 verification target).
    long long total = 0;
    std::lock_guard<std::mutex> lk(g_reg_mu);
    for (const auto& [key, entry] : g_stacks) {
        for (const auto* v : {&entry.undo, &entry.redo}) {
            for (const auto& item : *v) {
                if (item.text) total += static_cast<long long>(item.text->size());
            }
        }
    }
    return total;
}

void debug_reset_stacks() {
    std::lock_guard<std::mutex> lk(g_reg_mu);
    g_stacks.clear();
}

}  // namespace cfg_store
}  // namespace sa
