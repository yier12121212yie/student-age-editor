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
| `POST` | `/api/v1/files/upload/request` | 上报 `{name, size}`，返回 30 分钟有效的 COS 公网 `PUT` 预签名 URL（`upload_url`/`cos_key`/`expires_in`）。适合中小文件单次直传。 |
| `POST` | `/api/v1/files/upload/multipart/init` | **大文件分片上传**：上报 `{name, size}`，后端调 COS `InitiateMultipartUpload`，返回 `{file_id, part_size, part_count, expires_in}`。`part_size` 默认 8 MiB，并按总大小自适应放大以满足「片数 ≤ 10000」。 |
| `POST` | `/api/v1/files/upload/multipart/sign` | `{file_id, part_number}`（或 `{file_id, part_numbers:[...]}` 批量）→ 该片带 `partNumber`/`uploadId` 的预签名 PUT URL（`{parts:[{part_number, part_url}]}`）。 |
| `POST` | `/api/v1/files/upload/multipart/complete` | `{file_id, parts:[{part_number, etag}]}` → 后端调 COS 合并分片，记录转 `archiving` 并入队落盘。返回 `202 {status:"archiving", retry_after}`。 |
| `POST` | `/api/v1/files/upload/multipart/abort` | `{file_id}` 取消分片上传（best-effort `AbortMultipartUpload`）并标记 `failed`。 |
| `GET` | `/api/v1/files/upload/modes` | 选路探测：`{cos, local, part_size}`。配了 COS 时 `cos:true`（前端优先用它，可走 CDN / 内网落盘）；否则 `local:true`，前端改走下面的本地分片。 |
| `POST` | `/api/v1/files/upload/local/init` | **免对象存储的大文件上传**：上报 `{name, size}`，返回 `{file_id, part_size(=8 MiB), part_count}`，字节落到 `<data_root>` 下的暂存目录（上限沿用 `EDITOR_FILE_MAX_BYTES`）。 |
| `PUT` | `/api/v1/files/upload/local/:id/part/:n` | 原始字节（`application/octet-stream`），第 `n` 片（1 起）；大小必须与 init 给出的分片边界完全一致，否则 400。请求体正好落在 httpd 的 raw_body 保留上限内。 |
| `POST` | `/api/v1/files/upload/local/complete` | `{file_id}` 按序拼接分片、校验总大小后落成 `archived`（`storage_type:"local"`），可直接用于 `import_staged` / `add_ref`。 |
| `POST` | `/api/v1/files/upload/local/abort` | `{file_id}` 清理暂存分片并标记 `failed`（客户端取消/出错时调用）。 |
| `POST` | `/api/v1/files/upload/complete` | `{file_id}` 通知上传完成（单次直传与 COS 分片上传共用）；入后台队列，Worker 走内网 Endpoint 拉回本地磁盘、校验后删除 COS 暂存对象。返回 `202 {status:"archiving", retry_after}`。本地分片在 complete 时已落盘，**不需要**这一步。 |
| `GET` | `/api/v1/files/:id/download` | 文件在 COS → 返回 `{status:"ready", url}`（CDN 或预签名 GET）；本地记录（无 COS）→ `{status:"ready", url:"/api/v1/files/<id>/raw", local:true}`；已在本地但配了 COS → 触发预热并返回 `202 {status:"warming_up", retry_after}`。 |
| `GET` | `/api/v1/files/:id/raw` | **本地记录直读**（chunked 流）：浏览器必须带 `Authorization: Bearer`，因此前端用 XHR 取字节而不是原生下载。 |
| `GET` | `/api/v1/files/:id` | 状态查询（供客户端轮询）。 |

消费者：

- **大模组包导入**（`POST /api/mods/import_staged {file_id}`，见
  `server/services/mods_routes.cpp`）：网页端选择 >48 MiB 的模组 zip 时，前端
  自动走直传 → complete 落盘 → 轮询 `archived` → import_staged 的链路，对落盘
  文件跑与 `import_path` 同款导入管线；其中 **>64 MiB 的包走 COS 分片上传**
  （init → 逐片 sign + 浏览器 `Blob.slice` 直传 → complete 合并），单次请求
  体与前端内存都被 `part_size` 兜住，数百 MB~GB 的包不再整包进内存。导入
  解压按条目**流式落盘**（`ZipReader::extract_to_file`），大贴图/配乐也不整
  条读进堆。该端点只认本账号数据根里的已归档记录，**从不接受调用方提供的
  路径**（`import_path` 在托管模式下依旧被网关封禁）。
- **单资源大文件「留 COS 只存引用」**（`POST /api/mods/add_ref {file_id,name,dir?}`，
  见 `server/services/mod_refs_routes.cpp`）：贴图/配乐/视频超过 48 MiB 时，
  浏览器同样直传，但不 `complete` 落盘——add_ref 把记录钉成 `linked`（永久
  引用，免遭 pending 清理），模组目录只写一条 `cos_resources.json` 索引；
  `GET /api/v1/files/:id/download` 直接回预签名直链（不落盘不预热），可给
  `<img>`/播放器用。
- **模组导出拼包**（`POST /api/mods/export_staged`，支持 `?async=1`）：服务端把
  本地盘文件（cfg 表 + 已落盘资源）与上述 COS 引用资源经**内网拉回**后流式拼成
  store-only zip，产物用 `register_local_artifact` 登记为 `archived` 记录；
  客户端轮询 `/api/v1/files/:id/download` 拿直链，带进度下载。导出包内不含
  `cos_resources.json` 与 `.editor_history/`——分发的 zip 永远是自包含实体文件。
  **拼包中间产物写在 `EDITOR_FILE_LOCAL_ROOT`（本地落盘根目录，大容量盘）下
  的 `.export_stage/`**，而不是系统临时目录：系统 temp 往往是容量小/易满的盘
  （Linux tmpfs、Windows C:），大模组写到这里会 ENOSPC，表现为
  「打包失败: write failed: &lt;某资源&gt;」；与产物目录同盘后登记也退化为原子 rename。
- 人物立绘/背景等资源图走各自的扩展通道（`PORTRAITS.md` / `BACKGROUNDS.md`），
  与本模块共用 COS 配置。

> **浏览器直传的 CORS**：预签名 PUT（上传）与直链 GET（导出下载带进度）由浏览
> 器直接发往 `EDITOR_FILE_COS_PUBLIC_ENDPOINT`（CDN 配置时下载走 CDN）。桶必须
> 为站点来源放行 `PUT`/`GET`，否则浏览器报「HTTP 0（多为对象存储未配置 CORS）」。
> 后端在首个 `upload/request` 时会**自动把桶 CORS 写成允许配置来源**（默认
> `*`，可用 `EDITOR_FILE_COS_CORS_ORIGINS` 收紧、`EDITOR_FILE_COS_CORS_DISABLE=1`
> 关闭，由管理员自管桶策略）；CDN 侧不继承 COS 桶的 CORS，若下载走 CDN，请在
> CDN 域名配置响应头 `Access-Control-Allow-Origin`，否则前端会自动退回**浏览器
> 原生下载**（无页内进度条，但不依赖 CORS）。

> **没有对象存储时**：`GET /api/v1/files/upload/modes` 返回 `local:true`，浏览器
> 改走 8 MiB 本地分片（`local/init` → 逐片 `PUT local/:id/part/:n` →
> `local/complete`），字节直接写进服务器盘上的暂存目录，不经过 COS、也不需要
> 任何 CORS 配置。分片大小刻意等于 httpd 的 `kRawBodyKeepMax`（8 MiB），
> 每片都会作为原始请求体完整转发。大文件上限沿用 `EDITOR_FILE_MAX_BYTES`
> （缺省 2 GiB，`0` 表示不限制）。导出下载走带鉴权的
> `GET /api/v1/files/:id/raw`（前端用 XHR 取字节并显示进度）。

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
| `EDITOR_FILE_COS_CDN_AUTH_TYPE` | 否 | 腾讯云 CDN URL 鉴权类型 `A`/`B`/`C`/`D`；与 KEY 同时给出才签名 |
| `EDITOR_FILE_COS_CDN_AUTH_KEY` | 否 | CDN 鉴权主密钥 pkey（回源鉴权与 URL 鉴权均在 CDN 侧配置） |
| `EDITOR_FILE_COS_CDN_AUTH_PARAM` | 否 | 签名参数名，默认 `sign` |
| `EDITOR_FILE_COS_CDN_AUTH_TS_PARAM` | 否 | TypeD 时间戳参数名，默认 `t` |
| `EDITOR_FILE_COS_CDN_AUTH_TTL` | 否 | 鉴权有效期秒数（仅用于回报 `expires_in`；真实时长在 CDN 控制台） |
| `EDITOR_FILE_COS_PREFIX` | 否 | 默认 `editor-files` |
| `EDITOR_FILE_LOCAL_ROOT` | 否 | 本地落盘根目录（大容量盘）；默认 `<data_root>/_cache/file_transfer/objects` |
| `EDITOR_FILE_MAX_BYTES` | 否 | 单文件上限，默认 100 GiB |
| `EDITOR_FILE_UPLOAD_TTL` | 否 | 预签名 PUT 有效期秒数，默认 1800（30 分钟） |
| `EDITOR_FILE_DOWNLOAD_TTL` | 否 | 预签名 GET 有效期秒数，默认 600 |
| `EDITOR_FILE_RECLAIM_TTL` | 否 | 预热对象回收阈值秒数，默认 7200（2 小时） |
| `EDITOR_FILE_RECLAIM_INTERVAL` | 否 | 后台回收扫描间隔秒数，默认 60 |
| `EDITOR_FILE_PENDING_TTL` | 否 | 未完成上传的清理阈值秒数，默认 21600（6 小时） |
| `EDITOR_FILE_COS_CORS_ORIGINS` | 否 | 浏览器直传放行的来源，逗号分隔，默认 `*` |
| `EDITOR_FILE_COS_CORS_DISABLE` | 否 | `=1` 关闭启动时的桶 CORS 自动写入（管理员自管桶策略时） |

记录落盘在 `<data_root>/_cache/file_transfer/files.json`（原子写 + 进程内互斥）。

## 说明与边界

- **Endpoint 风格**：`EDITOR_FILE_COS_PUBLIC_ENDPOINT` / `_INTERNAL_ENDPOINT`
  同时支持路径风格（`https://cos.<region>.myqcloud.com`）与虚拟主机风格
  （`https://<bucket>.cos.<region>.myqcloud.com`）。腾讯云新桶默认禁用路径
  风格（返回 `PathStyleDomainForbidden`），此时必须填虚拟主机风格——后端会
  自检 host 是否已含桶名前缀，含则不再重复拼 `/<bucket>/`。
- **私有 COS + CDN 加速**：COS 保持私有读、CDN 开「回源鉴权」拉私有桶；下载
  直链由后端按 `EDITOR_FILE_COS_CDN_AUTH_*` 规则生成**带签名的 CDN URL**
  （不可把 COS 预签名 URL 的域名直接换成 CDN 域名——两套鉴权不通）。若希望
  立绘等公开图片走同一 CDN，请在 CDN 鉴权范围里选择「指定类型文件鉴权」或
  「指定类型文件不做鉴权」，把图片后缀排除。
- COS 对象键：暂存 `"<prefix>/staging/<id>/<safe_name>"`，预热
  `"<prefix>/warm/<id>/<safe_name>"`。`safe_name` 仅保留
  `[A-Za-z0-9._-]`，路径分隔符与点号串被清洗，杜绝目录穿越。
- 归档校验：本地文件大小与客户端上报 `size` 不一致则标记 `failed`，
  暂存对象保留以便重试。
- 测试 seam：`set_cos_ops_for_test()` 可注入内存/桩 COS；用例见
  `native/tests/test_file_transfer.cpp`。
