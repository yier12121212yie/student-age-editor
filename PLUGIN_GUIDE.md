# 学生时代 模组编辑器 — 插件系统指南

> 插件系统允许第三方用 Python 扩展编辑器：注册 HTTP 路由 / AI Agent 工具 /
> GUI 声明式面板 / CLI 命令。本文档面向插件作者与需要管理插件的用户，
> 完整可运行范例见 [`examples/plugins/hello_plugin`](examples/plugins/hello_plugin)。

---

## 1. 插件是什么 / 安全模型

插件是**可信的本地 Python 代码**。安装插件只会把文件放到本机插件目录，
不会执行；真正执行发生在**启用**之后：

- 启用 = 以**与编辑器相同的用户权限**运行第三方 Python，可读写本机文件、
  访问网络、甚至调用系统命令。请只安装你信任的来源的插件。
- **安装默认停用**。安装只是落盘（解压 + 登记到 `plugins.json`），不会加载执行。
- **启用是唯一闸门**。三端（GUI / CLI / TUI）每次启用都会弹出**高危确认**
  （GUI 对话框 / CLI `y/N` / TUI 确认框），确认后服务端才写入
  `risk_ack_at` 留痕，并持久化到 `plugins.json`。
- **服务端强制校验 risk_ack**，无法绕过：即使直接调 HTTP 接口，启用请求
  里不带 `risk_ack: true` 也会被拒绝（返回 400）。
- 单个插件加载失败会被隔离：错误记入该插件条目（`error` 字段），
  不影响其它已启用插件；加载失败时可安全停用 / 卸载。

## 2. 目录与 manifest

### 插件根目录

- 环境变量 `EDITOR_PLUGINS_ROOT` 可以覆盖（测试 /**发展**插件时用它，避免污染真实数据）。
- 默认 `<app_data_dir>/plugins/`（开发模式为 `backend/` 同目录下的 `plugins/`；
  发行版为 exe 同目录或平台用户数据目录，见 `backend/editor/core/paths.py`）。

```
plugins/
├── plugins.json          # 安装登记：{ pid: { enabled, risk_ack_at } }（原子写）
└── hello_plugin/
    ├── manifest.json      # 插件元数据（见下表）
    ├── plugin.py          # 入口：提供 def setup(ctx)（entry 字段可改名）
    └── data/              # ctx.data_dir，首次访问时懒创建，推荐放私有数据
```

### manifest 字段

| 字段 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | string | 否* | 从文件名生成 | 唯一标识，见下方 id 规则 |
| `name` | string | 否 | = `id` | 显示名称 |
| `version` | string | 否 | `"1.0.0"` | 版本号 |
| `author` | string | 否 | `""` | 作者 |
| `description` | string | 否 | `""` | 描述 |
| `entry` | string | 否 | `"plugin.py"` | 入口文件（须含可调用 `setup(ctx)`） |

\* zip 内 `manifest.json` 缺 `id` 时，由 zip 文件名自动生成（小写、非法字符
转下划线、首字符非字母加 `p_` 前缀、截断至 64 字符）。**建议总是显式写 `id`**。

### id 规则与保留

- 必须匹配 `^[a-z][a-z0-9_-]{0,63}$`（小写字母开头，可含数字/`_`/`-`，最长 64）。
- 保留 id 禁止安装：`agent`、`ui`、`reload`、`install`、`install_path`。

### zip 安装语义

- zip 根须含 `manifest.json` 与 `plugin.py`（或 manifest `entry` 指定的入口文件）。
- 条目安全校验：拒绝绝对路径 / `..` 穿越 / 含 `:` 的条目。
- 安装即**默认停用**；目标目录已存在 → 拒绝（如已存在请先卸载）。
- **更新 = 卸载后重装**：插件系统没有覆盖式更新，先停用并卸载再用新 zip 安装。

## 3. PluginContext API

每个插件在 `setup(ctx)` 时拿到 `PluginContext`，`setup` 结束后上下文即失效，
四类贡献**只能在 `setup(ctx) 执行期间注册**（期间之外的调用抛错）。

| 成员 | 签名 | 说明 |
| --- | --- | --- |
| `ctx.pid` | str | 插件 id |
| `ctx.plugin_dir` | str | 插件目录绝对路径 |
| `ctx.data_dir` | str | `数据目录 <plugin_dir>/data/`（懒创建，可读写） |
| `ctx.manifest` | dict | 当前 manifest 原样 |
| `ctx.log(msg)` | (str) | 打印 `[plugin:<id>] <msg>` |

### register_route：HTTP 路由

```python
ctx.register_route("GET", "greet", greet_fn)
```

- `pattern` 是**相对前缀正则**，挂载后完整路径为 `/api/plugins/<id>/<pattern>`，
  对请求路径做 **fullmatch（整串全匹配）**，例如 `greet` 精确匹配
  `GET /api/plugins/hello_plugin/greet`。
- 因此 pattern 写裸相对路径即可（如 `greet`、`panel/main`），可用 `$` 收尾；
  **不要以 `^` 开头**——前缀已占据路径开头，`^...$` 的整锚写法永远匹配不上。
- `fn` 约定 `fn(query, body) -> (status: int, payload: dict)`；
  `query` / `body` 为解析后的请求参数（未提供时为 `{}`）。
- 路由以 `owner=plugin:<id>` 挂载，插件停用 / 重载时自动注销。

### register_tool：Agent 工具

```python
ctx.register_tool("dice", "掷骰子演示只读工具",
                  {"type": "object", "properties": {...}},
                  roll_fn, readonly=True, confirm=False)
```

- Agent 侧全名为 `<id>__<name>`（如 `hello_plugin__dice`），同名冲突按插件隔离。
- `fn(args: dict, confirm) -> str`：`args` 是模型填入的参数字典；`confirm` 参数
  在只读 / 免确认工具下可能为 `None`，实现要容忍。
- `readonly=True`：只读工具，只读克隆（子代理 / 调研任务）也能看到并调用。
- `confirm=True`：高危写工具，必须经用户确认后才执行（见第 5 节）。

### register_command：CLI 命令

```python
ctx.register_command("greet", "打个招呼", cmd_fn)
```

- CLI 侧全名为 `<id>.<name>`（如 `hello_plugin.greet`）。
- `fn(args: str) -> None`：`args` 为命令后的剩余参数串；输出用 `print`。

### register_panel：UI 面板

```python
ctx.register_panel("main", "Hello 面板", "extension", "面板描述")
```

- 只负责**声明**（面板 id / 标题 / 图标名 / 描述），出现在 GUI 插件页 / AI 面板栏。
- **面板内容由插件自己注册路由提供**：注册 `GET` 路由
  `panel/<panel_id>`（如 `panel/main`），返回 `{"title", "blocks"}`
  （协议见第 4 节）。图标名参照 `frontend/lib/features/plugins/plugin_pane.dart`
  的映射表（`extension` / `box` / `apps` / `stats` / `wrench` 等），未知回退扩展图标。

## 4. UI blocks 协议

面板渲染器（`plugin_pane.dart`）拉
`GET /api/plugins/<id>/panel/<panel_id>` 渲染 `{"title", "blocks"}`。
块是一个 JSON 数组，五种类型各一块即可看全效果：

```jsonc
{
  "title": "Hello 面板",
  "blocks": [
    // 1) markdown：一段说明
    { "type": "markdown", "text": "## 标题\n\n**粗体** *斜体* `代码`" },

    // 2) stats：两三项统计卡片（label/value 均为字符串）
    { "type": "stats", "items": [
      { "label": "启用时间", "value": "2026-08-29 10:00:00" },
      { "label": "示例计数", "value": "3" }
    ] },

    // 3) table：columns 表头，rows 每行为等长字符串数组
    { "type": "table", "columns": ["特性", "说明"],
      "rows": [["HTTP 路由", "GET greet"], ["Agent 工具", "dice"]] },

    // 4) form：text / number / select / checkbox 四类字段
    { "type": "form",
      "fields": [
        { "name": "nickname", "label": "昵称", "type": "text", "default": "同学" },
        { "name": "level",    "label": "等级", "type": "number", "default": 3 },
        { "name": "theme",    "label": "主题", "type": "select",
          "options": ["校园", "科幻", "古代"] },
        { "name": "news",     "label": "订阅更新", "type": "checkbox", "default": true }
      ],
      "submit": { "url": "panel/main/hello", "label": "提交" } },

    // 5) actions：普通按钮 + 带 confirm 的按钮
    { "type": "actions", "buttons": [
      { "label": "Ping", "url": "panel/main/ping" },
      { "label": "确认动作", "url": "panel/main/confirm_action",
        "confirm": "确定要执行这个演示动作吗？" }
    ] }
  ]
}
```

字段类型约定：

- `form.fields[].type`：`text` | `number` | `select`（需 `options`）| `checkbox`
  （`default=true/false`）。
- `form.submit` / `actions.buttons[].url` 都是**相对路径**：渲染器统一拼到
  `/api/plugins/<id>/` 之前（如 `panel/main/hello` →
  `/api/plugins/hello_plugin/panel/main/hello`）。
- `actions.buttons[]`：`method` 缺省 `POST`（可为 `GET`/`PUT`/`DELETE`；
  GET 时 `body` 参数并入 query）；`confirm` 为字符串时先弹确认框再请求；
  `body` 可携带附加参数。
- **动作响应协议**：`{"message": str?, "refresh": bool?}` —— `message` 非空则
  弹出提示条；`refresh == true` 则重新拉取面板内容。插件 POST 处理函数返回
  此结构即可。

## 5. Agent 工具约定

- **只读克隆**（`spawn_subagents` 派生的子代理）只暴露内置只读工具 +
  `readonly=True` 的插件工具；写工具严格拒绝（含插件写工具）。
- **`confirm=True` 工具必须确认**：
  - GUI：先弹确认框，确认后调 `POST /api/plugins/agent/exec`（该端点已本地确认，
    后端无条件放行当次执行）；
  - CLI / TUI：走审批回调（CLI 终端 `y/N`、TUI 弹窗），由用户逐次批准；
  - 无回调（无人确认）时返回 `"该工具需要用户确认"`，不会执行。
- 插件工具异常会被捕获并折算为 **“工具执行失败: …”** 回填给模型，不会中断会话。

## 6. CLI / TUI 约定

```powershell
python run_cli.py plugin list                    # 列出全部插件
python run_cli.py plugin info hello_plugin       # 详情（含四类贡献 / risk_ack_at）
python run_cli.py plugin install ./hello_plugin.zip   # 安装（默认停用）
python run_cli.py plugin enable hello_plugin     # 启用：高危确认 y/N
python run_cli.py plugin enable hello_plugin --yes    # 跳过高危确认（CI / 脚本）
python run_cli.py plugin disable hello_plugin    # 停用
python run_cli.py plugin uninstall hello_plugin  # 卸载（须先停用）
python run_cli.py plugin reload                  # 重载全部已启用插件（改代码后生效）
```

- `--yes` = 显式认可高危确认（等价 GUI 已确认），服务端照常写 `risk_ack_at`。
- 已启用插件注册的 CLI 命令按 `<id>.<name>` 直接调用：
  `python run_cli.py hello_plugin.greet 同学`。
- REPL（`python run_cli.py` 无参进入）内 `/plugins` 可查看与操作插件；插件命令
  同样可按全名直接输入。
- TUI 插件屏：**空格** = 启用 / 停用（启用走确认框）、**i** = 详情、**r** = 重载、
  **d** = 卸载。详见 `CLI_TUI_GUIDE.md`。

## 7. 三端行为差异表

| 操作 | GUI（插件页 / 面板渲染器 / AI 工具） | CLI | TUI |
| --- | --- | --- | --- |
| 查看 | 插件页列表、面板栏 | `plugin list` / `plugin info` | 插件屏 |
| 安装 | 插件页传 zip / 本地路径 | `plugin install <zip>` | 插件屏内安装（默认停用） |
| 启用 | 高危确认**对话框** | `plugin enable`，`y/N` 确认；`--yes` 跳过 | 空格，走**确认框** |
| 停用 | 停用按钮 | `plugin disable` | 空格（再次） |
| 卸载 | 须先停用 | `plugin uninstall`（须先停用） | `d`（须先停用） |
| 重载 | 重载按钮 | `plugin reload` | `r` |
| risk_ack 记录 | 确认后服务端写 `risk_ack_at`；**三端同一份记录、同一闸门，无法绕过** |

面板渲染与 AI 工具为 GUI 专属入口；CLI / TUI 用自身命令与快捷键操作同一套后端。

## 8. 示例

完整可运行范例：`examples/plugins/hello_plugin/`，一个插件同时演示了
路由（`GET greet`）、五种块全面板（`panel/main`）、表单 / 动作 POST、
只读 Agent 工具（`hello_plugin__dice`）与 CLI 命令（`hello_plugin.greet`）。

打包成 zip（zip **根**目录直接包含 `manifest.json` 与 `plugin.py` 即可）：

```bash
cd examples/plugins/hello_plugin
zip -r ../../hello_plugin.zip manifest.json plugin.py data
```

然后用任一端安装并启用；启用前会看到高危确认。快速自测（纯后端，不装进真实目录）：

```bash
T=$(mktemp -d)
cp -r examples/plugins/hello_plugin "$T/hello_plugin"
cd backend
EDITOR_PLUGINS_ROOT="$T" python -c "
from editor.core import plugin_system
plugin_system.set_enabled('hello_plugin', True, risk_ack=True)
print(plugin_system.get_plugin_info('hello_plugin')['contributions'])
print(plugin_system.agent_exec('hello_plugin__dice', {}))
print(plugin_system.dispatch_plugin_route('hello_plugin', 'GET', 'greet', {}, {}))
"
rm -rf "$T"
```

（在 `backend/` 目录下运行以保证 `import editor` 可用；验证后删除临时目录。）

## 五、流程卡片贡献（剧情图模式）

插件可以注册**流程卡片**（第五类贡献，声明型、无执行体），让「剧情图」模式
（第三种 GUI）的节点画布按插件定义渲染特定对白/选项，并在「添加节点」菜单中
提供卡型入口。

注册 API（仅 `setup(ctx)` 期间可用）：

```python
ctx.register_flow_card("type_id", {
    "name": "卡片显示名",            # 必填
    "applies_to": "talk|option",     # 必填：作用对象（对白节点/选项节点）
    "color": "#RRGGBB",              # 可选：卡片主色
    "icon": "",                      # 可选：图标名（预留）
    "match": {"field": "screenEffect", "equals": [4007]},  # 可选：识别规则
    "body_fields": ["content"],      # 可选：卡片正文优先展示字段
    "hidden_ports": [],              # 可选：隐藏的输出端口名
    "description": "描述",
})
```

作用：

- 开启后，画布节点命中 `match`（字段值等于 `equals`，嵌套数组按整行比较）
  即按卡型渲染（着色 + 标题后缀卡名）；
- 「添加节点」菜单出现 `插件卡片 · <名称>` 项，新建节点时预置 `match` 字段，
  使其立即按卡型渲染。

完整示例见 `examples/plugins/flow_cards_demo`（对白卡「打电话」/ 选项卡「告白选项」）。
与面板一样，卡片注册不执行任何插件代码，启用时仍需高危确认。