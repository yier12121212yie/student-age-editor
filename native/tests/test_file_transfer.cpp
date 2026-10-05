// tests/test_file_transfer.cpp — 模块 A（自有私密大文件流转）单元/集成测试。
//
// 不依赖真实 COS：通过 set_cos_ops_for_test() 注入内存对象存储，覆盖
//   预签名 URL 结构、完整状态机（直传→落盘→预热→就绪→回收）、大小校验、
//   生命周期阈值、CDN 直链、文件名清洗与配置读取。
#include <catch_amalgamated.hpp>

#include <atomic>
#include <cctype>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <string>

#include "sa_core/atomic_io.h"
#include "sa_core/paths.h"
#include "sa_core/util.h"
#include "server/httpd.h"
#include "server/services/file_transfer.h"

namespace fs = std::filesystem;
using sa::json;

namespace {

std::atomic<int> g_tmp_counter{0};

struct TempDir {
    fs::path p;
    TempDir() {
        p = fs::temp_directory_path() /
            ("ft_test_" + std::to_string(sa_core::now_ms()) + "_" +
             std::to_string(g_tmp_counter.fetch_add(1)));
        std::error_code ec;
        fs::remove_all(p, ec);
        fs::create_directories(p);
    }
    ~TempDir() {
        std::error_code ec;
        fs::remove_all(p, ec);
    }
    std::string str() const { return sa_core::paths::path_to_utf8(p); }
};

struct EnvGuard {
    std::string key;
    std::string saved;
    bool had = false;
    EnvGuard(std::string k, std::string v) : key(std::move(k)) {
        saved = sa_core::paths::getenv_utf8(key.c_str());
        had = !saved.empty();
        sa_core::paths::setenv_utf8(key.c_str(), v, true);
    }
    ~EnvGuard() { sa_core::paths::setenv_utf8(key.c_str(), had ? saved : "", true); }
    EnvGuard(const EnvGuard&) = delete;
    EnvGuard& operator=(const EnvGuard&) = delete;
};

// 测试环境：临时 data root + COS 密钥/桶/区域/公网 endpoint（可带 CDN）。
struct CosEnv {
    TempDir td;
    EnvGuard data_root;
    EnvGuard sid;
    EnvGuard skey;
    EnvGuard bucket;
    EnvGuard region;
    EnvGuard pub;
    EnvGuard internal;
    EnvGuard cdn;

    explicit CosEnv(const std::string& cdn_domain = "")
        : data_root("EDITOR_DATA_ROOT", td.str()),
          sid("EDITOR_FILE_COS_SECRET_ID", "AKIDTEST"),
          skey("EDITOR_FILE_COS_SECRET_KEY", "SECRETKEY"),
          bucket("EDITOR_FILE_COS_BUCKET", "testbucket-1250000000"),
          region("EDITOR_FILE_COS_REGION", "ap-guangzhou"),
          pub("EDITOR_FILE_COS_PUBLIC_ENDPOINT", "https://cos.ap-guangzhou.myqcloud.com"),
          internal("EDITOR_FILE_COS_INTERNAL_ENDPOINT",
                   "https://cos-internal.ap-guangzhou.myqcloud.com"),
          cdn("EDITOR_FILE_COS_CDN_DOMAIN", cdn_domain) {}

    std::string root() const { return td.str(); }
};

// 内存 COS：key -> bytes。
struct MemCos {
    std::mutex mu;
    std::map<std::string, std::string> objects;
};

std::shared_ptr<MemCos> g_mem;

sa::file_transfer::CosOps mem_ops(const std::shared_ptr<MemCos>& m) {
    using namespace sa::file_transfer;
    CosOps ops;
    ops.download = [m](const CosConfig&, const std::string& key, const std::string& local,
                       std::string* err) -> bool {
        std::lock_guard<std::mutex> lk(m->mu);
        auto it = m->objects.find(key);
        if (it == m->objects.end()) {
            if (err) *err = "404 " + key;
            return false;
        }
        sa_core::paths::create_dirs(sa_core::paths::dirname(local));
        if (!sa_core::paths::write_bytes_simple(local, it->second)) {
            if (err) *err = "write failed";
            return false;
        }
        return true;
    };
    ops.upload = [m](const CosConfig&, const std::string& local, const std::string& key,
                     std::string* err) -> bool {
        auto data = sa_core::paths::read_bytes(local);
        if (!data) {
            if (err) *err = "read failed";
            return false;
        }
        std::lock_guard<std::mutex> lk(m->mu);
        m->objects[key] = *data;
        return true;
    };
    ops.remove = [m](const CosConfig&, const std::string& key, std::string*) -> bool {
        std::lock_guard<std::mutex> lk(m->mu);
        m->objects.erase(key);
        return true;
    };
    return ops;
}

bool is_hex64(const std::string& s) {
    if (s.size() != 64) return false;
    for (char c : s)
        if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
    return true;
}

std::string signature_of(const std::string& url) {
    auto p = url.find("X-Amz-Signature=");
    return p == std::string::npos ? std::string() : url.substr(p + 16);
}

sa::Router make_router() {
    sa::Router r;
    sa::file_transfer::register_file_transfer_routes(r);
    return r;
}

}  // namespace

TEST_CASE("file_transfer: presign PUT url is well-formed and time-sensitive",
          "[file_transfer]") {
    using namespace sa::file_transfer;
    CosConfig cfg;
    cfg.secret_id = "AKIDTEST";
    cfg.secret_key = "SECRETKEY";
    cfg.bucket = "testbucket-1250000000";
    cfg.region = "ap-guangzhou";
    cfg.public_endpoint = "https://cos.ap-guangzhou.myqcloud.com";

    const std::string key = "editor-files/staging/abc/file.bin";
    const std::string url = presign_url(cfg, "PUT", key, 1800, 1700000000);
    REQUIRE(url.rfind("https://cos.ap-guangzhou.myqcloud.com/testbucket-1250000000/" + key +
                          "?",
                      0) == 0);
    REQUIRE(url.find("X-Amz-Algorithm=AWS4-HMAC-SHA256") != std::string::npos);
    REQUIRE(url.find("X-Amz-Expires=1800") != std::string::npos);
    REQUIRE(url.find("X-Amz-SignedHeaders=host") != std::string::npos);
    REQUIRE(url.find("X-Amz-Credential=AKIDTEST%2F20231114%2Fap-guangzhou%2Fcos%2Faws4_request") !=
            std::string::npos);
    REQUIRE(is_hex64(signature_of(url)));

    // 同名同时刻 -> 签名确定；过期时间变化 -> 签名变化。
    const std::string again = presign_url(cfg, "PUT", key, 1800, 1700000000);
    REQUIRE(url == again);
    const std::string other_ttl = presign_url(cfg, "PUT", key, 900, 1700000000);
    REQUIRE(signature_of(other_ttl) != signature_of(url));
}

TEST_CASE("file_transfer: sanitize_name strips paths and rejects dot-only",
          "[file_transfer]") {
    using namespace sa::file_transfer;
    REQUIRE(sanitize_name("../../etc/passwd") == "passwd");
    REQUIRE(sanitize_name("a b*c.bin") == "a_b_c.bin");
    REQUIRE(sanitize_name("...") == "file");
    REQUIRE(sanitize_name("") == "file");
    REQUIRE(sanitize_name("normal-1.2_3.bin") == "normal-1.2_3.bin");
}

TEST_CASE("file_transfer: load_config reads env and defaults internal endpoint to public",
          "[file_transfer]") {
    CosEnv env;
    // CosEnv sets an explicit internal endpoint; drop it for this case.
    sa_core::paths::setenv_utf8("EDITOR_FILE_COS_INTERNAL_ENDPOINT", "", true);
    sa::file_transfer::CosConfig cfg = sa::file_transfer::load_config();
    REQUIRE(cfg.ready());
    REQUIRE(cfg.bucket == "testbucket-1250000000");
    REQUIRE(cfg.region == "ap-guangzhou");
    REQUIRE(cfg.internal_endpoint == cfg.public_endpoint);
    REQUIRE(cfg.upload_ttl_seconds == 1800);
}

TEST_CASE("file_transfer: end-to-end state machine over routes and workers",
          "[file_transfer]") {
    using namespace sa::file_transfer;
    CosEnv env;
    auto mem = std::make_shared<MemCos>();
    g_mem = mem;
    set_cos_ops_for_test(mem_ops(mem));
    struct Reset {
        ~Reset() { reset_cos_ops_for_test(); }
    } reset;
    const std::string root = env.root();

    sa::Router r = make_router();

    // 1) 客户端申请直传：拿到 30 分钟 PUT 预签名 URL。
    const std::string payload = "hello world";  // 11 bytes
    auto resp = sa::sa_test::dispatch_in_proc(
        r, "POST", "/api/v1/files/upload/request", {},
        json{{"name", "大文件.bin"}, {"size", static_cast<long long>(payload.size())}});
    REQUIRE(resp.status == 200);
    const std::string id = resp.json_payload.value("file_id", std::string());
    const std::string key = resp.json_payload.value("cos_key", std::string());
    REQUIRE(id.size() == 32);
    REQUIRE(key.find("/staging/") != std::string::npos);
    REQUIRE(resp.json_payload.value("method", std::string()) == "PUT");
    REQUIRE(signature_of(resp.json_payload.value("upload_url", std::string())).size() == 64);
    REQUIRE(find_record(root, id).value("status", std::string()) == "pending_upload");

    // 2) 客户端 HTTP PUT 直传暂存区（内存 mock）。
    mem->objects[key] = payload;

    // 3) 通知完成 -> 入队 archiving。
    auto done = sa::sa_test::dispatch_in_proc(r, "POST", "/api/v1/files/upload/complete", {},
                                          json{{"file_id", id}});
    REQUIRE(done.status == 202);
    REQUIRE(find_record(root, id).value("status", std::string()) == "archiving");

    // 4) Worker 内网落盘 + 校验 + 删除 COS 临时原文件。
    std::string err;
    REQUIRE(archive_now(root, id, &err));
    json rec = find_record(root, id);
    REQUIRE(rec.value("status", std::string()) == "archived");
    REQUIRE(rec.value("staging_deleted", false) == true);
    {
        std::lock_guard<std::mutex> lk(mem->mu);
        REQUIRE(mem->objects.count(key) == 0);  // 暂存对象已释放
    }
    const std::string local = rec.value("local_path", std::string());
    auto local_bytes = sa_core::paths::read_bytes(local);
    REQUIRE(local_bytes.has_value());
    REQUIRE(*local_bytes == payload);

    // 5) 冷数据下载：本地命中 -> 触发预热，先回 warming_up。
    auto dl = sa::sa_test::dispatch_in_proc(r, "GET", "/api/v1/files/" + id + "/download", {},
                                        json());
    REQUIRE(dl.status == 202);
    REQUIRE(dl.json_payload.value("status", std::string()) == "warming_up");
    REQUIRE(dl.json_payload.value("retry_after", 0) > 0);

    // 6) Worker 内网推回 COS -> ready。
    REQUIRE(warm_now(root, id, &err));
    const std::string warm = find_record(root, id).value("warm_key", std::string());
    {
        std::lock_guard<std::mutex> lk(mem->mu);
        REQUIRE(mem->objects.count(warm) == 1);
    }

    // 7) 重试拿到高速下载直链（预签名 GET）。
    auto dl2 = sa::sa_test::dispatch_in_proc(r, "GET", "/api/v1/files/" + id + "/download", {},
                                         json());
    REQUIRE(dl2.status == 200);
    REQUIRE(dl2.json_payload.value("status", std::string()) == "ready");
    const std::string url = dl2.json_payload.value("url", std::string());
    REQUIRE(url.find("X-Amz-Signature=") != std::string::npos);

    // 8) 生命周期：超过 2 小时未下载 -> 删除预热对象，回到 archived。
    const int reclaimed =
        reclaim_expired(root, sa_core::now_ms() + 3LL * 3600 * 1000, -1);
    REQUIRE(reclaimed >= 1);
    REQUIRE(find_record(root, id).value("status", std::string()) == "archived");
    {
        std::lock_guard<std::mutex> lk(mem->mu);
        REQUIRE(mem->objects.count(warm) == 0);
    }

    // 9) 回收后再下载 -> 重新预热。
    auto dl3 = sa::sa_test::dispatch_in_proc(r, "GET", "/api/v1/files/" + id + "/download", {},
                                         json());
    REQUIRE(dl3.status == 202);
    REQUIRE(dl3.json_payload.value("status", std::string()) == "warming_up");
}

TEST_CASE("file_transfer: archive size mismatch fails and keeps staging",
          "[file_transfer]") {
    using namespace sa::file_transfer;
    CosEnv env;
    auto mem = std::make_shared<MemCos>();
    g_mem = mem;
    set_cos_ops_for_test(mem_ops(mem));
    struct Reset {
        ~Reset() { reset_cos_ops_for_test(); }
    } reset;
    const std::string root = env.root();

    sa::Router r = make_router();
    auto resp = sa::sa_test::dispatch_in_proc(
        r, "POST", "/api/v1/files/upload/request", {},
        json{{"name", "x.bin"}, {"size", 100}});
    REQUIRE(resp.status == 200);
    const std::string id = resp.json_payload.value("file_id", std::string());
    const std::string key = resp.json_payload.value("cos_key", std::string());
    mem->objects[key] = "short";  // 实际只有 5 字节

    std::string err;
    REQUIRE_FALSE(archive_now(root, id, &err));
    REQUIRE(find_record(root, id).value("status", std::string()) == "failed");
    {
        std::lock_guard<std::mutex> lk(mem->mu);
        REQUIRE(mem->objects.count(key) == 1);  // 暂存保留以便重试
    }
}

TEST_CASE("file_transfer: reclaim respects the TTL boundary", "[file_transfer]") {
    using namespace sa::file_transfer;
    CosEnv env;
    auto mem = std::make_shared<MemCos>();
    g_mem = mem;
    set_cos_ops_for_test(mem_ops(mem));
    struct Reset {
        ~Reset() { reset_cos_ops_for_test(); }
    } reset;
    const std::string root = env.root();

    const std::string id = "aabbccddeeff00112233445566778899";
    const std::string warm = "editor-files/warm/" + id + "/x.bin";
    mem->objects[warm] = "data";

    json doc = json::object();
    json rec = json::object();
    rec["id"] = id;
    rec["name"] = "x.bin";
    rec["safe_name"] = "x.bin";
    rec["size"] = 4;
    rec["status"] = "ready";
    rec["warm_key"] = warm;
    rec["created_at"] = 1000;
    rec["updated_at"] = 1000;
    rec["warmed_at"] = 1000;
    rec["last_download_at"] = 1000;
    doc["files"] = json::array({rec});
    const std::string sdir = sa::file_transfer::store_dir(root);
    sa_core::paths::create_dirs(sdir);
    sa_core::write_text_atomic(sdir + "/files.json", doc.dump(2));

    // ttl = 1000ms：差 999ms 不回收，差 1000ms 回收。
    REQUIRE(reclaim_expired(root, 1999, 1000) == 0);
    {
        std::lock_guard<std::mutex> lk(mem->mu);
        REQUIRE(mem->objects.count(warm) == 1);
    }
    REQUIRE(reclaim_expired(root, 2000, 1000) == 1);
    {
        std::lock_guard<std::mutex> lk(mem->mu);
        REQUIRE(mem->objects.count(warm) == 0);
    }
    REQUIRE(find_record(root, id).value("status", std::string()) == "archived");
}

TEST_CASE("file_transfer: CDN domain wins over presigned GET for downloads",
          "[file_transfer]") {
    using namespace sa::file_transfer;
    CosEnv env("https://cdn.example.com");
    auto mem = std::make_shared<MemCos>();
    set_cos_ops_for_test(mem_ops(mem));
    struct Reset {
        ~Reset() { reset_cos_ops_for_test(); }
    } reset;
    const std::string root = env.root();

    sa::Router r = make_router();
    auto resp = sa::sa_test::dispatch_in_proc(
        r, "POST", "/api/v1/files/upload/request", {},
        json{{"name", "photo.jpg"}, {"size", 3}});
    const std::string id = resp.json_payload.value("file_id", std::string());
    const std::string key = resp.json_payload.value("cos_key", std::string());
    mem->objects[key] = "abc";
    (void)sa::sa_test::dispatch_in_proc(r, "POST", "/api/v1/files/upload/complete", {},
                                    json{{"file_id", id}});
    std::string err;
    REQUIRE(archive_now(root, id, &err));
    REQUIRE(warm_now(root, id, &err));

    auto dl = sa::sa_test::dispatch_in_proc(r, "GET", "/api/v1/files/" + id + "/download", {},
                                        json());
    REQUIRE(dl.status == 200);
    REQUIRE(dl.json_payload.value("url", std::string())
                .rfind("https://cdn.example.com/", 0) == 0);
}

TEST_CASE("file_transfer: virtual-hosted COS endpoint omits bucket from path",
          "[file_transfer]") {
    using namespace sa::file_transfer;
    CosConfig cfg;
    cfg.secret_id = "AKIDTEST";
    cfg.secret_key = "SECRETKEY";
    cfg.bucket = "testbucket-1250000000";
    cfg.region = "ap-guangzhou";
    cfg.public_endpoint = "https://testbucket-1250000000.cos.ap-guangzhou.myqcloud.com";

    const std::string key = "editor-files/staging/abc/file.bin";
    const std::string url = presign_url(cfg, "PUT", key, 1800, 1700000000);
    REQUIRE(url.rfind("https://testbucket-1250000000.cos.ap-guangzhou.myqcloud.com/" + key +
                          "?",
                      0) == 0);
    // 虚拟主机风格下不得再出现 /<bucket>/ 路径前缀（PathStyleDomainForbidden 根因）。
    REQUIRE(url.find("/testbucket-1250000000/editor-files") == std::string::npos);
}

TEST_CASE("file_transfer: CDN TypeD URL auth signs download link", "[file_transfer]") {
    using namespace sa::file_transfer;
    CosConfig cfg;
    cfg.cdn_domain = "https://cos.editor.liveint.cloud";
    cfg.cdn_auth_type = "D";
    cfg.cdn_auth_key = "0123456789abcdef0123456789abcdef";

    const std::string key = "editor-files/warm/abc/file.bin";
    const std::string url = download_url(cfg, key, 1700000000);
    // md5(pkey + /path + 1700000000)，见 CDN TypeD 规则。
    REQUIRE(url == "https://cos.editor.liveint.cloud/editor-files/warm/abc/file.bin"
                    "?sign=e7f37383dd4643f8070887238ab1acb5&t=1700000000");
}

TEST_CASE("file_transfer: CDN TypeC URL auth embeds hex timestamp in sign",
          "[file_transfer]") {
    using namespace sa::file_transfer;
    CosConfig cfg;
    cfg.cdn_domain = "https://cdn.example.com";
    cfg.cdn_auth_type = "C";
    cfg.cdn_auth_key = "0123456789abcdef0123456789abcdef";

    const std::string key = "editor-files/warm/abc/file.bin";
    const std::string url = download_url(cfg, key, 1700000000);
    REQUIRE(url.rfind("https://cdn.example.com/editor-files/warm/abc/file.bin?sign=6553f100-",
                      0) == 0);
    REQUIRE(url.find("-0-deb7af458256552c2ccc552784637839") != std::string::npos);
}

TEST_CASE("file_transfer: CDN without auth key stays unsigned", "[file_transfer]") {
    using namespace sa::file_transfer;
    CosConfig cfg;
    cfg.cdn_domain = "https://cdn.example.com/";
    const std::string key = "editor-files/warm/abc/file.bin";
    REQUIRE(download_url(cfg, key, 1700000000) ==
            "https://cdn.example.com/editor-files/warm/abc/file.bin");
}

TEST_CASE("file_transfer: browser direct transfer configures bucket CORS once",
          "[file_transfer]") {
    using namespace sa::file_transfer;
    CosConfig cfg;
    cfg.secret_id = "AKIDTEST";
    cfg.secret_key = "SECRETKEY";
    cfg.bucket = "testbucket-1250000000";
    cfg.region = "ap-guangzhou";
    cfg.public_endpoint = "https://cos.ap-guangzhou.myqcloud.com";
    cfg.cors_origins = "https://online.editor.liveint.cloud";

    std::atomic<int> calls{0};
    std::string seen_origins;
    CosOps ops;
    ops.put_cors = [&](const CosConfig&, const std::string& origins, std::string*) -> bool {
        seen_origins = origins;
        ++calls;
        return true;
    };
    set_cos_ops_for_test(ops);
    struct Reset {
        ~Reset() { reset_cos_ops_for_test(); }
    } reset;
    reset_bucket_cors_once_for_test();

    std::string err;
    REQUIRE(put_bucket_cors(cfg, &err));
    REQUIRE(seen_origins == "https://online.editor.liveint.cloud");

    // 一次性：再次触发不再调用（进程内只配一次，避免每个请求都写桶）。
    ensure_bucket_cors_once(cfg);
    ensure_bucket_cors_once(cfg);
    REQUIRE(calls.load() == 2);  // put_bucket_cors 显式一次 + ensure 首次一次

    // 关闭开关时不触发。
    reset_bucket_cors_once_for_test();
    CosConfig off = cfg;
    off.cors_enabled = false;
    ensure_bucket_cors_once(off);
    REQUIRE(calls.load() == 2);
}
