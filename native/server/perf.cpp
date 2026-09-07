#include "server/perf.h"

#include <algorithm>
#include <mutex>

namespace sa {

void PerfCounters::bump(const std::string& key, long long amount) {
    std::lock_guard<std::mutex> lk(mu_);
    for (auto& [k, v] : counters_) {
        if (k == key) {
            v += amount;
            return;
        }
    }
    counters_.emplace_back(key, amount);
}

long long PerfCounters::get(const std::string& key) const {
    std::lock_guard<std::mutex> lk(mu_);
    for (const auto& [k, v] : counters_) {
        if (k == key) return v;
    }
    return 0;
}

void PerfCounters::reset() {
    std::lock_guard<std::mutex> lk(mu_);
    counters_.clear();
}

std::vector<std::pair<std::string, long long>> PerfCounters::snapshot() const {
    std::lock_guard<std::mutex> lk(mu_);
    return counters_;
}

PerfCounters& counters() {
    static PerfCounters instance;
    return instance;
}

}  // namespace sa
