// server/cfg_store: the unified write pipeline (port of `server/cfg_store.py`).
//
// _commit order is frozen by CONVENTIONS 5.5 (cfg_store.py:245-301):
//   conflict detect -> serialize+BOM -> unchanged short-circuit -> snapshot ->
//   atomic write -> undo register -> prune.
//
// Pitfalls honored here: A7 one read per save, A8 snapshot-backed undo stack,
// A9 per-table rolling keep=10, B2 lossy refuses recovery, B3 peek-then-pop,
// B4 forced LF on the text fallback, B5 source BOM preserved on write,
// B6 sha1 digest checked before mtime.
//
// Results are Python-shaped dicts (same key names/order) because the api layer
// forwards pieces of them straight into HTTP envelopes.
#pragma once

#include <functional>
#include <memory>
#include <optional>
#include <string>

#include <nlohmann/json.hpp>

namespace sa {
namespace cfg_store {

using json = nlohmann::ordered_json;

// cfg_store.py:44-50
inline constexpr const char* kHistoryDir = ".editor_history";
inline constexpr int kHistoryLimit = 50;   // in-memory undo/redo stack depth
inline constexpr int kHistoryKeep = 10;    // disk snapshots per table

// S1 hook (cfg_store.py:59-68): api registers fn(path) -> (data, lossy,
// mtime_ns) so apply_patch skips JSON parsing on cache hits. cfg_store must
// never call back into the api layer directly (no reverse imports).
struct ProviderHit {
    std::shared_ptr<const json> data;
    bool lossy = false;
    long long mtime_ns = 0;
};
using ParseProvider = std::function<std::optional<ProviderHit>(const std::string&)>;
void set_parse_provider(ParseProvider fn);

// cfg_store.py:99-121
std::optional<std::string> read_raw(const std::string& abs_path);
struct LossyRead {
    std::optional<std::string> raw;
    std::optional<std::string> text;  // utf-8-sig lenient
    bool lossy = false;
};
LossyRead read_lossy(const std::string& abs_path);

// write_cfg / apply_patch / undo / redo return Python dicts:
//   {"ok": true, "mtime_ns": int|null, "snapshot": str|null,
//    "unchanged": bool, "lossy": bool}                    (write_cfg success)
//   {"ok": false, "conflict": true, "reason": "digest"|"mtime"|"rows", ...}
//   {"ok": false, "error": "..."}
json write_cfg(const std::string& abs_path, const json& data,
               std::optional<long long> expect_mtime_ns = std::nullopt,
               const std::string* expect_digest = nullptr, bool force = false,
               bool snapshot = true);
json apply_patch(const std::string& abs_path, const json& set, const json& remove,
                 const json* if_match, std::optional<long long> expect_mtime_ns = std::nullopt,
                 const std::string* expect_digest = nullptr, bool force = false);
json undo(const std::string& abs_path);
json redo(const std::string& abs_path);
json list_history(const std::string& abs_path);  // [{file,ts,size}] newest-first

// cfg_store.py:424-431: after an out-of-band whole-file overwrite (cloud sync)
// the in-memory stack is stale — drop it.
void forget(const std::string& abs_path);

// S2 exit metric (cfg_store.py:535-547): snapshot-backed entries count 0.
long long debug_stack_bytes();
void debug_reset_stacks();

namespace test_hooks {
// Python tests monkeypatch cfg_store._restore with side_effect=PermissionError.
// When set, the next _restore call throws once and the flag self-clears (B3).
extern std::atomic<bool> fail_next_restore;
}  // namespace test_hooks

}  // namespace cfg_store
}  // namespace sa
