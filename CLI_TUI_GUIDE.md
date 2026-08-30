# 学生时代 模组编辑器 — CLI / TUI 指南

> 终端版编辑器，与 Flutter 图形版共用同一套 `Cfgs/zh-cn/*.json` 与 `GAME_SCHEMA`，**离线文件模式**（无需启动 HTTP server），适合 SSH、CI、批处理、键盘重度用户。

---

## 1. 快速开始

### OOBE 首次使用引导

首次访问任一端时会自动开启一次 OOBE 向导（欢迎 → 工作区选择 → 可选创建首个 Mod → **可选 AI 助手 → 可选 TTS 配音 → 可选云存储**）。完成标记写入 `editor_env.json` 的 `oobe_completed`，**CLI / TUI / GUI 三端共用**，任一端完成后不再自动弹出。

- GUI 额外含「界面风格（创作/经典）」步骤（终端无 UI 模式概念，CLI/TUI 无此步）
- AI / TTS 配置写入三端共享的 `.editor_ai.json`；云存储写入工作区 `.editor_cloud.json`
- 所有新步骤均「全空跳过」即不配置，之后可在设置页 / 云同步面板随时补充

```powershell
# 强制重新开启 OOBE
python run_cli.py --oobe          # CLI：rich 向导，完成后可继续执行其它子命令
python run_tui.py --oobe         # TUI：OOBE 弹窗向导
# GUI：发行版 StudentAgeEditor.exe --oobe 或环境变量 EDITOR_OOBE=1

# 管道 / CI / 脚本中不会自动弹出（非 TTY 自动跳过）；彻底禁用：
$env:EDITOR_NO_OOBE="1"
```

### 环境要求

- Python 3.12+
- 依赖：`rich`（已自带）、`textual`（TUI 用，`pip install textual`）
- workspace 默认：`%USERPROFILE%\AppData\LocalLow\PakyiGame\StudentAge\Mods`（与图形版一致）
- 也可通过 `editor_env.json` 或 `--workspace` 显式指定

### 启动方式（源码运行）

```powershell
# 方式 A: 专用启动器（自动处理 PYTHONPATH）
python run_cli.py --help
python run_cli.py mods list
python run_tui.py --mod test

# 方式 B: 模块调用（需 PYTHONPATH=backend）
$env:PYTHONPATH="backend"
python -m editor.cli --help
python -m editor.cli tui
python -m editor.tui
```

### 发行版（PyInstaller）

```powershell
# GUI 仍由 Flutter 启动 backend.exe --port 8765
# CLI/TUI 复用同一 exe（需控制台）：
backend.exe --cli mods list
backend.exe --cli cfg get EvtCfg --mod test --id 320101
backend.exe --tui
# 源码模式更推荐：python run_cli.py / run_tui.py
```

> 注意：`build/release/backend.spec` 默认 `console=False`（GUI 无黑框）。  
> 若需发行版 CLI 控制台，请用 `console=True` 另行打包 `backend-cli.exe`，或直接分发源码 + `run_cli.py`。

---

## 2. CLI 使用

### 全局参数

```
--workspace PATH   覆盖工作区根目录
--json             JSON 输出（便于管道，需放在子命令后或全局）
--help
```

### 模组管理

```powershell
python run_cli.py mods list                      # 列出全部（Mods + workshop）
python run_cli.py mods list --json
python run_cli.py mods show test                 # 详情 + Cfgs 统计
python run_cli.py mods create MyMod --desc "xxx" # 新建
python run_cli.py mods delete MyMod --force
```

### 配置表 CRUD

`Cfgs/zh-cn/*.json` 为 `{ id: record }` 字典。`cfg` 命令自动做 `Cfgs/zh-cn/` 前缀与大小写归一。

```powershell
# 列出
python run_cli.py cfg list --mod test

# 读取整表: 默认表格视图 (自动挑选 title/name 等列), 大表仅显示前 30 行
python run_cli.py cfg get EvtCfg --mod test
python run_cli.py cfg get TalkCfg --mod test --fields title,npc,type   # 自定义列
python run_cli.py cfg get TalkCfg --mod test --all                    # 全部行

# 读取单条: 按 GAME_SCHEMA 字段顺序展示 (schema 外字段标 *, 缺失字段在底部列出)
python run_cli.py cfg get EvtCfg --mod test --id 320101

# 读取单字段 / 整表纯 JSON (管道)
python run_cli.py cfg get EvtCfg --mod test --id 320101 --key title
python run_cli.py cfg get EvtCfg --mod test --id 320101 --json

# 写入：整表 / 单条 / 单字段
python run_cli.py cfg set EvtCfg --mod test --id 999 --value '{"id":999,"title":"新事件","type":1}'
python run_cli.py cfg set EvtCfg --mod test --id 320101 --key title --value '"新标题"'
# 从文件写入（推荐，避免 shell 转义）
python run_cli.py cfg set EvtCfg --mod test --id 999 --file ./new_record.json
python run_cli.py cfg set EvtCfg --mod test --file ./full_table.json  # 覆盖整表

# 新建记录：按 schema 自动填默认值，ID 默认取最大数字 ID+1；--value/--file 仅覆盖指定字段
python run_cli.py cfg add TalkCfg --mod test
python run_cli.py cfg add TalkCfg --mod test --value '{"title":"我的对话"}'

# CLI 内置逐字段编辑器（无需外部编辑器）：
#   cfg set/edit 不带 --value 时逐个字段询问 — 回车=保留, 输入=替换,
#   "" 清空字符串, 数组支持 [1,2] 或 1,2 简写, !q 放弃, 结束汇总变更后 y/N 落盘
python run_cli.py cfg set TalkCfg --mod test --id 32010101
python run_cli.py cfg edit TalkCfg --mod test --id 32010101      # 同上 (无 --id 则编辑整表文件)

# 外部编辑器：加 --editor 改用 $EDITOR 打开临时 JSON
EDITOR="code --wait" python run_cli.py cfg edit EvtCfg --mod test --editor

# 删除
python run_cli.py cfg delete EvtCfg --mod test --id 999 --force

# 校验（对照 GAME_SCHEMA）
python run_cli.py cfg validate --mod test
python run_cli.py cfg validate --mod test --verbose
python run_cli.py cfg validate                 # 校验 workspace 下全部 mods

# 导入导出（覆盖）
python run_cli.py cfg export EvtCfg --mod test --out ./evt.json
python run_cli.py cfg import EvtCfg --mod test --in ./evt.json --force
```

### Schema / 搜索 / 工作区 / 自检

```powershell
python run_cli.py schema                 # 406 张表概览
python run_cli.py schema EvtCfg          # 单表字段: 18 字段 + 类型
python run_cli.py schema EvtCfg --json

python run_cli.py search 320101                        # 跨全部 mods
python run_cli.py search 关键词 --mod test --cfg TalkCfg
python run_cli.py search 320101 --json

python run_cli.py workspace show
python run_cli.py workspace set D:\MyMods

python run_cli.py doctor                 # 环境自检
python run_cli.py server start --port 8765  # 启动 HTTP 后端供 Flutter 用
```

### 检查更新（update）

```powershell
python run_cli.py update           # 通过 GitHub Release 检查新版本
python run_cli.py update --json    # JSON 输出（便于脚本解析）
```

显示最新版本号、发布说明与各资产的下载链接；REPL（`python run_cli.py` 无参进入）内 `/update` 等效。

### Shell 转义提示（Windows）

PowerShell 单引号内 `\"` 会保留反斜杠，导致 JSON 失效。推荐：

```powershell
# 推荐 1: 单引号 + 无转义
python run_cli.py cfg set EvtCfg --mod test --id 1 --value '{"title":"hello"}'

# 推荐 2: 双引号 + 转义内部双引号
python run_cli.py cfg set EvtCfg --mod test --id 1 --value "{""title"":""hello""}"

# 推荐 3: 用 --file 彻底避免转义
'{"title":"hello"}' | Set-Content -Path tmp.json -Encoding UTF8
python run_cli.py cfg set EvtCfg --mod test --id 1 --file tmp.json
```

CLI 已内置对 `\"` 的容错修复（PowerShell 误转义会自动还原）。

---

## 3. TUI 使用

```powershell
python run_tui.py
python run_tui.py --mod test
python run_cli.py tui --mod test        # 等价
python -m editor.tui --mod test         # 需 PYTHONPATH=backend
```

### 布局

```
┌─────────────────────────────────────────────────────────────────────┐
│ Header: 学生时代 模组编辑器 — TUI   (mod 名)                          │
├──────────────┬────────────────────┬─────────────────────────────────┤
│ 左: Mods/Cfgs│ 中: Records         │ 右: Detail / JSON                │
│  Tree        │  DataTable(ID,prev)│  TextArea + [保存][校验][外部编辑]│
│  workspace   │  选中高亮同步右侧  │  状态栏                          │
├──────────────┴────────────────────┴─────────────────────────────────┤
│ 搜索条 (/ 呼出)                                                     │
│ Footer: 快捷键提示                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

### 快捷键

| 按键 | 动作 |
|------|------|
| `q` | 退出 |
| `r` | 刷新 workspace / 当前 cfg |
| `n` | 新建记录（基于 schema 自动填默认值，ID= max+1）；未选中 cfg 时转入新建 Mod |
| `N`（Shift+N） | 新建 Mod：在 workspace 下生成 manifest.json + Cfgs/zh-cn 空骨架并自动选中 |
| `e` | 聚焦右侧 JSON 编辑区 |
| `d` | 删除（按两次确认） |
| `s` | 保存：先暂存 TextArea JSON → 写入 `Cfgs/zh-cn/*.json`（原子替换） |
| `/` | 搜索（当前 mod / 当前 cfg 内大小写不敏感） |
| `c` | 云同步面板（provider 增删改查 / 测试 / 同步） |
| `a` | AI 助手聊天面板（对话式改模，写操作需确认；面板内「⚙ 配置」可直接改 AI 配置，「📜 历史」回看/恢复 AI 会话） |
| `u` | 检查更新（比对 GitHub Release，弹窗展示最新版本 / 发布说明 / 下载链接） |
| `?` | 帮助 |
| `Enter` | 左树展开 / 打开 cfg；中表选中 |
| `↑↓` | 导航 |
| `Esc` | 关闭搜索条 |

### 操作流

1. 左侧树 `Enter` 选 mod → 自动展开 Cfgs；`Enter` 选 cfg → 中间表加载。
2. 中间表 `↑↓` 高亮即在右侧预览；`Enter` 锁定。
3. 右侧 `e` 进入编辑，改 JSON 后 `s` 保存落盘（先校验 schema，`warn` 放行，`error` 阻止，可在 CLI 用 `--force` 绕过）。
4. `校验` 按钮把问题以 `{"_validation": [...]}` 形式回显；`外部编辑` 用 `$EDITOR` 悬挂 TUI 打开原文件，关闭后自动重载。
5. `/` 搜索后结果暂代中表，`r` 刷新回到正常列表。

数据安全：保存采用 `*.tmp_<pid>` + `os.replace` 原子替换，避免断电半截文件；CLI/TUI 每次写盘前还会保留上一代 `*.json.bak`，误写可手动回滚。REPL 的 `/cfg` 与单命令版共用同一实现（含表格视图、`cfg add`、$EDITOR 单条编辑），`/mods use` 的上下文会自动注入 `--mod`。

---

## 4. 架构

```
backend/editor/
  cli/
    __main__.py  ← python -m editor.cli
    app.py       ← argparse + rich，离线直接读写 Cfgs
    oobe.py      ← OOBE 首次运行向导（三端共享标记 + CLI rich 向导实现）
    utils.py     ← workspace/mod/cfg/schema/validate/search 复用层（与 server/api.py 逻辑镜像）
  tui/
    __main__.py  ← python -m editor.tui
    app.py       ← textual 三栏 App，复用 cli.utils
  core/
    game_schema.py (406 cfg schemas)
    data_dicts.py
  server/
    api.py       ← HTTP 版（Flutter 用），本 CLI/TUI 不依赖，平行实现

run_cli.py / run_tui.py          ← 源码启动器（处理 PYTHONPATH）
packaging/backend_entry.py        ← PyInstaller 入口，支持 --cli/--tui 分流
build/release/backend.spec        ← 已追加 rich/textual/editor.cli/tui 的 hiddenimports
```

CLI/TUI **不启动 http server**，直接 `Path.read_text(utf-8-sig)` / `json.loads` / `json.dump` 操作文件，因此：
- 可在无游戏、无网络、无 Flutter 环境下使用
- 与图形版无冲突（文件锁仅靠原子替换，无并发守护；建议勿与图形版同时编辑同一 cfg，TUI 的 `r` 可手动同步）

校验：`utils.validate_cfg()` 对照 `GAME_SCHEMA` 做宽松类型检查（String/Number/1D Array/2D Array，未知字段 warn，类型不符 warn），与图形版 `field_utils.dart` 策略一致。

---

## 5. 构建与分发

```powershell
# 源码分发（推荐）：直接发本仓库，用户
pip install textual rich
python run_cli.py doctor
python run_tui.py

# PyInstaller 单文件（Windows 示例）
pip install pyinstaller UnityPy textual rich
python build_release.py --target windows --version Alpha-v0.1
# 产物 dist/*.zip 含 backend.exe + Flutter 前端；CLI 额外文档见本文件
# 如需控制台版：
#   修改 build/release/backend.spec: console=True
#   pyinstaller build/release/backend.spec --distpath dist/cli --name backend-cli
```

---

## 6. 常见问题

- **中文乱码**：PowerShell 默认 GBK，请 `chcp 65001` 或用 Windows Terminal（UTF-8）。文件本身为 UTF-8，`cat` 乱码不影响 JSON 正确性。
- **--mod 必填**：workspace 下多 mod 时无法推断，需显式 `--mod`；单 mod 时可省略。
- **workshop mods 不可删**：CLI 拒绝删除 `steamapps/workshop/content/1991040/*`，需在 Steam 客户端取消订阅。
- **TUI 无法启动**：`pip install textual`；`doctor` 会检测。CI/无 TTY 环境请用 CLI 代替。
- **同时编辑冲突**：CLI/TUI 与 Flutter 图形版同时写同一文件可能覆盖，保存前 `r` 刷新或避免并行编辑。

---

## 7. Agent 助手（AI 对话式改模）

CLI / TUI 内置 AI 助手，与 GUI 的 AI 侧栏同一套工具与提示词（领域 CRUD / 字典 /
只读文件 / 舞台调度，共 13 个；图片生成为 GUI 专属）。模型服务配置存在
`.editor_ai.json`（editor 根目录，**GUI / CLI / TUI 三端共享、实时生效**）：
GUI 设置页保存即写该文件；CLI 可直接读写。

```powershell
# 查看 / 交互式修改配置（协议、baseUrl、apiKey、model、temperature，可测试连通性）
python run_cli.py agent config

# 单次任务：执行完退出（流式输出 + 工具调用记录）
python run_cli.py agent chat -m test 把开局事件的标题改成「新的开始」

# 交互聊天：多轮上下文，输入 exit / Ctrl+D 退出
python run_cli.py agent chat
python run_cli.py agent chat -m test

# 临时覆盖配置（不改文件）
python run_cli.py agent chat --provider anthropic --base-url https://… --api-key sk-… --model …
```

REPL（`python run_cli.py` 无参进入）内亦可：`/agent` 直接进入 AI 对话；
`/agent <任务>` 以该任务开场进入对话；`/agent setting` 查看/交互式修改 AI
模型配置（`/agent config` 仍可用）；`/agent chat` 单命令模式带任务时为
一次性执行（非交互，等价 `python run_cli.py agent chat <任务>`）。

TUI 修改配置：聊天面板（`a`）内点「⚙ 配置」直接编辑协议 / baseUrl / apiKey /
model / temperature / AI 权限，可保存前测试连通；REPL 内 `/agent setting`（或
`/agent config`）同效。

安全语义与 GUI 一致：所有写操作（update/create/delete/set_talk_stage）都会
先展示字段级 diff，等待 `y/N` 审批；工具循环上限 20 轮；未配置时给出引导而非报错栈。

AI 权限（`permissionMode`，三端共享）：`confirm`=变更前确认（默认，每次写操作
弹出审批框 / `y/N`）；`full`=完全访问（AI 直接执行修改，不再弹出确认框）。
GUI 在设置页「AI 权限」或 AI 面板顶栏的盾牌按钮切换；CLI 在 `agent config` 里
切换，`agent chat` 以完全访问启动时会提示 ⚠；TUI 在「⚙ 配置」里切换，标题栏
会显示「完全访问」标识。

并行子代理：AI 可通过 `spawn_subagents` 把可独立完成的调研类子任务并行分派给
最多 4 个只读子代理并汇总结论（子代理只读，不可写）；所有写操作仍由主代理
执行并按当前 AI 权限模式确认。

自动重连：连接失败 / 流式中断 / HTTP 429、5xx 会自动按指数退避重试（默认 3 次、
首个间隔 1 秒，`agent config` 里可调 `maxRetries` / `retryDelayMs`，`maxRetries=0`
关闭）；重连前输出「⚠ 连接中断，正在自动重连 (n/N)…」，断流前已显示的半截文本
会随重连重新生成。用户主动取消（Ctrl+C）不会触发重连。

TUI 内按 `a` 打开聊天面板（Esc 关闭，写操作弹出确认框），按 `u` 检查更新；
REPL 内 `/agent`、`/agent setting|config`、`/agent chat`（当前 `/mods use`
选定的 mod 自动作为 `-m` 默认）。

### AI 会话历史（CLI / TUI 共享）

CLI 聊天与 TUI 聊天面板的每轮对话会**自动记录**到 editor 根目录下的
`.editor_ai_history/`（一会话一 JSON，含 provider / model / 模组 / 全量消息），
最多保留 50 个会话、超出自动淘汰最旧；`--no-history`（CLI）可对单次会话关闭。
GUI 不读取该目录。

```powershell
python run_cli.py agent history                 # 列出会话（时间/来源/模组/消息数/标题/id）
python run_cli.py agent history show last       # 回看某次会话内容（last=最新一条）
python run_cli.py agent history resume last     # 恢复会话并继续对话（上下文接上）
python run_cli.py agent chat --resume <id>      # 同上，chat 方式进入
python run_cli.py agent history delete <id>     # 删除一个会话
python run_cli.py agent history clear           # 清空全部（交互确认，-y 跳过）
```

恢复时历史消息会自动归一化为 OpenAI 风格，因此换协议（如 anthropic →
openai_compatible）后仍能无缝续聊。REPL 内 `/agent history` 同效；TUI 聊天
面板点「📜 历史」打开会话列表，↑↓ 选择即预览，回车 / 「▶ 继续会话」载入
聊天面板接着对话（继续写回同一会话文件），另支持删除 / 清空 / 刷新。

## 8. 云同步（手动上传 / 下载 Mod）

CLI/TUI 直接复用后端同步引擎（7 种驱动：local / webdav / openlist / 百度 /
123 / Google Drive / OneDrive；阿里云盘、夸克、天翼已停止支持，历史配置
会在操作时提示改用 OpenList 代理）。配置存于
`<workspace>/.editor_cloud.json`，**与 GUI 云页同一份**。

```powershell
python run_cli.py cloud providers              # 列出（GUI 配好的直接可见）
python run_cli.py cloud add                    # 交互式新增（选驱动 → 按 schema 问询字段）
python run_cli.py cloud add --type local --name 备份 --remote-root mods --cfg root=D:ackup
python run_cli.py cloud test <id>              # 测试连接
python run_cli.py cloud show <id>              # 详情（敏感字段掩码，--reveal 明文）
python run_cli.py cloud remove <id>            # 删除配置（远端文件不受影响）

# 同步（upload=本地→远端, download=远端→本地, sync=双向新者为准）
python run_cli.py cloud sync <id> --mod test --dry-run        # 只预览
python run_cli.py cloud sync <id> --mod test                  # 上传（增量）
python run_cli.py cloud sync <id> --mod test --direction sync --delete-extra
python run_cli.py cloud sync <id> --mod test --files readme.txt,Cfgs/zh-cn/EvtCfg.json
```

说明：
- 实时自动同步仍是 GUI 专属（realtime_sync）；CLI/TUI 为手动触发。
- 同步结果按动作汇总（上传新增/更新、跳过一致、删除多余…），失败文件单独列出。
- `--dry-run` 建议先跑一次，确认 `delete-extra` 影响范围后再真跑。
- TUI 内按 `c` 打开云同步面板：左侧选择网盘并测试，`新增 / 编辑 / 删除` 直接
  维护 provider（按驱动 schema 动态出表单，敏感字段掩码回显、保存保留原值），
  右侧选方向 / DRY-RUN / 删除多余后开始同步（后台线程 + 进度条），Esc 可随时关闭。

### REPL Tab 补全（agent / cloud）

REPL（`python run_cli.py` 无参进入）内 Tab 补全已覆盖 `agent` / `cloud` 全族
（裸词 `agent` / `cloud` 也可直接输入）：

- 子命令级：`/cloud ` → providers/add/test/show/remove/sync；`/agent ` → setting/config/chat/history
- 网盘 ID：`cloud test|show|remove|sync <Tab>` → 已配置 provider 的 id + 名称 [类型]
- 会话 ID：`agent history show|resume|delete <Tab>` / `agent chat --resume <Tab>`
  → 最近 30 个会话的 id + 标题·条数（`last` = 最新一条）
- 值补全：`--type`（10 种驱动）、`--direction`（upload/download/sync）、
  `--remote-root`（mods/cfgs/save）、`--provider`（三种 AI 协议）、
  `-m/--mod`（Mod 列表）；`cloud add --cfg` 提示为 `<驱动字段 k=v>`
- Flag 补全：未用过的 flag 自动去重提示（含 `--dry-run`、`--delete-extra`、`--reveal` 等）

## 9. 配音（TTS：合成 / 音色 / 素材）

CLI 可把文本合成为语音素材（阿里云 DashScope 百炼 / MiniMax T2A V2），保存到
`<mod>/audio/tts/` 并登记 `Cfgs/zh-cn/AudioCfg.json`。配音配置与 GUI 设置页共用
`.editor_ai.json` 的 `tts*` 字段（**三端共享**；`agent config` 的交互流程里也可顺带配置）。

```powershell
# 查看 / 交互式配置配音服务（provider、apiKey、groupId、baseUrl、model、voice、speed）
python run_cli.py tts config
python run_cli.py tts config --json      # JSON 输出（完整设置，ttsApiKey 打码为 ***）

# 列出音色（缺省取设置里的 ttsProvider，再缺省 aliyun；并标注来源：在线拉取 / 内置音色表）
python run_cli.py tts voices
python run_cli.py tts voices aliyun
python run_cli.py tts voices aliyun --model cosyvoice-v2   # 按模型切换内置音色表

# 连通性测试（minimax 拉一次音色列表；aliyun 会真实合成一句短文本后丢弃）
python run_cli.py tts test
python run_cli.py tts test minimax

# 合成并保存（默认自动登记 AudioCfg；wav 自动转 Ogg，本机需装 ffmpeg/oggenc）
python run_cli.py tts synthesize "欢迎来到学生时代" --mod test
python run_cli.py tts synthesize --mod test --key talk_intro_01 --voice Cherry "正文文本"
echo 长文本… | python run_cli.py tts synthesize - --mod test     # '-' 从 stdin 读取
python run_cli.py tts synthesize "文本" --mod test --no-cfg --raw-wav  # 不登记 / 保留 wav

# 素材管理（模组定位与 cfg 命令一致：唯一模组自动选定，多模组需 --mod）
python run_cli.py tts list --mod test
python run_cli.py tts delete talk_intro_01.ogg --mod test        # y/N 二次确认
python run_cli.py tts delete audio/tts/talk_intro_01.ogg --mod test --force
```

说明：

- `--provider/--voice/--model/--speed` 可单次覆盖共享设置（不改 `.editor_ai.json`）。
- `--key` 为素材键名（缺省 `tts_<时间戳>`），AudioCfg 的 `url` 登记为 `audio/tts/<key>`（与落盘路径一致、不带扩展名）；建议以 `talk_` 等前缀自行命名。
- 不写 `TalkCfg.vocals`（原版无逐行配音通道），只登记 AudioCfg，素材由 mod 作者自行接入。
- 未配置 apiKey 时 `synthesize` / `test` 返回中文错误提示；先运行 `tts config` 完成配置。
- 合成结果为 wav；`ffmpeg` / `oggenc` 任一存在即自动转 Ogg（游戏原生格式），无编码器时保留 wav。

## 10. 插件管理（Plugin）

插件是第三方 Python 代码，可与编辑器同权限运行（读文件 / 网络 / 系统调用）。
**安装默认停用；启用是唯一闸门**——三端每次启用都要高危确认，确认后才写
`risk_ack_at` 留痕（服务端强制校验，无法绕过）。详见 `PLUGIN_GUIDE.md`。

```powershell
python run_cli.py plugin list                     # 列出全部插件
python run_cli.py plugin info hello_plugin        # 详情（含四类贡献 / risk_ack_at）
python run_cli.py plugin install ./hello_plugin.zip   # 安装（默认停用；已被占用 id 拒绝）
python run_cli.py plugin enable hello_plugin      # 启用：高危确认 y/N
python run_cli.py plugin enable hello_plugin --yes     # 跳过高危确认（CI / 脚本）
python run_cli.py plugin disable hello_plugin     # 停用
python run_cli.py plugin uninstall hello_plugin   # 卸载（须先停用）
python run_cli.py plugin reload                   # 重载全部已启用插件（改代码后生效）
```

- 插件贡献四类：HTTP 路由、AI Agent 工具、GUI 面板、CLI 命令。
- 已启用插件注册的 CLI 命令按全名直接调用：`python run_cli.py hello_plugin.greet 同学`。
- REPL（`python run_cli.py` 无参进入）内 `/plugins` 查看与操作插件；插件命令同样
  可直接输入。
- TUI 插件屏：**空格** = 启用 / 停用（启用走确认框）、**i** = 详情、**r** = 重载、
  **d** = 卸载。
- 示例插件与完整指南：`examples/plugins/hello_plugin`、`PLUGIN_GUIDE.md`。
