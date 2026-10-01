// gateway/gw_accounts.cpp — see gw_accounts.h.
#include "gw_accounts.h"

#include <utility>

#include <nlohmann/json.hpp>

#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"

namespace gw {
namespace {

sa::json account_json(const Account& a) {
    sa::json j = sa::json::object();
    j["name"] = a.name;
    j["salt"] = a.salt;
    j["password_sha256"] = a.password_sha256;
    j["kdf_version"] = a.kdf_version;
    j["kdf_iterations"] = a.kdf_iterations;
    return j;
}

// Strict parse of one array entry. Returns false (entry skipped) on any
// malformed field, reusing the same format checks gateway.json applies.
bool account_from_json(const sa::json& j, Account* out) {
    if (!j.is_object()) return false;
    if (!j.contains("name") || !j["name"].is_string()) return false;
    if (!j.contains("salt") || !j["salt"].is_string()) return false;
    if (!j.contains("password_sha256") || !j["password_sha256"].is_string()) return false;
    out->name = j["name"].get<std::string>();
    out->salt = j["salt"].get<std::string>();
    out->password_sha256 = j["password_sha256"].get<std::string>();
    if (!valid_account_name(out->name)) return false;
    if (!is_hex_lower(out->salt, 32)) return false;
    if (!is_hex_lower(out->password_sha256, 64)) return false;
    out->kdf_version = kKdfVersion2;
    out->kdf_iterations = kKdfIterationsDefault;
    if (j.contains("kdf_version") && j["kdf_version"].is_number_integer())
        out->kdf_version = j["kdf_version"].get<int>();
    if (j.contains("kdf_iterations") && j["kdf_iterations"].is_number_integer())
        out->kdf_iterations = j["kdf_iterations"].get<int>();
    if (out->kdf_version != kKdfVersion2) return false;  // 注册账号恒 v2
    if (out->kdf_iterations < kKdfMinIterations) out->kdf_iterations = kKdfIterationsDefault;
    return true;
}

}  // namespace

RegisteredAccounts::RegisteredAccounts(std::string file, std::string user_data_root)
    : file_(std::move(file)), root_(std::move(user_data_root)) {}

void RegisteredAccounts::load_locked() {
    if (loaded_) return;
    loaded_ = true;
    auto raw = sa_core::paths::read_bytes(file_);
    if (!raw) return;  // 首次运行：文件不存在 == 空
    sa::json j = sa::json::parse(*raw, nullptr, false);
    if (j.is_discarded() || !j.is_array()) return;
    for (const auto& e : j) {
        Account a;
        if (account_from_json(e, &a)) accounts_.push_back(std::move(a));
    }
}

void RegisteredAccounts::merge_into(Config* cfg) {
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    for (const auto& a : accounts_) {
        if (cfg->find_account(a.name)) continue;  // 管理员声明优先
        Account copy = a;
        copy.dir = sa_core::paths::join(root_, copy.name);
        cfg->accounts.push_back(std::move(copy));
    }
}

std::size_t RegisteredAccounts::count() const {
    std::lock_guard<std::mutex> lk(mu_);
    const_cast<RegisteredAccounts*>(this)->load_locked();
    return accounts_.size();
}

bool RegisteredAccounts::add(const std::string& name, const std::string& password,
                             Account* out, std::string* err) {
    if (!valid_account_name(name)) {
        *err = "invalid account name";
        return false;
    }
    if (password.empty()) {
        *err = "empty password";
        return false;
    }
    std::lock_guard<std::mutex> lk(mu_);
    load_locked();
    for (const auto& a : accounts_) {
        if (a.name == name) {
            *err = "account already exists";
            return false;
        }
    }
    const PasswordMint m = mint_password(password);
    Account a;
    a.name = name;
    a.salt = m.salt;
    a.password_sha256 = m.hash;
    a.kdf_version = m.kdf_version;
    a.kdf_iterations = m.iterations;
    a.dir = sa_core::paths::join(root_, name);
    accounts_.push_back(a);

    sa::json arr = sa::json::array();
    for (const auto& e : accounts_) arr.push_back(account_json(e));
    try {
        sa_core::write_bytes_atomic(file_, sa_core::py_dumps(arr));
    } catch (const std::exception& e) {
        accounts_.pop_back();
        *err = std::string("cannot persist account: ") + e.what();
        return false;
    }
    if (out) *out = std::move(a);
    return true;
}

}  // namespace gw
