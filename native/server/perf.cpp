#include "server/perf.h"

#include <string_view>
#include <unordered_map>

namespace sa {

void PerfCounters::bump(const std::string& key, long long amount) {
    std::lock_guard<std::mutex> lk(mu_);
    // First bump appends to order_ so snapshot() keeps Python's
    // dict-insertion-order contract; later bumps are a single hash find.
    auto [it, inserted] = index_.try_emplace(key, order_.size());
    if (inserted) {
        order_.emplace_back(key, amount);
        return;
    }
    order_[it->second].second += amount;
}

long long PerfCounters::get(const std::string& key) const {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = index_.find(key);
    return it == index_.end() ? 0 : order_[it->second].second;
}

void PerfCounters::reset() {
    std::lock_guard<std::mutex> lk(mu_);
    index_.clear();
    order_.clear();
}

std::vector<std::pair<std::string, long long>> PerfCounters::snapshot() const {
    std::lock_guard<std::mutex> lk(mu_);
    return order_;
}

PerfCounters& counters() {
    static PerfCounters instance;
    return instance;
}

}  // namespace sa
