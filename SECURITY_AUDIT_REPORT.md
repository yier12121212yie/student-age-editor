# 安全审计与加固报告

> 范围：本轮「综合治理与升级」安全批次 A/B + 性能波次（同程交付）。
> 对象：native 后端（httpd/网关/云同步/AI 中继）、Flutter 前端、CLI/TUI、
> CI 工作流与打包脚本。日期：2026-09。

---

## 1. 重大发现：SHA-256 轮常数表 K[27] 错值（历史遗留）

**发现**：历史上 `sa_core::sha256_hex` 的轮常数表 `K[27]` 被写错——
`0xbf53c9d2`，真值 `0xbf597fc7`（`native/core/sha256.cpp:4`）。产出的是
**非标准摘要**：任何外部标准 SHA-256 工具（`sha256sum`、OpenSSL）与其比对
必然不一致；碰撞安全性未受单一常数替换的实质削弱，但「自称 SHA-256 的
输出与全世界的 SHA-256 不同」本身就是兼容性与信任缺陷。

**处置**（安全批次 A）：

- `sa_core` 双表：新表纠正为标准值，所有**新**哈希走标准 SHA-256；
  LEGACY 表（含 K[27] 已知错值）原样保留，**仅限**与历史落盘指纹 /
  旧口令哈希的自洽比对，任何新用途禁止引用（`sha256.cpp:176`、
  `sha256.h:3-17`）。
- 网关口令存储升级为 **PBKDF2-HMAC-SHA256 v2**（迭代参数
  `kKdfIterationsDefault`，新账号一律 v2）；v1（错值表 sha256）仅用于校验
  历史 `gateway.json` 账号，登录成功时**透明升级**为 v2 行（`gw_config.*`、
  `gw_proxy.cpp`），管理员无需迁移脚本。

---

## 2. 修复清单

### 2.1 供应链与 CI（安全批次 A）

| 项 | 落点 |
| --- | --- |
| 全部 5 个 workflow 显式最小 `permissions:`（release 仅 `contents: write`） | `.github/workflows/*.yml` |
| 外部资源包下载钉死 SHA-256（`ci_assets.lock.json` → `--expect-sha256` + 下载后复算双校验） | `release.yml:82+`、`packaging/ci_assets.lock.json` |
| 新增 secret 扫描工作流（push / PR 双触发，PR 场景按 base..head 增量扫） | `secret-scan.yml` |
| Android release 签名：无 keystore 材料时回落 debug 签名并显式告警（CI 不再因此静默失败） | `frontend/android/app/build.gradle.kts:80+`（遗留事项见 §5） |
| 原版配置表导出弃用 Python pickle（`base_data.pkl`），改为逐表 JSON（C++ 后端可读、无反序列化执行面） | `tools/resource_scan/`（`base_data/<Table>.json` + `base_meta.json`） |

### 2.2 网络暴露面（backend / httpd）

- **默认只绑 `127.0.0.1`**（`run.cpp:307`）：本机形态零暴露；`--host 0.0.0.0`
  需显式传入并配合 `--trusted-origin` 信任列表（ Origin 白名单校验不变）。
  网关拉起的每账号实例一律 127.0.0.1，仅网关可及。
- **进程击杀端点防外暴**：`/api/shutdown` 仅在环回 socket 下注册生效。
- **Backend Token 握手**（安全批次 B）：
  - `backend` 首启在数据根（`editor_root()`）生成 128-bit hex 令牌落盘
    `.backend_token`（POSIX 0600 / Windows 用户态 ACL），并要求所有
    `/api/*` 请求携带 `X-Backend-Token`；比较用常数时间折叠异或。
  - 豁免面最小化：`/api/ping`（探活）、CORS 预检、非 `/api/*` 静态资源。
  - 令牌传递：桌面 GUI 启动器 / Android（MethodChannel）/ CLI / TUI 读取
    同一路径自动携带；网关 fork 实例时用 `--auth-token` **内存注入**
    （不落第二份盘上明文）；`--no-auth-token` 为显式逃生口，令牌机制不可用
    时后端降级为禁用并打日志告警（兼容旧包，fail-open 可见）。
  - 消费端全套：`backend_launcher_io.dart`（三就绪点装载）、
    `MainActivity.kt`、`p7_cli_main.cpp`、`p8_api.cpp`。
- **请求体上限**：`--max-body` 可调；直连默认 256 MiB，网关给实例设 32 MiB
  （`httpd.cpp`、`gw_pool.cpp`）。
- **网关托管态端点黑名单**（`endpoint_banned`，`gw_proxy.cpp:90`）：
  `/api/shutdown`（进程击杀）、`/api/plugins/service`（插件 SSRF 面）、
  `/api/plugins/agent`（任意工具执行）、`/api/tts`（计费面）、`/api/oobe`
  （改写工作区根）、`/api/ai/image`、`/api/ai/settings`（用户自带密钥不得
  落服务器）。
- **登录限速**：`LoginRateLimiter` 滑动窗口（`gw_proxy.h:38`），连续失败
  锁定；配合 PBKDF2 抬高在线爆破成本。

### 2.3 SSRF 与出站请求（安全批次 A/B）

- **传输层禁自动重定向**：WinHTTP / curl / Android JNI 桥三层全部钉死
  NEVER；需要跟随的场景走 C++ 显式逐跳（上限 8 跳，`urllib` 折叠语义：
  303 或 301/302×POST → GET）。
- **跨源剥离**：逐跳检测同源性，跨源即剥离 `Authorization` / `Cookie` /
  `Cookie2` / `Proxy-Authorization` 等敏感头（token 不随 302 外泄）。
- **逐跳 SSRF 策略回调**：`Request::redirect_allowed`——云同步在
  `--cloud-public-only` 下把 `url_is_public_http` 护栏延伸到重定向链**每一
  跳**（首跳合法、302 跳内网的旁路已封堵）。
- **AI 中继注入墙**：`relay_chat` 转发前剥离 `protocol` / `base_url` /
  `baseUrl` / `api_key` / `apiKey`（控制键 + 注入键），上游主机只由服务端
  配置决定，调用方选主机零可能（`ai_relay_routes.cpp:94-102`）。
- **连接池**：curl easy handle 池（上限 8，池化句柄全选项重设防状态残留）
  与 WinHTTP 进程级共享 session——并发安全，性能见 §3。

### 2.4 AI 面板与工具门禁（安全批次 B）

- AI 领域工具（改条目 / 删条目 / 生图 / 改图 / 舞台编排等）一律带
  `confirm` 标记，执行前强制用户审批框（`frontend/lib/features/ai/ai_tools.dart`）；
  只读工具不设门槛，保持对话流。
- MCP 客户端（`features/ai/mcp/`）stdio 传输仅本地拉起、工具调用走同一
  确认通道；`mcp_client_test` / `mcp_settings_test` 固化契约。

### 2.5 网关口令与会话（安全批次 A）

见 §1：PBKDF2 v2 + 透明升级、登录限速。会话 Bearer token 机制与
`session_ttl_hours` 不变。

---

## 3. 性能波次（同程交付，非安全项）

| 项 | 内容 |
| --- | --- |
| 编辑器 P0 | 整表编码迁出 UI isolate（`putRaw` 等）、脏状态守卫（`editor_dirty_p0_test` 等 2 个 Widget 测试） |
| httpd | 响应体 `std::move` 透传、精确路由哈希表分流（~190 条 regex 路由先走精确表）、slots 64→192、keep-alive 空闲 65s→15s |
| 长任务 | `async=1` opt-in 202 job 队列（`/api/jobs/{id}`，4 worker，done TTL 15min）；前端 AI 对话/TTS/生图/云同步 6 端点接入 `runLongTask`，error 信封带 `status_code` |
| 云同步 | 全量同步逐文件传输并发化（`kCloudSyncWorkers=4`，`Driver::parallel_transfers()` 门控：Local/WebDAV/OpenList 并发，网盘驱动因懒刷新 token 保持串行）；结果按既定顺序重组，信封与串行版一致 |
| 编译 | MSVC `/GL + /LTCG`、GCC/Clang `-O3 -flto`（`CheckIPOSupported`，仅 Release） |

---

## 4. 验证记录

| 门槛 | 结果 |
| --- | --- |
| `actionlint`（5 个 workflow） | 0 error |
| `sa_tests`（WSL GCC Release, `-flto`） | 423 用例 / 422 passed / 1 skipped（`[network]` 真实 HTTPS）/ 0 fail |
| `sa_tests`（cloud_sync 并发化后复跑） | 见合入前最终记录，无回归（新增并发不改变信封契约） |
| MSVC `/GL + /LTCG` 全量构建 | 通过（`build.cmd` Release 门） |
| `flutter analyze --no-pub` | 改动文件 0 error（5 个遗留 warning 在无关 `story_*` 文件） |
| Flutter 定向测试 | save_service(8) / ai_client(7) / ai_policy_relay(16) / ai_image_settings(4) / ai_skills(13) / story_unsaved_guard(6) = 54/54 |
| 遗留失败（非本轮引入） | `test/ai_event_plan_test.dart` 4 例：在途 `event_plan_flow.dart` 新代码的 patch 形状/文案断言与测试预期不一致，与本轮改动无关 |

---

## 5. 用户侧待办（需要发布者手工完成）

1. **配置正式 Android keystore 并下架 debug 签名包**：当前 CI 在缺 keystore
   时会回落 debug 签名发版（`build.gradle.kts:80+`）。请把正式 keystore 纳入
   CI secrets（或本地签名后手动传包），并**撤下已发布的 debug 签名 APK**——
   debug 签名可被同签名应用冒充覆盖安装，且后续换正式签名后用户需卸载重装。
2. **历史网关账号升级确认**：老 `gateway.json` 账号首次登录即自动升级
   PBKDF2 v2；上线新版后让全部账号登录一遍，确认 `gateway.json` 中口令行
   已变为 v2 格式后，可考虑在运维侧禁用更早的备份副本。
3. **混合版本部署**：新版后端要求 `X-Backend-Token`（无 token 的 `/api/*`
   请求 403）。GUI / 网关 / CLI / TUI / 前端需同批升级，不要让旧版 CLI/TUI
   连新版后端。

---

## 6. 残留风险与建议（下批次候选）

- **Actions 仍为 tag 引用**（`actions/checkout@v4` 等）：建议后续按 commit
  SHA pin + 注释版本号，第三方 action（`subosito/flutter-action` 等）优先。
- **网关自身默认监听 0.0.0.0**（公网入口形态）：务必置于 Caddy TLS 之后，
  防火墙只对 Caddy 放行；实例 backend 已强制 127.0.0.1。
- **本地 AI 密钥明文存于 `.editor_ai`**：桌面单用户形态的设计取舍（密钥
  不上送、中继剥离已做）；如需再收紧可接 OS keychain。
- **jobs 结果存内存**（done TTL 15min）：进程重启即丢；对编辑器交互场景
  可接受，做持久化任务需换存储后端。
- **`parallel_transfers()` 的边界依赖驱动现状**：OpenList 当前无 token 自改
  代码（判定并发的依据）；上游若引入刷新逻辑需同步复查（已写注释锚点）。
