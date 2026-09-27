// server/services/usage_store.cpp — see usage_store.h for the contract.
#include "usage_store.h"

#include <algorithm>
#include <chrono>
#include <mutex>
#include <set>
#include <utility>
#include <vector>

#include "sa_core/atomic_io.h"
#include "sa_core/env_store.h"
#include "sa_core/paths.h"

namespace sa {
namespace usage {
namespace {

std::mutex g_write_lock;  // read-modify-write serialization (env_store._WRITE_LOCK)

constexpr std::size_t kMaxPerKind = 512;

long long now_ts() {
    return std::chrono::duration_cast<std::chrono::seconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

// (count, last_ts) ranking key — bigger = more used / more recent.
std::pair<long long, long long> rank_of(const json& rec) {
    auto num = [](const json& r, const char* k) -> long long {
        if (r.is_object() && r.contains(k) && r.at(k).is_number()) return r.at(k).get<long long>();
        return 0;
    };
    return {num(rec, "count"), num(rec, "last_ts")};
}

}  // namespace

bool valid_kind(const std::string& kind) {
    static const std::set<std::string> kKinds = {"command", "table", "role", "effect",
                                                 "condition", "cost", "action", "screen"};
    return kKinds.count(kind) > 0;
}

std::string usage_path(const std::string& editor_root) {
    return sa_core::paths::join(editor_root, ".editor_usage.json");
}

json record(const std::string& editor_root, const std::string& kind, const std::string& key) {
    if (kind.empty() || key.empty()) return json();
    std::lock_guard<std::mutex> lk(g_write_lock);
    json doc = sa_core::env_store::read_json_file(usage_path(editor_root));  // tolerant: broken -> {}
    if (!doc.is_object()) doc = json::object();
    json kmap = (doc.contains(kind) && doc[kind].is_object()) ? doc[kind] : json::object();
    long long count = 1;
    if (kmap.contains(key) && kmap[key].is_object() && kmap[key].contains("count") &&
        kmap[key]["count"].is_number()) {
        count = kmap[key]["count"].get<long long>() + 1;
    }
    const long long ts = now_ts();
    json rec{{"count", count}, {"last_ts", ts}};
    kmap[key] = rec;
    // Bounded memory: keep the best kMaxPerKind entries of this kind.
    if (kmap.size() > kMaxPerKind) {
        std::vector<std::pair<std::string, json>> v;
        v.reserve(kmap.size());
        for (auto it = kmap.begin(); it != kmap.end(); ++it) v.emplace_back(it.key(), it.value());
        std::sort(v.begin(), v.end(),
                  [](const auto& a, const auto& b) { return rank_of(a.second) > rank_of(b.second); });
        v.resize(kMaxPerKind);
        json trimmed = json::object();
        for (auto& p : v) trimmed[p.first] = p.second;
        kmap = std::move(trimmed);
    }
    doc[kind] = std::move(kmap);
    sa_core::write_text_atomic(usage_path(editor_root), doc.dump(2));
    return rec;
}

json top(const std::string& editor_root, const std::string& kind, std::size_t limit) {
    json out = json::array();
    json doc = sa_core::env_store::read_json_file(usage_path(editor_root));
    if (!doc.is_object() || !doc.contains(kind) || !doc[kind].is_object()) return out;
    std::vector<std::pair<std::string, json>> v;
    for (auto it = doc[kind].begin(); it != doc[kind].end(); ++it) {
        if (!it.value().is_object()) continue;
        v.emplace_back(it.key(), it.value());
    }
    std::sort(v.begin(), v.end(),
              [](const auto& a, const auto& b) { return rank_of(a.second) > rank_of(b.second); });
    if (v.size() > limit) v.resize(limit);
    for (auto& p : v)
        out.push_back(json{{"key", p.first},
                           {"count", rank_of(p.second).first},
                           {"last_ts", rank_of(p.second).second}});
    return out;
}

}  // namespace usage
}  // namespace sa
