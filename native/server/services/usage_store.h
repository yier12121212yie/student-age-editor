// server/services/usage_store.h — candidate-ranking usage stats shared by all
// three frontends (GUI / backend_cli REPL / backend_tui).
//
// Backing file: <editor_root>/.editor_usage.json, shaped
//   { "<kind>": { "<key>": {"count": int, "last_ts": epoch_seconds} }, ... }
// Kinds (whitelist, see valid_kind): "command" (REPL lines / slash commands),
// "table" (cfg names), "role" (person ids) and the five effect modes
// ("effect" | "condition" | "cost" | "action" | "screen", keyed by the raw
// code template so a bumped entry can be found back in the *_db() arrays).
//
// Same discipline as env_store (CONVENTIONS 5.5): tolerant read (any broken
// state -> {}), read-modify-write serialized under one mutex, atomic write
// with indent=2. Records are kept in bounded memory: one kind trims to the
// best kMaxPerKind (count, then last_ts) whenever it grows past it.
#pragma once

#include <cstddef>
#include <string>

#include <nlohmann/json.hpp>

namespace sa {
namespace usage {

using json = nlohmann::ordered_json;

// Whitelist for the HTTP surface; unknown kinds are rejected with 400 so a
// typo cannot silently pile up orphan buckets.
bool valid_kind(const std::string& kind);

// <editor_root>/.editor_usage.json
std::string usage_path(const std::string& editor_root);

// Bump (kind, key): count+1, last_ts=now. Returns the updated record
// {count, last_ts}. Empty kind/key returns null and writes nothing.
json record(const std::string& editor_root, const std::string& kind, const std::string& key);

// Top `limit` entries of `kind`, sorted by count desc then last_ts desc, as
// [{key, count, last_ts}]. Never throws on a missing/corrupt store.
json top(const std::string& editor_root, const std::string& kind, std::size_t limit);

}  // namespace usage
}  // namespace sa
