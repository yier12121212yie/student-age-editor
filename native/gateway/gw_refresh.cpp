// gateway/gw_refresh.cpp — see gw_refresh.h.
#include "gw_refresh.h"

#include <cstdio>
#include <random>
#include <stdexcept>
#include <utility>

#include <nlohmann/json.hpp>

#include "sa_core/atomic_io.h"
#include "sa_core/http_client.h"  // bytes_to_hex
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/sha256.h"
#include "sa_core/util.h"  // now_ms
#include "server/httpd.h"  // sa::json

namespace gw {

std::string RefreshTokens::random_token_hex() {
    std::random_device rd;
    std::string raw;
    raw.reserve(32);
    while (raw.size() < 32) {
        unsigned int v = rd();
        for (int i = 0; i < 4 && raw.size() < 32; ++i)
            raw.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
    }
    return sa_core::http::bytes_to_hex(raw);
}

std::string RefreshTokens::hash_token(const std::string& token) {
    return sa_core::sha256_hex(token);
}

RefreshTokens::RefreshTokens(std::string file) : file_(std::move(file)) {}

void RefreshTokens::load_locked() {
    if (loaded_) return;
    loaded_ = true;
    auto raw = sa_core::paths::read_bytes(file_);
    if (!raw) return;  // 首次运行：文件不存在 == 空
    sa::json j = sa::json::parse(*raw, nullptr, false);
    if (j.is_discarded() || !j.is_array()) return;
    const long long now = sa_core::now_ms();
    for (const auto& e : j) {
        if (!e.is_object()) continue;
        if (!e.contains("hash") || !e["hash"].is_string()) continue;
        if (!e.contains("name") || !e["name"].is_string()) continue;
        if (!e.contains("expires_ms") || !e["expires_ms"].is_number_integer()) continue;
        Entry entry;
        entry.name = e["name"].get<std::string>();
        entry.expires_ms = e["expires_ms"].get<long long>();
        if (e.contains("created_ms") && e["created_ms"].is_number_integer())
            entry.created_ms = e["created_ms"].get<long long>();
        if (e.contains("last_seen_ms") && e["last_seen_ms"].is_number_integer())
            entry.last_seen_ms = e["last_seen_ms"].get<long long>();
        entry.persist = true;
        if (entry.expires_ms <= now) continue;  // 启动时即丢弃过期条目
        const std::string hash = e["hash"].get<std::string>();
        if (hash.size() != 64) continue;
        by_hash_[hash] = std::move(entry);
    }
}

void RefreshTokens::save_locked() {
    sa::json arr = sa::json::array();
    for (const auto& kv : by_hash_) {
        if (!kv.second.persist) continue;
        sa::json e = sa::json::object();
        e["hash"] = kv.first;
        e["name"] = kv.second.name;
        e["expires_ms"] = kv.second.expires_ms;
        e["created_ms"] = kv.second.created_ms;
        e["last_seen_ms"] = kv.second.last_seen_ms;
        arr.push_back(std::move(e));
    }
    try {
        sa_core::write_bytes_atomic(file_, sa_core::py_dumps(arr));
    } catch (const std::exception& ex) {
        // 落盘失败不阻断本次请求：令牌仍在内存有效，只是重启后丢失。
        std::fprintf(stderr, "[gateway] cannot persist refresh tokens: %s\n", ex.what());
    }
}

std::string RefreshTokens::issue(const std::string& name, long long ttl_ms, bool persist) {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    std::string token;
    Entry entry;
    entry.name = name;
    const long long now = sa_core::now_ms();
    entry.expires_ms = now + ttl_ms;
    entry.created_ms = now;
    entry.last_seen_ms = now;
    entry.persist = persist;
    // 随机源足够好，冲突实际不可能；但表是身份映射，仍防御性去重。
    do {
        token = random_token_hex();
    } while (by_hash_.count(hash_token(token)));
    by_hash_[hash_token(token)] = std::move(entry);
    if (persist) save_locked();
    return token;
}

bool RefreshTokens::check(const std::string& token, std::string* name) {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    auto it = by_hash_.find(hash_token(token));
    if (it == by_hash_.end()) return false;
    const long long now = sa_core::now_ms();
    if (now >= it->second.expires_ms) {
        by_hash_.erase(it);
        return false;
    }
    it->second.last_seen_ms = now;
    if (name) *name = it->second.name;
    return true;
}

bool RefreshTokens::refresh(const std::string& old_token, long long remember_ttl_ms,
                            long long session_ttl_ms, std::string* new_token,
                            std::string* name, long long* new_ttl_ms) {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    auto it = by_hash_.find(hash_token(old_token));
    if (it == by_hash_.end()) return false;
    const long long now = sa_core::now_ms();
    if (now >= it->second.expires_ms) {
        const bool was_persist = it->second.persist;
        by_hash_.erase(it);
        if (was_persist) save_locked();
        return false;
    }
    // 旧令牌一次性失效 + 沿用其持久化属性签发新令牌（旋转）。
    const std::string account = it->second.name;
    const bool persist = it->second.persist;
    by_hash_.erase(it);
    std::string token;
    Entry entry;
    entry.name = account;
    const long long ttl_ms = persist ? remember_ttl_ms : session_ttl_ms;
    entry.expires_ms = now + ttl_ms;
    entry.created_ms = now;
    entry.last_seen_ms = now;
    entry.persist = persist;
    do {
        token = random_token_hex();
    } while (by_hash_.count(hash_token(token)));
    by_hash_[hash_token(token)] = std::move(entry);
    if (persist) save_locked();
    if (new_token) *new_token = token;
    if (name) *name = account;
    if (new_ttl_ms) *new_ttl_ms = ttl_ms;
    return true;
}

bool RefreshTokens::revoke(const std::string& token) {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    auto it = by_hash_.find(hash_token(token));
    if (it == by_hash_.end()) return false;
    const bool was_persist = it->second.persist;
    by_hash_.erase(it);
    if (was_persist) save_locked();
    return true;
}

std::size_t RefreshTokens::prune_expired() {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    const long long now = sa_core::now_ms();
    std::size_t removed = 0;
    bool changed_persist = false;
    for (auto it = by_hash_.begin(); it != by_hash_.end();) {
        if (now >= it->second.expires_ms) {
            if (it->second.persist) changed_persist = true;
            it = by_hash_.erase(it);
            ++removed;
        } else {
            ++it;
        }
    }
    if (changed_persist) save_locked();
    return removed;
}

std::size_t RefreshTokens::size() {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    return by_hash_.size();
}

}  // namespace gw
