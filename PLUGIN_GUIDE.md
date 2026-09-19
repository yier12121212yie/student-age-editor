# 学生时代 模组编辑器 — 插件系统指南

> 插件系统允许第三方以**声明**方式扩展编辑器：贡献**流程卡片**（剧情图模式的
> 卡型）、**UI 面板**，以及由**独立进程**提供的 **HTTP 服务插件**（自描述 +
> 代理，见第 5 节）。
>
> 本指南以 [`native/PLUGIN_SPEC.md`](native/PLUGIN_SPEC.md) 为唯一真相源。C++ 后端
> 废弃了进程内 Python 插件：插件**只是「目录 + `manifest.json`」的静态声明，
> 不执行任何代码**，因此没有启用 / 停用状态（安装即可用、常开），也没有「启用高危
> 确认」。

---

## 1. 插件是什么 / 安全模型

- 插件是一个目录，内含 `manifest.json` 声明文件。安装插件只是把文件放到本机插件
  目录，**从不加载或执行代码**——这是「声明型」的核心。
- 因为不执行代码，插件**没有权限**：不能读写本机文件、不能访问网络（服务插件形态
  例外，见第 5 节）、不能调用系统命令。旧 Python 版「以编辑器同权限运行第三方
  Python」的风险模型已不存在。
- 由于无代码即无风险，插件**没有启用 / 停用闸门**：安装完成后其声明立即生效
  （常开）；旧版的 `risk_ack_at` 留痕、三端高危确认全部废弃。
- 单个插件 `manifest.json` 解析失败或非对象时，该插件被**整体忽略且不报错**，
  不影响其它插件。
- 后端会合成插件的 `enabled` / `loaded` 字段（恒 `true`）与 `risk_ack_at`（恒 `""`），
  以保持与旧响应形状的兼容；它们不再代表任何可切换状态。`error` 恒 `""`，**例外**是
  服务插件（第 5 节）：自描述拉取失败 / 声明不合规时会把原因写进 `error`，并附带
  `service_status`（`ok` / `url` / `name` / `checked`）。

## 2. 目录与发现

- 插件根由环境变量 `EDITOR_PLUGINS_ROOT` 指定，缺省 `<editor_root>/plugins`
  （C++ 侧 `plugins_root()` 已对齐，含 best-effort mkdir）。
- 每个插件一个子目录，**目录名即插件 id**。id 约束沿用旧规则：
  `^[a-z][a-z0-9_-]{0,63}$`（小写字母开头，可含数字 / `_` / `-`，最长 64），
  且不得为保留名 `agent`、`ui`、`reload`、`install`、`install_path`、`service`。
- 目录内必有 `manifest.json`（UTF-8，允许 BOM，读取按 `utf-8-sig`）。
- 扫描排序：目录名升序，跨实现确定；`__pycache__` 目录被排除。

```
plugins/
└── my_cards/
    └── manifest.json      # 插件元数据 + 声明型贡献（唯一必需文件）
```

## 3. manifest.json 字段

```json
{
  "id": "my_cards",
  "name": "示例卡片包",
  "version": "1.0.0",
  "author": "...",
  "description": "...",
  "ui": {
    "flow_cards": [ { "type_id": "...", "name": "..." } ],
    "panels":     [ { "..." : "..." } ]
  },
  "service": { "url": "http://127.0.0.1:39211", "name": "..." }
}
```

| 字段 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | string | 否 | 取目录名 | 插件标识；建议显式写且与目录名一致 |
| `name` | string | 否 | = `id`（目录名） | 显示名称 |
| `version` | string | 否 | `"1.0.0"` | 版本号 |
| `author` | string | 否 | `""` | 作者 |
| `description` | string | 否 | `""` | 描述 |
| `ui.flow_cards` | array | 否 | — | 流程卡片声明（顶层 `flow_cards` 亦接受，兼容演示包） |
| `ui.panels` | array | 否 | — | UI 面板声明 |
| `service` | object | 否 | — | HTTP 服务插件声明（第 5 节） |

- 未知字段一律忽略（向前兼容）。
- **不存在任何可执行入口字段**：旧 Python 时代的 `entry` / `plugin.py` 在 C++
  后端无消费者，出现也仅按原样透传于详情响应。
- `ui.flow_cards` 与 `service` 可并存；两者都没有的 manifest 只是元数据占位。

## 4. 声明型贡献

### 4.1 流程卡片（flow_cards）

流程卡片让「剧情图」模式（第三种 GUI）的节点画布按插件定义渲染特定对白 / 选项，
并在「添加节点」菜单中提供卡型入口。插件在 `ui.flow_cards` 数组里逐项声明：

```json
{
  "ui": {
    "flow_cards": [
      {
        "type_id": "phone",
        "name": "打电话",
        "applies_to": "talk",
        "color": "#3498DB",
        "match": { "field": "screenEffect", "equals": [4007] },
        "body_fields": ["content"],
        "description": "屏幕效果 4007（打电话）模式的对白卡"
      }
    ]
  }
}
```

字段白名单：`type_id`、`name`、`icon`、`color`、`applies_to`、`match`、
`body_fields`、`hidden_ports`、`description`；后端另注入 `plugin_id`（= 目录名），
按 pid 升序拼接。单元素非对象则跳过。

- `applies_to`：`talk`（对白节点）/ `option`（选项节点）。
- `match`：声明式识别条件（对行数据的谓词描述）；由前端剧情图工作区注册表消费，
  **后端不解释、不执行**——这正是「声明型」的含义。命中后画布节点按卡型着色并加
  名称后缀，同时「添加节点」菜单出现 `插件卡片 · <名称>`。
- 聚合端点：`GET /api/plugins/ui/flow_cards` → `{"flow_cards":[...]}`。

### 4.2 UI 面板（panels）

在 `ui.panels` 数组中声明面板，`GET /api/plugins/ui` 聚合返回
`{"panels":[...]}`，并注入 `plugin_id`（声明里自带 `plugin_id` 时以其为准），按 pid
升序。面板字段集**保持开放**（不设白名单），以便向前兼容。

> 与旧 Python 版的重要区别：面板不再由插件注册内容路由提供（声明型插件不执行代码）。
> 旧版「面板内容由插件自己注册 `GET panel/<id>` 返回 `{"title","blocks"}`」的 UI blocks
> 协议，由声明型「manifest description → markdown 块」承接；需要**动态**面板内容时走
> 第 5 节的服务插件：`GET /api/plugins/<pid>/panel/<panel_id>` 在声明查不到该面板且
> 插件声明了 service 时，代理 `GET <url>/panel/<panel_id>`。`<pid>/<rest>` 式的通用
> 代理回退**不存在**——代理只走显式的 `/api/plugins/service/<pid>/<subpath>` 形态。

## 5. HTTP 服务插件（已实现）

面向确需代码贡献的场景（如动态面板内容 / Agent 工具）：插件是一个**独立进程**，
监听 loopback HTTP；后端只做聚合与代理。可运行示例见
`examples/plugins/service_demo/`。

- 声明：manifest `"service": {"url": "http://127.0.0.1:<port>", "name": "..."}`。
  `url` 仅允许 `http://` + `127.0.0.1` / `localhost`，必须写明端口（约定 `39xxx` 段），
  可带路径前缀（不得含 `..`）。不合规声明 → 插件行 `error` = `invalid service url: ...`，
  代理回 400，绝不发请求。
- 自描述：服务须在 `GET <url>/plugin.json` 返回贡献声明（`flow_cards` 数组，可选
  `panels`、`agent_tools`）。后端在**启动**（总预算 4s）、`POST /api/plugins/reload`
  （同步全刷）、安装 / 卸载（单刷该 pid）时拉取并缓存（单次超时 1.5s、上限 2 MiB）；
  拉取失败记入该插件 `error` 字段，不影响其它插件。**所有 GET 端点只读缓存、不触网**，
  死服务不会拖慢轮询；`GET /api/plugins` 的行内 `service_status`（ok/url/name/checked）
  反映最近一次刷新结果。
- 聚合：`GET /api/plugins/ui/flow_cards`、`GET /api/plugins/ui`、
  `GET /api/plugins/agent/tools` = 声明型贡献（先）+ 各服务自描述（后），按 pid 升序、
  注入 `plugin_id`；服务卡片与声明型卡片走同一字段白名单，线格式一致。
- 代理：`GET/POST/PUT/DELETE /api/plugins/service/<pid>/<subpath>` → 转发到
  `<url>/<subpath>`（subpath 先 percent-decode 再 re-quote；query 原样；body 原样；
  超时 10s；附 `X-Plugin-Id` 头，客户端其余请求头不透传），上游 status / body /
  Content-Type 原样返回（body 上限 32 MiB）；服务未就绪 →
  502 `{"error": "plugin service unavailable"}`。代理现读 manifest、不依赖缓存。
- Agent 工具执行：AI 面板对 `POST /api/plugins/agent/exec` `{"name","args"}` 的调用，
  后端按缓存的 `agent_tools` 找到归属插件，转发到该工具声明的 `path`
  （缺省 `/agent/exec`），返回体原样透传（前端读 `{"result": ...}`）；未命中 →
  404 `{"error": "unknown plugin tool: <name>"}`。
- 出站加固：服务插件相关出站请求一律绕过系统代理（loopback 不被企业代理截胡）且
  不跟随重定向（3xx 跳到非 loopback 即绕过白名单）。
- 生命周期：后端**不负责**拉起或杀掉服务进程。服务进程退出后，代理回 502，
  列表 `error` 在下次刷新时更新。

## 6. 安装 / 卸载 / 重载

插件为**常开**，没有 `enable` / `disable`（该端点已废弃，调用返回 410）。

| 操作 | 端点 | 说明 |
| --- | --- | --- |
| 安装 zip | `POST /api/plugins/install` | JSON body `{"data": "<zip 的 base64>", "filename": "..."}`，zip ≤ 100MB |
| 按路径安装 | `POST /api/plugins/install_path` | JSON body `{"path": "...", "filename": "..."}` 指向本地 zip |
| 卸载 | `DELETE /api/plugins/<pid>` | **纯删目录**，无启用态可清理 |
| 重载 | `POST /api/plugins/reload` | 重扫目录 + 同步重拉 §4 服务自描述（总预算 4s），返回与 `GET /api/plugins` 同形状 |
| 列表 / 详情 | `GET /api/plugins`、`GET /api/plugins/<pid>` | 由目录 + manifest 合成 |
| 启用 / 停用 | `POST /api/plugins/<pid>/enable\|disable` | **已废弃，恒 410** |
| Agent 工具执行 | `POST /api/plugins/agent/exec` | **已废弃，未注册（404）** |

安装语义：

- zip 条目安全校验沿用旧规则：拒绝绝对路径 / `..` 穿越 / 含 `:` 的条目。
- **不再要求 `plugin.py` / entry 存在性检查**：只含 `manifest.json` 的声明型插件即可安装。
- 安装后**立即可用**（无默认停用）；目标目录已存在则拒绝（先卸载再装）。
- 旧版的 `plugins.json` 安装登记 / 启用状态文件**不再写入**。
- 更新 = 卸载后重装（无覆盖式更新）。

## 7. 端点一览

| 端点 | 旧 Python 语义 | native C++ 现状 |
| --- | --- | --- |
| `GET /api/plugins` | 已加载插件列表 | 枚举目录 + manifest 合成（`enabled`/`loaded`=true，`risk_ack_at`=""）；服务插件行另带 `error`（刷新失败原因）与 `service_status` |
| `GET /api/plugins/<pid>` | 单插件详情 | 命中目录 → 详情；否则 404 `{"error":"plugin not found"}` |
| `GET /api/plugins/ui` | 面板贡献聚合 | manifest `ui.panels` 透传 + §4 服务 `panels`，注入 `plugin_id` |
| `GET /api/plugins/ui/flow_cards` | 代码注册聚合 | 声明型 `ui.flow_cards` 聚合 + §4 服务 `flow_cards`（同一字段白名单） |
| `GET /api/plugins/agent/tools` | 插件工具定义 | §4 服务 `agent_tools` 聚合（声明型无工具贡献；缓存只读） |
| `POST /api/plugins/install` / `install_path` | zip 解压安装、默认停用 | 保留安装面，**默认即可用**；无 entry 检查；装后单刷该 pid 的服务自描述 |
| `POST /api/plugins/reload` | 重新 import 全部 | 重扫目录 + 重拉 §4 自描述（声明型无需 import） |
| `POST /api/plugins/<pid>/enable\|disable` | 引擎生命周期 | **恒 410**（常开无启用态） |
| `DELETE /api/plugins/<pid>` | 卸载 | 纯删目录，并清该 pid 的服务缓存项 |
| `POST /api/plugins/agent/exec` | 进程内执行插件工具 | **路由到 owning service 代理**（§4；未命中 404 `unknown plugin tool`） |
| `GET/POST/PUT/DELETE /api/plugins/service/<pid>/<subpath>` | —（新增形态） | **§4 代理**：转发到 `<service.url>/<subpath>`，超时 10s；未就绪 502 |
| `GET /api/plugins/<pid>/panel/<panel_id>` | 面板内容 | 声明型 → markdown 块；声明查不到且插件有 service → 代理动态内容 |

## 8. 三端行为差异

| 操作 | GUI | CLI | TUI |
| --- | --- | --- | --- |
| 查看插件 | 插件页列表 | 无 plugin 命令 | 无插件屏 |
| 查看流程卡片 | 剧情图模式消费 `flow_cards` | — | — |
| 安装 / 卸载 / 重载 | 插件页 | 无 | 无 |

> native 后端下 CLI / TUI **没有 plugin 子命令**（旧版的 `plugin list/info/install/
> enable/disable/uninstall/reload` 未移植），也没有「启用的插件注册 CLI 命令」机制；
> 插件管理与流程卡片消费在 GUI。

## 9. 示例

声明型插件最小可用形态（目录 `plugins/my_cards/`）：

```json
{
  "id": "my_cards",
  "name": "示例卡片包",
  "version": "1.0.0",
  "author": "示例作者",
  "description": "声明两张流程卡片",
  "ui": {
    "flow_cards": [
      { "type_id": "phone", "name": "打电话", "applies_to": "talk",
        "color": "#3498DB", "match": { "field": "screenEffect", "equals": [4007] },
        "body_fields": ["content"], "description": "屏幕效果 4007 的对白卡" },
      { "type_id": "confess", "name": "告白选项", "applies_to": "option",
        "color": "#E91E63", "match": { "field": "content", "equals": "表白" },
        "description": "表白类选项卡" }
    ]
  }
}
```

打包成 zip（zip **根**目录直接包含 `manifest.json` 即可，无需任何 `.py`）：

```bash
cd plugins/my_cards
zip -r ../../my_cards.zip manifest.json
```

然后用 GUI 插件页安装（或调 `POST /api/plugins/install_path`）即可生效——**没有启用
步骤，也不会再出现高危确认**。

> **关于 `examples/plugins/`**：仓库内的两个示例均已改写为**声明型插件**，不再含
> 任何 `.py` 或 `ctx.register_*` 代码：
> - `examples/plugins/flow_cards_demo/`：`ui.flow_cards` 声明对白卡 `phone` 与选项卡
>   `confess`，与上文内联 manifest 同构（可直接对照 §4.1）。
> - `examples/plugins/hello_plugin/`：`ui.panels` 声明一个面板，演示 `GET /api/plugins/ui`
>   的聚合形态（见 §4.2）；旧版的路由 / Agent 工具 / CLI 命令 / 面板内容路由在声明型
>   规范中无对应，已随 `plugin.py` 一并移除。
> - `examples/plugins/service_demo/`：**HTTP 服务插件**示例（§5）——`manifest.json`
>   声明 `service.url`，配套 `service.py`（仅标准库）提供 `/plugin.json` 自描述、
>   动态面板 `/panel/live` 与 Agent 工具 `/agent/exec`；README 有三步跑通指引。
>
> 前两者只是「目录 + `manifest.json`」：拷入插件根即生效，无代码、无启用态；服务插件
> 另需自行运行其服务进程（后端不代拉）。字段语义以 `native/PLUGIN_SPEC.md` 为唯一真相源。
