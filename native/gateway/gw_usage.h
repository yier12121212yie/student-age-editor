// gateway/gw_usage: per-account per-UTC-day AI relay quota (网页版计划 M2.3).
//
// <state_dir>/usage.json: {"<account>": {"<YYYY-MM-DD>": <count>}}. Read on
// every check (small file), written atomically after a relayed chat round —
// quota therefore charges *completed* requests, and a gateway crash loses at
// most the in-flight one. daily_limit <= 0 == unlimited (no file touched).
#pragma once

#include <mutex>
#include <string>

namespace gw {

class UsageStore {
  public:
    UsageStore(std::string file_path, long long daily_limit)
        : file_(std::move(file_path)), limit_(daily_limit) {}

    long long limit() const { return limit_; }

    // True when name already burned `limit` requests today (limit>0).
    bool over_limit(const std::string& name);

    // +1 for (name, today) and persist. Called after a successful relay.
    void record(const std::string& name);

    // Count for (name, today); 0 when file missing/corrupt (corrupt file is
    // replaced on the next record, matching the "state file, not ledger"
    // stance of the desktop env stores).
    long long count_today(const std::string& name);

    // YYYY-MM-DD in UTC for the given epoch-ms (default: now). Exposed for
    // tests — the day key must not follow the host timezone.
    static std::string utc_date_key(long long epoch_ms = -1);

  private:
    std::string file_;
    long long limit_;
    std::mutex mu_;
};

}  // namespace gw
