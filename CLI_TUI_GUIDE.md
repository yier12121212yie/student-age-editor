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
任一端完成后不再自动弹出。CLI **不会**在首次访问时自动弹出向导（旧 Python 版的
交互式 REPL 特性未移植）；`EDITOR_OOBE` / `EDITOR_NO_OOBE` 环境变量由各消费方
自理，CLI 不消费。

```powershell
# 查看是否首次运行 / 是否已完成
backend_cli oobe status

# 设置工作区、可选顺手建一个模组（默认同时标记 OOBE 完成）
backend_cli oobe setup --workspace D:\MyMods --mod FirstMod --desc "第一个模组"

# 只标记完成
backend_cli oobe done
```

### 环境要求

- 无需 Python / pip / Flutter：发行版为原生可执行文件，`backend_cli` /
  `backend_tui` 随包分发。
- `backend_cli` 默认内嵌自起后端，无需另开后端；`backend_tui` 需先有一个后端在运行
  （GUI 启动的 `backend`，或手工 `backend --port 8770`）。
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

### 环境变量文件（本地，非 HTTP）

```powershell
backend_cli env get workspace_root
backend_cli env set workspace_root D:\MyMods
backend_cli env set some_flag 42 --json-value
```

`env` 直接读写 `editor_env.json`（`--json-value` 时值按 JSON 解析后存）；键不存在时
`env get` 退出码 1。

### Shell 转义提示（Windows）

PowerShell 单引号内 `\"` 会保留反斜杠，导致 JSON 失效。推荐用 `--file` / `--set-file`
传 JSON，或：

```powershell
# 推荐 1: 单引号 + 无转义
backend_cli cfg set EvtCfg --mod test --data '{"1":{"title":"hello"}}'

# 推荐 2: 双引号 + 转义内部双引号
backend_cli cfg set EvtCfg --mod test --data "{""1"":{""title"":""hello""}}"
```

---

## 3. TUI 使用

```powershell
backend_tui                                  # 连默认 127.0.0.1:8770
backend_tui --port 8765
backend_tui --url http://127.0.0.1:8765
backend_tui --data-root D:\editor_data       # 覆盖 EDITOR_DATA_ROOT
```

TUI 是纯客户端，需先有一个后端实例在运行；连接失败会在状态栏报错。

### 无头自检（排障 / CI）

```powershell
backend_tui --render-check all               # 渲染全部页面样例到 stdout（不发网络）
backend_tui --render-check table --width 100
backend_tui --connect                        # ping→mods→select→cfg list→load，打印 CONNECT_OK
```

### 布局

```
┌─────────────────────────────────────────────────────────────────────┐
│ Header: 学生时代 模组编辑器 — TUI                                    │
├─────────────────────────────────────────────────────────────────────┤
│ 当前页：Mods / Tables / Table / Bugfix / Agent                      │
│                                                                     │
│  列表（模组 / 表 / 行 / Bug / 聊天记录） + 右侧内容区                 │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ 状态行（操作提示 / 错误）                                            │
│ Footer: [?] 帮助  [Ctrl-Q] 退出                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 快捷键

| 按键 | 动作 |
|------|------|
| `Ctrl-Q` | 退出 |
| `?` | 开关帮助覆盖层（任意键先行关闭） |
| `Ctrl-D` / `Ctrl-T` / `Ctrl-B` / `Ctrl-A` | 切换 模组 / 表 / Bug / AI 助手 页 |
| `↑↓` | 列表 / 行移动 |
| `Enter` | 模组页进入表列表 / 表列表打开表 / 行进入编辑 / 助手页发送消息 |
| `Esc` | 返回上一页 / 退出编辑 |
| `r` | 刷新当前列表（表列表、模组） |
| `Ctrl-R` | 在 Bug 页重新扫描 |
| `Ctrl-S` | 表页保存（行级补丁）/ Bug 页应用修复 |
| `d` | 表页标记删除当前行 |
| 直接输入 | 表列表 / 表页按字符过滤 |

### 操作流

1. `Ctrl-D` 模组页，`↑↓` 选择，`Enter` 进入该模组的表列表。
2. 表列表 `↑↓` 选择，`Enter` 打开表（拉取该表行）。
3. 表页 `↑↓` 选行，`Enter` 编辑该行 JSON；`d` 标记删除；
   `Ctrl-S` 保存（增量补丁，冲突 / lossy 会在状态行给出后端错误）。
4. Bug 页 `Ctrl-R` 扫描，`↑↓` 选择，`Ctrl-S` 应用修复。
5. 助手页 `Ctrl-A`，直接输入后 `Enter` 发送；`Esc` 返回。

数据安全：保存通过后端写管线（原子替换 + 快照），TUI 不直接写文件；与图形版同时
编辑同一 cfg 可能互相覆盖，保存前 `r` 刷新。

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
  history），agent 页用 `AgentClient` 直连模型服务。
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

- **TUI** 内置轻量 AI 对话面板（`Ctrl-A`）：**仅支持 `openai_compatible` 协议**、
  **纯对话无工具**（不能直接改模），显示在独立的会话记录里。配置来源：
  `--agent-config <json>`（`{provider, baseUrl, model, temperature, apiKey}`）或环境变量
  `P8_AI_PROVIDER` / `P8_AI_BASE` / `P8_AI_MODEL` / `P8_AI_KEY`。会话历史以单文件
  JSON 落盘于 `<data_root>/.p8_ai_history/`。
- **CLI 没有 agent 子命令**（旧 Python 版的 `agent chat/config/history` 未移植）。
- GUI 的完整 AI 侧栏（工具调用、字段级 diff 审批、多协议、并行子代理、自动重连）
  仍由 Flutter 前端直连后端 AI 路由提供；配置三端共享 `.editor_ai.json`。

> 与旧 Python 版的差异：native TUI 的 agent 是大幅简化的「纯对话」实现（无 14 个领域
> 工具、无审批回调、无 `spawn_subagents`、无自动重连退避/取消、无多协议）。

---

## 8. 云同步

- **CLI / TUI 未移植云同步命令**（旧 Python 版的 `cloud providers/add/test/show/remove/sync`
  不存在）。
- 后端 `/api/cloud/*` 路由与同步引擎仍在，由 GUI 云同步页消费（7 种驱动：local /
  webdav / openlist / 百度 / 123 / Google Drive / OneDrive；配置存
  `<workspace>/.editor_cloud.json`）。实时自动同步为 GUI 专属。

---

## 9. 配音（TTS）

- **CLI / TUI 未移植 TTS 命令**（旧 Python 版的 `tts config/voices/test/synthesize/list/delete`
  不存在）。
- 后端 `/api/tts/*` 路由仍在，由 GUI 设置页 / 领声功能消费；配置沿用
  `.editor_ai.json` 的 `tts*` 字段（三端共享）。

---

## 10. 插件管理

- **CLI / TUI 没有 plugin 子命令**（旧 Python 版的 `plugin list/info/install/enable/...`
  未移植）；插件系统已改为**声明型**（目录 + `manifest.json`，不执行代码、无启用/停用态），
  不存在旧版的「启用高危确认」「启用的插件注册 CLI 命令」等机制。
- GUI 插件页可查看插件与流程卡片贡献；插件作者指南见 `PLUGIN_GUIDE.md`，规范以
  `native/PLUGIN_SPEC.md` 为唯一真相源。
