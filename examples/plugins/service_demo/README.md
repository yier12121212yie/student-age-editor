# service_demo — HTTP 服务插件示例

声明型插件（`flow_cards_demo` / `hello_plugin`）不运行任何代码；本示例演示另一种
形态：**插件是一个独立进程**，监听 loopback HTTP，后端只做「自描述拉取 + 代理转发」
（`PLUGIN_GUIDE.md` §5）。适合动态面板内容、Agent 工具这类确需代码贡献的场景。

## 三步跑通

1. **安装**：把本目录放进编辑器的 `plugins/` 根（即 `<编辑器目录>/plugins/service_demo/`，
   目录名即插件 id）。也可以在插件页用 zip 安装（zip 内须有 `manifest.json`）。
2. **起服务**：`python service.py`（仅用标准库，监听 `127.0.0.1:39211`）。
3. **重载**：插件页点「重载」（或重启编辑器）。列表里 `service_demo` 显示正常即
   自描述拉取成功；剧情图的「添加节点」菜单会出现插件卡片「掷骰子」。

## 它演示了什么

| 能力 | 入口 |
| --- | --- |
| 贡献流程卡片 | `GET /plugin.json` 的 `flow_cards`（与声明型卡片同线格式，经同一字段白名单） |
| 动态面板内容 | 插件页打开未声明的面板 `live` 时，后端代理 `GET <url>/panel/live` |
| Agent 工具 | AI 面板的工具列表来自 `plugin.json` 的 `agent_tools`；调用经 `POST /api/plugins/agent/exec` 转发到 `/agent/exec`，服务返回 `{"result": ...}` |
| 通用代理 | 任意 `GET/POST/PUT/DELETE /api/plugins/service/service_demo/<subpath>` 原样转发到 `<url>/<subpath>`（超时 10s，附 `X-Plugin-Id` 头） |

## 注意

- `service.url` 只允许 `http://127.0.0.1:<端口>` / `http://localhost:<端口>`，且必须
  写明端口；不合规的声明会在插件行 `error` 字段报 `invalid service url: ...`。
- 后端**不会**拉起或杀掉服务进程：本脚本退出后，插件页显示服务不可用（502），
  自描述缓存停留在最后一次「重载」的结果。
- 自描述只在「启动 / 重载 / 安装」时拉取；GET 类端点读缓存、不触网。
