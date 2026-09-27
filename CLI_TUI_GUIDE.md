# 学生时代 模组编辑器 — CLI / TUI 指南

> 终端版编辑器，与 Flutter 图形版共用**同一套 native C++ 后端 HTTP API**（`127.0.0.1`
> 本地服务）与同一份 `Cfgs/zh-cn/*.json`。CLI / TUI 是各自独立的可执行文件
> （`backend_cli` / `backend_tui`，Windows 带 `.exe`），不再是 `backend tui` /
> `backend cli` 子命令，也不再有 Python 时代的 `run_cli.py` / `run_tui.py` /
> `editor_cmd.exe`。
>
> CLI 默认**内嵌自起**一个后端进程（临时端口，自调自），也可用 `--url` 打一个已在
> 运行的后端实例；TUI 则是纯客户端，**需要已有后端在运行**（`--url` / `--port`），
> 本身不启动服务。

---

## 1. 快速开始

### OOBE 首次使用引导

native CLI 把首次引导显式化为 `oobe` 子命令（`status` / `done` / `setup`），
完成标记写入 `editor_env.json` 的 `oobe_completed`，**CLI / TUI / GUI 三端共用**，
任一端完成后不再自动弹出。CLI **不会**在首次访问时自动弹出向导；`EDITOR_OOBE` /
`EDITOR_NO_OOBE` 环境变量由各消费方自理，CLI 不消费。

```powershell
# 查看是否首次运行 / 是否已完成
backend_cli oobe status

# 设置工作区、可选顺手建一个模组（默认同时标记 OOBE 完成）
backend_cli oobe setup --workspace D:\MyMods --mod FirstMod --desc "第一个模组"

# 顺带配置 AI 与云盘（后端 /api/oobe/setup 本身忽略这两项，
# CLI 会在 setup 之后追加真正的 PUT /api/ai/settings 与 POST /api/cloud/providers）
backend_cli oobe setup --workspace D:\MyMods --ai '{"permissionMode":"confirm","provider":"openai_compatible"}' --cloud-provider '{"name":"我的网盘","type":"webdav","config":{"url":"https://dav.example.com"}}'

# 只标记完成
backend_cli oobe done
```

### 环境要求

- 无需 Python / pip / Flutter：发行版为原生可执行文件，`backend_cli` /
  `backend_tui` 随包分发。
- `backend_cli` 默认内嵌自起后端，无需另开后端；`backend_tui` 无参启动时若默认端口
  8770 探测失败，会自起同目录的 `backend --port 8770` 并在退出时回收。
  显式指定 `--url` / `--port` / `P8_BACKEND_URL` 则只连接不自起，需先有一个后端在运行
  （GUI 启动的 `backend`，或手工 `backend --port 8770`）。
- 与 `127.0.0.1` 后端通信时自动读取数据根目录的 `.backend_token`（后端首次启动
  自动生成，权限 0600）并以 `X-Backend-Token` 头携带；配套版本的 GUI / 网关 /
  CLI / TUI 无需任何配置。注意：新版后端对不带令牌的 API 请求返回 403，
  请勿新旧版本混搭连接同一后端。
- workspace 默认：`%USERPROFILE%\AppData\LocalLow\PakyiGame\StudentAge\Mods`（与图形版一致）；
  也可通过 `editor_env.json` 或全局 `--workspace` 显式指定。

### 启动方式

```powershell
# CLI：内嵌自起后端（默认），子命令直挂
backend_cli --help
backend_cli mods list
backend_cli cfg get EvtCfg --mod test --id 320101

# CLI：打一个已在运行的后端（例如 GUI 已开 8765）
backend_cli --url http://127.0.0.1:8765 mods list

# TUI：连接已在运行的后端（默认 http://127.0.0.1:8770，可用 --url/--port 覆盖）
backend_tui --port 8765
backend_tui --url http://127.0.0.1:8765
```

### 发行版安装器提供的命令包装

Windows 安装器会视组件创建三个 PATH 包装（默认只勾选 CLI）：

| 包装命令 | 目标 |
| --- | --- |
| `editor-gui` | 主程序 `学生时代模组编辑器.exe` |
| `editor-cli` | `backend_cli.exe`（子命令直挂 `mods`/`cfg`/...） |
| `editor-tui` | `backend_tui.exe` |

---

## 2. CLI 使用

### 全局参数

```
--url URL          打已在运行的后端实例（省略则内嵌自起，随机临时端口）
--data-root DIR    数据根目录（EDITOR_DATA_ROOT；内嵌模式与 env 子命令使用）
--workspace DIR    工作区目录（内嵌模式 init_state 注入）
--mod NAME         本次命令使用的模组（等价旧 Python CLI 的每命令 --mod）
--json             原样输出后端 JSON 响应（便于管道）
--timeout SEC      HTTP 超时秒数
--version / --help
```

全局参数可放在子命令之前或之后（CLI11 fallthrough；如 `backend_cli cfg list --mod test`
与 `backend_cli --mod test cfg list` 等价）。

### 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 后端业务错误（非 2xx 响应 / 选择项不存在等），错误信封照常打印 |
| 2 | 用法错误（参数缺失或非法） |
| 3 | 传输失败（`--url` 指向的实例不可达 / 连接中断） |

### 模组管理

```powershell
backend_cli mods list                       # 列出全部（Mods + workshop）与当前选中
backend_cli mods list --json
backend_cli mods create MyMod --desc "xxx"  # 新建空模组（add 的别名）
backend_cli mods add MyMod --desc "xxx"     # 新建 / 导入
backend_cli mods add --path D:\Mods\SomeMod --name Imported   # 复制已有目录进工作区并选中
backend_cli mods add --zip .\mod.zip --name Imported          # 解包 zip 进工作区并选中
backend_cli mods select MyMod               # 选中（--root 可显式指定目录）
backend_cli mods remove MyMod               # 删除
```

### 配置表 CRUD

`Cfgs/zh-cn/*.json` 为 `{ id: record }` 字典。`cfg` 命令自动做 `Cfgs/zh-cn/` 前缀与
大小写归一。

```powershell
# 列出当前模组的表
backend_cli cfg list --mod test

# 读取表 / 单条 / 单字段 / 键列表 / 元信息 / 前缀过滤
backend_cli cfg get EvtCfg --mod test
backend_cli cfg get EvtCfg --mod test --id 320101
backend_cli cfg get EvtCfg --mod test --id 320101 --field title
backend_cli cfg get EvtCfg --mod test --keys
backend_cli cfg get EvtCfg --mod test --meta
backend_cli cfg get TalkCfg --mod test --prefix 32 --suffix 3 --limit 50

# 整表覆盖写入（PUT）
backend_cli cfg set EvtCfg --mod test --file .\full_table.json
backend_cli cfg set EvtCfg --mod test --data '{"1": {"id":1,"title":"新事件"}}'
backend_cli cfg set EvtCfg --mod test --file .\t.json --expect-mtime 1725... --force

# 行级补丁（PUT body 判别 patch 字段，无 PATCH 动词）
backend_cli cfg patch TalkCfg --mod test --set '{"9003":{"id":9003,"content":"第三行"}}' --remove 9001
backend_cli cfg patch TalkCfg --mod test --set-file .\patch.json --if-match '{"9003":{"content":"第三行"}}'
backend_cli cfg patch TalkCfg --mod test --set-file .\patch.json --force

# 历史快照 / 撤销 / 重做
backend_cli cfg history EvtCfg --mod test
backend_cli cfg history EvtCfg --mod test --undo
backend_cli cfg history EvtCfg --mod test --redo
```

### 校验 / Bug 扫描 / 剧情

```powershell
# schema + 跨表校验（--strict 时有 error 级问题则 exit 1）
backend_cli validate EvtCfg --mod test
backend_cli validate EvtCfg --mod test --data '{"1": {}}'
backend_cli validate EvtCfg --mod test --file .\t.json --strict

# 逻辑 bug 扫描 / 修复
backend_cli bugfix scan
backend_cli bugfix scan --mod test
backend_cli bugfix fix
backend_cli bugfix fix --from-file .\bugs.json

# 剧情文本导入导出
backend_cli story export --evt 101,102 --mod test
backend_cli story export --evt 101 --out .\story.txt --dual both
backend_cli story import --start-id 101 --file .\story.txt          # 默认仅预览
backend_cli story import --start-id 101 --file .\story.txt --write  # 落库
backend_cli story import --start-id 101 --text "【甲】你好" --write --append
```

`bugfix scan` 的输出按 `flag` 逐行列出，并在末尾给出 `count` 与
`by_flag: LOGIC=n ERROR=n ...` 分类统计；`bugfix fix` 除 `fixed` / `remaining` 计数外，
还会逐条列出**无法自动修复**的遗留缺陷（LOGIC / ERROR 类后端不会自动改）。

### 插件管理

```powershell
backend_cli plugin list                      # 已安装插件（id / 名称 / 版本 / 加载状态）
backend_cli plugin install .\my-plugin.zip   # 安装（--name 可指定 zip 文件名，用于推导 id）
backend_cli plugin uninstall my-plugin       # 卸载（删除插件目录，无启用态）
backend_cli plugin reload                    # 重新扫描全部插件
backend_cli plugin tools                     # 插件提供给 AI 的工具
```

插件系统为**声明型**：目录 + `manifest.json`，不执行代码、无启用/停用态，
因此**没有** `enable` / `disable`（后端对这些请求返回 410）。安装走
`POST /api/plugins/install_path`（本地路径），不做 base64 包装，不受体积上限限制。
卸载是立即删除，不弹确认——与 `mods remove` 的既有约定一致。

### 云同步

```powershell
backend_cli cloud providers                  # Provider 列表 + 可用驱动
backend_cli cloud add --name 我的网盘 --type webdav --config '{"url":"https://dav.x","username":"u","password":"p"}'
backend_cli cloud add --type webdav --config-file .\drv.json --remote-root mods
backend_cli cloud update p_1 --name 新名字 --config '{"password":"p2"}'
backend_cli cloud remove p_1
backend_cli cloud test p_1                   # 已保存 Provider
backend_cli cloud test --type local --config '{"root":"D:\mods"}'
backend_cli cloud drivers                    # 各驱动的配置 schema（字段名）
backend_cli cloud status                     # 进度 + 历史
backend_cli cloud local --mod MyMod          # Mod 本地文件列表
backend_cli cloud remote p_1 --mod MyMod     # 远端文件列表

# 同步：默认整文件夹；--files 走选中文件模式
backend_cli cloud sync p_1 --direction upload --dry-run      # 只预览
backend_cli cloud sync p_1 --direction sync                  # 双向（mtime 新者胜）
backend_cli cloud sync p_1 --direction upload --delete-extra
backend_cli cloud sync p_1 --direction download --files Cfgs/zh-cn/TalkCfg.json
```

`--direction` 取 `upload|download|sync|delete_remote|delete_local`（必填）。
`--dry-run` 只预览不写入。输出逐行 `[ok|!!] <action> <rel>` 并给出
`summary: upload=n download=n skip=n failed=n`。

### AI 设置（权限模式）

```powershell
backend_cli ai settings                      # 查看（含 permissionMode）
backend_cli ai set --mode confirm            # 变更前确认（默认）
backend_cli ai set --mode full               # 不再确认，AI 直接修改
backend_cli ai set --data '{"model":"gpt-4o-mini","temperature":0.3}'
backend_cli ai set --file .\ai.json
```

`ai set` 写 `PUT /api/ai/settings`，与 GUI 设置页写的是同一份 `.editor_ai.json`。

### 环境变量文件（本地，非 HTTP）

```powershell
backend_cli env get workspace_root
backend_cli env set workspace_root D:\MyMods
backend_cli env set some_flag 42 --json-value
```

`env` 直接读写 `editor_env.json`（`--json-value` 时值按 JSON 解析后存）；键不存在时
`env get` 退出码 1。

### 无代码模式（编辑器共享设置）

```powershell
backend_cli settings no-code show    # 查看当前值（未写过时默认 off）
backend_cli settings no-code on      # 打开无代码模式
backend_cli settings no-code off     # 关闭
```

`settings no-code` 读写后端的 `GET/PUT /api/settings/editor`，落盘在
`editor_env.json` 的 `no_code_mode` 键——与 GUI / TUI 是同一个开关。`show` 只读，
输出 `no-code: on|off`；`on` / `off` 是写操作，文本输出带 `ok:` 前缀，`--json` 给
完整信封 `{"ok":true,"settings":{"noCodeMode":…}}`。取值只接受 `on|off|show`
（子命令别名 `nocode`），其余是用法错误、退出码 2；裸 `backend_cli settings`（不带
子命令）与 `mods` / `cfg` 等命令族一致，落到交互模式而不是报错。

REPL 内用 `/settings`（无参 = 查看）或 `/settings no-code on|off`，欢迎面板与
`/status` 都会显示 `无代码模式: 开 / 关 / 未知`（读一次后端，失败显示“未知”）。

### Shell 转义提示（Windows）

PowerShell 单引号内 `\"` 会保留反斜杠，导致 JSON 失效。推荐用 `--file` / `--set-file`
传 JSON，或：

```powershell
# 推荐 1: 单引号 + 无转义
backend_cli cfg set EvtCfg --mod test --data '{"1":{"title":"hello"}}'

# 推荐 2: 双引号 + 转义内部双引号
backend_cli cfg set EvtCfg --mod test --data "{""1"":{""title"":""hello""}}"
```

### 交互模式（REPL，「类 Claude Code」）

**无参数启动 `backend_cli`**（或显式 `backend_cli repl`）进入交互模式，复刻
Alpha-v0.3 Python CLI 的 REPL：cyan 边框欢迎面板、` {当前模组}› ` 提示符、
slash 命令、Tab 候选菜单、↑↓ 历史（持久化于 `editor_root/.editor_cli_history`）、
空回车重复上一条（回显 `↻`）、`Ctrl+C` 取消当前行、`Ctrl+D` / `exit` 退出。
子命令用法不变（`backend_cli mods list` 仍是一次性执行）。

```
╭ 学生时代 · Editor CLI — 类 Claude Code ──────────────╮
  Workspace: D:\MyMods        Mods: 3 (test, ...)
  Cfgs: 7  当前模组: test
  无代码模式: 关（/settings no-code on|off 切换）
────────────────────────────────────────────────────────
[test]› /mods list
```

| 命令 | 作用 |
| --- | --- |
| `/help` | 命令总表（命令 / 说明 / 示例三列） |
| `/use <模组>` | 切换当前模组（后续命令免 `--mod`，写回 `cli_selected_mod`） |
| `/status` | 工作区 / 模组 / 表 / 当前选中概览（含无代码模式开/关） |
| `/settings [no-code on\|off\|show]` | 无代码模式开关（无参 = 查看，等价 `settings no-code`） |
| `/search <关键词>` | 全局搜索对白（等价 `search` 子命令） |
| `/mods /cfg /validate /bugfix /story /oobe /env /plugin /cloud /ai …` | 撇掉斜杠直接跑对应子命令（含各自参数） |
| `/clear` | 清屏 |
| `! <命令>` | 透传系统 shell（如 `!git status`） |
| `/exit` `/quit` `/q` 裸 `exit` | 退出 |
| `@提及` | `@模组` = 选中该模组；`@表` / `@表:id` = 读该表 / 该条记录；`@role:人物` = 读该人物记录 |

`@提及` 按当前缓存的模组名判定：名字能对上是选中模组，否则按表名处理（可带
`:记录id`）。`@role:<名字或id>` 按人物池解析（精确优先，其次唯一模糊匹配），命中后
执行 `cfg get PersonCfg --id <id>`。上下文记忆：`/use test` 之后，`cfg get EvtCfg`
等命令自动作用于当前模组，与 Python REPL 的体验一致。

#### Tab 候选菜单（M3）

Tab 不再是一次性罗列，而是按**词法槽**选池、模糊匹配后弹出可交互候选菜单：

- 首词 → 命令池；**空行 Tab → 高频命令菜单**（`GET /api/usage?kind=command&limit=10`，
  启动拉一次、执行命令后刷新）；`/` 开头 → slash 命令池。
- `cfg <Tab>` → 子命令池；`-` 开头 → 当前命令的 flag 池（含 `--json` 等全局 flag，
  匹配忽略前导横线）。
- 值槽各有专属池：`cfg get/set/patch/history` 与 `validate` 的表名、`mods select/remove`
  的模组名、`--path/--zip/--file/--out/--root/--workspace` 的路径（当前目录实时枚举）、
  `settings no-code` 的 `on|off|show`、`cloud sync --direction`、`story export --dual`、
  `ai set --mode` 等固定枚举。
- JSON 值槽（`--data/--set/--opts/--if-match/--config` 里的 `"key":` 后按 Tab）按 TUI
  同款键名映射拉 `/api/effect_suggest`：`effect*` / `condition|cond|precondition|check` /
  `screenEffect` / `cost`，候选行以中文描述为主、代码为次，接受后自动补引号；
  `"roleIds"/"roles"/"speaker"` 拉 `/api/roles`（value=id、hint=名字）。
  `story import --text` 直接补 effect 代码。
- 交互规则：**唯一前缀直接补全**；多候选弹菜单，`↑↓` 移动高亮、数字直达
  （1-9，`0` = 第 10 项）、`Enter` 接受、`Esc` 退回编辑。管道 / 非 TTY 时退回
  一次性罗列，不影响脚本。
- 使用统计：每条执行的命令（含 slash 形式）POST `/api/usage {kind:"command",key:命令名}`，
  接受 effect / 人物 / 表名候选也会上报对应 kind；上报失败静默，绝不影响命令本身。

### 彩色输出

一次性命令与 REPL 的文本输出对齐 Alpha-v0.3（Python rich）观感：ID 列
**bold green**、数据列 **cyan**、`ok:` 绿 / `error:` 红 / 警告黄、校验分级
`[error]` 红 `[warn]` 黄 `[info]` 青。默认**仅在标准输出为终端时**着色；管道 /
重定向自动退回纯文本，`--no-color` 强制关闭、`--color` 强制开启，`--json`
输出永不着色——脚本与 CI 的纯文本断言不受影响。

---

## 3. TUI 使用

```powershell
backend_tui                                  # 默认 127.0.0.1:8770，探测失败自起同目录 backend
backend_tui --port 8765                      # 只连接，不自起
backend_tui --url http://127.0.0.1:8765
backend_tui --data-root D:\editor_data       # 覆盖 EDITOR_DATA_ROOT
```

TUI 默认目标是连接已有后端；仅无参启动且 8770 探测失败时才自起同目录 `backend`，
退出时经 `/api/shutdown` 回收。显式 `--url` / `--port` 为纯客户端，连接失败只在状态栏报错。

### 无头自检（排障 / CI）

```powershell
backend_tui --render-check all               # 渲染全部界面样例到 stdout（不发网络）
backend_tui --render-check main --width 100
backend_tui --connect                        # ping→mods→select→cfg list→load，打印 CONNECT_OK
```

### 布局（Alpha-v0.3 复刻）

主界面即 Alpha-v0.3 Python/textual 版的三栏编辑器（VS Code Dark+ 观感：蓝色
`#007acc` 面板标题条 + 分层灰阶底色），没有页签栏：

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ Header: 学生时代 · 模组编辑器 — TUI  终端版 · 直接读写 Cfgs 文件               │
├────────────┬─────────────────────────────┬─────────────────────────────────────┤
│ 📦 Mods /  │ 📋 Records — <当前表>       │ 📝 Detail / JSON                    │
│ Cfgs       │  行数 / 未保存计数 / 过滤   │  [JSON] ⇄ [表单]（m 切换）          │
│ 📁 模组    │  n 新增 / y 复制 / d 删除   │  Enter 编辑 / Ctrl-S 保存           │
│ └ ◦ Cfgs   │  斑马纹行 + 选中高亮        │  [s 保存][v 校验][y][d]             │
│            │                             │  （脏状态标题条变红）               │
├────────────┴─────────────────────────────┴─────────────────────────────────────┤
│ a AI 助手  c 云同步  p 插件  b Bug 扫描  Ctrl-K 搜索  Ctrl-M 权限 Ctrl-N 无代码│
│ 状态栏（蓝底：Workspace · 表 · 权限 · 无代码 · 未保存数；错误时变红）          │
└────────────────────────────────────────────────────────────────────────────────┘
```

左栏是 **模组 → Cfgs 两级树**（`Enter` 选中并展开模组，`Enter` Cfg 打开表，
`→`/`←` 展开/收起，`N` 新建模组）。首次进入右栏显示欢迎引导，打开表后变为
详情视图。

其余界面都是**居中蓝色粗边框弹窗**（Alpha-v0.3 的模态样式）：`a` 🤖 AI 助手、
`c` ☁️ 云同步（Provider 轨 + 本地/远端双栏对比）、`p` 🧩 插件管理、
`b` 🐞 Bug 扫描/修复，以及 `Ctrl-K` 🔍 全局搜索、`v` ● 校验结果、`?` ⌨️ 帮助、
`confirm` 权限模式下的 ⚠ 审批框。

### 快捷键

| 按键 | 动作 |
|------|------|
| `q` / `Ctrl-Q` | 退出（有未保存修改先弹确认框） |
| `a` / `c` / `p` / `b` | 呼出 AI 助手 / 云同步 / 插件 / Bug 扫描弹窗（`Esc` 关闭） |
| `Ctrl-M` | 切换权限模式 `confirm`（变更前确认）⇄ `full`（直接执行） |
| `Ctrl-N` | 切换无代码模式（编辑字段时选效果/人物，不写代码；与 GUI/CLI 同一开关） |
| `?` | 开关帮助弹窗（任意键先行关闭） |
| `Tab` / `Shift+Tab` | 三栏焦点循环：树 → 记录 → 详情 → 树（反向用 Shift） |
| `↑↓` | 树 / 行 / 表单字段移动 |
| `Enter` | 树上选中模组或打开表 / 行进入 JSON 编辑 / 表单模式编辑字段 / 弹窗内执行 |
| `→` / `←` | 树节点展开 / 收起 |
| `N` | 新建模组（输入标题，`Enter` 创建） |
| `m` | 详情面板 JSON ⇄ 表单 切换（详情焦点时） |
| `n` / `y` | 新增行 / 复制当前行（自动分配键，Ctrl-S 保存落盘） |
| `d` | 标记删除当前行（再按一次取消） |
| `/` | 过滤当前面板（`Enter` 保留并退出，`Esc` 清空；过滤中所有按键进过滤器） |
| `Ctrl-K` | 全局搜索对白（跨 TalkCfg/EvtCfg，含本体） |
| `v` | 校验当前打开的表（issues + counts 弹窗） |
| `r` | 刷新（树 / 当前表 / 弹窗数据） |
| `Ctrl-S` | 保存（表页补丁、Bug 弹窗应用修复） |

插件弹窗：`r` 刷新、`R` 重载全部、`i` 安装（弹出单行 zip 路径输入，`Enter` 确认、
`Esc` 取消）、`u` 卸载选中项。

云同步弹窗：`↑↓` 选 Provider、`Enter` 读取本地/远端列表、`u`/`d`/`b` 选
upload / download / sync 方向、`y` 切 DryRun、`x` 切「清理远端多余」、
`s` 执行同步、`t` 测试连接、`r` 刷新 Provider。

### 权限模式与审批框

`permission_mode`（默认 `confirm`，与后端 `.editor_ai.json` 的默认值一致）决定
**写操作是否先弹审批框**：

| 操作 | 类型 | confirm 模式 |
|------|------|--------------|
| 保存补丁（`Ctrl-S`） | 写 | 弹框 |
| 应用修复（Bug 页 `f` / `Ctrl-S`） | 写 | 弹框 |
| 插件安装（`i`） | 写 | 弹框 |
| 插件卸载（`u`） | 写 | 弹框 |
| 云同步（`s`，DryRun 关） | 写 | 弹框 |
| 云同步 DryRun / 扫描 / 校验 / 读表 / 搜索 / 测试连接 | 读 | 不弹 |

审批框 `y`/`Enter` 允许、`n`/`Esc` 拒绝（拒绝只记状态行，不执行）。启动时 TUI 用
`GET /api/ai/settings` 读入当前模式，`Ctrl-M` 切换后用 `PUT /api/ai/settings` 写回，
与 GUI 的「变更前确认 / 完全访问」是同一份设置。

### 无代码模式（编辑器共享设置）

`no_code_mode` 存 `editor_env.json` 的 `no_code_mode` 键（默认 off），与 GUI 设置页的
「无代码模式」、CLI 的 `settings no-code on|off` 是**同一个开关**：启动时
`GET /api/settings/editor` 读入，`Ctrl-N` 切换后 `PUT /api/settings/editor` 写回。
开启时状态栏出现 `· 无代码` chip，底部提示行常显 `Ctrl-N 无代码`，`?` 帮助里也有两行说明。

开启后，详情面板**表单模式**（`m` 切过去）里编辑效果 / 条件 / 人物类字段不再手写
代码 DSL，而是从候选里选：

| 字段名（大小写不敏感） | 候选池 |
|------|--------|
| `effect*`、`TalkCfg.roles` | `GET /api/effect_suggest`（中文描述为主，空查询 = 最近使用 + 目录默认） |
| `condition` / `cond` / `precondition` / `check` | 同上（条件池） |
| `screenEffect` | 同上（屏幕效果池） |
| `cost` | 同上（花费池） |
| `roles` / `roleIds` / `speaker` | `GET /api/roles`（人物池，行内 `id · 名字`） |

操作：

1. 候选只在无代码模式下出现：`Enter` 进入字段编辑即拉一次候选（`Tab` 可重开已缓存的
   候选、不发新请求），关闭无代码模式后字段编辑就是原来的纯手输。
   候选浮层里 `↑↓` / `Tab` 移动高亮、`Enter` 接受、`Esc` 关闭浮层但**保留已手输的内容**；
   继续打字是**本地过滤**（不发请求），退格会还原过滤前的列表。
2. 带参数的候选（如 `[1,1,@ATTR@,V]`）接受后进入**二级选择列表**：标题是
   `槽 i/N · 标签 (name)`，列表项来自对应字典池（属性 / 人物 / 物品 / 关系 …），
   打字即过滤；`Enter` 取当前高亮项，池为空或想手输时直接键入数值再 `Enter`。
   最后一槽填完自动拼成完整效果码写回字段；中途 `Esc` 取消整次选择。
3. 接受候选会 `POST /api/usage` 上报（命令 / 效果 / 人物分别计数），下次打开时高频项
   排前面——与 GUI、CLI 共用同一份统计。

TUI **不做逐键网络请求**：候选只在进入编辑（或 `Tab`）时拉一次并缓存在会话里，之后
全部本地过滤，与 CLI REPL 的 Tab 菜单同一策略。

### 操作流

1. 启动即进三栏主界面；左栏 `↑↓` 选择模组，`Enter` 选中并展开其 Cfgs。
2. `Enter` 打开一张表（或 `Tab` 切换面板）；记录栏 `↑↓` 选行，右侧详情实时显示
   该行 JSON；`m` 切表单模式后 `Enter` 可逐字段编辑（非法 JSON 自动按字符串落值）。
3. `Enter` 编辑整行 JSON；`n` 新增 / `y` 复制 / `d` 标记删除（再按取消）；
   `Ctrl-S` 保存（增量补丁，冲突 / lossy 会在状态栏给出后端错误，再按强制覆盖）。
4. `v` 校验当前表，`Ctrl-K` 全局搜索对白（`↑↓` 选结果，`Esc` 关闭）。
5. `b` 呼出 Bug 扫描弹窗，`r` 扫描，`f` 应用修复（confirm 模式先审批）。
6. `a` 呼出 AI 助手弹窗，直接输入后 `Enter` 发送；`Esc` 关闭。
7. `p` 呼出插件弹窗，`r` 读清单，`i` 输入 zip 路径安装，`↑↓` 选中后 `u` 卸载，
   `R` 重载全部。
8. `c` 呼出云同步弹窗，`↑↓` 选 Provider，`Enter` 读本地/远端对比；`u`/`d`/`b` 选方向、
   `y`/`x` 切 DryRun / 清理远端，`s` 执行（先 `y` 打开 DryRun 可安全预览）。
9. `Ctrl-N` 开无代码模式，`m` 切表单后 `Enter` 进字段编辑即出候选：选效果（带参的走
   二级槽列表）、选人物，不用记代码。
10. `/` 过滤当前面板；`q` 退出（脏数据先确认）。

数据安全：保存通过后端写管线（原子替换 + 快照），TUI 不直接写文件；与图形版同时
编辑同一 cfg 可能互相覆盖，保存前 `r` 刷新。`confirm` 权限模式下所有写操作先弹审批框。

---

## 4. 架构

```
native/
  cli/                       backend_cli（CLI11 + sa_core::http）
    p7_cli_logic.{h,cpp}     语法/命令规划/渲染/退出码（纯逻辑，进 sa_cli 供 sa_tests）
    p7_cli_main.cpp          main + 内嵌服务器引导（仅进 backend_cli）
  tui/                       backend_tui（FTXUI）
    p8_model.h               AppState / Page / Intent / KeyInput
    p8_view_model.cpp        纯状态机 HandleKey（不发网络，只产出 Intent）
    p8_api.{h,cpp}           BackendApi（HTTP + 静态响应解析）
    p8_cfg.{h,cpp}           编辑 diff → 补丁 body
    p8_agent.{h,cpp}         openai_compatible 对话编解码 + 会话落盘
    p8_render.{h,cpp}        AppState → FTXUI DOM + 无头字符串渲染
    tui/{app,main}.cpp       交互层与入口（仅进 backend_tui）
```

- **CLI**：默认在进程内起真后端（`sa::init_state + build_router + Httpd`，
  与桌面同一组 route handler），再经 `sa_core::http` 走 loopback HTTP 自调自；
  `--json` 时原样透传后端字节。`--url` 时退化为纯客户端。
- **TUI**：纯客户端，用 `BackendApi` 调后端 HTTP API（mods / cfg / bugfix /
  history / plugins / cloud / ai settings），agent 页用 `AgentClient` 直连模型服务。
- 二者都不再离线直接读写文件（旧 Python CLI/TUI 的「离线文件模式」已随迁移取消）；
  所有读写经后端，语义与 GUI 一致。

---

## 5. 构建与分发

```powershell
# 手动构建（Windows）：vcvars64 + CMake/Ninja → native/build/bin/ 三件套 + sa_tests
cmd //c native\build.cmd

# POSIX（Linux / macOS）：需 cmake + ninja + C++20 编译器
./native/build.sh

# 发行版（三件套随包 + 可选 aa_scan）
python build_release.py --target windows --version Alpha-v0.1
python build_release.py --target linux   --version Alpha-v0.1
python build_release.py --target macos   --version Alpha-v0.1
```

产物 `backend_dist/`（Windows 为 `.exe`）含 `backend` / `backend_cli` / `backend_tui`
三件套；不再有 PyInstaller 的 `_internal/` 与 `editor_cmd.exe`。Windows 安装器提供
`editor-cli.cmd` / `editor-tui.cmd` 包装与可选 PATH 注册。

---

## 6. 常见问题

- **中文乱码**：PowerShell 默认 GBK，请 `chcp 65001` 或用 Windows Terminal（UTF-8）。
  文件本身为 UTF-8，`cat` 乱码不影响 JSON 正确性。
- **`--mod` 必填**：workspace 下多 mod 时无法推断，需显式 `--mod`；单 mod 时可省略。
- **workshop mods 不可删**：拒绝删除 `steamapps/workshop/content/1991040/*`，
  需在 Steam 客户端取消订阅。
- **TUI 连不上**：确认已有后端在运行，或 `--url` / `--port` 指向正确实例；
  可用 `backend_tui --connect` 排查。
- **同时编辑冲突**：CLI/TUI 与 Flutter 图形版同时写同一文件可能覆盖，保存前 `r`
  刷新或避免并行编辑。

---

## 7. AI 助手

- **TUI** 内置轻量 AI 对话弹窗（`a` 呼出）：**仅支持 `openai_compatible` 协议**、
  **纯对话无工具**（不能直接改模），显示在独立的会话记录里。配置来源：
  `--agent-config <json>`（`{provider, baseUrl, model, temperature, apiKey}`）或环境变量
  `P8_AI_PROVIDER` / `P8_AI_BASE` / `P8_AI_MODEL` / `P8_AI_KEY`。会话历史以单文件
  JSON 落盘于 `<data_root>/.p8_ai_history/`。
- **CLI 有 `ai` 子命令**（`ai settings` / `ai set`），覆盖 `.editor_ai.json` 的设置
  读写（含 `permissionMode`）；工具调用与工具级 diff 审批仍未移植
  （旧 Python 版的 `agent chat/config/history` 不在其中）。
- **权限模式**：`permissionMode` 取 `confirm`（默认，写操作先弹审批框）或 `full`
  （直接执行）。TUI 用 `Ctrl-M` 切换并写回后端，CLI 用 `ai set --mode`，GUI 用设置页
  与 AI 面板快捷键——三端同一份 `.editor_ai.json`。TUI 的审批框覆盖保存 / 修复 /
  装插件 / 卸载 / 真实云同步。
- GUI 的完整 AI 侧栏（工具调用、字段级 diff 审批、多协议、并行子代理、自动重连）
  仍由 Flutter 前端直连后端 AI 路由提供；配置三端共享 `.editor_ai.json`。

> 与旧 Python 版的差异：native TUI 的 agent 是大幅简化的「纯对话」实现（无 14 个领域
> 工具、无审批回调、无 `spawn_subagents`、无自动重连退避/取消、无多协议）；它复用了
> 后端的 `permissionMode` 设置，但审批的对象是 TUI 自身的写操作，而非工具调用。

---

## 8. 云同步

- **CLI 有完整 `cloud` 子命令**（`providers` / `add` / `update` / `remove` / `test` /
  `sync` / `status` / `drivers` / `local` / `remote`），见 §2「云同步」。
- **TUI 有云同步页**（`Ctrl-L`）：Provider 轨 + 本地/远端双栏对比 + 方向/DryRun/
  清理远端 开关 + 同步与连接测试，对齐 GUI 云同步页的布局与语义。
- 后端 `/api/cloud/*` 路由与同步引擎为三端共用（11 种驱动别名：local / webdav /
  openlist / alist / 百度 / 123 / Google Drive / OneDrive 等；配置存
  `<workspace>/.editor_cloud.json`）。**实时自动同步仍为 GUI 专属**（CLI/TUI 未移植
  `/api/cloud/realtime/*` 的交互）。

---

## 9. 配音（TTS）

- **CLI / TUI 未移植 TTS 命令**（旧 Python 版的 `tts config/voices/test/synthesize/list/delete`
  不存在）。
- 后端 `/api/tts/*` 路由仍在，由 GUI 设置页 / 领声功能消费；配置沿用
  `.editor_ai.json` 的 `tts*` 字段（三端共享）。

---

## 10. 插件管理

- **CLI 有 `plugin` 子命令**（`list` / `install` / `uninstall` / `reload` / `tools`），
  **TUI 有插件页**（`Ctrl-P`：清单 + `i` 安装 / `u` 卸载 / `R` 重载），与 GUI 插件页
  对齐，见 §2「插件管理」。
- 插件系统为**声明型**（目录 + `manifest.json`，不执行代码、无启用/停用态），因此
  三端都**没有** `enable` / `disable`（后端返回 410），也不存在旧版的「启用高危确认」
  「启用的插件注册 CLI 命令」等机制。插件的 UI 面板 / 流程卡片贡献仍由 GUI 渲染。
- 插件作者指南见 `PLUGIN_GUIDE.md`，规范以 `native/PLUGIN_SPEC.md` 为唯一真相源。
