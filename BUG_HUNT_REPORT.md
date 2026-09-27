# 全量 Bug 测试报告（模拟真实用户）

日期：2026-09-27 · 平台：Windows 11 x64 · 被测版本：工作区 main@96cd7b0（含未提交修改）

## 测试覆盖与结论总览

| 通道 | 结果 |
| --- | --- |
| Flutter 自动化套件（frontend/test，478 用例） | ✅ 全绿（~7 skip） |
| native Catch2（sa_tests，413 用例 / 4469 断言） | ✅ 全绿（1 项因未设 EDITOR_BASE_ARTIFACT_DIR 跳过） |
| CLI 全命令族（OOBE/mods/cfg/validate/bugfix/story/search/settings/plugin/cloud/ai/env/repl/错误码） | ⚠️ 主链路可用，发现 3 个功能性失效（#1 #2 #3 #6 #7） |
| TUI（非 TTY 冒烟） | ⚠️ 渲染正常，连接契约违背（#8） |
| GUI Windows 版真机操作（OOBE 7 步 / 模组 / 故事编辑 / 保存 / 预览 / 表编辑 / 文件 / 云 / 诊断 / 插件 / 设置 / 主题 / 最大化） | ⚠️ 主流程可用，亮色主题渲染破碎（#4）、OOBE 建模组无效（#5） |

所有 GUI 写操作均发生在沙箱工作区 `_bughunt/`（复制的 test 模组），未触碰真实
`AppData\...\Mods`；测试后真实 `editor_env.json` 与 git 工作区确认无新增改动。

---

## P1

### #1 CLI `cfg patch --remove` 完全失效（静默不删还报 ok）
- 复现：`backend_cli cfg patch TalkCfg --mod test --remove 9000001001`（或逗号列表）
- 期望：删除该行，`applied_remove: 1`
- 实际：`applied_remove: 0`，退出码 0，数据原样保留。指南示例 `--remove 9001` 照抄即中招。
- 根因：后端 `cfg_store.cpp apply_patch()` 只接受字符串键（`k.is_string()`），CLI 把
  `--remove` 的纯数字 ID 序列化为 JSON number 发送；字符串版 `curl {"remove":["9000001001"]}` 正常。
  两层都有问题：CLI 应发字符串数组；后端对非字符串键应报错而非静默跳过。

### #2 剧情文本导出→导入回环损坏（丢行/串行/说话人丢失）
- 复现：`story export --evt 320101 --out f.txt`（66 句）→ `story import --start-id 4200001 --file f.txt`
- 实际：预览仅 20 行；事件标题行变成第一句对白正文；`----- END -----` 被并入正文；
  未识别说话人（如"男主"）的整句台词被吞或与相邻句合并；已识别说话人（旁白/田俊伟）的角色信息丢失（roleName=null）。
- 影响：指南把导出/导入作为一对功能宣传（"剧情文本导入导出"），用户"导出→改字→导入"会静默毁数据。
- 根因方向：`story_service.cpp` 导入按"行首命中人物池名字"切段，与导出的"说话人独立行+空行分隔+标题行"格式互逆性缺失。至少需要：格式对齐，或导入预览时给"行数与源事件不符"的强警告。

### #3 CLI `cfg get --prefix` 过滤恒为空
- 复现：`backend_cli cfg get TalkCfg --mod test --prefix 32`（表内 65 个键以 32 开头）
- 实际：`records: 0`；`--suffix 1` 正常；新旧两版后端均复现。
- 指南示例 `--prefix 32 --suffix 3 --limit 50` 的前缀部分不可用。

## P2

### #4 GUI 亮色（白日）模式渲染破碎
- 复现：`PUT /api/settings/editor {"appearanceMode":"light"}` → 重启 GUI。
- 实际：主内容区保持深色底，但文字改用亮色主题的深色字（"学生时代模组编辑器"、模组列表名几乎不可读）；
  标题栏仍暗紫；仅部分面板（模组列表卡、状态栏）转白底。稳定态截图已留存。
- 与 README"亮色是另配一套白底深字调色板、WCAG AA 由 app_theme_test 守门"不符——单测只测调色板常量，
  未覆盖真实页面渲染（建议补一张亮色模式下的 golden/visual 测试）。

### #5 OOBE"创建第一个模组"步骤无效（静默失败）
- 复现：OOBE 第②步填模组名 → 完成向导。
- 实际：工作区无新模组、后端无创建请求痕迹、无任何报错提示；同页的云存储步骤正常保存（对照组）。
- 注：向导文案承诺"生成 manifest.json 与 Cfgs/zh-cn 空骨架"。

### #6 CLI 内嵌模式下 `cfg history --undo/--redo` 永远"nothing to undo"
- 复现：默认（无 `--url`）连续执行 `cfg patch ...` → `cfg history EvtCfg --undo`。
- 实际：`history` 能列出磁盘快照（snapshots: N），但 undo 报"nothing to undo"（退出码 1）。
- 根因：撤销栈在后端进程内存（`cfg_store.cpp` g_undo），内嵌模式每条命令起新后端。
  指南示例 `backend_cli cfg history EvtCfg --mod test --undo` 在默认模式下永远不可用；
  同一后端实例（`--url`）下 undo/redo 验证正常。建议：undo 栈落盘（与快照同目录），或文档明确"需 --url 共享实例"。

### #7 CLI `search` 不接全局 `--mod`
- 复现：`backend_cli search 篮球场 --mod test` → `error: The following arguments were not expected: test --mod`（exit 2）。
- 全局 help 声称 `--mod` 对所有命令生效（"本次命令使用的模组"），cfg/validate/story/bugfix 均接受，唯 search 未开 fallthrough。

### #8 TUI 显式 `--url` 探测失败后自起 8770 后端（违背契约，split-brain 风险）
- 复现：8798 有活后端时 `backend_tui --url http://127.0.0.1:8798`。
- 实际：WinHTTP 12029 探测失败 → 打印"尝试自起 backend --port 8770"并连上 8770（默认工作区），
  与指南"显式指定 --url/--port 则只连接不自起"直接矛盾；用户会以为在编辑 A 工作区，实际读写 B。
- 次生问题：WinHTTP 探测对活着的 127.0.0.1 端口报 12029（疑走系统代理未豁免 loopback；同机 CLI 的 HTTP 栈正常）。

### #9 CLI `settings appearance` 子命令未实现
- README/指南承诺 `settings appearance show|light|dark|system`；实际 `settings --help` 只有 `no-code`，
  `settings appearance light` 掉进交互 REPL。

## P3

### #10 CLI `env` 子命令默认数据根 = exe 所在目录
`env set` 无 `--data-root` 时把 `editor_env.json` 写到 `backend_cli.exe` 旁边（实测生成于 build-native/bin/），
与后端/GUI 的数据根不同源：`env set workspace_root` 对后续内嵌命令不生效（`env get workspace_root` 报 no such key），
且安装到 Program Files 后写入会失败/被虚拟化。

### #11 未知子命令静默进入 REPL（退出码 0）
`backend_cli cfg badsub` 不报用法错误而是进交互模式；脚本场景（`>/dev/null`）下错误被吞、退出码 0。
与"裸 `backend_cli` 进 REPL"的设计一致，但 `cfg` 后接未知子命令应属用法错误（exit 2）。

### #12 `cloud remote` 列表不递归
上传 14 文件成功后 `cloud remote` 只显示 2 项（顶层目录 + manifest.json）。同步判定不受影响
（二次 dry-run 正确 skip=14），纯展示 bug；GUI 云页远端列表同源需复查。

### #13 GUI 故事页"配置表"下拉只改标签不切页
下拉选 EvtCfg 后页面仍是故事编辑，需再从左侧分组进入表编辑器；入口语义易困惑。

### #14 GUI 云同步页模组选择器不跟随当前模组
全局当前模组为 test，云页默认选中 FirstMod，文件对比显示"本地 1"（仅 manifest），易误操作同步错模组。

### #15 GUI 剧情库"未加载原版数据"提示与 CLI 数据根不一致
`_cache/base_data.pkl` 已在数据根，GUI 剧情库页仍提示未加载（路径查找逻辑与 CLI/后端不一致，待开发确认）。

## 工具性观察（非产品缺陷，但影响测试/自动化）

- **Flutter Windows 文本输入对自动化不友好**：UIA `SetValue`、TextPattern 插入、SendInput（前台）三条路径
  均无法写入 TextField（值不变）；本次 GUI 编辑流改经"插入对话"按钮 + 后端 API 验证了编辑→保存→落盘→预览全链路正常。
  对真实键鼠用户无影响，但建议核查 Flutter 版本对 UIA TextPattern 的支持（影响读屏软件）。
- `build/bin/` 下的三件套是旧构建（缺 `settings` 命令族），与 `build-native/bin/` 不同步，易误导本地验证；
  本次全部复测已改用 `build-native/bin/`。

## 通过项（抽样）

OOBE 7 步向导渲染与导航、模组列表/选择、故事编辑（插入对白→未保存态→保存→磁盘 66 行、nextTalk 链重连正确）、
对白预览翻页、EvtCfg 字段编辑器、文件页、云同步（provider 创建/测试/整Mod上传/增量收敛）、诊断修复扫描
（与 CLI bugfix 结果一致）、插件页、设置页全分区、最大化布局无溢出、中文字形与 Fluent 观感整体良好；
CLI：mods/cfg CRUD/validate --strict 退出码/bugfix scan/story export/插件装卸/云 local 同步/AI 权限模式/
REPL（/status /search @提及 /use !shell）均正常；错误码 1/2/3 语义符合文档。
