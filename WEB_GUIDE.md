# 学生时代 模组编辑器 — 网页版指南

> **（随本里程碑交付生效）** 本指南描述网页版的规划形态：网页版不引入新内核，
> 仍是同一套 native C++ 后端 HTTP API——本机浏览器版直接跑单实例 `backend`，
> 自托管在线服务版在其前面加一层 `backend_gateway`（账号鉴权 + 进程池）。
> 桌面版的全部编辑能力（模组编辑 / 无代码模式 / AI 助手 / 云同步 / 声明型插件）
> 原样进入浏览器。
>
> 网页版有两种形态，按使用场景选择：
>
> | 形态 | 适用场景 | 前端来源 | 后端进程 |
> | --- | --- | --- | --- |
> | 形态一 本机浏览器版 | 个人在任意有浏览器的机器上用本机编辑器 | `web-app.zip` 静态产物 | 单实例 `backend --web-root` |
> | 形态二 自托管在线服务 | 管理员在 Linux 服务器上部署，多账号共用 | 同 `web_root`，由后端实例伺服 | `backend_gateway` 进程池（每账号一个 `backend`） |

---

## 1. 形态一：本机浏览器版

前后端都在你自己的机器上，数据不出本机；局域网里的其他设备（如平板）也可以
访问同一实例。

1. 下载 `web-app.zip`——**独立发行**的网页前端产物（`flutter build web`），
   **不在桌面包里**，桌面无需先安装；解压到任意目录。
2. 启动本机后端，指向解压目录：

   ```bash
   backend --web-root <解压目录>
   # → 打开 http://127.0.0.1:8765 即完整编辑器
   ```

3. （可选）供局域网设备访问：加 `--host 0.0.0.0` 并把设备将用的 Origin 加入
   可信来源（`--trusted-origin` 可重复传）：

   ```bash
   backend --web-root <解压目录> --host 0.0.0.0 \
     --trusted-origin http://<本机IP>:端口
   # 局域网设备打开 http://<本机IP>:端口
   ```

AI 与桌面同源：读本机 `.editor_ai` 配置文件。平台模式走本机后端
`/api/ai/relay/chat`（默认整包；流式通道 `/api/ai/relay/chat/stream` 在同源
部署下也走这条链路）；自带 key 模式由浏览器直连服务商。
云同步、TTS、生图与桌面同款可用——所有 key 都留在本机，与桌面版同一安全边界。

> **安全默认值**：`backend` 默认只绑定 `127.0.0.1`；加 `--host 0.0.0.0` 时须
> 显式列入可信 Origin，公网暴露请改走形态二。后端首次启动会在数据根目录自动
> 生成 API 令牌文件 `.backend_token`（权限 0600），同机的网页前端 / CLI / TUI
> 读取后以 `X-Backend-Token` 头自动携带——拦截本机其它进程裸打 API。

## 2. 形态二：自托管在线服务（Linux）

一台 Linux 服务器上运行 `backend_gateway`：它做账号鉴权与会话管理，并为每个
登录账号维护**一个懒启动的后端实例**（进程池，闲置回收），账号之间以各自独立
的 `backend` 进程与工作区目录隔离。工作区固定为 `user_data_root/<账号名>`，
数据保存地址由管理员通过 gateway.json 的 `user_data_root` / 每账号 `data_dir`
设定。

```
浏览器 ──HTTPS──▶ Caddy（TLS） ──▶ backend_gateway --config gateway.json
                                      │  登录 /api/auth/login → Bearer + refresh token
                                      └─ 进程池：每账号一个懒启动 backend
                                         工作区 = user_data_root/<账号名>
```

> **实例防护**：每个 `backend` 实例只绑定 `127.0.0.1`，由网关独家访问；网关为
> 每个实例生成一次性 API 令牌（`--auth-token` 注入实例进程，实例侧落盘
> `.backend_token`，权限 0600），转发请求时自动携带 `X-Backend-Token` 头，
> 并默认给实例加 `--cloud-public-only`（云同步出站仅允许公网地址）。网关与
> 每个实例的请求体上限统一取 `gateway.json` 的 `max_body_bytes`（默认 256 MiB）；
> 上传类接口的可解码字节上限自动派生为它的 3/4（base64 膨胀 4/3）。直连运行
> `backend` 时默认 256 MiB，可用 `--max-body` 调整。管理员无需手工配置以上任何一项。

> **大文件上传**：`max_body_bytes` 决定 base64 通道（`*_upload` 端点）的实际上限，
> 请与容器内存（`docker-compose.yml` 的 `mem_limit`）配套调大——一次上传在网关与
> 实例中各有约 2~3 份整包副本，建议内存 ≥ `max_body_bytes × 8`。台式直连时
> 可用环境变量 `EDITOR_MAX_UPLOAD_BYTES` 单独覆盖实例侧的解码上限。
>
> **带资源的大模组包（贴图/配乐/视频，数百 MB~GB）**：base64 通道必然超限（正是
> 「模组里有资源就无法导入自托管」的根因）。网页端以下三类操作超过 48 MiB 时自动
> 改走**对象存储直传**，全程不占网关/实例内存，也不进 base64：
> 1. **整包导入**：浏览器直传 → 服务端内网落盘 → `POST /api/mods/import_staged {file_id}` 流式解压导入。>64 MiB 的包走 **COS 分片上传**（`/api/v1/files/upload/multipart/{init,sign,complete}`，浏览器 `Blob.slice` 逐片直传、单次内存可控）；
> 2. **单资源上传**（贴图/配乐/视频导入）：直传后 `POST /api/mods/add_ref {file_id,name,dir?}`——字节**留在 COS 只存引用**（`<mod>/cos_resources.json` 索引），小文件仍落盘；
> 3. **模组导出/下载**：`POST /api/mods/export_staged` 由服务端把**本地盘文件 + COS 引用资源**流式拼成 zip 并登记周转，浏览器经预签名直链**带进度条**下载（页面弹进度对话框）。
>
> 前提是给 backend/网关进程注入 `EDITOR_FILE_COS_*` 凭据（见
> [`native/FILE_TRANSFER.md`](native/FILE_TRANSFER.md)）。后端会在首个直传请求
> 时**自动把 COS 桶 CORS 配好**（默认放行 `*`，可用 `EDITOR_FILE_COS_CORS_ORIGINS`
> 收紧），因此不再需要人工开桶 CORS；若下载走 CDN，CDN 域名需自行配响应头
> `Access-Control-Allow-Origin`，否则浏览器会自动退回原生下载（无进度条）。
>
> **没有对象存储也能传大文件**：未注入 COS 凭据时，前端先问
> `GET /api/v1/files/upload/modes`，选**本地分片上传**
> （`POST /api/v1/files/upload/local/init` → 逐片
> `PUT .../local/{id}/part/{n}`，默认 8 MiB/片 → `.../local/complete`）：字节
> 直接落到服务器盘上，不再经过 base64；导出下载走带鉴权的
> `GET /api/v1/files/{id}/raw`。单文件上限沿用部署的
> `EDITOR_FILE_MAX_BYTES`。阈值以下的小文件仍走 base64 通道。

### 2.1 gateway.json 字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `user_data_root` | string | **是** | 账号数据根目录，**绝对路径**；每账号工作区 = `<user_data_root>/<账号名>` |
| `web_root` | string | 否 | 网页前端目录（`web-app.zip` 解压产物），由**网关**直接伺服（不经 backend 实例） |
| `listen_port` | number | 否 | 网关监听端口，默认 8770（Caddy 反代指向它）；`--port` 可覆盖 |
| `trusted_origins` | array | 否 | 允许跨源访问的浏览器 Origin 列表（公网部署填 `https://你的域名`） |
| `session_ttl_hours` | number | 否 | 登录 access token 有效期（小时） |
| `refresh_ttl_days` | number | 否 | 「记住我」长期 refresh token 有效期（天），默认 30；落盘于 `<state_dir>/refresh_tokens.json`，网关重启后仍可免登 |
| `max_body_bytes` | number | 否 | 请求体/上传上限（字节），默认 256 MiB；同时作用于网关转发与各实例 `--max-body`（下限 1 MiB） |
| `instance.max` | number | 否 | 同时存活的后端实例上限 |
| `instance.idle_minutes` | number | 否 | 实例闲置多少分钟后回收 |
| `state_dir` | string | 否 | 网关运行时状态目录 |
| `registration` | object | 否 | 自助注册配置，见 §2.3；缺省**关闭** |
| `accounts` | array | 是 | 账号列表，见下表 |
| `ai_relay` | object | 否 | 管理员平台 AI 中转配置，见 §3.1 |
| `mcp_stdio` | object | 否 | 托管 stdio MCP 桥接，见 §4.2；缺省**关闭**（全部拒绝） |

`accounts[]` 每个账号：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `name` | string | 账号名（同时是工作区目录名） |
| `salt` | string | 密码盐（`--hash-password` 生成） |
| `password_sha256` | string | 密码哈希（`--hash-password` 生成） |
| `data_dir` | string | 该账号数据目录（缺省 = `user_data_root/<name>`；迁移换盘时改这一项） |
| `disabled` | bool | 置 `true` 停用账号而不删数据 |

### 2.2 账号与登录

密码哈希由 `backend_gateway` 自带工具生成（`salt:hash` 一行，分别填进
`accounts[].salt` 与 `accounts[].password_sha256`）：

```bash
backend_gateway --hash-password
```

登录 `POST /api/auth/login`：

```bash
curl -X POST https://你的域名/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"name":"alice","password":"...","remember":true}'
# → {"token":"<access>","name":"alice","expires_in":86400,
#    "refresh_token":"<long-lived>","refresh_expires_in":2592000}
```

后续所有请求带 `Authorization: Bearer <access>`。access token 过期（`expires_in`
秒）后，前端用 `refresh_token` 调 `POST /api/auth/refresh` 静默换新并自动重试；
刷新也失败才回登录页。

**长期鉴权（记住我）**：登录/注册请求带 `"remember": true` 时，refresh token
按 `refresh_ttl_days`（默认 30 天）签发并**落盘**到
`<state_dir>/refresh_tokens.json`——网关重启后仍免登；前端把它存本地存储，
关闭浏览器再回来自动换新。未勾选时 refresh token 与会话同寿且仅内存，关闭
标签页即需重登。每次刷新都会**旋转**（旧 refresh 立即失效，磁盘只存哈希）。

```bash
# 用 refresh 换新（旋转：响应里的 refresh_token 才是下次要用的那个）
curl -X POST https://你的域名/api/auth/refresh \
  -H 'Content-Type: application/json' \
  -d '{"refresh_token":"<上一步的 refresh>"}'
# → {"token":"<new access>","name":"alice","expires_in":86400,
#    "refresh_token":"<new refresh>","refresh_expires_in":2592000}

# 登出：吊销 access（Bearer）与 refresh（body）；access 已过期时仅凭
# refresh 也能登出
curl -X POST https://你的域名/api/auth/logout \
  -H 'Authorization: Bearer <access>' -H 'Content-Type: application/json' \
  -d '{"refresh_token":"<refresh>"}'
```

> 令牌落盘只写 SHA-256 哈希；明文 refresh token 仅在签发/旋转响应中出现一次。

### 2.3 自助注册（可选，默认关闭）

默认**关闭**：账号只能由管理员用 `--hash-password` 预置。若要让用户自行注册，
在 `gateway.json` 增加 `registration` 段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `enabled` | bool | 是否开放注册（默认 `false`） |
| `invite_code` | string | 邀请码；非空则注册必须提供，空 = 开放注册 |
| `max_accounts` | number | 账号总数上限（含 `accounts[]` 预置账号）；`0` = 不限 |
| `min_password_length` | number | 注册密码最短字符数（默认 8） |

```json
"registration": { "enabled": true, "invite_code": "你的邀请码", "max_accounts": 50 }
```

开启后登录页出现「注册」入口，用户填用户名 / 密码 /（可选）邀请码即可注册并
**自动登录**。约束：

- **账号落盘独立**：注册账号写入 `<state_dir>/accounts.json`（原子写），
  `gateway.json` 保持管理员只读；网关启动时并入运行时账号表，重启后仍在。
- **同名优先**：与 `gateway.json` `accounts[]` 同名时管理员声明优先（文件的同名
  条目被忽略），管理员可随时回收任意用户名。
- **口令哈希**：注册账号一律 PBKDF2-HMAC-SHA256（v2，10 万轮）。
- **工作区隔离**：与预置账号一致，工作区 = `user_data_root/<账号名>`，由网关
  进程池懒启动独立 `backend`。
- **限速**：注册尝试复用登录滑动窗口限速（60 秒 10 次失败即锁 5 分钟），
  挡邀请码爆破与 PBKDF2 算力耗尽。

公开端点 `GET /api/auth/registration` 返回 `{enabled, invite_required,
min_password_length}` 供前端决定是否显示注册入口；`POST /api/auth/register`
提交 `{name, password, invite_code?, remember?}`，成功返回与登录相同的
`{token, name, expires_in, refresh_token, refresh_expires_in}`（`remember`
决定 refresh token 是否长期落盘，见 §2.2）。

### 2.4 部署步骤（Ubuntu 24.04）

1. **装 Caddy**（官方 apt 源或系统包管理器均可），用于 TLS 终结与反向代理。
2. **下载 server-linux 包**，解压到 `/opt/editor`，其中含 `backend_gateway`
   与每账号拉起的 `backend`；`web-app.zip` 解压为网页前端目录。
3. **建专用用户**：`useradd -r -m editor`，把 `/opt/editor` 与数据根目录
   （如 `/srv/editor-data`）chown 给它。
4. **写 `gateway.json`**：`user_data_root`、`web_root`、`listen_port`、
   `trusted_origins` 等；用 `backend_gateway --hash-password` 为每个账号生成
   `salt:hash` 填入 `accounts`（完整字段见 §2.1）。
5. **systemd 单元启用**（示例见 `packaging/gateway/`，路径以仓库为准）：

   ```ini
   [Unit]
   Description=StudentAge Editor Gateway
   After=network.target

   [Service]
   User=editor
   ExecStart=/opt/editor/backend_gateway --config /etc/editor/gateway.json
   Restart=always

   [Install]
   WantedBy=multi-user.target
   ```

   `systemctl enable --now editor-gateway`。
6. **Caddy 反代 + HTTPS**（示例见 `packaging/gateway/`，路径以仓库为准）：

   ```caddyfile
   editor.example.com {
       reverse_proxy 127.0.0.1:8770   # gateway.json 的 listen_port（示例值）
   }
   ```

   Caddy 自动证书 / 续期，无需手工配置 TLS。
7. **验证**：policy 等除 `/api/auth/login` 外的所有 `/api/*` 均需会话 token——部署后先拿 token 再验：

   ```bash
   TOKEN=*** -s -X POST https://域名/api/auth/login \
     -H 'Content-Type: application/json' \
     -d '{"name":"你","password":"***"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
   curl -H "Origin: https://你的域名" -H "Authorization: Bearer $TOKEN" \
     https://域名/api/ai/policy
   ```

   返回 JSON 策略即链路通畅（登录后访问第一个代理端点时，网关会懒启动该账号的 `backend` 实例）。

### 2.5 数据与运维

- **备份**：`user_data_root` 整目录打包即可恢复全部账号：

  ```bash
  tar czf editor-backup.tgz -C / editor-data
  ```

- **迁移 / 换盘**：新盘就位后把对应账号的 `data_dir`（或整体 `user_data_root`）
  指向新路径，重启网关。
- **磁盘配额**：v1 不提供网关侧配额，建议以 `du` 定期监控
  `user_data_root/<账号名>` 大小。

## 3. AI 配置（双供给）

网页版 AI 有两种互补的 key 来源，**同一账号可同时启用**：

| | 管理员平台 key（relay） | 用户自带 key（直连） |
| --- | --- | --- |
| 覆盖能力 | AI 对话；**可另行开启**服务端 TTS / 生图（§3.1.1） | AI 对话（服务商由配置决定） |
| 请求路径 | 浏览器 → `/api/ai/relay/chat`（服务器中转，支持流式） | **浏览器直连服务商，不经服务器** |
| key 存放 | 服务器 gateway.json，浏览器永不接触 | 浏览器本地存储，不落服务器 |
| 限制 | 模型白名单 + 按账号日额度，超限 429 | 取决于服务商 CORS 策略 |

### 3.1 管理员平台 key（`ai_relay`）

gateway.json 的 `ai_relay` 段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `enabled` | bool | 是否开启平台中转 |
| `provider` | string | 上游服务商 |
| `base_url` | string | 上游 API 基址 |
| `api_key` | string | 平台 key（只存在于服务器端） |
| `models` | array | **模型白名单**：仅这些模型可被账号选用 |
| `daily_limit` | number | **按账号日额度**：超限后 `/api/ai/relay/chat` 返回 429 |
| `media_relay` | object | 服务端 TTS / 生图的全局 key，见 §3.1.1；缺省关闭 |

#### 3.1.1 服务端 TTS / 生图（`ai_relay.media_relay`）

托管形态**默认封禁** `/api/tts/*` 与 `/api/ai/image/*`（平台不替用户付费）。
管理员填好全局 key 后可显式开启，网页端对应的配音 / 生图面板重新出现：

```json
"ai_relay": {
  "enabled": true,
  "provider": "openai_compatible",
  "base_url": "https://api.example.com/v1",
  "api_key": "sk-chat",
  "media_relay": {
    "enabled": true,
    "daily_limit": 20,
    "tts": {
      "provider": "minimax",
      "base_url": "https://api.minimax.io",
      "api_key": "sk-tts",
      "model": "speech-02-hd",
      "voice": "female-shaonv",
      "format": "mp3"
    },
    "image": {
      "base_url": "https://api.example.com/v1",
      "api_key": "sk-image",
      "model": "gpt-image-1"
    }
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `enabled` | bool | 总开关；**false 时两个前缀继续 403** |
| `daily_limit` | number | 按账号/UTC 日计数（`<state_dir>/usage_media.json`），0 = 不限，与对话额度分开 |
| `tts.*` | object | `provider` / `base_url` / `api_key` / `model` / `voice` / `format`，只下发填写的字段 |
| `image.*` | object | `base_url` / `api_key` / `model` |

实现方式（安全边界不变）：

- **生图**：网关把请求体里的 `api_key`/`base_url`/`model` 换成管理员的配置，
  **客户端自带的 host 一律丢弃**（SSRF 面与封禁时等价）；只有
  `/api/ai/image/generate|edit` 走这条注入。
- **TTS**：网关把管理员配置写成 `<state_dir>/hosted_media.json`，通过
  `EDITOR_HOSTED_MEDIA_FILE` 传给每个实例；实例合成时叠加在账号自身设置
  之上，**key 从不写入账号沙箱**，`GET /api/tts/settings` 也会把它抹掉。
- 只有 `POST /api/tts/{synthesize,test}` 与生图接口计媒体额度；保存已有音频
  （`/api/tts/save`）不消耗额度。
- 任一 key 缺失时对应端点返回 503（而不是悄悄用用户 key）。

### 3.2 用户自带 key（浏览器直连）

自带 key 保存在浏览器本地，请求由浏览器直接发往服务商——**不经过服务器**，
所以「用户自带 key 不落服务器」是自托管形态的默认安全边界（网关也因此封禁
AI/TTS settings 的服务端写入端点，见 §4）。

一个硬约束是 **CORS**：服务商必须允许浏览器跨源调用——

- OpenAI **官方 API 不允许浏览器直连**（CORS 拒绝），此模式不可用；
- Anthropic 官方 API 需要请求带 `anthropic-dangerous-direct-browser-access`
  头（前端在该模式下已自动附加）；
- 自建网关 / OpenAI 兼容站需自行开启 CORS。

因此**自带 key 模式仅对 CORS 友好的服务商可用**，配置页会对此明确提示。

### 3.3 端点与策略

- `GET /api/ai/policy`：返回当前供给策略——relay 是否可用、白名单模型与额度、
  是否允许自带 key、`stream`（平台通道是否支持 SSE 流式），以及
  `tts_image_available`（§3.1.1 未开启时为 `false`）。自托管形态下该端点同样
  在网关会话之后（需 `Authorization: Bearer`）。
- `POST /api/ai/relay/chat`：平台对话唯一通道（整包非流式返回）。
- `POST /api/ai/relay/chat/stream`：平台对话的 SSE 流式通道——服务器逐块转发
  上游 delta，前端按打字机渲染；失败/被取消时自动回退整包通道。
  **只有平台 relay 走流式**，自带 key 直连仍是整包。
- **TTS / 生图**：默认不提供（策略 `tts_image_available:false`，前端面板置灰）；
  管理员按 §3.1.1 开启后由网关用全局 key 代办。

## 4. Web 端 HTTP MCP 与外部 Agent 接入（含后端对接规范）

网页版与桌面版均支持通过 **Streamable HTTP MCP（协议版本 `2025-03-26`）** 将当前工作区的模组读写能力直接暴露给外部 Agent（Claude Code、Claude Desktop、Cursor、Windsurf、Dify 等），无需在客户端本地额外部署 Python 桥接脚本。同时，编辑器内置 AI 助手连接外部 HTTP MCP 服务器时也支持携带自定义鉴权请求头。

### 4.1 前端使用说明（生成令牌卡片 & 外部 Agent 接入）

打开编辑器 **「设置」→「HTTP MCP 服务端（供外部 Agent 接入）」** 区块：

1. **查看 HTTP MCP 端点地址**：
   - 默认读写端点：`<Origin>/api/mcp`（例如 `http://127.0.0.1:8765/api/mcp` 或 `https://editor.example.com/api/mcp`）
   - 只读端点（勾选「只读模式」）：`<Origin>/api/mcp?readonly=1`（仅暴露 9 个查询工具，屏蔽 4 个写工具）
2. **通过「生成令牌」卡片签发鉴权凭据**：
   - 填写**令牌备注**（如 `Cursor 办公电脑`、`Claude Code`）；
   - 选择**有效期**（`30 天` / `90 天` / `365 天` / `永不过期`）；
   - 选择**权限范围**（`只读权限（仅查询）` 或 `读写权限（可修改模组）`）；
   - 点击 **「生成令牌」**：
     - 在线服务（`backend_gateway`）或已实现令牌接口的 `backend` 会签发长期 API 令牌（前缀 `sa_mcp_...`）；
     - 若后端尚未升级 `/api/auth/tokens` 接口，前端自动回退使用当前网关登录会话 Token 或本机 `--auth-token` 生成可用凭据；
   - **明文令牌仅在生成时展示一次**，卡片内提供 **「复制令牌」** 与 **「复制鉴权请求头」**（`Authorization: Bearer <token>`）快捷按钮，并自动将该令牌填入下方的配置片段预览。
3. **一键复制外部 Agent 配置片段**：
   - 支持切换 **Claude Code / Desktop**、**Cursor**、**Windsurf** 与 **cURL 自检** 四种模板，均已自动填入 `url` 与 `headers.Authorization`。
4. **编辑器连接外部受保护的 HTTP MCP 服务器**：
   - 在 **「设置」→「AI 对话 · 自定义指令与 MCP 工具」** 中添加 `http` 传输类型的 MCP 服务器时，可在 **「HTTP 鉴权请求头（可选）」** 输入框中填写：
     - 裸令牌：`sa_mcp_xxx`（自动补齐为 `Authorization: Bearer sa_mcp_xxx`）
     - Bearer 串：`Bearer sa_mcp_xxx`（自动补齐为 `Authorization: Bearer sa_mcp_xxx`）
     - 多行自定义请求头：`Header-Name: Value`（如 `Authorization: Bearer xxx` 换行 `X-Workspace: my_mod`）

---

### 4.2 网页版 stdio MCP 桥接（`mcp_stdio`）

浏览器的 AI 助手也能用 **stdio 类型**的 MCP 服务器：子进程由后端代持
（`/api/mcp/stdio/{start,send,stream,stop}`），浏览器只收发 JSON-RPC 行。

- **本机浏览器版**：与桌面同权限，直接可用（后端就是本机进程）。
- **自托管**：**默认关闭**——网关给每个实例注入 `EDITOR_HOSTED=1` 与命令
  白名单，未开启 / 命令不在白名单一律 403，设置页也会隐藏 stdio 表单。开启方式：

```json
"mcp_stdio": {
  "enabled": true,
  "allow": ["npx.cmd", "node", "python"]
}
```

`allow` 同时匹配**完整命令**与**文件名**（`/usr/bin/node` 也算命中 `node`）；
白名单为空即全部拒绝。其他约束：

- 只转发子进程 **stdout**（stderr 丢弃），单行上限 4 MiB；
- 每个实例最多 8 个会话，空闲 10 分钟自动回收，会话关闭即终止子进程；
- 桥接端点**拒绝只读令牌**（子进程工具不受编辑器只读门禁约束）；
- Windows 上请直接写 exe，或用 `cmd /c <命令>` 包装（参数里不要嵌 `"`）；
  进程拥有与后端相同的文件/网络权限。

---

> 后端 C++ 接口对接方案已独立拆分至 [`plan/http_mcp_backend_plan.md`](plan/http_mcp_backend_plan.md)。

---

## 5. 功能对照（自托管形态 vs 桌面）

核心编辑与 AI 对话与桌面一致；以下端点或服务在自托管形态按设计收敛：

| 能力 | 自托管形态 | 说明 |
| --- | --- | --- |
| HTTP MCP（`/api/mcp`） | **原生支持** | 经 `Authorization: Bearer <token>` 鉴权后路由到账号专属 `backend` 实例 |
| stdio MCP（浏览器端 AI 助手） | **默认关闭，可开启** | 后端代持子进程，见 §4.2；管理员的命令白名单是唯一放行依据 |
| HTTP 服务插件代理 | **不提供（403）** | `/api/plugins/service/*`、`/api/plugins/agent/*` 网关不代理（见 `native/PLUGIN_SPEC.md` §4）；**声明型插件照常** |
| Steam 自动路径探测 | **不提供** | 工作区由管理员目录制（`user_data_root/<账号名>`） |
| TTS / 生图端点 | **默认封禁，可开启** | 管理员配置 `ai_relay.media_relay` 后由网关用全局 key 代办（§3.1.1） |
| `POST /api/workspace`、`/api/oobe`、`/api/shutdown`、AI/TTS settings 写入端点 | **网关封禁** | 工作区归网关管；禁止关停网关进程；用户自带 key 不落服务器 |
| 云同步（WebDAV / OpenList / 百度网盘等） | **照常可用** | 在账号工作区内与桌面同款 |
| 大表编辑（~10 万行） | 已知限制 | 解析在浏览器进行，比桌面原生慢 |
| AI 回复打字机流式 | **支持（平台 relay）** | `/api/ai/relay/chat/stream` SSE；自带 key 直连仍是整包 |
| 大文件导入导出 | **支持** | 有 COS 走对象存储直传；无 COS 走 8 MiB 本地分片（§2） |


> **窗口自适应**：浏览器窗口宽度小于 1100 逻辑像素时，桌面壳自动把 AI 侧栏
> 由并排停靠切换为**悬浮抽屉**（不占用布局宽度，点遮罩或右下角悬浮按钮开合），
> 避免「活动栏 + 侧边栏 + AI 面板」叠加把编辑区压窄 / 溢出；窗口放宽即恢复
> 并排停靠。两种形态共用同一 AI 会话与设置（见 `design/ai_sidebar.md`）。

## 6. 构建网页产物与 server 包

- **网页前端产物**（独立发行，可在任意平台构建）：

  ```bash
  python build_release.py --target web --version Alpha-v0.1
  # → dist/web-app-<版本>.zip（内容即 `flutter build web` 产物 + 网页版说明）
  ```

  Web 通道在打包前会做五件事，部署时无需额外配置：

  1. **内置中文字体**：CanvasKit 没有系统字体，中文原本只能靠引擎的 fallback
     字体服务按 unicode 切片下载。Flutter 3.47 的该服务在首屏只登记极少数切片
     （实测只取 2 片），大量汉字会显示成豆腐块（□）。因此网页版随包带一份
     `assets/fonts/EditorCJK.ttf`（覆盖 GB2312 + 源码用字，约 2.1 MB，
     gzip 1.36 MB / brotli 1.21 MB），由 `core/editor_font_web.dart` 在 `runApp`
     前注册（同时挂到 `EditorCJK` / `Consolas` / `monospace` 三个族名，代码
     查看器里的中文也不会掉回切片）并设为主题字体。生成/更新见
     `tools/build_web_cjk_font.py`；文件已随仓库提交，正常构建不会重新生成。
  2. **去 Google 依赖**：`--no-web-resources-cdn` + 自定义 `frontend/web/flutter_bootstrap.js`
     让 CanvasKit 走同源 `canvaskit/`，并把 Roboto / Noto 中文切片的
     `fontFallbackBaseUrl` 指向同源 `fallback_fonts/`（`tools/fetch_web_fallback_fonts.py`
     在构建期镜像，约 4.3 MB，运行时按需只取命中的切片）。源码直跑
     `flutter build web` 时没有镜像，bootstrap 会自动回退 `fonts.gstatic.com`；
     镜像切片现在只用于内置字体未覆盖的生僻字兜底。
  3. **裁剪图标字体**：`tools/subset_web_icon_fonts.py` 按源码实际引用的图标
     码点子集化 fluent 字体（Flutter 自带的 tree-shake 对包字体只裁表不裁
     字形），4.4 MB → 约 0.05 MB；零引用的 `SegoeIcons` 直接移除。
  4. **预压缩**：为 js/wasm/字体/html 生成 `.gz`（装了 `brotli` 模块时再生成 `.br`）
     旁文件；`backend --web-root` 会按 `Accept-Encoding` 直接下发，`main.dart.js`
     从约 6 MB 降到约 1.4 MB。
  5. **缓存**：静态路由对 `main.dart.js`/`index.html`/`canvaskit` 回 `no-cache` +
     ETag（重复访问是 304，升级立即生效）；`fallback_fonts/**` 为一年 immutable。
  6. **版本指纹**：在 Web 根目录生成 `version.json`（`version` + `main.dart.js`
     的 sha256 前 16 位）。页面每 2 分钟比对一次，产物被重新部署后旧的标签页
     会弹出「编辑器已更新，刷新后使用新版本」——否则已打开的页面会一直跑旧包
     （Service Worker 只在新页面加载时才切换）。

  构建日志会打印首屏体积估算（gzip/brotli），超过预算时告警。本机构建请
  先 `pip install fonttools brotli`；缺失时对应步骤自动跳过（功能不受影响，
  只是首屏变大或图标字体不裁剪）。

  > 手动 `flutter build web` 后如果直接复用旧的 `.gz/.br` 旁文件，浏览器会继续
  > 拿到压缩的旧包。改动前端后请走 `build_release.py --target web`（会重新生成
  > 旁文件），或先删掉 `frontend/build/web/**/*.gz|*.br`。

- **Linux 服务端包**（须在 Linux 构建，桌面包规则不变，不支持交叉编译）：

  ```bash
  python build_release.py --target server-linux --version Alpha-v0.1
  ```

  server-linux 包提供 `backend` 与 `backend_gateway`。

## 7. 浏览器端的交互细节

以下行为只在网页版生效，桌面端不受影响（同一份 Dart 代码按平台分流）：

| 行为 | 说明 | 实现位置 |
| --- | --- | --- |
| **关页/刷新拦截** | 有未保存修改时，关标签页、刷新（F5/Ctrl+R）、地址栏跳转都会先让浏览器弹确认。文案与按钮由浏览器固定，不能自定义；没有用户交互时浏览器可能直接忽略 | `core/web_lifecycle*.dart` |
| **拖拽导入** | 把图片/音频/视频拖进窗口即导入当前模组（与「导入本地…」同一链路，超阈值的 Web 大文件仍走对象存储引用）。同时挡掉浏览器「直接打开被拖入文件」的默认行为——那会整页跳走并丢掉未保存的修改 | `core/web_drop*.dart` |
| **标签页标题** | `当前文档 · 模组名 — 学生时代模组编辑器`，多开标签页可区分。`WidgetsApp` 的 `Title` 会在根部重建时把标题写回静态文案，这里用 `MutationObserver` 守住 | `core/web_head*.dart`、`core/app_title_text.dart` |
| **浏览器 UI 配色** | 引擎会按 `FluentApp.primaryColor` 注入一个**不带 media** 的 `theme-color`（`#0078d4`），把 index.html 里浅/深一对覆盖掉。同一个 observer 会删掉它并补齐 `prefers-color-scheme` 两条 | `core/web_head_web.dart` |
| **大响应解析提示** | Web 上 `compute()` 退化为同步执行，几十 MB 的整表解码会冻结主线程。超过 3 MB 时状态栏先显示「正在解析 N MB…」（先等一帧再开始解析），冻结期间用户能看到进度圈而不是以为卡死 | `core/heavy_task.dart`、`core/web_frame*.dart`、`api_client.dart` |
| **粘贴图片** | 剪贴板里是文件（截图、复制的图片）且当前**不在文本输入中**时，按「导入到当前模组」处理；普通文本粘贴完全不受影响 | `core/web_drop_web.dart` |
| **运行错误兜底** | 某个子树 build 失败时就地显示错误卡片（说明 + 首句异常 + 「重新加载页面」），不再是一块灰底或整页空白；异步异常同时记入 `__editorDiag.err`，控制台输出照旧保留 | `core/error_fallback.dart` |
| **JS 错误采集** | 监听 `error` / `unhandledrejection`，只收集不拦截（不 `preventDefault`）；过滤 `Script error.`、`ResizeObserver loop` 等噪音，最近 5 条写入 `__editorDiag.jsErr` | `core/web_errors*.dart` |
| **诊断信息** | 设置 → 诊断 →「复制诊断信息」：启动阶段、界面模式、浏览器 UA/屏幕/视口/内存/已用堆与最近 JS 错误汇总成一段文本，一键复制即可贴到反馈里（不含模组内容与账号信息） | `core/diagnostics.dart`、`core/web_diag*.dart` |
| **首屏加载屏** | 纯 HTML/CSS：进度条 + 慢网提示（8s）+ 15s 重试出口 + 启动脚本失败提示（含 Ctrl+F5 指引）。内置中文字体就绪（或 2.5s 超时）后才让位给 Flutter 首帧，避免先闪一屏豆腐块 | `web/index.html`、`web/flutter_bootstrap.js` |
| **首帧不再等字体** | `main()` 不再 `await` 2.1 MB 中文字体；注册完成后引擎会发 `fontsChange`，框架自动重排全部文本 | `main.dart`、`core/editor_font_web.dart` |
| **下载可靠性** | `<a download>` 触发后不再立即 `revokeObjectURL`（Firefox/Safari 会得到 0 字节文件），改为 60s 后释放；文件名做非法字符净化与超长截断 | `core/file_save_stub.dart`、`core/download_name.dart` |
| **屏幕阅读器** | 设置 → 外观下方新增「无障碍 · 屏幕阅读器支持（语义树）」。默认关闭（CanvasKit 语义树有每帧开销），开启后持久化；桌面端仍一律排除语义树 | `core/a11y_semantics.dart` |
| **快捷键提示** | macOS 浏览器里显示 `⌘S` / `⌘Z`，不再写死 Ctrl | `core/shortcut_labels.dart` |
| **PWA** | `manifest.json` 不再锁竖屏（`orientation: any`，平板横屏可用），补齐 `lang`/`scope`/`id`；`index.html` 补 `viewport-fit=cover`、浅/深色 `theme-color`、`<noscript>` | `web/manifest.json`、`web/index.html` |

> **排查「停在加载页」**：浏览器 F12 看 `window.__editorDiag`——里面记录了
> `init`（根组件实例数）、`auth`（鉴权探测结果）、`uiMode`、`boot`
> （bootstrap 是否完成）与 `render`（当前渲染的是登录页 / 加载页 / 壳层，
> 加载页还会带上 `_loadError`）。另外控制台会打印一条
> `[bootstrap] 初始化完成: ...` 或 `[bootstrap] 初始化异常: ...`。
>
> 界面能开但某块区域坏了：`err` 是最近一次框架异常的首行，`jsErr` 是最近 5 条
> 浏览器层错误（含时间与序号）。不想逐项手抄就走「设置 → 诊断 → 复制诊断信息」。

## 8. 常见问题

- **打开页面一直 401？** 若已勾选「记住我」，前端会用 refresh token 自动换新；
  仍 401 说明长期凭据也过期/被吊销（如网关换了 `state_dir`），重新登录即可。
  服务端排查时先走 `POST /api/auth/login` 拿新 token。
- **外部 Agent 连 `/api/mcp` 报 401？** 检查客户端配置中是否已携带
  `Authorization: Bearer <令牌>` 请求头，或在编辑器「设置 → 生成令牌」卡片中重新生成一枚未过期的令牌。
- **局域网设备打不开本机版？** 确认除 `--host 0.0.0.0` 外，该设备的
  `http://<本机IP>:端口` 已用 `--trusted-origin` 声明为可信来源。
- **自带 key 填了报 CORS 错误？** 你的服务商不允许浏览器直连（如 OpenAI 官方
  API），换 CORS 友好的服务商/自建网关，或改用管理员平台模式。
- **网页版中文全是方块（□）？** 说明内置中文字体没有加载成功。检查部署目录里
  是否存在 `assets/assets/fonts/EditorCJK.ttf`（以及 `.br`/`.gz` 旁文件是否与
  本体匹配），浏览器控制台会打印 `[font] 内置中文字体加载失败` 并退回引擎的
  fallback 切片（只能覆盖少量汉字）。重新执行
  `python tools/build_web_cjk_font.py` 可重新生成该字体。
- **关标签页没有弹「未保存」确认？** 只有真的存在未保存修改时才会拦，且浏览器
  要求页面先有过用户交互；弹窗文案与按钮由浏览器固定，无法自定义。关闭前更稳妥
  的做法仍是先按 `Ctrl+S`（macOS 为 `⌘S`）。
- **把文件拖进窗口没反应？** 先确认已选中模组；只识别图片/音频/视频扩展名，
  其它类型会提示「已跳过不支持的文件」，请走资源面板的「导入本地…」。剪贴板里
  有图片时也可以直接 `Ctrl+V` 粘贴导入（正在文本输入框里打字时不接管）。
- **界面某块区域突然变成「界面渲染出错」？** 那是运行期异常的兜底卡片：其余部分
  通常还能用，先继续操作并尽快保存；点卡片里的「重新加载页面」（或 `F5`）即可恢复。
  需要反馈时去「设置 → 诊断 → 复制诊断信息」，里面带着出错首行与最近的浏览器错误。
- **TTS / 生图面板是灰的？** 自托管形态默认不提供这两项
  （`tts_image_available:false`），管理员配置 `ai_relay.media_relay` 并重启网关
  后才会出现（§3.1.1）；本机浏览器版不受影响。
- **设置了 stdio MCP 服务器却看不到？** 自托管默认关闭桥接，需管理员在
  `gateway.json` 开启 `mcp_stdio` 并配置命令白名单（§4.2）；配置本身不会被删除。
- **磁盘快满了？** v1 无配额；先 `du -sh user_data_root/*` 找大头账号，再决定
  迁移 `data_dir` 或清理。
