# hello_plugin — 声明型 UI 面板示例

这是一个**声明型插件**：整个插件就是「一个目录 + 一个 `manifest.json`」，没有任何
代码（无 `plugin.py`、不执行任何东西）。把本目录放进插件根
（`EDITOR_PLUGINS_ROOT`，缺省 `<editor_root>/plugins`）即生效，**没有启用 / 停用态**。

- 插件 id = 目录名 `hello_plugin`。
- `ui.panels` 声明一个面板（`panel_id` / `title` / `icon` / `description`）。
- 聚合端点为 `GET /api/plugins/ui` → `{"panels":[...]}`；后端逐字段透传并注入
  `plugin_id`（声明里自带 `plugin_id` 时以其为准）。

> 旧 Python 版此示例还演示路由 / Agent 工具 / CLI 命令 / 面板内容路由，这些在当前
> 声明型规范中**均无对应**（`service` HTTP 插件为规范先行、未实现）。这里只保留
> 能被声明型后端消费的面板声明；面板字段集保持开放，见 `native/PLUGIN_SPEC.md` §3、§5。
