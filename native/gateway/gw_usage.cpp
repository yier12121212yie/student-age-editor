// gateway/gw_usage.cpp — see gw_usage.h.
#include "gw_usage.h"

#include <ctime>

#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/util.h"
#include "server/httpd.h"  // sa::json

namespace gw {

std::string UsageStore::utc_date_key(long long epoch_ms) {
    if (epoch_ms < 0) epoch_ms = sa_core::now_ms();
    std::time_t secs = static_cast<std::time_t>(epoch_ms / 1000);
    std::tm tmv{};
#if defined(_WIN32)
    gmtime_s(&tmv, &secs);
#else
    gmtime_r(&secs, &tmv);
#endif
    char buf[16];
    std::strftime(buf, sizeof(buf), "%Y-%m-%d", &tmv);
    return buf;
}

namespace {

sa::json load_usage(const std::string& file) {
    auto raw = sa_core::paths::read_bytes(file);
    if (!raw) return sa::json::object();
    sa::json j = sa::json::parse(*raw, nullptr, false);
    if (j.is_discarded() || !j.is_object()) return sa::json::object();
    return j;
}

}  // namespace

long long UsageStore::count_today(const std::string& name) {
    std::lock_guard<std::mutex> lk(mu_);
    sa::json j = load_usage(file_);
    std::string day = utc_date_key();
    if (!j.contains(name) || !j[name].is_object() || !j[name].contains(day) ||
        !j[name][day].is_number_integer())
        return 0;
    return j[name][day].get<long long>();
}

bool UsageStore::over_limit(const std::string& name) {
    if (limit_ <= 0) return false;
    return count_today(name) >= limit_;
}

void UsageStore::record(const std::string& name) {
    if (limit_ <= 0) return;  // unlimited: never touch the file
    std::lock_guard<std::mutex> lk(mu_);
    sa::json j = load_usage(file_);
    std::string day = utc_date_key();
    if (!j.contains(name) || !j[name].is_object()) j[name] = sa::json::object();
    long long cur = 0;
    if (j[name].contains(day) && j[name][day].is_number_integer())
        cur = j[name][day].get<long long>();
    j[name][day] = cur + 1;
    sa_core::write_bytes_atomic(file_, sa_core::py_dumps(j));
}

}  // namespace gw
