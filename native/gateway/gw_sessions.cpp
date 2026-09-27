// gateway/gw_sessions.cpp — see gw_sessions.h.
#include "gw_sessions.h"

#include <random>

#include "sa_core/http_client.h"  // bytes_to_hex
#include "sa_core/strings.h"
#include "sa_core/util.h"  // now_ms

namespace gw {

std::string Sessions::random_token_hex() {
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

std::string Sessions::issue(const std::string& name) {
    std::lock_guard<std::mutex> lk(mu_);
    Info info;
    info.name = name;
    info.expires_ms = sa_core::now_ms() + ttl_ms_;
    info.last_seen_ms = sa_core::now_ms();
    std::string token;
    // The random source is good enough that collisions cannot happen in
    // practice, but the table is an identity map: loop defensively.
    do {
        token = random_token_hex();
    } while (map_.count(token));
    map_[token] = std::move(info);
    return token;
}

bool Sessions::check(const std::string& token, Info* out) {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = map_.find(token);
    if (it == map_.end()) return false;
    const long long now = sa_core::now_ms();
    if (now >= it->second.expires_ms) {
        map_.erase(it);
        return false;
    }
    it->second.last_seen_ms = now;
    if (out) *out = it->second;
    return true;
}

bool Sessions::logout(const std::string& token) {
    std::lock_guard<std::mutex> lk(mu_);
    return map_.erase(token) > 0;
}

std::size_t Sessions::prune_expired() {
    std::lock_guard<std::mutex> lk(mu_);
    const long long now = sa_core::now_ms();
    std::size_t before = map_.size();
    for (auto it = map_.begin(); it != map_.end();) {
        if (now >= it->second.expires_ms)
            it = map_.erase(it);
        else
            ++it;
    }
    return before - map_.size();
}

std::size_t Sessions::size() {
    std::lock_guard<std::mutex> lk(mu_);
    return map_.size();
}

bool parse_bearer(const std::string& header, std::string* token) {
    std::string h = sa_core::str::trim(header);
    if (h.size() <= 7) return false;
    if (sa_core::str::lower(h.substr(0, 6)) != "bearer") return false;
    if (h[6] != ' ' && h[6] != '\t') return false;
    std::string tok = sa_core::str::trim(h.substr(7));
    if (tok.empty()) return false;
    *token = std::move(tok);
    return true;
}

}  // namespace gw
