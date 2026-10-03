// server/services/file_transfer.h — 自有私密大文件流转（自托管服务器端）。
//
// 模块 A：直传 ➔ 内网落盘 ➔ 按需预热
//
//   1) 客户端直传：POST /api/v1/files/upload/request 用环境变量密钥签发 30
//      分钟有效的 COS 公网域名 PUT 预签名 URL，客户端 HTTP PUT 直传暂存区。
//   2) 内网极速落盘：POST /api/v1/files/upload/complete 入后台队列，Worker
//      走内网 Endpoint 拉回本地大容量硬盘，校验后删除 COS 临时原文件。
//   3) 冷数据预热：GET /api/v1/files/:id/download 命中本地时触发后台 Worker
//      经内网 Endpoint 推回 COS，接口先回 warming_up；在 COS 时直接给
//      CDN / 预签名公网直链。
//   4) 生命周期：定时回收 COS 上超过 2 小时未被下载的临时预热对象。
//
// 业务状态机（record["status"]）：
//
//   pending_upload ──complete──▶ archiving ──worker ok──▶ archived
//                                                        │  │
//                                     (download 触发预热) │  │ worker 失败回退
//                                                        ▼  │
//                                                    warming_up ──worker ok──▶ ready
//                                                                              │
//                       reclaim（>2h 未下载，删 COS 预热对象）◀───────────────┘
//
// 签名与内网读写复用既有 cloud_sync 的 AWS SigV4 实现（不引入 cos-cpp-sdk）。
// 真实传输走 sa_core::http；测试通过 set_cos_ops_for_test() 注入内存 seam。
#pragma once

#include <functional>
#include <string>

#include "server/httpd.h"

namespace sa {
namespace file_transfer {

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------
enum class Status { PendingUpload, Archiving, Archived, WarmingUp, Ready, Failed, S3Uploaded, Linked };

const char* status_name(Status s);
bool status_from_name(const std::string& name, Status* out);

// ---------------------------------------------------------------------------
// COS 配置：全部来自环境变量（自托管服务器可注入密钥，不落盘明文）。
//
//   EDITOR_FILE_COS_SECRET_ID / EDITOR_COS_SECRET_ID / COS_SECRET_ID
//   EDITOR_FILE_COS_SECRET_KEY / EDITOR_COS_SECRET_KEY / COS_SECRET_KEY
//   EDITOR_FILE_COS_SESSION_TOKEN            （可选，临时密钥）
//   EDITOR_FILE_COS_BUCKET                   必填
//   EDITOR_FILE_COS_REGION                    默认 ap-guangzhou
//   EDITOR_FILE_COS_PUBLIC_ENDPOINT           默认 https://cos.<region>.myqcloud.com
//   EDITOR_FILE_COS_INTERNAL_ENDPOINT         默认同公网；自托管填内网域名/IP
//   EDITOR_FILE_COS_CDN_DOMAIN                可选，下载直链优先用它
//   EDITOR_FILE_COS_CDN_AUTH_TYPE             可选，CDN URL 鉴权类型 A/B/C/D
//   EDITOR_FILE_COS_CDN_AUTH_KEY              可选，CDN 鉴权密钥 pkey
//   EDITOR_FILE_COS_CDN_AUTH_PARAM            签名参数名，默认 sign
//   EDITOR_FILE_COS_CDN_AUTH_TS_PARAM         TypeD 时间戳参数名，默认 t
//   EDITOR_FILE_COS_CDN_AUTH_TTL              鉴权有效期秒数（仅回报 expires_in）
//   EDITOR_FILE_COS_PREFIX                    默认 editor-files
//   EDITOR_FILE_LOCAL_ROOT                    本地落盘根目录（大容量盘）
//   EDITOR_FILE_MAX_BYTES                     单文件上限（默认 100 GiB）
//   EDITOR_FILE_UPLOAD_TTL / DOWNLOAD_TTL     预签名有效期秒数
//   EDITOR_FILE_RECLAIM_TTL                   预热对象回收阈值（默认 7200s）
//   EDITOR_FILE_RECLAIM_INTERVAL              后台回收扫描间隔（默认 60s）
//   EDITOR_FILE_S3_ENABLED                    是否启用 S3 直传开关（默认 false）
//   EDITOR_FILE_S3_THRESHOLD_BYTES            S3 直传阈值（默认 50 MiB）
// ---------------------------------------------------------------------------
struct CosConfig {
    std::string secret_id;
    std::string secret_key;
    std::string session_token;
    std::string bucket;
    std::string region = "ap-guangzhou";
    std::string service = "cos";
    std::string public_endpoint;    // 客户端直传 / 下载直链
    std::string internal_endpoint;  // Worker 落盘 / 预热（内网）
    std::string cdn_domain;         // 可选
    // CDN URL 鉴权（腾讯云 CDN TypeA/B/C/D）：私有 COS + CDN 加速时，由后端按
    // CDN 规则生成带签名的 CDN 直链。type 为空 = 不签名（要求 CDN 侧对该资源
    // 公开读）。鉴权密钥 pkey 与有效期在 CDN 控制台配置；URL 本身不含时长，
    // 只有 TypeA/B/C 把 timestamp 编进签名串，TypeD 另带时间戳参数。
    std::string cdn_auth_type;             // "A"/"B"/"C"/"D"（大小写不敏感）
    std::string cdn_auth_key;              // pkey（鉴权主密钥）
    std::string cdn_auth_param = "sign";   // 签名参数名（TypeD 可自定义）
    std::string cdn_auth_ts_param = "t";   // TypeD 时间戳参数名
    long long cdn_auth_ttl_seconds = 0;    // 仅回报 expires_in；0 = 未知
    std::string prefix = "editor-files";
    long long upload_ttl_seconds = 1800;    // 30 分钟
    long long download_ttl_seconds = 600;
    long long max_bytes = 100LL * 1024 * 1024 * 1024;
    long long reclaim_ttl_seconds = 2 * 3600;  // 2 小时
    long long reclaim_interval_seconds = 60;
    bool s3_direct_enabled = false;
    long long s3_threshold_bytes = 50LL * 1024 * 1024;  // 50 MiB

    bool ready() const;
};
CosConfig load_config();

// ---------------------------------------------------------------------------
// 路径 / 对象键
// ---------------------------------------------------------------------------
std::string store_dir(const std::string& data_root);
std::string local_objects_dir(const std::string& data_root);
std::string sanitize_name(const std::string& name);
std::string staging_key(const CosConfig& cfg, const std::string& id, const std::string& safe_name);
std::string warm_key(const CosConfig& cfg, const std::string& id, const std::string& safe_name);

// ---------------------------------------------------------------------------
// SigV4 预签名（公网 PUT / GET）。now_unix==0 时取当前时间；暴露给测试。
// ---------------------------------------------------------------------------
std::string presign_url(const CosConfig& cfg, const std::string& method,
                        const std::string& key, long long expires_seconds,
                        long long now_unix = 0);

// 下载直链：配置了 cdn_domain 时走 CDN（按需附腾讯云 CDN URL 鉴权签名，
// 私有 COS + CDN 加速场景），否则回退 COS 预签名 GET。now_unix=0 取当前时间。
std::string download_url(const CosConfig& cfg, const std::string& key,
                         long long now_unix = 0);

// ---------------------------------------------------------------------------
// 内网传输（真实实现走 sa_core::http；测试经 CosOps 注入）
// ---------------------------------------------------------------------------
struct CosOps {
    // download(cfg, key, local_path, err)
    std::function<bool(const CosConfig&, const std::string&, const std::string&, std::string*)> download;
    // upload(cfg, local_path, key, err)
    std::function<bool(const CosConfig&, const std::string&, const std::string&, std::string*)> upload;
    // remove(cfg, key, err)
    std::function<bool(const CosConfig&, const std::string&, std::string*)> remove;
};

bool default_download(const CosConfig& cfg, const std::string& key,
                      const std::string& local_path, std::string* err);
bool default_upload(const CosConfig& cfg, const std::string& local_path,
                    const std::string& key, std::string* err);
bool default_remove(const CosConfig& cfg, const std::string& key, std::string* err);

CosOps make_default_ops();
void set_cos_ops_for_test(const CosOps& ops);
void reset_cos_ops_for_test();

// ---------------------------------------------------------------------------
// 记录存储（<data_root>/_cache/file_transfer/files.json，进程内互斥 + 原子写）
// ---------------------------------------------------------------------------
json read_store(const std::string& data_root);
json find_record(const std::string& data_root, const std::string& id);
json public_record(const json& record);

// ---------------------------------------------------------------------------
// 同步归档 / 预热（路由经 sa::jobs 后台调用；测试直接调用）
// ---------------------------------------------------------------------------
bool archive_now(const std::string& data_root, const std::string& id, std::string* err);
bool warm_now(const std::string& data_root, const std::string& id, std::string* err);

// ---------------------------------------------------------------------------
// 大资源引用与导出产物（模组线集成）：
//   mark_linked   —— 浏览器直传完成后把暂存记录钉成持久引用（status=linked）：
//                    字节永远留在 COS，不再被 pending 上传清理器回收，也不落盘。
//                    对象键固化进 rec["key"]（s3_key / staging_key / 重算）。
//   materialize   —— 把记录字节取回到本机路径：linked/s3_uploaded 走内网 GET，
//                    archived/ready 直接拷贝 local_path。导出拼接 zip 时用。
//   register_local_artifact —— 把服务端自产的成品文件（如模组导出 zip）登记为
//                    archived 记录（文件移入 objects/<id>），返回 id；客户端拿
//                    GET /api/v1/files/:id/download 触发预热换下载直链。
// ---------------------------------------------------------------------------
bool mark_linked(const std::string& data_root, const std::string& id, std::string* err);
bool materialize(const std::string& data_root, const std::string& id,
                 const std::string& dst_path, std::string* err);
std::string register_local_artifact(const std::string& data_root, const std::string& name,
                                    const std::string& src_path, long long size);

// 生命周期回收：删除 now_unix_ms 起超过 ttl_ms 未被下载的 ready 预热对象。
// 返回处理的条数。
int reclaim_expired(const std::string& data_root, long long now_unix_ms,
                    long long ttl_ms = -1);

// ---------------------------------------------------------------------------
// 后台调度线程（run_server 启动；测试直接调 reclaim_expired / *_now）
// ---------------------------------------------------------------------------
void start_background();
void stop_background();

// ---------------------------------------------------------------------------
// 路由：/api/v1/files/*
// ---------------------------------------------------------------------------
void register_file_transfer_routes(Router& r);

}  // namespace file_transfer
}  // namespace sa
