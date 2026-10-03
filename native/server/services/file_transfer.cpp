// server/services/file_transfer.cpp — 模块 A 实现（自有私密大文件流转）。
//
// 复用既有 cloud_sync 的 AWS SigV4 原语（sa_core::sha256_hex_strict +
// hmac_sha256_raw），不引入 cos-cpp-sdk；预签名走 query 认证，服务端内网
// 传输走 header 认证（与 S3Driver::sign 同构）。
#include "file_transfer.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <initializer_list>
#include <map>
#include <mutex>
#include <random>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "sa_core/atomic_io.h"
#include "sa_core/http_client.h"
#include "sa_core/md5.h"
#include "sa_core/paths.h"
#include "sa_core/sha256.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"
#include "server/jobs.h"
#include "server/state.h"

namespace sa {
namespace file_transfer {
namespace {

namespace sp = sa_core::str;
namespace spath = sa_core::paths;

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
std::string env_first(std::initializer_list<const char*> names) {
    for (const char* n : names) {
        std::string v = spath::getenv_utf8(n);
        if (!v.empty()) return v;
    }
    return {};
}

long long env_i64(const char* name, long long def) {
    std::string v = spath::getenv_utf8(name);
    if (v.empty()) return def;
    auto p = sa_core::py_int(sp::trim(v));
    return p.value_or(def);
}

std::string rstrip_slash(std::string s) {
    while (!s.empty() && (s.back() == '/' || s.back() == '\\')) s.pop_back();
    return s;
}

std::string uri_encode(const std::string& s, bool keep_slash) {
    static const char* hexd = "0123456789ABCDEF";
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) {
        if (std::isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~' ||
            (keep_slash && c == '/')) {
            out += static_cast<char>(c);
        } else {
            out += '%';
            out += hexd[c >> 4];
            out += hexd[c & 0xF];
        }
    }
    return out;
}

std::string hex_lower(const std::string& raw) {
    static const char* hexd = "0123456789abcdef";
    std::string out;
    out.reserve(raw.size() * 2);
    for (unsigned char c : raw) {
        out += hexd[c >> 4];
        out += hexd[c & 0xF];
    }
    return out;
}

std::string new_id() {
    static std::atomic<unsigned long long> counter{0};
    static const char* hexd = "0123456789abcdef";
    std::mt19937_64 rng(static_cast<unsigned long long>(std::random_device{}()) ^
                        static_cast<unsigned long long>(sa_core::now_ms()) ^
                        counter.fetch_add(0x9E3779B97F4A7C15ull));
    std::string out;
    out.reserve(32);
    for (int i = 0; i < 32; ++i) out += hexd[(rng() >> ((i % 16) * 4)) & 0xF];
    return out;
}

void utc_stamps(time_t now, char* amz_date, size_t ad_len, char* date_stamp, size_t ds_len) {
    std::tm g{};
#ifdef _WIN32
    gmtime_s(&g, &now);
#else
    gmtime_r(&now, &g);
#endif
    std::strftime(amz_date, ad_len, "%Y%m%dT%H%M%SZ", &g);
    std::strftime(date_stamp, ds_len, "%Y%m%d", &g);
}

std::string signing_key(const std::string& secret, const char* date_stamp,
                        const std::string& region, const std::string& service) {
    std::string k_date = sa_core::hmac_sha256_raw("AWS4" + secret, date_stamp);
    std::string k_region = sa_core::hmac_sha256_raw(k_date, region);
    std::string k_service = sa_core::hmac_sha256_raw(k_region, service);
    return sa_core::hmac_sha256_raw(k_service, "aws4_request");
}

// endpoint 是否已是虚拟主机风格（host 以 "<bucket>." 开头）。腾讯云新桶默认
// 禁用路径风格（PathStyleDomainForbidden），必须用虚拟主机风格，此时对象路径
// 不再前置桶名。
bool endpoint_is_virtual_host(const CosConfig& cfg, const std::string& endpoint) {
    if (cfg.bucket.empty()) return false;
    sa_core::http::Url u;
    if (!sa_core::http::parse_url(endpoint, &u)) return false;
    const std::string host = sp::lower(u.host);
    const std::string prefix = sp::lower(cfg.bucket) + ".";
    return host.rfind(prefix, 0) == 0;
}

std::string canonical_path_for(const CosConfig& cfg, const std::string& endpoint,
                               const std::string& key) {
    std::string p = endpoint_is_virtual_host(cfg, endpoint) ? std::string()
                                                            : ("/" + cfg.bucket);
    if (!key.empty()) p += "/" + key;
    if (p.empty()) p = "/";
    return p;
}

std::string host_with_port(const sa_core::http::Url& u) {
    std::string host = sp::lower(u.host);
    const bool default_port = (u.https && u.port == 443) || (!u.https && u.port == 80);
    if (!default_port && u.port > 0) host += ":" + std::to_string(u.port);
    return host;
}

// header 认证签名（内网 GET/PUT/DELETE 用），与 S3Driver::sign 同构。
struct SignedHttp {
    std::string url;
    std::vector<std::pair<std::string, std::string>> headers;
};

SignedHttp sign_headers(const CosConfig& cfg, const std::string& endpoint,
                        const std::string& method, const std::string& key,
                        const std::string& payload, const std::string& content_type) {
    SignedHttp out;
    sa_core::http::Url u;
    if (!sa_core::http::parse_url(endpoint, &u)) return out;

    const std::string encoded_path =
        uri_encode(canonical_path_for(cfg, endpoint, key), true);
    char amz_date[32] = {};
    char date_stamp[16] = {};
    utc_stamps(std::time(nullptr), amz_date, sizeof(amz_date), date_stamp, sizeof(date_stamp));

    const std::string payload_hash = sa_core::sha256_hex_strict(payload);
    const std::string host = host_with_port(u);

    std::vector<std::pair<std::string, std::string>> to_sign;
    to_sign.emplace_back("host", host);
    to_sign.emplace_back("x-amz-content-sha256", payload_hash);
    to_sign.emplace_back("x-amz-date", amz_date);
    if (!cfg.session_token.empty())
        to_sign.emplace_back("x-amz-security-token", cfg.session_token);
    if (!content_type.empty()) to_sign.emplace_back("content-type", content_type);
    std::sort(to_sign.begin(), to_sign.end());

    std::string canonical_headers;
    std::string signed_headers;
    for (const auto& [k, v] : to_sign) {
        canonical_headers += k + ":" + v + "\n";
        if (!signed_headers.empty()) signed_headers += ";";
        signed_headers += k;
    }

    const std::string canonical_request = method + "\n" + encoded_path + "\n\n" +
                                          canonical_headers + "\n" + signed_headers + "\n" +
                                          payload_hash;
    const std::string scope =
        std::string(date_stamp) + "/" + cfg.region + "/" + cfg.service + "/aws4_request";
    const std::string string_to_sign = "AWS4-HMAC-SHA256\n" + std::string(amz_date) + "\n" +
                                       scope + "\n" +
                                       sa_core::sha256_hex_strict(canonical_request);
    const std::string signature =
        hex_lower(sa_core::hmac_sha256_raw(signing_key(cfg.secret_key, date_stamp, cfg.region,
                                                       cfg.service),
                                           string_to_sign));

    out.url = rstrip_slash(endpoint) + encoded_path;
    out.headers.emplace_back("x-amz-content-sha256", payload_hash);
    out.headers.emplace_back("x-amz-date", amz_date);
    if (!cfg.session_token.empty())
        out.headers.emplace_back("x-amz-security-token", cfg.session_token);
    if (!content_type.empty()) out.headers.emplace_back("Content-Type", content_type);
    out.headers.emplace_back(
        "Authorization",
        "AWS4-HMAC-SHA256 Credential=" + cfg.secret_id + "/" + scope +
            ", SignedHeaders=" + signed_headers + ", Signature=" + signature);
    return out;
}

// ---------------------------------------------------------------------------
// JSON 取值 / body 取值（宽松，坏类型按缺省）
// ---------------------------------------------------------------------------
long long j_i64(const json& o, const char* k) {
    auto it = o.find(k);
    if (it == o.end()) return 0;
    if (it->is_number_integer()) return it->get<long long>();
    if (it->is_number_unsigned()) return static_cast<long long>(it->get<unsigned long long>());
    if (it->is_number_float()) return static_cast<long long>(it->get<double>());
    if (it->is_string()) {
        auto v = sa_core::py_int(it->get<std::string>());
        return v.value_or(0);
    }
    return 0;
}

std::string j_str(const json& o, const char* k) {
    auto it = o.find(k);
    return (it != o.end() && it->is_string()) ? it->get<std::string>() : std::string();
}

bool get_body_object(const Req& req, const json** out) {
    if (!req.body.is_object() || req.body.contains("_raw")) return false;
    *out = &req.body;
    return true;
}

std::string body_str(const json& b, const char* k) { return j_str(b, k); }

bool body_i64(const json& b, const char* k, long long* out) {
    auto it = b.find(k);
    if (it == b.end()) return false;
    if (it->is_number_integer()) {
        *out = it->get<long long>();
        return true;
    }
    if (it->is_number_unsigned()) {
        *out = static_cast<long long>(it->get<unsigned long long>());
        return true;
    }
    if (it->is_number_float()) {
        *out = static_cast<long long>(it->get<double>());
        return true;
    }
    if (it->is_string()) {
        auto v = sa_core::py_int(it->get<std::string>());
        if (v) {
            *out = *v;
            return true;
        }
    }
    return false;
}

// 可选字符串字段：命中且非空返回 true 并写出值（initiate 的 story_id/kind）。
bool str_field(const json& o, const char* k, std::string& out) {
    auto it = o.find(k);
    if (it != o.end() && it->is_string()) {
        out = it->get<std::string>();
        return !out.empty();
    }
    return false;
}

Resp err_json(int status, const std::string& msg) {
    return Resp::Json(status, json{{"error", msg}});
}

// ---------------------------------------------------------------------------
// 记录存储：<data_root>/_cache/file_transfer/files.json
// ---------------------------------------------------------------------------
std::mutex g_store_mu;

std::string store_path(const std::string& root) {
    return spath::join(store_dir(root), "files.json");
}

json read_store_unlocked(const std::string& root) {
    json doc = json::object();
    doc["files"] = json::array();
    auto raw = spath::read_bytes(store_path(root));
    if (!raw) return doc;
    json parsed = json::parse(*raw, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object()) return doc;
    if (!parsed.contains("files") || !parsed["files"].is_array())
        parsed["files"] = json::array();
    return parsed;
}

bool write_store_unlocked(const std::string& root, const json& doc) {
    try {
        spath::create_dirs(store_dir(root));
        sa_core::write_text_atomic(store_path(root), doc.dump(2));
        return true;
    } catch (...) {
        return false;
    }
}

json find_unlocked(json& doc, const std::string& id) {
    if (!doc.contains("files") || !doc["files"].is_array()) return json();
    for (auto& rec : doc["files"]) {
        if (rec.is_object() && j_str(rec, "id") == id) return rec;
    }
    return json();
}

// 读-改-写一条记录；未找到返回 null。`found` 标记命中。
json update_record(const std::string& root, const std::string& id,
                   const std::function<void(json&)>& mutate, bool* found) {
    std::lock_guard<std::mutex> lk(g_store_mu);
    json doc = read_store_unlocked(root);
    if (found) *found = false;
    if (!doc.contains("files") || !doc["files"].is_array()) return json();
    for (auto& rec : doc["files"]) {
        if (rec.is_object() && j_str(rec, "id") == id) {
            mutate(rec);
            rec["updated_at"] = sa_core::now_ms();
            write_store_unlocked(root, doc);
            if (found) *found = true;
            return rec;
        }
    }
    return json();
}

void mark_failed(const std::string& root, const std::string& id, const std::string& error) {
    update_record(root, id, [&](json& r) {
        r["status"] = status_name(Status::Failed);
        r["error"] = error;
    }, nullptr);
}

// ---------------------------------------------------------------------------
// CosOps 注入 seam
// ---------------------------------------------------------------------------
std::mutex g_ops_mu;
CosOps g_ops;
bool g_ops_set = false;

CosOps active_ops() {
    std::lock_guard<std::mutex> lk(g_ops_mu);
    if (g_ops_set) return g_ops;
    return make_default_ops();
}

// rand 字段：0-100 位大小写字母与数字。
std::string random_alnum(std::size_t n) {
    static const char kChars[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    thread_local std::mt19937_64 rng{std::random_device{}()};
    std::uniform_int_distribution<std::size_t> dist(0, sizeof(kChars) - 2);
    std::string out;
    out.reserve(n);
    for (std::size_t i = 0; i < n; ++i) out.push_back(kChars[dist(rng)]);
    return out;
}

// 腾讯云 CDN URL 鉴权（TypeA/B/C/D）签名 query（不含 '?'）。path 以 '/' 开头，
// 未配置 type/key 时返回空串（此时 CDN 直链要求源资源公开读）。
//   TypeD：sign=md5(key+path+timestamp)&t=timestamp（timestamp 十进制 Unix）
//   TypeC：sign=timestamp-rand-uid-md5，md5(key+path+timestamp)，timestamp 十六进制
//   TypeA：sign=timestamp-rand-uid-md5，md5(path-timestamp-rand-uid-key)，timestamp 十进制
//   TypeB：sign=timestamp-rand-uid-md5，md5(key+timestamp+path)，timestamp=UTC+8 YYYYMMDDHHMM
std::string cdn_auth_query(const CosConfig& cfg, const std::string& path, long long now_unix) {
    if (cfg.cdn_auth_type.empty() || cfg.cdn_auth_key.empty()) return {};
    const char t = static_cast<char>(
        std::toupper(static_cast<unsigned char>(cfg.cdn_auth_type[0])));
    const long long now =
        now_unix > 0 ? now_unix : static_cast<long long>(std::time(nullptr));
    const std::string param = cfg.cdn_auth_param.empty() ? "sign" : cfg.cdn_auth_param;

    if (t == 'D') {
        const std::string ts = std::to_string(now);
        const std::string hash = sa_core::md5_hex(cfg.cdn_auth_key + path + ts);
        const std::string tsp = cfg.cdn_auth_ts_param.empty() ? "t" : cfg.cdn_auth_ts_param;
        return uri_encode(param, false) + "=" + hash + "&" + uri_encode(tsp, false) + "=" + ts;
    }

    std::string ts;
    std::string hash;
    std::string rand;
    if (t == 'B') {
        const std::time_t shifted = static_cast<std::time_t>(now) + 8 * 3600;
        std::tm g{};
#if defined(_WIN32)
        gmtime_s(&g, &shifted);
#else
        gmtime_r(&shifted, &g);
#endif
        char buf[16] = {};
        std::strftime(buf, sizeof(buf), "%Y%m%d%H%M", &g);
        ts = buf;
        hash = sa_core::md5_hex(cfg.cdn_auth_key + ts + path);
    } else if (t == 'C') {
        char buf[32] = {};
        std::snprintf(buf, sizeof(buf), "%llx", static_cast<unsigned long long>(now));
        ts = buf;
        hash = sa_core::md5_hex(cfg.cdn_auth_key + path + ts);
    } else {
        ts = std::to_string(now);
        rand = random_alnum(10);
        hash = sa_core::md5_hex(path + "-" + ts + "-" + rand + "-0-" + cfg.cdn_auth_key);
    }
    if (rand.empty()) rand = random_alnum(10);
    return uri_encode(param, false) + "=" + ts + "-" + rand + "-0-" + hash;
}

// ---------------------------------------------------------------------------
// 后台调度线程
// ---------------------------------------------------------------------------
std::atomic<bool> g_bg_running{false};
std::thread g_bg_thread;

void background_loop() {
    long long interval = load_config().reclaim_interval_seconds;
    if (interval < 5) interval = 5;
    long long elapsed = 0;
    while (g_bg_running.load()) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        if (!g_bg_running.load()) break;
        if (++elapsed < interval) continue;
        elapsed = 0;
        try {
            reclaim_expired(sa::editor_root(), sa_core::now_ms(), -1);
        } catch (...) {
            // 回收是尽力而为；单次失败不得拖垮调度线程。
        }
    }
}

void enqueue_archive(const std::string& root, const std::string& id) {
    try {
        sa::jobs::submit([root, id]() -> Resp {
            std::string err;
            archive_now(root, id, &err);
            return Resp::Json(200, json::object());
        });
    } catch (...) {
    }
}

void enqueue_warm(const std::string& root, const std::string& id) {
    try {
        sa::jobs::submit([root, id]() -> Resp {
            std::string err;
            warm_now(root, id, &err);
            return Resp::Json(200, json::object());
        });
    } catch (...) {
    }
}

json patch_and_get(const std::string& root, const std::string& id,
                   const std::function<void(json&)>& mutate) {
    bool found = false;
    json rec = update_record(root, id, mutate, &found);
    return found ? rec : json();
}

}  // namespace

std::string download_url(const CosConfig& cfg, const std::string& key, long long now_unix) {
    if (cfg.cdn_domain.empty())
        return presign_url(cfg, "GET", key, cfg.download_ttl_seconds, now_unix);
    const std::string path = "/" + key;
    std::string url = rstrip_slash(cfg.cdn_domain) + uri_encode(path, true);
    const std::string q = cdn_auth_query(cfg, path, now_unix);
    if (!q.empty()) url += "?" + q;
    return url;
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------
const char* status_name(Status s) {
    switch (s) {
        case Status::PendingUpload: return "pending_upload";
        case Status::Archiving: return "archiving";
        case Status::Archived: return "archived";
        case Status::WarmingUp: return "warming_up";
        case Status::Ready: return "ready";
        case Status::S3Uploaded: return "s3_uploaded";
        case Status::Linked: return "linked";
        case Status::Failed: return "failed";
    }
    return "failed";
}

bool status_from_name(const std::string& name, Status* out) {
    if (name == "pending_upload") { *out = Status::PendingUpload; return true; }
    if (name == "archiving") { *out = Status::Archiving; return true; }
    if (name == "archived") { *out = Status::Archived; return true; }
    if (name == "warming_up") { *out = Status::WarmingUp; return true; }
    if (name == "s3_uploaded") { *out = Status::S3Uploaded; return true; }
    if (name == "linked") { *out = Status::Linked; return true; }
    if (name == "ready") { *out = Status::Ready; return true; }
    if (name == "failed") { *out = Status::Failed; return true; }
    return false;
}

bool CosConfig::ready() const {
    return !secret_id.empty() && !secret_key.empty() && !bucket.empty();
}

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------
CosConfig load_config() {
    CosConfig cfg;
    cfg.secret_id = env_first({"EDITOR_FILE_COS_SECRET_ID", "EDITOR_COS_SECRET_ID",
                               "COS_SECRET_ID"});
    cfg.secret_key = env_first({"EDITOR_FILE_COS_SECRET_KEY", "EDITOR_COS_SECRET_KEY",
                                "COS_SECRET_KEY"});
    cfg.session_token = env_first({"EDITOR_FILE_COS_SESSION_TOKEN",
                                   "EDITOR_COS_SESSION_TOKEN", "COS_SESSION_TOKEN"});
    cfg.bucket = env_first({"EDITOR_FILE_COS_BUCKET", "EDITOR_COS_BUCKET", "COS_BUCKET"});
    cfg.region = env_first({"EDITOR_FILE_COS_REGION", "EDITOR_COS_REGION", "COS_REGION"});
    if (cfg.region.empty()) cfg.region = "ap-guangzhou";
    cfg.service = "cos";

    cfg.public_endpoint = env_first({"EDITOR_FILE_COS_PUBLIC_ENDPOINT",
                                     "EDITOR_COS_PUBLIC_ENDPOINT"});
    if (cfg.public_endpoint.empty())
        cfg.public_endpoint = "https://cos." + cfg.region + ".myqcloud.com";
    cfg.public_endpoint = rstrip_slash(cfg.public_endpoint);

    cfg.internal_endpoint = env_first({"EDITOR_FILE_COS_INTERNAL_ENDPOINT",
                                       "EDITOR_COS_INTERNAL_ENDPOINT"});
    if (cfg.internal_endpoint.empty()) cfg.internal_endpoint = cfg.public_endpoint;
    cfg.internal_endpoint = rstrip_slash(cfg.internal_endpoint);

    cfg.cdn_domain = rstrip_slash(
        env_first({"EDITOR_FILE_COS_CDN_DOMAIN", "EDITOR_COS_CDN_DOMAIN"}));

    // CDN URL 鉴权（可选）：type + pkey 同时给出才签名；参数名可自定义。
    cfg.cdn_auth_type = env_first({"EDITOR_FILE_COS_CDN_AUTH_TYPE",
                                    "EDITOR_COS_CDN_AUTH_TYPE"});
    cfg.cdn_auth_key = env_first({"EDITOR_FILE_COS_CDN_AUTH_KEY",
                                   "EDITOR_COS_CDN_AUTH_KEY"});
    {
        std::string p = env_first({"EDITOR_FILE_COS_CDN_AUTH_PARAM",
                                    "EDITOR_COS_CDN_AUTH_PARAM"});
        if (!p.empty()) cfg.cdn_auth_param = p;
        std::string tp = env_first({"EDITOR_FILE_COS_CDN_AUTH_TS_PARAM",
                                     "EDITOR_COS_CDN_AUTH_TS_PARAM"});
        if (!tp.empty()) cfg.cdn_auth_ts_param = tp;
    }
    cfg.cdn_auth_ttl_seconds = env_i64("EDITOR_FILE_COS_CDN_AUTH_TTL", 0);

    cfg.prefix = env_first({"EDITOR_FILE_COS_PREFIX", "EDITOR_COS_PREFIX"});
    if (cfg.prefix.empty()) cfg.prefix = "editor-files";
    cfg.prefix = rstrip_slash(cfg.prefix);

    cfg.upload_ttl_seconds = env_i64("EDITOR_FILE_UPLOAD_TTL", 1800);
    cfg.download_ttl_seconds = env_i64("EDITOR_FILE_DOWNLOAD_TTL", 600);
    cfg.max_bytes = env_i64("EDITOR_FILE_MAX_BYTES", 100LL * 1024 * 1024 * 1024);
    cfg.reclaim_ttl_seconds = env_i64("EDITOR_FILE_RECLAIM_TTL", 2 * 3600);
    cfg.reclaim_interval_seconds = env_i64("EDITOR_FILE_RECLAIM_INTERVAL", 60);
    cfg.s3_direct_enabled = spath::getenv_utf8("EDITOR_FILE_S3_ENABLED") == "1";
    cfg.s3_threshold_bytes = env_i64("EDITOR_FILE_S3_THRESHOLD_BYTES", 50LL * 1024 * 1024);
    return cfg;
}

// ---------------------------------------------------------------------------
// 路径 / 对象键
// ---------------------------------------------------------------------------
std::string store_dir(const std::string& data_root) {
    return spath::join(data_root, "_cache/file_transfer");
}

std::string local_objects_dir(const std::string& data_root) {
    std::string env = spath::getenv_utf8("EDITOR_FILE_LOCAL_ROOT");
    if (!env.empty()) return rstrip_slash(env);
    return spath::join(store_dir(data_root), "objects");
}

std::string sanitize_name(const std::string& name) {
    size_t pos = name.find_last_of("/\\");
    std::string base = (pos == std::string::npos) ? name : name.substr(pos + 1);
    std::string out;
    out.reserve(base.size());
    for (unsigned char c : base) {
        if (std::isalnum(c) || c == '.' || c == '_' || c == '-')
            out += static_cast<char>(c);
        else
            out += '_';
    }
    bool all_dots = !out.empty();
    for (char c : out)
        if (c != '.') { all_dots = false; break; }
    if (out.empty() || all_dots) out = "file";
    return out;
}

std::string staging_key(const CosConfig& cfg, const std::string& id,
                        const std::string& safe_name) {
    return cfg.prefix + "/staging/" + id + "/" + safe_name;
}

std::string warm_key(const CosConfig& cfg, const std::string& id,
                     const std::string& safe_name) {
    return cfg.prefix + "/warm/" + id + "/" + safe_name;
}

// ---------------------------------------------------------------------------
// SigV4 预签名
// ---------------------------------------------------------------------------
std::string presign_url(const CosConfig& cfg, const std::string& method, const std::string& key,
                        long long expires_seconds, long long now_unix) {
    if (!cfg.ready()) return {};
    sa_core::http::Url u;
    if (!sa_core::http::parse_url(cfg.public_endpoint, &u)) return {};
    if (expires_seconds <= 0) expires_seconds = 900;

    const std::string encoded_path =
        uri_encode(canonical_path_for(cfg, cfg.public_endpoint, key), true);
    const time_t now = now_unix > 0 ? static_cast<time_t>(now_unix) : std::time(nullptr);
    char amz_date[32] = {};
    char date_stamp[16] = {};
    utc_stamps(now, amz_date, sizeof(amz_date), date_stamp, sizeof(date_stamp));

    const std::string scope =
        std::string(date_stamp) + "/" + cfg.region + "/" + cfg.service + "/aws4_request";
    const std::string credential = cfg.secret_id + "/" + scope;

    std::vector<std::pair<std::string, std::string>> q;
    q.emplace_back("X-Amz-Algorithm", "AWS4-HMAC-SHA256");
    q.emplace_back("X-Amz-Credential", credential);
    q.emplace_back("X-Amz-Date", amz_date);
    q.emplace_back("X-Amz-Expires", std::to_string(expires_seconds));
    q.emplace_back("X-Amz-SignedHeaders", "host");
    if (!cfg.session_token.empty()) q.emplace_back("X-Amz-Security-Token", cfg.session_token);
    std::sort(q.begin(), q.end());

    std::string canonical_query;
    for (const auto& [k, v] : q) {
        if (!canonical_query.empty()) canonical_query += "&";
        canonical_query += uri_encode(k, false) + "=" + uri_encode(v, false);
    }

    const std::string host = host_with_port(u);
    const std::string canonical_headers = "host:" + host + "\n";
    const std::string canonical_request = method + "\n" + encoded_path + "\n" + canonical_query +
                                          "\n" + canonical_headers + "\n" + "host" + "\n" +
                                          "UNSIGNED-PAYLOAD";
    const std::string string_to_sign = "AWS4-HMAC-SHA256\n" + std::string(amz_date) + "\n" +
                                       scope + "\n" +
                                       sa_core::sha256_hex_strict(canonical_request);
    const std::string signature =
        hex_lower(sa_core::hmac_sha256_raw(signing_key(cfg.secret_key, date_stamp, cfg.region,
                                                       cfg.service),
                                           string_to_sign));

    return rstrip_slash(cfg.public_endpoint) + encoded_path + "?" + canonical_query +
           "&X-Amz-Signature=" + signature;
}

// ---------------------------------------------------------------------------
// 内网传输默认实现
// ---------------------------------------------------------------------------
bool default_download(const CosConfig& cfg, const std::string& key,
                      const std::string& local_path, std::string* err) {
    SignedHttp s = sign_headers(cfg, cfg.internal_endpoint, "GET", key, "", "");
    if (s.url.empty()) {
        if (err) *err = "invalid internal endpoint";
        return false;
    }
    spath::create_dirs(spath::dirname(local_path));
    std::ofstream f(spath::to_path(local_path), std::ios::binary | std::ios::trunc);
    if (!f) {
        if (err) *err = "cannot write local file: " + local_path;
        return false;
    }
    sa_core::http::Request req;
    req.method = "GET";
    req.url = s.url;
    req.headers = s.headers;
    req.timeout_seconds = 600;
    req.bypass_proxy = true;  // 内网 Endpoint 不应经系统代理
    bool write_ok = true;
    auto resp = sa_core::http::request_stream(req, [&](std::string_view chunk) {
        f.write(chunk.data(), static_cast<std::streamsize>(chunk.size()));
        if (!f.good()) {
            write_ok = false;
            return false;
        }
        return true;
    });
    f.flush();
    if (!resp.transport_ok()) {
        if (err) *err = "COS internal GET failed: " + resp.error_message;
        return false;
    }
    if (resp.status != 200) {
        if (err) *err = "COS internal GET " + key + " -> HTTP " + std::to_string(resp.status);
        return false;
    }
    if (!write_ok || !f.good()) {
        if (err) *err = "write failed: " + local_path;
        return false;
    }
    return true;
}

bool default_upload(const CosConfig& cfg, const std::string& local_path,
                    const std::string& key, std::string* err) {
    auto data = spath::read_bytes(local_path);
    if (!data) {
        if (err) *err = "cannot read local file: " + local_path;
        return false;
    }
    SignedHttp s = sign_headers(cfg, cfg.internal_endpoint, "PUT", key, *data,
                                "application/octet-stream");
    if (s.url.empty()) {
        if (err) *err = "invalid internal endpoint";
        return false;
    }
    sa_core::http::Request req;
    req.method = "PUT";
    req.url = s.url;
    req.headers = s.headers;
    req.body = std::move(*data);
    req.timeout_seconds = 1200;
    req.bypass_proxy = true;
    auto resp = sa_core::http::request(req);
    if (!resp.transport_ok()) {
        if (err) *err = "COS internal PUT failed: " + resp.error_message;
        return false;
    }
    if (!(resp.status == 200 || resp.status == 201 || resp.status == 204)) {
        if (err) *err = "COS internal PUT " + key + " -> HTTP " + std::to_string(resp.status);
        return false;
    }
    return true;
}

bool default_remove(const CosConfig& cfg, const std::string& key, std::string* err) {
    SignedHttp s = sign_headers(cfg, cfg.internal_endpoint, "DELETE", key, "", "");
    if (s.url.empty()) {
        if (err) *err = "invalid internal endpoint";
        return false;
    }
    sa_core::http::Request req;
    req.method = "DELETE";
    req.url = s.url;
    req.headers = s.headers;
    req.timeout_seconds = 60;
    req.bypass_proxy = true;
    auto resp = sa_core::http::request(req);
    if (!resp.transport_ok()) {
        if (err) *err = "COS internal DELETE failed: " + resp.error_message;
        return false;
    }
    if (!(resp.status == 200 || resp.status == 202 || resp.status == 204 || resp.status == 404)) {
        if (err) *err = "COS internal DELETE " + key + " -> HTTP " + std::to_string(resp.status);
        return false;
    }
    return true;
}

CosOps make_default_ops() {
    CosOps ops;
    ops.download = default_download;
    ops.upload = default_upload;
    ops.remove = default_remove;
    return ops;
}

void set_cos_ops_for_test(const CosOps& ops) {
    std::lock_guard<std::mutex> lk(g_ops_mu);
    g_ops = ops;
    g_ops_set = true;
}

void reset_cos_ops_for_test() {
    std::lock_guard<std::mutex> lk(g_ops_mu);
    g_ops = CosOps{};
    g_ops_set = false;
}

// ---------------------------------------------------------------------------
// 记录读写（公开）
// ---------------------------------------------------------------------------
json read_store(const std::string& data_root) {
    std::lock_guard<std::mutex> lk(g_store_mu);
    return read_store_unlocked(data_root);
}

json find_record(const std::string& data_root, const std::string& id) {
    std::lock_guard<std::mutex> lk(g_store_mu);
    json doc = read_store_unlocked(data_root);
    return find_unlocked(doc, id);
}

json public_record(const json& record) {
    if (!record.is_object()) return json();
    json out = json::object();
    out["id"] = j_str(record, "id");
    out["name"] = j_str(record, "name");
    out["size"] = j_i64(record, "size");
    out["status"] = j_str(record, "status");
    out["created_at"] = j_i64(record, "created_at");
    out["updated_at"] = j_i64(record, "updated_at");
    for (const char* k : {"uploaded_at", "archived_at", "warmed_at", "last_download_at"}) {
        long long v = j_i64(record, k);
        if (v > 0) out[k] = v;
    }
    std::string err = j_str(record, "error");
    if (!err.empty()) out["error"] = err;
    out["storage_type"] = j_str(record, "storage_type");
    if (!j_str(record, "s3_key").empty()) out["s3_key"] = j_str(record, "s3_key");
    std::string st = j_str(record, "status");
    if (st == "archiving" || st == "warming_up") out["retry_after"] = 5;
    return out;
}

// ---------------------------------------------------------------------------
// 同步归档 / 预热
// ---------------------------------------------------------------------------
bool archive_now(const std::string& data_root, const std::string& id, std::string* err) {
    json rec = find_record(data_root, id);
    if (!rec.is_object()) {
        if (err) *err = "no such file: " + id;
        return false;
    }
    Status st = Status::Failed;
    status_from_name(j_str(rec, "status"), &st);
    if (st == Status::Archived) return true;  // 幂等

    const long long expected = j_i64(rec, "size");
    const std::string safe = j_str(rec, "safe_name").empty()
                                 ? sanitize_name(j_str(rec, "name"))
                                 : j_str(rec, "safe_name");

    // 标记 archiving，避免重复入队。
    patch_and_get(data_root, id, [](json& r) {
        r["status"] = "archiving";
        r["error"] = "";
    });

    CosConfig cfg = load_config();
    if (!cfg.ready()) {
        const std::string msg = "file transfer not configured";
        mark_failed(data_root, id, msg);
        if (err) *err = msg;
        return false;
    }

    const std::string key = staging_key(cfg, id, safe);
    const std::string local = spath::join(local_objects_dir(data_root), id);
    spath::create_dirs(local_objects_dir(data_root));

    CosOps ops = active_ops();
    std::string terr;
    if (!ops.download || !ops.download(cfg, key, local, &terr)) {
        mark_failed(data_root, id, "archive download failed: " + terr);
        if (err) *err = terr;
        return false;
    }

    // 校验成功后立即删除 COS 临时原文件（失败仅记录，不阻塞归档）。
    const long long got = spath::file_size(local);
    if (expected > 0 && got != expected) {
        spath::remove_file(local);
        const std::string msg = "archive verify failed: expected " +
                                std::to_string(expected) + " got " + std::to_string(got);
        mark_failed(data_root, id, msg);
        if (err) *err = msg;
        return false;
    }

    std::string derr;
    bool deleted = true;
    if (ops.remove) deleted = ops.remove(cfg, key, &derr);

    patch_and_get(data_root, id, [&](json& r) {
        r["status"] = "archived";
        r["local_path"] = local;
        r["staging_key"] = key;
        r["archived_at"] = sa_core::now_ms();
        r["staging_deleted"] = deleted;
        r["error"] = deleted ? "" : ("staging delete failed: " + derr);
    });
    return true;
}

bool warm_now(const std::string& data_root, const std::string& id, std::string* err) {
    json rec = find_record(data_root, id);
    if (!rec.is_object()) {
        if (err) *err = "no such file: " + id;
        return false;
    }
    Status st = Status::Failed;
    status_from_name(j_str(rec, "status"), &st);
    if (st == Status::Ready) return true;  // 幂等

    const std::string safe = j_str(rec, "safe_name").empty()
                                 ? sanitize_name(j_str(rec, "name"))
                                 : j_str(rec, "safe_name");
    const std::string local = j_str(rec, "local_path");

    CosConfig cfg = load_config();
    if (!cfg.ready()) {
        const std::string msg = "file transfer not configured";
        patch_and_get(data_root, id, [&](json& r) {
            r["status"] = "archived";
            r["error"] = msg;
        });
        if (err) *err = msg;
        return false;
    }
    if (local.empty() || !spath::is_file(local)) {
        const std::string msg = "local archive missing: " + local;
        mark_failed(data_root, id, msg);
        if (err) *err = msg;
        return false;
    }

    const std::string key = warm_key(cfg, id, safe);
    CosOps ops = active_ops();
    std::string terr;
    if (!ops.upload || !ops.upload(cfg, local, key, &terr)) {
        patch_and_get(data_root, id, [&](json& r) {
            r["status"] = "archived";
            r["error"] = "warm upload failed: " + terr;
        });
        if (err) *err = terr;
        return false;
    }

    const long long now = sa_core::now_ms();
    patch_and_get(data_root, id, [&](json& r) {
        r["status"] = "ready";
        r["warm_key"] = key;
        r["warmed_at"] = now;
        r["last_download_at"] = now;  // 预热完成即视为一次“新鲜”，给回收留窗口
        r["error"] = "";
    });
    return true;
}

// ---------------------------------------------------------------------------
// 大资源引用 / 导出产物（模组线集成）
// ---------------------------------------------------------------------------

// linked 记录的对象键：优先已固化的 key，其次 s3_key / staging_key，最后按
// staging 规则重算（upload/request 与 initiate-s3 两条来路都能覆盖）。
static std::string record_cos_key(const CosConfig& cfg, const json& rec) {
    std::string key = j_str(rec, "key");
    if (key.empty()) key = j_str(rec, "s3_key");
    if (key.empty()) key = j_str(rec, "staging_key");
    if (key.empty())
        key = staging_key(cfg, j_str(rec, "id"), j_str(rec, "safe_name"));
    return key;
}

bool mark_linked(const std::string& data_root, const std::string& id, std::string* err) {
    json rec = find_record(data_root, id);
    if (!rec.is_object()) {
        if (err) *err = "no such file: " + id;
        return false;
    }
    Status st = Status::Failed;
    status_from_name(j_str(rec, "status"), &st);
    if (st != Status::PendingUpload && st != Status::S3Uploaded && st != Status::Linked) {
        if (err) *err = "status not linkable: " + j_str(rec, "status");
        return false;
    }
    const CosConfig cfg = load_config();
    const std::string key = record_cos_key(cfg, rec);
    patch_and_get(data_root, id, [&](json& r) {
        r["status"] = "linked";
        r["key"] = key;
        r["updated_at"] = sa_core::now_ms();
        r["error"] = "";
    });
    return true;
}

bool materialize(const std::string& data_root, const std::string& id,
                 const std::string& dst_path, std::string* err) {
    json rec = find_record(data_root, id);
    if (!rec.is_object()) {
        if (err) *err = "no such file: " + id;
        return false;
    }
    Status st = Status::Failed;
    status_from_name(j_str(rec, "status"), &st);
    spath::create_dirs(spath::dirname(dst_path));
    std::error_code ec;
    switch (st) {
        case Status::Archived:
        case Status::Ready:
        case Status::WarmingUp: {
            const std::string local = j_str(rec, "local_path");
            if (local.empty() || !spath::is_file(local)) {
                if (err) *err = "local archive missing: " + local;
                return false;
            }
            std::filesystem::copy_file(spath::to_path(local), spath::to_path(dst_path),
                                       std::filesystem::copy_options::overwrite_existing, ec);
            if (ec) {
                if (err) *err = "copy failed: " + ec.message();
                return false;
            }
            return true;
        }
        case Status::Linked:
        case Status::S3Uploaded: {
            const CosConfig cfg = load_config();
            if (!cfg.ready()) {
                if (err) *err = "file transfer not configured";
                return false;
            }
            CosOps ops = active_ops();
            if (!ops.download) {
                if (err) *err = "no COS download op";
                return false;
            }
            return ops.download(cfg, record_cos_key(cfg, rec), dst_path, err);
        }
        default:
            if (err) *err = "status not materializable: " + j_str(rec, "status");
            return false;
    }
}

std::string register_local_artifact(const std::string& data_root, const std::string& name,
                                    const std::string& src_path, long long size) {
    const std::string id = new_id();
    const std::string safe = sanitize_name(name);
    const long long now = sa_core::now_ms();
    spath::create_dirs(local_objects_dir(data_root));
    const std::string dst = spath::join(local_objects_dir(data_root), id);
    std::error_code ec;
    std::filesystem::rename(spath::to_path(src_path), spath::to_path(dst), ec);
    if (ec) {
        std::error_code ec2;
        std::filesystem::copy_file(spath::to_path(src_path), spath::to_path(dst),
                                   std::filesystem::copy_options::overwrite_existing, ec2);
        if (ec2) return {};
        std::filesystem::remove(spath::to_path(src_path), ec);
    }

    json rec = json::object();
    rec["id"] = id;
    rec["name"] = name;
    rec["safe_name"] = safe;
    rec["size"] = size;
    rec["status"] = status_name(Status::Archived);
    rec["storage_type"] = "server";
    rec["local_path"] = dst;
    rec["created_at"] = now;
    rec["updated_at"] = now;
    rec["archived_at"] = now;
    std::lock_guard<std::mutex> lk(g_store_mu);
    json doc = read_store_unlocked(data_root);
    doc["files"].push_back(rec);
    if (!write_store_unlocked(data_root, doc)) return {};
    return id;
}

// ---------------------------------------------------------------------------
// 生命周期回收
// ---------------------------------------------------------------------------
int reclaim_expired(const std::string& data_root, long long now_unix_ms, long long ttl_ms) {
    CosConfig cfg = load_config();
    if (ttl_ms < 0) ttl_ms = cfg.reclaim_ttl_seconds > 0 ? cfg.reclaim_ttl_seconds * 1000
                                                         : 2LL * 3600 * 1000;
    long long pending_ttl_ms = env_i64("EDITOR_FILE_PENDING_TTL", 6 * 3600) * 1000;

    CosOps ops = active_ops();
    int processed = 0;

    std::lock_guard<std::mutex> lk(g_store_mu);
    json doc = read_store_unlocked(data_root);
    if (!doc.contains("files") || !doc["files"].is_array()) return 0;

    for (auto& rec : doc["files"]) {
        if (!rec.is_object()) continue;
        Status st = Status::Failed;
        if (!status_from_name(j_str(rec, "status"), &st)) continue;
        const std::string id = j_str(rec, "id");
        const std::string safe = j_str(rec, "safe_name").empty()
                                     ? sanitize_name(j_str(rec, "name"))
                                     : j_str(rec, "safe_name");

        if (st == Status::Ready) {
            long long base = j_i64(rec, "last_download_at");
            if (base <= 0) base = j_i64(rec, "warmed_at");
            if (base <= 0) base = j_i64(rec, "updated_at");
            if (base <= 0 || now_unix_ms - base < ttl_ms) continue;

            std::string key = j_str(rec, "warm_key");
            if (key.empty()) key = warm_key(cfg, id, safe);
            bool removed = true;
            std::string derr;
            if (cfg.ready() && ops.remove) removed = ops.remove(cfg, key, &derr);
            if (!removed) {
                rec["error"] = "reclaim delete failed: " + derr;
                continue;
            }
            rec["status"] = "archived";
            rec["warm_key"] = "";
            rec["warmed_at"] = 0;
            rec["last_download_at"] = 0;
            rec["updated_at"] = now_unix_ms;
            rec["error"] = "";
            ++processed;
        } else if (st == Status::PendingUpload) {
            long long created = j_i64(rec, "created_at");
            if (created <= 0 || now_unix_ms - created < pending_ttl_ms) continue;
            std::string key = j_str(rec, "staging_key");
            if (key.empty()) key = staging_key(cfg, id, safe);
            if (cfg.ready() && ops.remove) {
                std::string derr;
                ops.remove(cfg, key, &derr);  // 尽力删除；对象可能本就未上传
            }
            rec["status"] = "failed";
            rec["error"] = "upload abandoned";
            rec["updated_at"] = now_unix_ms;
            ++processed;
        }
    }

    if (processed > 0) write_store_unlocked(data_root, doc);
    return processed;
}

// ---------------------------------------------------------------------------
// 后台线程
// ---------------------------------------------------------------------------
void start_background() {
    if (g_bg_running.exchange(true)) return;
    try {
        g_bg_thread = std::thread(background_loop);
    } catch (...) {
        g_bg_running.store(false);
    }
}

void stop_background() {
    if (!g_bg_running.exchange(false)) return;
    if (g_bg_thread.joinable()) g_bg_thread.join();
}

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------
void register_file_transfer_routes(Router& r) {
    // POST /api/v1/files/upload/request — 生成 30 分钟 COS 公网 PUT 预签名 URL。
    r.post("/api/v1/files/upload/request", [](const Req& req) -> Resp {
        const json* body = nullptr;
        if (!get_body_object(req, &body) || !body->is_object())
            return err_json(400, "invalid JSON body");
        CosConfig cfg = load_config();
        if (!cfg.ready())
            return err_json(500,
                            "file transfer not configured: set EDITOR_FILE_COS_SECRET_ID, "
                            "EDITOR_FILE_COS_SECRET_KEY and EDITOR_FILE_COS_BUCKET");

        std::string name = body_str(*body, "name");
        if (name.empty()) name = body_str(*body, "filename");
        name = sanitize_name(name);
        long long size = 0;
        if (!body_i64(*body, "size", &size)) return err_json(400, "size required");
        if (size <= 0) return err_json(400, "size must be positive");
        if (cfg.max_bytes > 0 && size > cfg.max_bytes)
            return err_json(413, "file too large (max " + std::to_string(cfg.max_bytes) +
                                     " bytes)");

        const std::string id = new_id();
        const std::string safe = sanitize_name(name);
        const std::string key = staging_key(cfg, id, safe);
        const long long now = sa_core::now_ms();

        json rec = json::object();
        rec["id"] = id;
        rec["name"] = name;
        rec["safe_name"] = safe;
        rec["size"] = size;
        rec["status"] = status_name(Status::PendingUpload);
        rec["staging_key"] = key;
        rec["created_at"] = now;
        rec["updated_at"] = now;
        rec["upload_ttl_seconds"] = cfg.upload_ttl_seconds;

        {
            std::lock_guard<std::mutex> lk(g_store_mu);
            json doc = read_store_unlocked(sa::editor_root());
            doc["files"].push_back(rec);
            if (!write_store_unlocked(sa::editor_root(), doc))
                return err_json(500, "cannot persist file record");
        }

        const std::string url = presign_url(cfg, "PUT", key, cfg.upload_ttl_seconds);
        if (url.empty()) return err_json(500, "cannot sign upload url");

        json out = json::object();
        out["file_id"] = id;
        out["status"] = status_name(Status::PendingUpload);
        out["method"] = "PUT";
        out["upload_url"] = url;
        out["cos_key"] = key;
        out["expires_in"] = cfg.upload_ttl_seconds;
        return Resp::Json(200, out);
    });


// ---------------------------------------------------------------------------
// POST /api/v1/files/upload/initiate - 初始化上传请求（支持 S3 直传）
// ---------------------------------------------------------------------------
r.post(R"(/api/v1/files/upload/initiate)", [](const Req& req) -> Resp {
    const json* body = nullptr;
    if (!get_body_object(req, &body) || !body->is_object())
        return err_json(400, "invalid JSON body");
    
    CosConfig cfg = load_config();
    if (!cfg.ready())
        return err_json(500, "file transfer not configured: set EDITOR_FILE_COS_SECRET_ID, EDITOR_FILE_COS_SECRET_KEY and EDITOR_FILE_COS_BUCKET");

    std::string name = body_str(*body, "name");
    if (name.empty()) name = body_str(*body, "filename");
    if (name.empty()) return err_json(400, "name or filename required");
    
    name = sanitize_name(name);
    long long size = 0;
    if (!body_i64(*body, "size", &size)) return err_json(400, "size required");
    if (size <= 0) return err_json(400, "size must be positive");
    if (cfg.max_bytes > 0 && size > cfg.max_bytes)
        return err_json(413, "file too large (max " + std::to_string(cfg.max_bytes) + " bytes)");
    
    // 可选参数
    std::string story_id;
    bool has_story_id = str_field(*body, "story_id", story_id);
    std::string kind;
    bool has_kind = str_field(*body, "kind", kind);
    
    const std::string id = new_id();
    const std::string safe = sanitize_name(name);
    const long long now = sa_core::now_ms();
    
    // 判断是否需要 S3 直传
    bool use_s3 = cfg.s3_direct_enabled && size > cfg.s3_threshold_bytes;
    std::string mode = use_s3 ? "s3_direct" : "server_upload";
    
    // 创建记录
    json rec = json::object();
    rec["id"] = id;
    rec["name"] = name;
    rec["safe_name"] = safe;
    rec["size"] = size;
    rec["status"] = status_name(Status::PendingUpload);
    rec["storage_type"] = use_s3 ? "s3" : "server";
    rec["created_at"] = now;
    rec["updated_at"] = now;
    rec["upload_ttl_seconds"] = cfg.upload_ttl_seconds;
    rec["threshold_bytes"] = cfg.s3_threshold_bytes;
    if (has_kind && !kind.empty()) rec["kind"] = kind;
    
    // 保存记录
    {
        std::lock_guard<std::mutex> lk(g_store_mu);
        json doc = read_store_unlocked(sa::editor_root());
        doc["files"].push_back(rec);
        if (!write_store_unlocked(sa::editor_root(), doc))
            return err_json(500, "cannot persist file record");
    }
    
    json out = json::object();
    out["file_id"] = id;
    out["upload_mode"] = mode;
    out["threshold_bytes"] = cfg.s3_threshold_bytes;
    
    if (use_s3) {
        // 生成 S3 PUT 预签名 URL
        std::string key;
        if (has_story_id && !story_id.empty()) {
            key = cfg.prefix + "/stories/" + story_id + "/" + safe;
        } else {
            key = cfg.prefix + "/staging/" + id + "/" + safe;
        }
        out["s3_key"] = key;
        out["method"] = "PUT";
        out["upload_url"] = presign_url(cfg, "PUT", key, cfg.upload_ttl_seconds);
        out["expires_in"] = cfg.upload_ttl_seconds;
        rec["s3_key"] = key;
        rec["updated_at"] = now;
        {
            std::lock_guard<std::mutex> lk(g_store_mu);
            json doc = read_store_unlocked(sa::editor_root());
            for (auto& r : doc["files"]) {
                if (j_str(r, "id") == id) {
                    r = rec;
                    break;
                }
            }
            write_store_unlocked(sa::editor_root(), doc);
        }
    } else {
        // 服务器上传模式：使用原有的 staging_key
        std::string key = staging_key(cfg, id, safe);
        out["method"] = "POST";
        out["upload_url"] = "/api/v1/files/upload/request";  // 提示客户端使用旧接口或 base64
        rec["staging_key"] = key;
        rec["updated_at"] = now;
        {
            std::lock_guard<std::mutex> lk(g_store_mu);
            json doc = read_store_unlocked(sa::editor_root());
            for (auto& r : doc["files"]) {
                if (j_str(r, "id") == id) {
                    r = rec;
                    break;
                }
            }
            write_store_unlocked(sa::editor_root(), doc);
        }
    }
    
    return Resp::Json(200, std::move(out));
});

// ---------------------------------------------------------------------------
// POST /api/v1/files/upload/s3-complete - 通知 S3 上传完成
// ---------------------------------------------------------------------------
r.post("/api/v1/files/upload/s3-complete", [](const Req& req) -> Resp {
    const json* body = nullptr;
    if (!get_body_object(req, &body) || !body->is_object())
        return err_json(400, "invalid JSON body");
    
    std::string id = j_str(*body, "file_id");
    if (id.empty()) return err_json(400, "file_id required");
    
    json rec = find_record(sa::editor_root(), id);
    if (!rec.is_object()) return err_json(404, "no such file: " + id);
    
    Status st = Status::Failed;
    status_from_name(j_str(rec, "status"), &st);
    
    // 只允许 PendingUpload 状态转为 S3Uploaded
    if (st != Status::PendingUpload) {
        json public_rec = public_record(rec);
        public_rec["retry_after"] = 5;
        return Resp::Json(409, std::move(public_rec));
    }
    
    // 更新为 s3_uploaded
    patch_and_get(sa::editor_root(), id, [&](json& r) {
        r["status"] = "s3_uploaded";
        r["uploaded_at"] = sa_core::now_ms();
        r["error"] = "";
        if (body->contains("etag")) {
            r["etag"] = j_str(*body, "etag");
        }
    });
    
    json public_rec = public_record(find_record(sa::editor_root(), id));
    return Resp::Json(200, std::move(public_rec));
});
    // POST /api/v1/files/upload/complete — 入后台队列，内网拉回本地落盘。
    r.post("/api/v1/files/upload/complete", [](const Req& req) -> Resp {
        const json* body = nullptr;
        if (!get_body_object(req, &body) || !body->is_object())
            return err_json(400, "invalid JSON body");
        const std::string id = body_str(*body, "file_id");
        if (id.empty()) return err_json(400, "file_id required");

        json rec = find_record(sa::editor_root(), id);
        if (!rec.is_object()) return err_json(404, "no such file: " + id);

        Status st = Status::Failed;
        status_from_name(j_str(rec, "status"), &st);
        if (st == Status::Archiving || st == Status::Archived || st == Status::Ready) {
            json out = public_record(rec);
            out["retry_after"] = 5;
            return Resp::Json(202, out);  // 幂等
        }
        if (st == Status::Failed && j_str(rec, "error") == "upload abandoned")
            return err_json(409, "upload expired; request a new upload url");

        patch_and_get(sa::editor_root(), id, [](json& r) {
            r["status"] = "archiving";
            r["uploaded_at"] = sa_core::now_ms();
            r["error"] = "";
        });
        enqueue_archive(sa::editor_root(), id);
        return Resp::Json(202, json{{"file_id", id},
                                    {"status", "archiving"},
                                    {"retry_after", 5}});
    });

    // GET /api/v1/files/:id/download — 命中本地则预热；在 COS 则给直链。
    r.get(R"(/api/v1/files/(?P<id>[0-9a-fA-F]{8,64})/download)", [](const Req& req) -> Resp {
        const std::string id = req.params.at("id");
        const std::string root = sa::editor_root();
        json rec = find_record(root, id);
        if (!rec.is_object()) return err_json(404, "no such file: " + id);

        Status st = Status::Failed;
        status_from_name(j_str(rec, "status"), &st);
        CosConfig cfg = load_config();

        switch (st) {
            case Status::PendingUpload:
                return Resp::Json(409, json{{"file_id", id},
                                            {"status", "pending_upload"},
                                            {"error", "upload not completed"}});
            case Status::Failed:
                return Resp::Json(500, json{{"file_id", id},
                                            {"status", "failed"},
                                            {"error", j_str(rec, "error")}});
            case Status::Archiving:
                return Resp::Json(202, json{{"file_id", id},
                                            {"status", "archiving"},
                                            {"retry_after", 5}});
            case Status::WarmingUp:
                return Resp::Json(202, json{{"file_id", id},
                                            {"status", "warming_up"},
                                            {"retry_after", 3}});
            case Status::Archived: {
                if (!cfg.ready())
                    return err_json(500, "file transfer not configured");
                patch_and_get(root, id, [](json& r) {
                    r["status"] = "warming_up";
                    r["error"] = "";
                });
                enqueue_warm(root, id);
                return Resp::Json(202, json{{"file_id", id},
                                            {"status", "warming_up"},
                                            {"retry_after", 3}});
            }
            case Status::S3Uploaded:
            case Status::Linked: {
                // 直传/引用文件：字节在 COS，直接回 GET 预签名（或 CDN）直链，
                // 不落盘不预热；linked 记录永不被 pending 清理器回收。
                std::string key = record_cos_key(cfg, rec);
                if (key.empty()) return err_json(500, "no object key in record");
                const std::string url = download_url(cfg, key);
                if (url.empty()) return err_json(500, "cannot sign download url");
                long long expires = 0;
                if (cfg.cdn_domain.empty())
                    expires = cfg.download_ttl_seconds;
                else if (!cfg.cdn_auth_type.empty() && !cfg.cdn_auth_key.empty())
                    expires = cfg.cdn_auth_ttl_seconds;
                return Resp::Json(200, json{{"file_id", id},
                                            {"status", j_str(rec, "status")},
                                            {"url", url},
                                            {"method", "GET"},
                                            {"expires_in", expires}});
            }
            case Status::Ready: {
                std::string key = j_str(rec, "warm_key");
                if (key.empty()) key = warm_key(cfg, id, j_str(rec, "safe_name"));
                const std::string url = download_url(cfg, key);
                if (url.empty()) return err_json(500, "cannot sign download url");
                patch_and_get(root, id, [](json& r) {
                    r["last_download_at"] = sa_core::now_ms();
                });
                long long expires = 0;
                if (cfg.cdn_domain.empty())
                    expires = cfg.download_ttl_seconds;
                else if (!cfg.cdn_auth_type.empty() && !cfg.cdn_auth_key.empty())
                    expires = cfg.cdn_auth_ttl_seconds;
                return Resp::Json(200, json{{"file_id", id},
                                            {"status", "ready"},
                                            {"url", url},
                                            {"method", "GET"},
                                            {"expires_in", expires}});
            }
        }
        return err_json(500, "unknown file state");
    });

    // GET /api/v1/files/:id — 状态查询（供客户端轮询 retry_after 用）。
    r.get(R"(/api/v1/files/(?P<id>[0-9a-fA-F]{8,64}))", [](const Req& req) -> Resp {
        json rec = find_record(sa::editor_root(), req.params.at("id"));
        if (!rec.is_object()) return err_json(404, "no such file: " + req.params.at("id"));
        return Resp::Json(200, public_record(rec));
    });
}

}  // namespace file_transfer
}  // namespace sa
