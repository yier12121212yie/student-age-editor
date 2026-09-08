# 插件体系规范（C++ 后端）—— 声明型 manifest + 可选 HTTP 服务插件

状态：规范冻结（波次 3，编排者）。§5 的实现改造在波次 3 合并后的正树窗口执行。
决策依据：迁移计划决策 2「废弃进程内 Python 插件」——后端重写为单一 C++ 可执行文件后，
进程内加载 Python 代码在机制上不成立；插件能力收缩为两种安全形态。

## 1. 目录与发现

- 插件根：`EDITOR_PLUGINS_ROOT`，缺省 `<editor_root>/plugins`（与 `plugin_system.plugins_root()` 一致，
  C++ 侧 `plugins_root()` 已对齐，含 best-effort mkdir）。
- 每个插件一个子目录，目录名即插件 id。id 约束沿用 Python：`^[a-z][a-z0-9_-]{0,63}$`，
  且不得为 RESERVED_IDS 保留名。
- 目录内必有 `manifest.json`（UTF-8，允许 BOM，读取按 utf-8-sig；解析失败/非对象 → 整个插件忽略，不报错）。
- 扫描排序：目录名升序（listdir_sorted），跨实现确定。

## 2. manifest.json 模式

```json
{
  "id": "my_cards",
  "name": "示例卡片包",
  "version": "1.0.0",
  "author": "...",
  "description": "...",
  "ui": {
    "flow_cards": [ { "type_id": "...", "...": "..." } ]
  },
  "service": { "url": "http://127.0.0.1:39211", "name": "..." }
}
```

- `id/name/version/author/description`：元数据；`name` 缺省取目录名。
- `ui.flow_cards`：声明型流程卡片贡献（顶层 `flow_cards` 亦接受，兼容演示包）。
- `service`：§4 HTTP 服务插件声明。两者可并存；都没有的 manifest 只是元数据占位。
- 未知字段一律忽略（向前兼容）。**不存在任何可执行入口字段**：Python 时代的
  `entry`/`plugin.py` 在 C++ 后端无消费者，出现也仅按原样透传于详情响应。

## 3. 声明型贡献：flow_cards（已实现）

- `GET /api/plugins/ui/flow_cards` → `{"flow_cards":[...]}`，聚合语义（`declarative_flow_cards()`）：
  逐插件目录读 manifest，取 `ui.flow_cards`（或顶层 `flow_cards`）数组元素，
  白名单字段透传：`type_id, name, icon, color, applies_to, match, body_fields, hidden_ports, description`，
  注入 `plugin_id`＝目录名，按 pid 升序拼接。单元素非对象 → 跳过。
- `match` 为声明式识别条件（对行数据的谓词描述），由前端剧情图工作区注册表消费；
  后端不解释、不执行——这是「声明型」的含义：插件不运行任何代码。

## 4. HTTP 服务插件（规范先行，未实现）

面向确需代码贡献的场景：插件是**独立进程**，监听 loopback HTTP；后端只做聚合与代理。

- 声明：manifest `"service": {"url": "http://127.0.0.1:<port>", "name": "..."}`。
  url 仅允许 `127.0.0.1/localhost`；端口任意（约定 39xxx 段）。
- 自描述：服务须在 `GET <url>/plugin.json` 返回与 §3 同字段的贡献声明
  （`flow_cards` 数组），可选 `panels`、`agent_tools`。后端启动/`reload` 时拉取并缓存，
  拉取失败记入该插件 `error` 字段，不影响其它插件。
- 代理：`POST /api/plugins/service/<pid>/<subpath>` → 转发到 `<url>/<subpath>`（body 原样、
  超时 10s），响应原样返回；服务未就绪 → 502 `{"error": "plugin service unavailable"}`。
- 生命周期：后端**不**负责拉起/杀掉服务进程（与旧引擎 enable/disable 语义不同，写进文档避免误解）。

## 5. /api/plugins* 端点对齐表与待办

| 端点 | Python 语义 | C++ 现状 | 目标（波次 3 合并后实现） |
| --- | --- | --- | --- |
| GET /api/plugins | 已加载插件列表（entry 形状含 loaded/enabled/error/risk_ack_at） | 恒 `{"plugins": []}` 桩 | 枚举 §1 目录 + manifest 合成条目：`enabled:true`、`loaded:true`、`error:""`、`risk_ack_at:""`（无代码即无风险确认环节），形状逐字段保持 Python |
| GET /api/plugins/\<pid\> | 单插件详情 | 恒 404 | 命中目录 → 详情；否则 404 `{"error": "plugin not found"}` |
| GET /api/plugins/ui | 面板贡献聚合 | 恒 `{"panels": []}` | 保持空 + manifest `ui.panels` 数组透传（字段白名单待定） |
| GET /api/plugins/ui/flow_cards | 代码注册聚合 | 已声明型实现 | 不变；后续并入 service 自描述结果 |
| POST /api/plugins/install、install_path | zip 解压安装（安全校验、补 manifest、默认停用） | 未注册（404） | 保留安装面：zip 校验沿用 Python 条目规则（绝对路径/`..`/盘符拒绝），**默认即可用**（无 enable 态）；无 `entry` 存在性检查 |
| POST /api/plugins/reload | 重新 import 全部 | 未注册 | 重扫目录 + 重拉 service 自描述，返回与 GET /api/plugins 同形状 |
| POST /api/plugins/enable、disable、uninstall | 引擎生命周期 | 未注册 | enable/disable 永久废弃（返回 410 不保留，前端本无入口则直接不注册）；uninstall 保留为纯删目录（安全校验同安装） |
| POST /api/plugins/agent/exec | 进程内执行插件工具 | 未注册 | 废弃；agent 工具贡献走 §4 service 代理 |

兼容性红线：以上任何改造不得改动现有 4 个 golden（`api_plugins*.json` 在 bare 环境＝空集合/404，
目标实现同样在 bare 环境成立）；selftest 中涉及 plugins 的用例保持通过。

## 6. 演示与迁移示例

- Python 时代示例 `flow_cards_demo`（register_flow_card 代码贡献）→ 等价声明形态：
  仅保留其 manifest，把卡片注册调用翻译为 `ui.flow_cards` JSON 数组，字段一一对应。
  示例目录待波次 4 文档重写时移入 `examples/plugins/flow_cards_demo/`。
