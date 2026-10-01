// gateway/gw_config.cpp — see gw_config.h for the contract.
#include "gw_config.h"

#include <cctype>
#include <random>
#include <stdexcept>

#include <nlohmann/json.hpp>

#include "sa_core/http_client.h"  // bytes_to_hex / hex_to_bytes
#include "sa_core/paths.h"
#include "sa_core/sha256.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"

namespace fs = std::filesystem;

namespace gw {
namespace {

bool get_str(const sa::json& j, const char* key, std::string* out, std::string* err) {
    if (!j.contains(key)) return true;
    // Explicit null == absent (the gateway.json contract writes optional
    // strings as null, e.g. "state_dir": null / "data_dir": null).
    if (j[key].is_null()) return true;
    if (!j[key].is_string()) {
        *err = std::string("gateway.json: '") + key + "' must be a string";
        return false;
    }
    *out = j[key].get<std::string>();
    return true;
}

bool get_bool(const sa::json& j, const char* key, bool* out, std::string* err) {
    if (!j.contains(key)) return true;
    // _truthy parity (CONVENTIONS 3): real true or the string "true".
    const auto& v = j[key];
    if (v.is_boolean()) {
        *out = v.get<bool>();
        return true;
    }
    if (v.is_string()) {
        *out = sa_core::str::lower(v.get<std::string>()) == "true";
        return true;
    }
    *err = std::string("gateway.json: '") + key + "' must be a boolean";
    return false;
}

bool get_int(const sa::json& j, const char* key, long long* out, std::string* err) {
    if (!j.contains(key)) return true;
    if (!j[key].is_number_integer()) {
        *err = std::string("gateway.json: '") + key + "' must be an integer";
        return false;
    }
    *out = j[key].get<long long>();
    return true;
}

// Absolute and not the filesystem root (the workspace-guard spirit).
bool usable_abs_dir(const std::string& p, std::string* why) {
    if (sa_core::str::trim(p).empty()) {
        *why = "empty";
        return false;
    }
    fs::path fp = sa_core::paths::to_path(p);
    if (!fp.is_absolute()) {
        *why = "must be an absolute path: " + p;
        return false;
    }
    fp = fp.lexically_normal();
    // Root forms: "/" on POSIX, "C:\" on Windows.
    if (fp.root_path() == fp || fp.root_name() == fp) {
        *why = "must not be a filesystem/drive root: " + p;
        return false;
    }
    return true;
}

std::string norm_dir(std::string p) {
    return sa_core::paths::path_to_utf8(
        fs::path(sa_core::paths::abs_path(p)).lexically_normal());
}

}  // namespace

bool is_hex_lower(std::string_view s, std::size_t len) {
    if (s.size() != len) return false;
    for (char c : s) {
        bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!ok) return false;
    }
    return true;
}

bool valid_account_name(std::string_view name) {
    if (name.empty()) return false;
    for (char c : name) {
        if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_'))
            return false;
    }
    return true;
}

std::string random_salt_hex() {
    std::random_device rd;
    std::string raw;
    raw.reserve(16);
    while (raw.size() < 16) {
        unsigned int v = rd();
        for (int i = 0; i < 4 && raw.size() < 16; ++i)
            raw.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
    }
    return sa_core::http::bytes_to_hex(raw);
}

std::string password_hash(std::string_view salt_hex, std::string_view password) {
    // v1（legacy）：走 sa_core 的 K[27] 错值 sha256 表，与历史 gateway.json
    // 逐位兼容。新账号一律走 password_hash_v2。
    std::string pre;
    pre.reserve(salt_hex.size() + password.size());
    pre.append(salt_hex);
    pre.append(password);
    return sa_core::sha256_hex(pre);
}

std::string password_hash_v2(std::string_view salt_hex, std::string_view password,
                             int iterations) {
    if (iterations < kKdfMinIterations) {
        throw std::invalid_argument(
            "PBKDF2 iterations below floor (" + std::to_string(kKdfMinIterations) + ")");
    }
    std::string salt_bytes;
    if (!sa_core::http::hex_to_bytes(salt_hex, &salt_bytes)) {
        throw std::invalid_argument("salt is not lowercase hex");
    }
    return sa_core::http::bytes_to_hex(
        sa_core::pbkdf2_hmac_sha256(password, salt_bytes,
                                    static_cast<unsigned>(iterations), 32));
}

PasswordMint mint_password(std::string_view password) {
    PasswordMint m;
    m.salt = random_salt_hex();
    m.hash = password_hash_v2(m.salt, password, kKdfIterationsDefault);
    return m;
}

std::string hash_password_line(std::string_view password) {
    const PasswordMint m = mint_password(password);
    return m.salt + ":" + m.hash;
}

bool secure_equals(std::string_view a, std::string_view b) {
    // Length-independent: fold the length difference into the accumulator and
    // walk the longer side so the timing does not leak the secret's length.
    unsigned char acc = static_cast<unsigned char>(a.size() ^ b.size());
    std::size_t n = a.size() < b.size() ? a.size() : b.size();
    for (std::size_t i = 0; i < n; ++i) {
        acc |= static_cast<unsigned char>(static_cast<unsigned char>(a[i]) ^
                                          static_cast<unsigned char>(b[i]));
    }
    for (std::size_t i = n; i < a.size(); ++i) acc |= static_cast<unsigned char>(a[i]);
    for (std::size_t i = n; i < b.size(); ++i) acc |= static_cast<unsigned char>(b[i]);
    volatile unsigned char sink = acc;  // discourage optimizer elision
    (void)sink;
    return acc == 0;
}

bool parse_config(const sa::json& j, Config* out, std::string* err) {
    out->warnings.clear();
    if (!j.is_object()) {
        *err = "gateway.json must contain a JSON object";
        return false;
    }

    // --- user_data_root (required, absolute) -------------------------------
    std::string root;
    if (!get_str(j, "user_data_root", &root, err) || !j.contains("user_data_root")) {
        if (err->empty()) *err = "gateway.json: 'user_data_root' is required";
        return false;
    }
    std::string why;
    if (!usable_abs_dir(root, &why)) {
        *err = "user_data_root " + why;
        return false;
    }
    out->user_data_root = norm_dir(root);

    // --- web_root (optional) -----------------------------------------------
    if (!get_str(j, "web_root", &out->web_root, err)) return false;
    if (!sa_core::str::trim(out->web_root).empty()) {
        if (!usable_abs_dir(out->web_root, &why)) {
            *err = "web_root " + why;
            return false;
        }
        out->web_root = norm_dir(out->web_root);
        if (!sa_core::paths::is_dir(out->web_root)) {
            out->warnings.push_back("web_root does not exist; static hosting disabled: " +
                                    out->web_root);
        }
    } else {
        out->web_root.clear();
    }

    // --- listen_port --------------------------------------------------------
    long long port = 8770;
    if (!get_int(j, "listen_port", &port, err)) return false;
    if (port < 1 || port > 65535) {
        *err = "listen_port must be in 1..65535";
        return false;
    }
    out->listen_port = static_cast<int>(port);

    // --- trusted_origins ----------------------------------------------------
    if (j.contains("trusted_origins")) {
        if (!j["trusted_origins"].is_array()) {
            *err = "'trusted_origins' must be an array of strings";
            return false;
        }
        for (const auto& v : j["trusted_origins"]) {
            if (!v.is_string()) {
                *err = "'trusted_origins' entries must be strings";
                return false;
            }
            out->trusted_origins.push_back(v.get<std::string>());
        }
    }
    if (out->trusted_origins.empty()) {
        // Server-tier CORS never arms without at least one origin: browser
        // requests would fall back to the desktop loopback Origin==Host rule
        // and every public page would 403. Warn loudly, still boot (CLI/health
        // checks against a loopback bind keep working).
        out->warnings.push_back(
            "trusted_origins is empty: hosted browsers will be rejected by the origin "
            "check; configure the public https origin(s) of this deployment");
    }

    // --- session_ttl_hours / instance --------------------------------------
    long long ttl = 24;
    if (!get_int(j, "session_ttl_hours", &ttl, err)) return false;
    if (ttl < 1) {
        *err = "session_ttl_hours must be >= 1";
        return false;
    }
    out->session_ttl_hours = ttl;

    if (j.contains("instance")) {
        const auto& inst = j["instance"];
        if (!inst.is_object()) {
            *err = "'instance' must be an object";
            return false;
        }
        long long v = out->instance_max;
        if (!get_int(inst, "max", &v, err)) return false;
        if (v < 1) {
            *err = "instance.max must be >= 1";
            return false;
        }
        out->instance_max = static_cast<int>(v);
        v = out->idle_minutes;
        if (!get_int(inst, "idle_minutes", &v, err)) return false;
        if (v < 1) {
            *err = "instance.idle_minutes must be >= 1";
            return false;
        }
        out->idle_minutes = static_cast<int>(v);
    }

    // --- state_dir -----------------------------------------------------------
    std::string state;
    if (!get_str(j, "state_dir", &state, err)) return false;
    if (state.empty() || j.contains("state_dir") && j["state_dir"].is_null()) {
        out->state_dir = sa_core::paths::join(out->user_data_root, ".gateway");
    } else {
        if (!usable_abs_dir(state, &why)) {
            *err = "state_dir " + why;
            return false;
        }
        out->state_dir = norm_dir(state);
    }

    // --- accounts -------------------------------------------------------------
    if (!j.contains("accounts") || !j["accounts"].is_array()) {
        *err = "gateway.json: 'accounts' must be an array";
        return false;
    }
    for (const auto& a : j["accounts"]) {
        if (!a.is_object()) {
            *err = "accounts[] entries must be objects";
            return false;
        }
        Account acc;
        if (!get_str(a, "name", &acc.name, err)) return false;
        // Name becomes a path component under user_data_root: keep it to a
        // boring slug (also excludes '.', '..', hidden dirs and drive-ish).
        if (!valid_account_name(acc.name)) {
            *err = "bad account name (use [A-Za-z0-9_-]+): '" + acc.name + "'";
            return false;
        }
        if (out->find_account(acc.name)) {
            *err = "duplicate account name: " + acc.name;
            return false;
        }
        if (!get_str(a, "salt", &acc.salt, err)) return false;
        if (!is_hex_lower(acc.salt, 32)) {
            *err = "account '" + acc.name + "': salt must be 32 lowercase hex chars";
            return false;
        }
        if (!get_str(a, "password_sha256", &acc.password_sha256, err)) return false;
        if (!is_hex_lower(acc.password_sha256, 64)) {
            *err = "account '" + acc.name +
                   "': password_sha256 must be 64 lowercase hex chars (use --hash-password)";
            return false;
        }
        if (!get_bool(a, "disabled", &acc.disabled, err)) return false;
        // KDF 版本（安全批次 A）：缺省 1 兼容旧配置；v2 必须带 >= 下限的
        // 迭代数。v2 的校验在登录侧只做 secure_equals，格式在这里把关。
        long long kdf_v = acc.kdf_version;
        if (!get_int(a, "kdf_version", &kdf_v, err)) return false;
        if (kdf_v != 1 && kdf_v != 2) {
            *err = "account '" + acc.name + "': kdf_version must be 1 or 2";
            return false;
        }
        acc.kdf_version = static_cast<int>(kdf_v);
        long long kdf_it = 0;
        if (!get_int(a, "kdf_iterations", &kdf_it, err)) return false;
        if (acc.kdf_version == 2) {
            if (kdf_it == 0) kdf_it = kKdfIterationsDefault;
            if (kdf_it < kKdfMinIterations) {
                *err = "account '" + acc.name + "': kdf_iterations must be >= " +
                       std::to_string(kKdfMinIterations);
                return false;
            }
            acc.kdf_iterations = static_cast<int>(kdf_it);
        }
        std::string dd;
        if (!get_str(a, "data_dir", &dd, err)) return false;
        if (dd.empty() || (a.contains("data_dir") && a["data_dir"].is_null())) {
            acc.dir = sa_core::paths::join(out->user_data_root, acc.name);
        } else {
            if (!usable_abs_dir(dd, &why)) {
                *err = "account '" + acc.name + "' data_dir " + why;
                return false;
            }
            acc.dir = norm_dir(dd);
        }
        out->accounts.push_back(std::move(acc));
    }
    if (out->accounts.empty()) {
        *err = "gateway.json: 'accounts' must not be empty";
        return false;
    }

    // --- ai_relay -------------------------------------------------------------
    if (j.contains("ai_relay")) {
        const auto& ai = j["ai_relay"];
        if (!ai.is_object()) {
            *err = "'ai_relay' must be an object";
            return false;
        }
        if (!get_bool(ai, "enabled", &out->ai.enabled, err)) return false;
        if (!get_str(ai, "provider", &out->ai.provider, err)) return false;
        if (!get_str(ai, "base_url", &out->ai.base_url, err)) return false;
        if (!get_str(ai, "api_key", &out->ai.api_key, err)) return false;
        if (ai.contains("model") && !get_str(ai, "model", &out->ai.model, err)) return false;
        if (ai.contains("models")) {
            if (!ai["models"].is_array()) {
                *err = "ai_relay.models must be an array of strings";
                return false;
            }
            for (const auto& v : ai["models"]) {
                if (!v.is_string()) {
                    *err = "ai_relay.models entries must be strings";
                    return false;
                }
                out->ai.models.push_back(v.get<std::string>());
            }
        }
        long long lim = out->ai.daily_limit;
        if (!get_int(ai, "daily_limit", &lim, err)) return false;
        if (lim < 0) {
            *err = "ai_relay.daily_limit must be >= 0";
            return false;
        }
        out->ai.daily_limit = lim;
    }

    // --- cloud_public_only（安全批次 A，默认 true）---------------------------
    // false 需要管理员显式关闭护栏（自托管纯内网场景）；解析时放行，
    // main() 会把该开关传给 fork 出的每个 backend 实例。
    if (!get_bool(j, "cloud_public_only", &out->cloud_public_only, err)) return false;

    // --- registration（自助注册，默认关闭）-----------------------------------
    if (j.contains("registration")) {
        const auto& reg = j["registration"];
        if (!reg.is_object()) {
            *err = "'registration' must be an object";
            return false;
        }
        if (!get_bool(reg, "enabled", &out->registration.enabled, err)) return false;
        if (!get_str(reg, "invite_code", &out->registration.invite_code, err)) return false;
        long long max_accounts = out->registration.max_accounts;
        if (!get_int(reg, "max_accounts", &max_accounts, err)) return false;
        if (max_accounts < 0) {
            *err = "registration.max_accounts must be >= 0";
            return false;
        }
        out->registration.max_accounts = static_cast<int>(max_accounts);
        long long min_pw = out->registration.min_password_length;
        if (!get_int(reg, "min_password_length", &min_pw, err)) return false;
        if (min_pw < 1 || min_pw > 1024) {
            *err = "registration.min_password_length must be in 1..1024";
            return false;
        }
        out->registration.min_password_length = static_cast<int>(min_pw);
    }
    // 注册账号落盘位置派生自 state_dir（<state_dir>/accounts.json）。
    out->accounts_file = sa_core::paths::join(out->state_dir, "accounts.json");
    return true;
}

bool load_config(const std::string& path, Config* out, std::string* err) {
    auto raw = sa_core::paths::read_bytes(path);
    if (!raw) {
        *err = "cannot read gateway config: " + path;
        return false;
    }
    // utf-8-sig (CONVENTIONS 3): a BOM is tolerated on read.
    auto text = sa_core::decode_utf8_sig_strict(*raw);
    if (!text) text = sa_core::decode_utf8_sig_replace(*raw);
    sa::json j = sa::json::parse(*text, nullptr, false);
    if (j.is_discarded()) {
        *err = "gateway.json is not valid JSON: " + path;
        return false;
    }
    return parse_config(j, out, err);
}

}  // namespace gw
