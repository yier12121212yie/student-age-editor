# 自有私密大文件流转（服务器端 / 模块 A）

面向**自托管服务**的私有大文件直传、内网落盘与按需预热。实现位于
`native/server/services/file_transfer.{h,cpp}`，路由经
`native/server/api_router.cpp` 挂到 `/api/v1/files/*`，后台回收调度线程在
`native/server/run.cpp` 的 `run_server()` 中随服务启停。

> 本模块复用既有云同步（`server/services/cloud_sync.cpp`）的 AWS SigV4
> 签名原语，**不引入 `cos-cpp-sdk`**；出站传输走 `sa_core::http`。

## 业务状态机

```
                    POST upload/request
                           │
                           ▼
                    pending_upload
                           │  POST upload/complete
                           ▼
                      archiving ──(Worker 内网拉取失败)──▶ failed
                           │  校验成功 → 删除 COS 暂存对象
                           ▼
                       archived ─────────────┐
                           │  GET download    │
                           ▼                  │
                      warming_up              │ Worker 内网推回失败
                           │  Worker 内网推回  │
                           ▼                  │
                        ready ────────────────┘
                           ▲
                           │ GET download（刷新直链，记录 last_download_at）
                           ▼
              超过 2h 未下载 → 定时回收 COS 预热对象 → archived
```

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `POST` | `/api/v1/files/upload/request` | 上报 `{name, size}`，返回 30 分钟有效的 COS 公网 `PUT` 预签名 URL（`upload_url`/`cos_key`/`expires_in`）。 |
| `POST` | `/api/v1/files/upload/complete` | `{file_id}` 通知上传完成；入后台队列，Worker 走内网 Endpoint 拉回本地磁盘、校验后删除 COS 暂存对象。返回 `202 {status:"archiving", retry_after}`。 |
| `GET` | `/api/v1/files/:id/download` | 文件在 COS → 返回 `{status:"ready", url}`（CDN 或预签名 GET）；已在本地 → 触发预热并返回 `202 {status:"warming_up", retry_after}`；归档中返回 `202 {status:"archiving"}`。 |
| `GET` | `/api/v1/files/:id` | 状态查询（供客户端轮询）。 |

客户端直传示例（`upload_url` 为 PUT 预签名地址，直接送文件流即可）：

```bash
# 1) 申请
curl -X POST http://127.0.0.1:8765/api/v1/files/upload/request \
     -H 'Content-Type: application/json' \
     -d '{"name":"movie.mkv","size":1073741824}'

# 2) 直传 COS 暂存区
curl -X PUT --upload-file movie.mkv '<upload_url>'

# 3) 通知完成（触发内网落盘）
curl -X POST http://127.0.0.1:8765/api/v1/files/upload/complete \
     -H 'Content-Type: application/json' -d '{"file_id":"<id>"}'

# 4) 下载（首次 warming_up，数秒后重试拿直链）
curl http://127.0.0.1:8765/api/v1/files/<id>/download
```

## 环境变量

密钥与桶从环境变量注入（自托管服务器可只给进程环境，不落盘明文）：

| 变量 | 必填 | 默认 / 说明 |
| --- | --- | --- |
| `EDITOR_FILE_COS_SECRET_ID` | 是 | 兼容回退 `EDITOR_COS_SECRET_ID` / `COS_SECRET_ID` |
| `EDITOR_FILE_COS_SECRET_KEY` | 是 | 兼容回退 `EDITOR_COS_SECRET_KEY` / `COS_SECRET_KEY` |
| `EDITOR_FILE_COS_SESSION_TOKEN` | 否 | 临时密钥 token |
| `EDITOR_FILE_COS_BUCKET` | 是 | 存储桶名 |
| `EDITOR_FILE_COS_REGION` | 否 | 默认 `ap-guangzhou` |
| `EDITOR_FILE_COS_PUBLIC_ENDPOINT` | 否 | 默认 `https://cos.<region>.myqcloud.com`（客户端直传/下载） |
| `EDITOR_FILE_COS_INTERNAL_ENDPOINT` | 否 | 默认同公网；**自托管请填内网域名/IP**（Worker 落盘/预热） |
| `EDITOR_FILE_COS_CDN_DOMAIN` | 否 | 设置后下载直链优先用 CDN |
| `EDITOR_FILE_COS_PREFIX` | 否 | 默认 `editor-files` |
| `EDITOR_FILE_LOCAL_ROOT` | 否 | 本地落盘根目录（大容量盘）；默认 `<data_root>/_cache/file_transfer/objects` |
| `EDITOR_FILE_MAX_BYTES` | 否 | 单文件上限，默认 100 GiB |
| `EDITOR_FILE_UPLOAD_TTL` | 否 | 预签名 PUT 有效期秒数，默认 1800（30 分钟） |
| `EDITOR_FILE_DOWNLOAD_TTL` | 否 | 预签名 GET 有效期秒数，默认 600 |
| `EDITOR_FILE_RECLAIM_TTL` | 否 | 预热对象回收阈值秒数，默认 7200（2 小时） |
| `EDITOR_FILE_RECLAIM_INTERVAL` | 否 | 后台回收扫描间隔秒数，默认 60 |
| `EDITOR_FILE_PENDING_TTL` | 否 | 未完成上传的清理阈值秒数，默认 21600（6 小时） |

记录落盘在 `<data_root>/_cache/file_transfer/files.json`（原子写 + 进程内互斥）。

## 说明与边界

- COS 对象键：暂存 `"<prefix>/staging/<id>/<safe_name>"`，预热
  `"<prefix>/warm/<id>/<safe_name>"`。`safe_name` 仅保留
  `[A-Za-z0-9._-]`，路径分隔符与点号串被清洗，杜绝目录穿越。
- 归档校验：本地文件大小与客户端上报 `size` 不一致则标记 `failed`，
  暂存对象保留以便重试。
- 测试 seam：`set_cos_ops_for_test()` 可注入内存/桩 COS；用例见
  `native/tests/test_file_transfer.cpp`。
