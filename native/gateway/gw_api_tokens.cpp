// gateway/gw_api_tokens.cpp — see gw_api_tokens.h.
#include "gw_api_tokens.h"

#include <algorithm>
#include <cstdio>
#include <random>
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
namespace {

constexpr const char* kTokenPrefix = "sa_mcp_";

// 令牌体：24 字节随机 → 48 位小写 hex。
std::string random_hex_48() {
    std::random_device rd;
    std::string raw;
    raw.reserve(24);
    while (raw.size() < 24) {
        unsigned int v = rd();
        for (int i = 0; i < 4 && raw.size() < 24; ++i)
            raw.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
    }
    return sa_core::http::bytes_to_hex(raw);
}

}  // namespace

std::string ApiTokens::token_prefix() { return kTokenPrefix; }

std::string ApiTokens::hash_token(const std::string& token) {
    // 真 FIPS 摘要（安全批次 A 起，凡与外部互通/承担密码学强度的场景都用
    // strict 版本；token 哈希正是这种场景）。
    return sa_core::sha256_hex_strict(token);
}

std::string ApiTokens::token_id(const std::string& hash) {
    return hash.size() >= 16 ? hash.substr(0, 16) : hash;
}

ApiTokens::ApiTokens(std::string file) : file_(std::move(file)) {}

void ApiTokens::load_locked() {
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
        if (!e.contains("account") || !e["account"].is_string()) continue;
        const std::string hash = e["hash"].get<std::string>();
        if (hash.size() != 64) continue;
        Entry entry;
        entry.account = e["account"].get<std::string>();
        if (e.contains("label") && e["label"].is_string())
            entry.label = e["label"].get<std::string>();
        if (e.contains("created_ms") && e["created_ms"].is_number_integer())
            entry.created_ms = e["created_ms"].get<long long>();
        if (e.contains("expires_ms") && e["expires_ms"].is_number_integer())
            entry.expires_ms = e["expires_ms"].get<long long>();
        if (e.contains("readonly") && e["readonly"].is_boolean())
            entry.readonly = e["readonly"].get<bool>();
        if (entry.expires_ms != 0 && entry.expires_ms <= now) continue;  // 启动即清理
        by_hash_[hash] = std::move(entry);
    }
}

void ApiTokens::save_locked() {
    sa::json arr = sa::json::array();
    for (const auto& kv : by_hash_) {
        sa::json e = sa::json::object();
        e["hash"] = kv.first;
        e["account"] = kv.second.account;
        e["label"] = kv.second.label;
        e["created_ms"] = kv.second.created_ms;
        e["expires_ms"] = kv.second.expires_ms;
        e["readonly"] = kv.second.readonly;
        arr.push_back(std::move(e));
    }
    try {
        sa_core::write_bytes_atomic(file_, sa_core::py_dumps(arr));
    } catch (const std::exception& ex) {
        // 落盘失败不阻断签发：令牌内存有效，只是网关重启后丢失。
        std::fprintf(stderr, "[gateway] cannot persist api tokens: %s\n", ex.what());
    }
}

std::string ApiTokens::issue(const std::string& account, const std::string& label, int ttl_days,
                             bool readonly, ApiTokenInfo* out) {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    std::string token;
    do {
        token = std::string(kTokenPrefix) + random_hex_48();
    } while (by_hash_.count(hash_token(token)));
    const std::string hash = hash_token(token);
    Entry entry;
    entry.account = account;
    entry.label = label;
    entry.created_ms = sa_core::now_ms();
    entry.expires_ms = ttl_days > 0 ? entry.created_ms + static_cast<long long>(ttl_days) * 86400LL * 1000LL
                                    : 0;
    entry.readonly = readonly;
    if (out) {
        out->id = token_id(hash);
        out->account = account;
        out->label = label;
        out->created_ms = entry.created_ms;
        out->expires_ms = entry.expires_ms;
        out->readonly = readonly;
    }
    by_hash_[hash] = std::move(entry);
    save_locked();
    return token;
}

bool ApiTokens::verify(const std::string& token, std::string* account, bool* readonly) {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    auto it = by_hash_.find(hash_token(token));
    if (it == by_hash_.end()) return false;
    const long long now = sa_core::now_ms();
    if (it->second.expires_ms != 0 && now >= it->second.expires_ms) {
        by_hash_.erase(it);
        save_locked();
        return false;
    }
    if (account) *account = it->second.account;
    if (readonly) *readonly = it->second.readonly;
    return true;
}

std::vector<ApiTokenInfo> ApiTokens::list_for_account(const std::string& account) {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    std::vector<ApiTokenInfo> out;
    for (const auto& kv : by_hash_) {
        if (kv.second.account != account) continue;
        ApiTokenInfo info;
        info.id = token_id(kv.first);
        info.account = kv.second.account;
        info.label = kv.second.label;
        info.created_ms = kv.second.created_ms;
        info.expires_ms = kv.second.expires_ms;
        info.readonly = kv.second.readonly;
        out.push_back(std::move(info));
    }
    std::sort(out.begin(), out.end(), [](const ApiTokenInfo& a, const ApiTokenInfo& b) {
        if (a.created_ms != b.created_ms) return a.created_ms > b.created_ms;
        return a.id < b.id;  // 同一毫秒内保证确定性
    });
    return out;
}

bool ApiTokens::revoke(const std::string& account, const std::string& id) {
    if (id.empty()) return false;
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    for (auto it = by_hash_.begin(); it != by_hash_.end(); ++it) {
        if (it->second.account != account) continue;
        if (token_id(it->first) != id && it->first != id) continue;
        by_hash_.erase(it);
        save_locked();
        return true;
    }
    return false;
}

std::size_t ApiTokens::size() {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    return by_hash_.size();
}

}  // namespace gw
