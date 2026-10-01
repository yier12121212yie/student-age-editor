// gateway/gw_config: gateway.json parsing + validation, and the password-hash
// primitive shared by `--hash-password` and POST /api/auth/login (网页版计划 M2.1).
//
// 口令哈希带版本（安全批次 A）：
//   v1（legacy）：sha256_hex( salt_hex_ASCII ++ password )（sa_core 的
//                 K[27] 错值表 —— 与历史 gateway.json 逐位兼容）。
//   v2（现行）  ：PBKDF2-HMAC-SHA256( password, salt_bytes, iterations )
//                 （sa_core 的 FIPS 表；iterations >= kKdfMinIterations）。
// 账号字段 kdf_version 选择校验路径；v1 命中后 check_login 会透明升级到
// v2（内存内生效并回传新哈希行，提醒管理员写回 gateway.json）。
//
// `--hash-password` 现在输出 v2：`salt:hash` 行 + 一段可直接粘贴进
// gateway.json accounts[] 的 JSON 字段（含 kdf_version/kdf_iterations）。
//
// Validation mirrors the spirit of workspace_routes' 阶段1c guard (reject
// empty / filesystem root as an account workspace) without re-implementing
// the whole table — the account dirs live under an admin-declared
// user_data_root, so the root/empty checks are what actually matter here.
//
// This file is platform-neutral (no POSIX-only code): the whole gateway
// target only builds on UNIX (root CMakeLists gate), but keeping the config
// layer portable is what lets test_gateway.cpp parse configs directly.
#pragma once

#include <deque>
#include <string>
#include <vector>

#include "server/httpd.h"  // sa::json (ordered_json)

namespace gw {

// v2 KDF 迭代次数：下限即默认（安全批次 A 要求 >= 10 万）。调高由管理员
// 在 gateway.json 显式指定；调低直接拒绝解析。
constexpr int kKdfVersion2 = 2;
constexpr int kKdfIterationsDefault = 100000;
constexpr int kKdfMinIterations = 100000;

struct Account {
    std::string name;
    std::string salt;              // 32 lowercase hex chars
    std::string password_sha256;   // 64 lowercase hex chars（v1/v2 通用字段）
    std::string dir;               // resolved account workspace (absolute)
    bool disabled = false;
    int kdf_version = 1;           // 1 = legacy sha256(salt+pw)；2 = PBKDF2
    int kdf_iterations = 0;        // v2 有效；0 == 解析时取 kKdfIterationsDefault
};

// 自助注册（自托管网页端）：默认关闭；开启后可选择要求邀请码。新账号写入
// 独立的 credentials 文件（Config::accounts_file），gateway.json 保持管理员
// 只读。见 gw_accounts.h。
struct RegistrationCfg {
    bool enabled = false;          // 安全默认：关闭
    std::string invite_code;       // 空 == 开放注册；非空 == 必须精确匹配
    int max_accounts = 0;          // 0 == 不限（含 gateway.json 预置账号）
    int min_password_length = 8;   // 注册密码最短字符数
};

struct AiRelayCfg {
    bool enabled = false;
    std::string provider = "openai_compatible";
    std::string base_url;
    std::string api_key;
    std::string model;             // optional default model
    std::vector<std::string> models;  // whitelist; empty == unrestricted
    long long daily_limit = 0;     // 0 == unlimited
};

struct Config {
    std::string user_data_root;    // absolute, created if missing
    std::string web_root;          // "" == no static hosting
    int listen_port = 8770;
    std::vector<std::string> trusted_origins;
    long long session_ttl_hours = 24;
    int instance_max = 8;
    int idle_minutes = 30;
    std::string state_dir;         // resolved (defaults to <root>/.gateway)
    // 自助注册账号的持久化文件（默认为 <state_dir>/accounts.json）；由
    // parse_config 派生，管理员无需配置。
    std::string accounts_file;
    // 安全批次：注册写入是低频但并发的，用 std::deque 保证既有 Account*
    // 在 push_back 后不失效（vector 扩容会让代理/进程池持有的指针悬空）。
    std::deque<Account> accounts;
    AiRelayCfg ai;
    RegistrationCfg registration;
    // 托管模式 SSRF 护栏（安全批次 A）：true 时网关 fork 的 backend 以
    // --cloud-public-only 启动，云同步出站 URL 强校验为公网地址。
    bool cloud_public_only = true;

    // Non-fatal findings the caller should print as warnings (e.g. web_root
    // missing -> static hosting not registered).
    std::vector<std::string> warnings;

    const Account* find_account(const std::string& name) const {
        for (const auto& a : accounts)
            if (a.name == name) return &a;
        return nullptr;
    }
};

// Parse a nlohmann view (already read from disk by load_config). Returns
// false + a human-readable `err` on any fatal problem (missing/relative
// user_data_root, empty accounts, bad salt/hash format, duplicate names...).
// Does NOT touch the filesystem except to resolve absolute paths; directory
// creation lives in main() so tests can parse without side effects.
bool parse_config(const sa::json& j, Config* out, std::string* err);

// Read + parse + validate the file. Same error semantics as parse_config.
bool load_config(const std::string& path, Config* out, std::string* err);

// --- password hashing --------------------------------------------------------

// Lowercase hex of exactly `len` chars?
bool is_hex_lower(std::string_view s, std::size_t len);

// Account names become a path component under user_data_root, so they are held
// to a boring slug: [A-Za-z0-9_-]+, non-empty. Shared by gateway.json parsing
// and self-registration so the two can never diverge.
bool valid_account_name(std::string_view name);

// 16 random bytes rendered as 32 lowercase hex chars (std::random_device).
std::string random_salt_hex();

// v1（legacy）：hex of sha256(salt_hex bytes ++ password bytes)——sa_core 的
// K[27] 错值表。仅为校验历史 gateway.json 账号保留，禁止用于新账号。
std::string password_hash(std::string_view salt_hex, std::string_view password);

// v2（现行）：hex of PBKDF2-HMAC-SHA256(password, salt 字节, iterations)。
// salt_hex 按存储的 32 位小写 hex 解码为 16 字节盐。iterations < 下限时
// 抛 std::invalid_argument（解析层与 --hash-password 均不会构造出该调用）。
std::string password_hash_v2(std::string_view salt_hex, std::string_view password,
                             int iterations);

// `--hash-password` 的一次铸造结果（现行策略 = v2 + 默认迭代数）。
struct PasswordMint {
    std::string salt;        // 32 lowercase hex chars
    std::string hash;        // 64 lowercase hex chars
    int kdf_version = kKdfVersion2;
    int iterations = kKdfIterationsDefault;
};
PasswordMint mint_password(std::string_view password);

// `--hash-password` 输出行："<random-salt>:<hash>"（v2 哈希；main.cpp 会在
// 旁边附上含 kdf 字段的 gateway.json JSON 片段）。
std::string hash_password_line(std::string_view password);

// Length-independent, branch-minimized equality over hex strings (the login
// compare). Returns false fast only on empty-vs-empty mismatch semantics being
// irrelevant here: callers pre-validate formats.
bool secure_equals(std::string_view a, std::string_view b);

}  // namespace gw
