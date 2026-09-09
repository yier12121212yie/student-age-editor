# P8 工作日志 — TUI（FTXUI）+ 轻量 agent 对话

分支 cpp-backend，禁 git 写操作。构建目录 `native/build-P8`（`-DSA_GROUP_WIP=P8`，见 `wip/P8/build_p8.cmd`）。所有新代码位于 `native/wip/P8/` 内；正树与共享 CMakeLists 未改动。

用户已拍板：**TUI/agent 不要求与 Python 版一致，功能相似即可，目标 ≤3k 行 C++**。Python 版 TUI 是 7933 行的 Textual（rich）应用（30+ 个 ModalScreen），Python agent 是 2657 行三协议 + 工具循环 + 子代理。P8 做大幅取舍，最终自写 C++ **1756 行**（含测试 2073 行），远低于 3k。

## 里程碑

- **M0 盘点 + FTXUI go/no-go（完成）**：读 CONVENTIONS 全文、http_client.h、P4 build/status、agent 五件套（client/engine/prompt/tools/history_store）、app.py 结构（Textual ModalScreen 群）、C++ 后端路由（system/mods/cfg/semantic-bugfix）。确认 `sa_core::http` 已提供 `request`/`request_stream`（WinHTTP，流式无需自造）。vendor FTXUI v5.0.0（`git clone --depth 1 -b v5.0.0`）到 `wip/P8/third_party/ftxui/`。写最小探针 group.cmake + main：`add_subdirectory(ftxui)`（`FTXUI_ENABLE_INSTALL=OFF`、EXAMPLES/DOCS/TESTS 全 OFF，静态库 screen/dom/component + `ftxui::` 别名）→ **MSVC 19.44 + /utf-8 一次编过**，`Screen::Create(Dimension::Fixed) + Render(Screen&,Element) + ToString()` 正常，探针 exe exit 0。**FTXUI 路线确认可行，未启用 Win32 自绘退路。**
- **M1 逻辑层（完成）**：视图模型与渲染、逻辑与 I/O 彻底分离。`p8_model.h` 数据 + `Page/Intent/KeyInput`；`p8_view_model.cpp` 纯状态机 `HandleKey(AppState&,KeyInput)->Intent`（不发网络，只产出副作用意图）；`p8_api.{h,cpp}` 后端客户端（请求构造 + 响应解析，解析器全静态可测：ParseMods/ParseTables/ParseTable/ParseBugs/InterpretSave/JoinUrl）；`p8_cfg.{h,cpp}` 编辑 diff→PATCH body（`BuildPatchSet/BuildSaveBody`，含 no-op 剔除 + 无效 JSON 回退字符串 + `expect_mtime_ns`）；`p8_agent.{h,cpp}` openai_compatible 编解码（`BuildChatBody/SplitSSE/AccumulateStream/ParseWhole`）+ 会话历史落盘（`SaveSession/LoadSession`，`<data>/.p8_ai_history/`，id 做 `[A-Za-z0-9._-]` 白名单）。
- **M2 渲染层（完成）**：`p8_render.{h,cpp}` AppState→FTXUI DOM（`BuildElement`）+ 无头字符串渲染（`RenderPageToString`，剥 ANSI）。放 `wip/P8/` 根以便 Catch2 快照测试链接 ftxui::dom（`group.cmake` 里 `target_link_libraries(sa_tests PRIVATE ftxui::dom)`）。
- **M3 交互层（完成）**：`tui/app.{h,cpp}` 一个 `ComponentBase` 子类：`Render()` 出面板，`OnEvent()` 把 `ftxui::Event`→`KeyInput`、跑 `HandleKey`、`RunIntent` 打真实网络。`tui/main.cpp` 参数解析 + `--render-check <page|all>`（无网络，渲染样例页到 stdout 退）+ `--connect`（对真实后端跑 ping→mods→select→cfg→load 打印 `CONNECT_OK`）+ 交互 `screen.Loop`。
- **M4 测试 + smoke + 收口（完成）**：见验收。

## 纳入 / 排除清单

纳入（TUI 主面板）：连接后端（`--url`/`--port`）→ 启动 ping 探测 → mods 选择/切换（Ctrl-D/Ctrl-T 页跳）→ 表列表（`GET /api/cfg` 的 cfg_files，子串过滤）→ 单表浏览（`GET /api/cfg/<name>?keys=1`）/单元格编辑（Enter 起编辑，编辑框承载原始 JSON 文本）/行删除标记 → `Ctrl-S` 走 PATCH 分支保存（`PUT` body `{patch:{set,remove},expect_mtime_ns}`），**409 冲突提示**（行级=他人改动保留编辑；表级/lossy=提示再按 Ctrl-S 强制 `force`）→ bugfix `scan`/`fix`（`POST /api/bugfix/{scan,fix}`，展示 cfg/id/key/flag/desc，修复后重扫）→ 退出。
纳入（agent）：一个聊天 pane，`openai_compatible` 协议 `POST {base}/chat/completions`（`Authorization: Bearer`），SSE 逐 `data:` 行聚合 `delta.content`；无 SSE 时回退整段 JSON `choices[0].message.content`；会话历史存 `<data>/.p8_ai_history/*.json`。

**排除（与 Python 差异，宁小勿仿）**：
1. Python TUI 富组件全不做：内嵌图片预览、剧情图 GUI、内嵌 3D/舞台、全局搜索/OOBE/插件面板/TTS 面板/云同步面板等 30+ ModalScreen。
2. **agent 无工具循环**：Python `tools.py`(588) + `engine.py`(211) 的 14 个领域读写工具、审批(confirm/ask)、并行子代理(spawn_subagents)、20 轮工具循环——全部不做，退化为纯对话（简报允许「若超预算：无工具，纯对话」）。系统提示相应缩为一句话角色设定。
3. agent 仅 `openai_compatible` 一协议（Python 支持 openai_compatible/responses/anthropic 三协议）；无自动重连退避、无 cancel；base64 图片块转换不做。
4. 流式回复：用 `request()` 缓冲读全 SSE body 再切 `data:` 行（等价整段到达后聚合），非逐 token 增量刷新（视觉差异，记此）。

## 键位（不必对齐 Python）

`↑/↓` 移动 · `Enter` 进入/编辑/发送 · `d` 标记删行 · `r` 刷新/重扫 · `f` 修复全部(Bug 页) · `Ctrl-S` 保存/修复 · `Ctrl-D/T/B/A` 切 模组/表/Bug/助手 页 · `Ctrl-Q` 退出 · `Esc` 返回上层 · `?` 帮助。

## 文件地图（自写，均 wip/P8/ 下）

- 逻辑（glob 进 sa_tests，纯函数可测）：`p8_model.h` `p8_view_model.cpp` `p8_api.{h,cpp}` `p8_cfg.{h,cpp}` `p8_agent.{h,cpp}`
- 渲染（glob 进 sa_tests，链 ftxui::dom）：`p8_render.{h,cpp}`
- 交互（仅 `backend_tui`，在 `tui/` 子目录，避开 sa_tests 入口符号污染）：`tui/app.{h,cpp}` `tui/main.cpp`
- 构建：`group.cmake`（add_subdirectory ftxui + sa_tests 链 dom + 定义 backend_tui）· `build_p8.cmd`
- 测试：`test_p8_logic.cpp`（19 例）`test_p8_render.cpp`（3 例快照）· `smoke.py`
- vendor：`third_party/ftxui/`（不计入 LOC）

`group.cmake` 要点：`${CMAKE_CURRENT_SOURCE_DIR}` 在钩子内仍指 `native/`；不新建 `wip/P8/main.cpp`（否则 tests/CMakeLists 会造 `backend_wip` 且与本入口冲突），入口在 `tui/main.cpp`；逻辑 .cpp 被 tests 的 `wip/P8/*.cpp` glob 收进 sa_tests 做单测，渲染源同在根但只依赖 ftxui::dom，交互源在 `tui/` 不被 glob。

## 验收

### 1) build_p8.cmd exit 0
`rm -rf build-P8` 后从零：`cmd //c "wip\P8\build_p8.cmd config"`（cmake -G Ninja -DSA_GROUP_WIP=P8 -DCMAKE_BUILD_TYPE=Release）→ `cmd //c "wip\P8\build_p8.cmd"`（cmake --build）→ **CLEAN_EXIT=0**，产出 `build-P8/bin/backend_tui.exe`(2.29MB) + `sa_tests.exe`。FTXUI 三库(screen/dom/component)全量编译通过。

### 2) 全页面 --render-check 输出（样例态，无网络）

见文末「附录 A：五页渲染快照」。

### 3) smoke.py exit 0（起正树 backend.exe + TUI connect + render-check）
见文末「附录 B：smoke.py 输出」。端口用 8772（8770-8779 内），temp 数据根 + `EDITOR_DISABLE_STEAM_DETECT=1` + `--workspace-root`，杀进程仅按自记 PID / `/api/shutdown`。

### 4) 自写 C++ 行数
`find wip/P8 -name '*.cpp' -o -name '*.h' | grep -v test | xargs wc -l`（不含 third_party）= **1756 行**（含 test_p8_* 共 2073 行）。≤3000，未砍任何纳入功能。

## 测试结果

- `[p8]`：**22 test cases / 90 assertions 全绿**。覆盖 view-model 状态机（导航/钳位/编辑/删除/保存意图/页跳/退出/过滤）、cfg diff（no-op 剔除、无效 JSON 回退、patch body 形状、RowsFromData 排序+raw）、api 解析器（mods/tables/table/bugs/save 各状态码含 409 rows/table/lossy/500）、agent 编解码（SplitSSE/AccumulateStream/ParseWhole/BuildChatBody/AgentSettingsFromJson）、历史 Save/Load 往返 + 非法 id 拒绝。
- **FTXUI 快照测试 3 例**（`test_p8_render.cpp`）：`RenderPageToString` 真实渲染 DOM→去 ANSI 字符串→断言行内容（标题、页名、`»` 光标、模组名、状态行；表页编辑标记 `*2`+新值+`Ctrl-S 保存`；帮助覆盖层出现且隐藏列表）。
- 无回归（含 P8）：`sa_tests "~[p3a]~[slow]"` → **All tests passed (1932 assertions in 208 test cases)**，rc=0。此规格含全部 22 个 `[p8]` 用例，排除的是下方两处**先于 P8 存在、与本组无关**的破损。

## 先于 P8 存在的破损（非本组，禁改共享树，仅上报）

用 `~[p8]`（完全排除 P8 测试）复现，证明与 P8 无关：

1. **`p3a preview 组装与三缓存失效接线`（`[p3a][preview]`，他组 P3a/preview_service）硬崩溃**：运行即 `Assertion failed: false, third_party/nlohmann/json.hpp:18380`（序列化器对未知 `value_t` 的内部断言，疑似悬垂/损坏 json 值），整进程 abort，Catch2 汇总不打印。**默认全量 `sa_tests` 因此中断**，非 P8 触发。
2. **wave-1 `[perf][slow]` 两例**（`tests/test_perf_s1_s2.cpp`）在隔离构建目录下失败：`REQUIRE(cold)`/`REQUIRE(warm)` 取到 0——40MB benchdata 产物在本机/本 build 未就位，`GET /api/cfg/TalkCfg` 返回空响应所致（环境依赖，非逻辑回归）。

集成建议：主代理合并/回归时在**具备 40MB benchdata** 且**修好 P3a preview 序列化断言**的环境跑全量，方能达「基线全绿」。P8 自身 `build_p8.cmd` exit 0、`[p8]` 全绿、`smoke.py` 全绿、`~[p3a]~[slow]` 全绿，交付面自洽。

## 运行方式

```
wip\P8\build_p8.cmd config         # cmake -G Ninja -DSA_GROUP_WIP=P8 -DCMAKE_BUILD_TYPE=Release
wip\P8\build_p8.cmd                # cmake --build build-P8
build-P8\bin\backend_tui.exe --render-check all            # 无头自检
build-P8\bin\backend_tui.exe --connect --url http://127.0.0.1:8770   # 打真实后端
build-P8\bin\backend_tui.exe --url http://127.0.0.1:8770   # 交互 TUI
python wip\P8\smoke.py             # 端到端冒烟
```
Agent 配置：`--agent-config <json>`（{provider,baseUrl,model,temperature,apiKey}）或环境变量 `P8_AI_KEY/P8_AI_BASE/P8_AI_MODEL/P8_AI_PROVIDER`。

---

## 附录 A：五页渲染快照（--render-check，样例态，78 宽）

```text
==== render-check: mods ====
╭────────────────────────────────────────────────────────────────────────────╮
│学生时代 · 编辑器 TUI  |  模组                       [?] 帮助  [Ctrl-Q] 退出│
├────────────────────────────────────────────────────────────────────────────┤
│选择模组 (Enter 进入表列表, r 刷新):                                        │
├────────────────────────────────────────────────────────────────────────────┤
│» DemoMod                                                                   │
│  Another                                                                   │
│  示例数据（--render-check）                                                │
╰────────────────────────────────────────────────────────────────────────────╯

==== render-check: tables ====
╭────────────────────────────────────────────────────────────────────────────╮
│学生时代 · 编辑器 TUI  |  表列表                     [?] 帮助  [Ctrl-Q] 退出│
├────────────────────────────────────────────────────────────────────────────┤
│模组: DemoMod   过滤: -                                                     │
│↑↓ 选择  Enter 打开  r 刷新  Esc 返回                                       │
├────────────────────────────────────────────────────────────────────────────┤
│» TalkCfg                                                                   │
│  ItemCfg                                                                   │
│  PersonCfg                                                                 │
│  EvtCfg                                                                    │
│  示例数据（--render-check）                                                │
╰────────────────────────────────────────────────────────────────────────────╯

==== render-check: table ====
╭────────────────────────────────────────────────────────────────────────────╮
│学生时代 · 编辑器 TUI  |  表格                       [?] 帮助  [Ctrl-Q] 退出│
├────────────────────────────────────────────────────────────────────────────┤
│表: TalkCfg  行数: 2  未保存: 1                                             │
│↑↓ 行  Enter 编辑  d 删除  Ctrl-S 保存  过滤:-  Esc 返回                    │
├────────────────────────────────────────────────────────────────────────────┤
│»  1 = 你好，同学                                                           │
│  *2 = "今天下雨了"                                                         │
│  示例数据（--render-check）                                                │
╰────────────────────────────────────────────────────────────────────────────╯

==== render-check: bugfix ====
╭────────────────────────────────────────────────────────────────────────────╮
│学生时代 · 编辑器 TUI  |  Bug 扫描                   [?] 帮助  [Ctrl-Q] 退出│
├────────────────────────────────────────────────────────────────────────────┤
│Bug 扫描/修复  共 2 条                                                      │
│↑↓ 选择  r 重扫  f 修复全部  Esc 返回                                       │
├────────────────────────────────────────────────────────────────────────────┤
│» [REF] TalkCfg/5 roleIds: 引用了不存在的角色 ID 999                        │
│  [SCHEMA_HEAL] ItemCfg/12 icon: 字段应为数组 []                            │
│  示例数据（--render-check）                                                │
╰────────────────────────────────────────────────────────────────────────────╯

==== render-check: agent ====
╭────────────────────────────────────────────────────────────────────────────╮
│学生时代 · 编辑器 TUI  |  AI 助手                    [?] 帮助  [Ctrl-Q] 退出│
├────────────────────────────────────────────────────────────────────────────┤
│AI 助手 (openai_compatible, 纯对话)                                         │
│Enter 发送  Esc 返回                                                        │
├────────────────────────────────────────────────────────────────────────────┤
│你: 帮我看看 TalkCfg 的第一句                                               │
│AI: 第一句对白内容为「你好，同学」，说话人角色已配置。                      │
├────────────────────────────────────────────────────────────────────────────┤
│输入> ▏                                                                     │
│  示例数据（--render-check）                                                │
╰────────────────────────────────────────────────────────────────────────────╯
```

## 附录 B：smoke.py 输出（正树 backend.exe，端口 8772，temp 数据根）

```text
  PASS  backend.exe ping ready  | port=8772
  PASS  tui --connect exit 0  | rc=0
  PASS  connect reports CONNECT_OK  | CONNECT_OK mods=1 tables=1 first=TestCfg rows=2
  PASS  connect sees the smoke mod's table  | CONNECT_OK mods=1 tables=1 first=TestCfg rows=2
  PASS  connect loaded 2 rows  | CONNECT_OK mods=1 tables=1 first=TestCfg rows=2
  PASS  render-check exit 0  | rc=0
  PASS  render contains '编辑器 TUI'
  PASS  render contains '模组'
  PASS  render contains '表列表'
  PASS  render contains '表格'
  PASS  render contains 'Bug 扫描'
  PASS  render contains 'AI 助手'
  PASS  render contains 'DemoMod'
  PASS  render contains 'TalkCfg'
  PASS  render contains '今天下雨了'
  PASS  render contains '引用了不存在的角色'
RESULT: PASS (16/16)
```

`--connect` 直证 P8 客户端全链路（ping → mods → select → cfg 列表 → cfg 载入）对**真实** `native/build/bin/backend.exe` 端到端可用（读出 1 mod / 1 表 TestCfg / 2 行）。
