// gateway/gw_api_tokens: 长期 API 令牌表（网页版 M2 · 外部 Agent 接入）。
//
// 与 refresh token 的区别：refresh token 是「登录会话的延长线」，用完即旋转；
// 这里的 API 令牌是用户主动为外部 Agent（Cursor / Claude Code / Dify…）签发的
// 长期凭据，可带备注、有效期与「只读」标记，可随时吊销。
//
// 安全约束与 gw_refresh 一致：
//   * 明文令牌只在签发响应里出现一次，内存表与 `<state_dir>/api_tokens.json`
//     都只存 SHA-256 哈希；
//   * 令牌形如 `sa_mcp_<48 hex>`，一眼可辨来源；
//   * expires_ms == 0 表示永不过期。
//
// 只读标记的强制点在网关代理：`readonly` 令牌转发 `/api/mcp` 时被追加
// `?readonly=1`，后端据此只暴露/放行 9 个只读工具。
#pragma once

#include <cstddef>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace gw {

// 令牌的内存视图（不含明文）。
struct ApiTokenInfo {
    std::string id;       // 16 位小写 hex，= sha256 前 16 位（展示 / 吊销用）
    std::string account;  // 所属账号
    std::string label;    // 备注（如 "Cursor"）
    long long created_ms = 0;
    long long expires_ms = 0;  // 0 == 永不过期
    bool readonly = false;
};

class ApiTokens {
  public:
    // `file` 可以尚不存在（按空处理）；state_dir 由 main() 预先创建。
    explicit ApiTokens(std::string file);

    // 签发一个新令牌，返回明文（`sa_mcp_` + 48 位小写 hex）并回填 *out。
    // ttl_days <= 0 == 永不过期。
    std::string issue(const std::string& account, const std::string& label, int ttl_days,
                      bool readonly, ApiTokenInfo* out);

    // 校验令牌（不消费、不删除）。命中且未过期返回 true，回填账号与只读标记。
    bool verify(const std::string& token, std::string* account, bool* readonly);

    // 某账号的全部令牌，按创建时间倒序（新的在前）。
    std::vector<ApiTokenInfo> list_for_account(const std::string& account);

    // 吊销：在该账号范围内按 id（16 位前缀）或完整哈希删除。返回是否命中。
    bool revoke(const std::string& account, const std::string& id);

    std::size_t size();

    static std::string token_prefix();  // "sa_mcp_"
    // 令牌哈希（sha256 hex）——内存表与磁盘都以它作键；暴露供测试。
    static std::string hash_token(const std::string& token);
    // 令牌展示用 id（哈希前 16 位）。
    static std::string token_id(const std::string& hash);

  private:
    struct Entry {
        std::string account;
        std::string label;
        long long created_ms = 0;
        long long expires_ms = 0;
        bool readonly = false;
    };
    void load_locked();
    void save_locked();

    std::string file_;
    std::mutex mu_;
    // std::map（而非 unordered）让列表输出顺序稳定、便于断言。
    std::map<std::string, Entry> by_hash_;
    bool loaded_ = false;
};

}  // namespace gw
