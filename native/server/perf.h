// server/perf: process-wide performance counters (port of `server/perf.py`).
//
// Counter key names are frozen by CONVENTIONS section 7 and must stay verbatim:
//   cfg.reads  cfg.read_bytes  cfg.parses  cfg.dumps
//   cfg.writes cfg.write_bytes cfg.snapshot_bytes cfg.snapshots_written
//
// Bump discipline (perf.py docstring / CONVENTIONS 7): count only at "once per
// request" sites, NEVER inside the 98,963-row loop; cfg.dumps counts real
// serializations only (bytes-direct sends are NOT counted); unchanged short
// circuits do not bump cfg.writes.
#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace sa {

class PerfCounters {
  public:
    // perf.COUNTERS.bump(name, amount): defaultdict-style, unknown keys start 0.
    void bump(const std::string& key, long long amount = 1);
    void add(const std::string& key, long long amount) { bump(key, amount); }
    long long get(const std::string& key) const;
    void reset();  // perf.COUNTERS.reset(): all counters (window included)

    // Snapshot of every key that has ever been bumped, in first-bump order
    // (dict(self._counters) insertion order in Python).
    std::vector<std::pair<std::string, long long>> snapshot() const;

  private:
    struct Impl;
    static PerfCounters& instance();

    // Guarded by one mutex: perf.py uses a single Lock for the whole registry.
    mutable std::mutex mu_;
    std::vector<std::pair<std::string, long long>> counters_;
};

// Process-wide singleton (perf.COUNTERS).
PerfCounters& counters();

inline void bump(const std::string& key, long long amount = 1) { counters().bump(key, amount); }
inline long long get(const std::string& key) { return counters().get(key); }
inline void reset() { counters().reset(); }

// Key-name constants mirroring perf._LegacyConstants / LC.
namespace lc {
inline constexpr const char* kCfgReads = "cfg.reads";
inline constexpr const char* kCfgReadBytes = "cfg.read_bytes";
inline constexpr const char* kCfgParses = "cfg.parses";
inline constexpr const char* kCfgDumps = "cfg.dumps";
inline constexpr const char* kCfgWrites = "cfg.writes";
inline constexpr const char* kCfgWriteBytes = "cfg.write_bytes";
inline constexpr const char* kCfgSnapshotBytes = "cfg.snapshot_bytes";
inline constexpr const char* kCfgSnapshotsWritten = "cfg.snapshots_written";
}  // namespace lc

}  // namespace sa
