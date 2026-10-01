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
`/api/ai/relay/chat`（整包非流式）；自带 key 模式由浏览器直连服务商。
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
                                      │  登录 /api/auth/login → Bearer token
                                      └─ 进程池：每账号一个懒启动 backend
                                         工作区 = user_data_root/<账号名>
```

> **实例防护**：每个 `backend` 实例只绑定 `127.0.0.1`，由网关独家访问；网关为
> 每个实例生成一次性 API 令牌（`--auth-token` 注入实例进程，实例侧落盘
> `.backend_token`，权限 0600），转发请求时自动携带 `X-Backend-Token` 头，
> 并默认给实例加 `--cloud-public-only`（云同步出站仅允许公网地址）。实例
> 请求体上限由网关设为 32 MiB；直连运行 `backend` 时默认 256 MiB，可用
> `--max-body` 调整。管理员无需手工配置以上任何一项。

### 2.1 gateway.json 字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `user_data_root` | string | **是** | 账号数据根目录，**绝对路径**；每账号工作区 = `<user_data_root>/<账号名>` |
| `web_root` | string | 否 | 网页前端目录（`web-app.zip` 解压产物），由**网关**直接伺服（不经 backend 实例） |
| `listen_port` | number | 否 | 网关监听端口，默认 8770（Caddy 反代指向它）；`--port` 可覆盖 |
| `trusted_origins` | array | 否 | 允许跨源访问的浏览器 Origin 列表（公网部署填 `https://你的域名`） |
| `session_ttl_hours` | number | 否 | 登录令牌有效期（小时） |
| `instance.max` | number | 否 | 同时存活的后端实例上限 |
| `instance.idle_minutes` | number | 否 | 实例闲置多少分钟后回收 |
| `state_dir` | string | 否 | 网关运行时状态目录 |
| `registration` | object | 否 | 自助注册配置，见 §2.3；缺省**关闭** |
| `accounts` | array | 是 | 账号列表，见下表 |
| `ai_relay` | object | 否 | 管理员平台 AI 中转配置，见 §3.1 |

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
  -d '{"name":"alice","password":"..."}'
# → {"token": "..."}
```

后续所有请求带 `Authorization: Bearer <token>`；网关返回 401 时前端自动回
登录页。

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
提交 `{name, password, invite_code?}`，成功返回与登录相同的
`{token, name, expires_in}`。

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
| 覆盖能力 | **仅 AI 对话** | AI 对话（服务商由配置决定） |
| 请求路径 | 浏览器 → `/api/ai/relay/chat`（服务器中转） | **浏览器直连服务商，不经服务器** |
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
  是否允许自带 key，以及 `tts_image_available`（自托管形态为 `false`，
  见下）。自托管形态下该端点同样在网关会话之后（需 `Authorization: Bearer`）。
- `POST /api/ai/relay/chat`：平台对话唯一通道（整包非流式返回）。
- **TTS / 生图**：自托管形态**不提供服务端 TTS / 生图**——策略里
  `tts_image_available:false`，前端对应面板置灰。

## 4. 功能对照（自托管形态 vs 桌面）

核心编辑与 AI 对话与桌面一致；以下端点或服务在自托管形态按设计收敛：

| 能力 | 自托管形态 | 说明 |
| --- | --- | --- |
| HTTP 服务插件代理 | **不提供（403）** | `/api/plugins/service/*`、`/api/plugins/agent/*` 网关不代理（见 `native/PLUGIN_SPEC.md` §4）；**声明型插件照常** |
| Steam 自动路径探测 | **不提供** | 工作区由管理员目录制（`user_data_root/<账号名>`） |
| `POST /api/workspace`、`/api/oobe`、TTS / 生图端点、`/api/shutdown`、AI/TTS settings 写入端点 | **网关封禁** | 工作区归网关管；服务端不代办 TTS/生图；禁止关停网关进程；用户自带 key 不落服务器 |
| 云同步（WebDAV / OpenList / 百度网盘等） | **照常可用** | 在账号工作区内与桌面同款 |
| 大表编辑（~10 万行） | 已知限制 | 解析在浏览器进行，比桌面原生慢 |
| AI 回复打字机流式 | 已知限制 | v1 整包返回，无流式 |

## 5. 构建网页产物与 server 包

- **网页前端产物**（独立发行，可在任意平台构建）：

  ```bash
  python build_release.py --target web --version Alpha-v0.1
  # → dist/web-app-<版本>.zip（内容即 `flutter build web` 产物 + 网页版说明）
  ```

- **Linux 服务端包**（须在 Linux 构建，桌面包规则不变，不支持交叉编译）：

  ```bash
  python build_release.py --target server-linux --version Alpha-v0.1
  ```

  server-linux 包提供 `backend` 与 `backend_gateway`。

## 6. 常见问题

- **打开页面一直 401？** 令牌过期或未登录；重新走 `POST /api/auth/login` 拿
  新 token。
- **局域网设备打不开本机版？** 确认除 `--host 0.0.0.0` 外，该设备的
  `http://<本机IP>:端口` 已用 `--trusted-origin` 声明为可信来源。
- **自带 key 填了报 CORS 错误？** 你的服务商不允许浏览器直连（如 OpenAI 官方
  API），换 CORS 友好的服务商/自建网关，或改用管理员平台模式。
- **TTS / 生图面板是灰的？** 自托管形态不提供这两项（`tts_image_available:false`），
  属预期行为；本机浏览器版不受影响。
- **磁盘快满了？** v1 无配额；先 `du -sh user_data_root/*` 找大头账号，再决定
  迁移 `data_dir` 或清理。
