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
enum class Status { PendingUpload, Archiving, Archived, WarmingUp, Ready, Failed };

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
//   EDITOR_FILE_COS_PREFIX                    默认 editor-files
//   EDITOR_FILE_LOCAL_ROOT                    本地落盘根目录（大容量盘）
//   EDITOR_FILE_MAX_BYTES                     单文件上限（默认 100 GiB）
//   EDITOR_FILE_UPLOAD_TTL / DOWNLOAD_TTL     预签名有效期秒数
//   EDITOR_FILE_RECLAIM_TTL                   预热对象回收阈值（默认 7200s）
//   EDITOR_FILE_RECLAIM_INTERVAL              后台回收扫描间隔（默认 60s）
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
    std::string prefix = "editor-files";
    long long upload_ttl_seconds = 1800;    // 30 分钟
    long long download_ttl_seconds = 600;
    long long max_bytes = 100LL * 1024 * 1024 * 1024;
    long long reclaim_ttl_seconds = 2 * 3600;  // 2 小时
    long long reclaim_interval_seconds = 60;

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
