// gateway/gw_sessions: in-memory Bearer session table (网页版计划 M2.1).
//
// {token -> (name, expires_ms, last_seen_ms)}; tokens are 256-bit
// std::random_device values hex-encoded. Expiry is absolute (ttl from issue
// time); `last_seen_ms` is refreshed on every successful check so a future
// idle-policy can read it. Sessions live only in this process: a gateway
// restart signs everyone out (accepted for M2 — the frontend treats 401 as
// "back to login").
#pragma once

#include <cstddef>
#include <mutex>
#include <string>
#include <unordered_map>

namespace gw {

class Sessions {
  public:
    explicit Sessions(long long ttl_ms) : ttl_ms_(ttl_ms) {}

    // 64-lowercase-hex token. Issues with expires_ms = now + ttl.
    std::string issue(const std::string& name);

    struct Info {
        std::string name;
        long long expires_ms = 0;
        long long last_seen_ms = 0;
    };
    // Found && not expired (expired entries are deleted here). Refreshes
    // last_seen on success.
    bool check(const std::string& token, Info* out);

    bool logout(const std::string& token);

    // Background sweep (reaper thread): drop expired entries. Returns count.
    std::size_t prune_expired();

    std::size_t size();

    // 256-bit random token (64 lowercase hex chars); exposed for tests.
    static std::string random_token_hex();

  private:
    long long ttl_ms_;
    std::mutex mu_;
    std::unordered_map<std::string, Info> map_;
};

// Extract the token from a raw Authorization header value ("Bearer <tok>",
// scheme case-insensitive per RFC 7235). False when absent/malformed.
bool parse_bearer(const std::string& header, std::string* token);

}  // namespace gw
