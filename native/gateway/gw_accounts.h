// gateway/gw_accounts: persistent store for self-service registered accounts
// (网页版计划 · 自托管注册)。
//
// gateway.json 的 accounts[] 始终由管理员拥有、可只读挂载；通过
// POST /api/auth/register 建的账号写入独立的 <state_dir>/accounts.json
// （默认 Config::accounts_file），启动时并回运行时 Config。同名冲突时
// 管理员声明的账号优先（文件条目被忽略），因此管理员永远可以回收任意名字。
//
// 文件格式：一个 JSON 数组，元素为
//   {"name","salt","password_sha256","kdf_version","kdf_iterations"}
// 格式非法的条目直接跳过；写入用 sa_core::write_bytes_atomic 原子落盘，
// 并由内部互斥锁串行化。新账号一律 v2（PBKDF2-HMAC-SHA256）。
#pragma once

#include <mutex>
#include <string>
#include <vector>

#include "gw_config.h"

namespace gw {

class RegisteredAccounts {
  public:
    // `file` 可以尚不存在（按空处理）；`user_data_root` 用于解析每个账号的
    // 工作区目录（<root>/<name>）。
    RegisteredAccounts(std::string file, std::string user_data_root);

    // 读取并合并持久化账号到 *cfg：已由 gateway.json 声明的同名账号跳过。
    // 启动期调用一次（单线程）。
    void merge_into(Config* cfg);

    // 当前内存中持久化账号的数量。
    std::size_t count() const;

    // 校验 + 哈希（v2/PBKDF2）+ 落盘一个新账号。enabled / 重名 / 上限由调用
    // 方针对 Config 先行判定。`out` 收到解析好的账号（dir 已指向 root）。
    // 校验或 IO 失败返回 false 并填 *err。
    bool add(const std::string& name, const std::string& password, Account* out,
             std::string* err);

  private:
    void load_locked();

    std::string file_;
    std::string root_;
    mutable std::mutex mu_;
    std::vector<Account> accounts_;  // 已加载条目（dir 留空，合并时才解析）
    bool loaded_ = false;
};

}  // namespace gw
