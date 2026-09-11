# flow_cards_demo — 声明型流程卡片示例

这是一个**声明型插件**：整个插件就是「一个目录 + 一个 `manifest.json`」，没有任何
代码（无 `plugin.py`、不执行任何东西）。把本目录放进插件根
（`EDITOR_PLUGINS_ROOT`，缺省 `<editor_root>/plugins`）即生效，**没有启用 / 停用态**。

- 插件 id = 目录名 `flow_cards_demo`。
- `ui.flow_cards` 声明两张卡片：`phone`（对白，`screenEffect` 含 `4007`）与
  `confess`（选项，`content` 为 `"表白"`）。
- 后端不解释 `match`：它只是声明式谓词描述，由前端剧情图工作区注册表消费；
  聚合端点为 `GET /api/plugins/ui/flow_cards` → `{"flow_cards":[...]}`（注入 `plugin_id`）。

字段语义见仓库根 `PLUGIN_GUIDE.md` 与 `native/PLUGIN_SPEC.md`（唯一真相源）。
