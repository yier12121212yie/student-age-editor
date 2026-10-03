// gateway/gw_refresh: long-lived refresh-token table (网页端「记住我」).
//
// access 会话（Sessions）是内存态、短时的；refresh token 用于在 access
// token 过期后静默换新，支撑长期鉴权（记住我）：
//   - 令牌只在签发/旋转响应中出现一次，表内与磁盘均只存其 SHA-256 哈希；
//   - persist=true 的条目落盘到 <state_dir>/refresh_tokens.json，网关重启
//     后仍可长期免登；persist=false 的条目仅内存态（会话级）；
//   - 旋转（refresh）时旧令牌立即失效，降低重放窗口；
//   - logout 可按明文令牌吊销。
//
// 与 gw_sessions 相同：令牌为 256-bit std::random_device 值 hex（64 位）。
#pragma once

#include <cstddef>
#include <mutex>
#include <string>
#include <unordered_map>

namespace gw {

class RefreshTokens {
  public:
    // `file` 可以尚不存在（按空处理）；state_dir 由 main() 预先创建。
    explicit RefreshTokens(std::string file);

    // 签发一个新刷新令牌（64 位小写 hex）。ttl_ms 为有效期；
    // persist=true 时写盘（跨网关重启长期有效）。
    std::string issue(const std::string& name, long long ttl_ms, bool persist);

    // 校验令牌（不消费、不删除）。命中且未过期返回 true 并回填 *name。
    bool check(const std::string& token, std::string* name);

    // 旋转：旧令牌有效则删除并签发新令牌（沿用旧条目的持久化属性），
    // 并按旧条目是否 persist 在 remember_ttl_ms / session_ttl_ms 间选择
    // 新 TTL。旧令牌无效/过期时返回 false 且不签发。新令牌实际 TTL
    // 回填 *new_ttl_ms（可为 nullptr）。
    bool refresh(const std::string& old_token, long long remember_ttl_ms,
                 long long session_ttl_ms, std::string* new_token,
                 std::string* name, long long* new_ttl_ms = nullptr);

    // 吊销一个令牌（logout）。返回是否命中。
    bool revoke(const std::string& token);

    // 后台回收（reaper 线程）：删除过期条目。返回删除数。
    std::size_t prune_expired();

    std::size_t size();

    // 令牌哈希（sha256 hex）——内存表与磁盘都以它作键；暴露供测试。
    static std::string hash_token(const std::string& token);
    // 256-bit 随机令牌（64 位小写 hex）；暴露供测试。
    static std::string random_token_hex();

  private:
    struct Entry {
        std::string name;
        long long expires_ms = 0;
        long long created_ms = 0;
        long long last_seen_ms = 0;
        bool persist = false;  // 是否写入磁盘（记住我）
    };
    void load_locked();
    // 只写 persist 条目；IO 失败仅告警，不回滚内存态（本次会话仍可用）。
    void save_locked();

    std::string file_;
    std::mutex mu_;
    std::unordered_map<std::string, Entry> by_hash_;
    bool loaded_ = false;
};

}  // namespace gw
