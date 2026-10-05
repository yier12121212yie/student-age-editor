# UX 优化方案 · 第一轮

> 范围：**整体交互与导航** + **具体工作台/页面**。
> 状态：调研完成，待评审。其它四个方向（OOBE、移动端/响应式专项、无障碍与视觉一致性、性能体验）留待第二轮，见文末「后续轮次」。
> 事实依据：以下每条结论都带 `文件:行号`。行号对应本轮盘点时的代码，实施前请以当时代码为准。

## 实施进度（滚动更新）

已合入（P0 第一、二批，测试 74 项全绿）：

- ✅ **N1 数据安全**：`AppState` 新增多实例守卫注册表 + `runLeaveGuards()`（`core/models.dart`）；
  新增 `core/workbench_guard.dart`（`WorkbenchLeaveGuard` mixin + 统一离开弹窗）；
  11 个工作台（人物/社交/空间/仓库/小游戏/JSON/外部对话/手机消息/目标/事件/闲聊）全部接入，
  切模式、切模组、刷新当前视图前统一确认；切模组后自动重载新模组数据，消除跨模组写入。
  切模式（`app.dart`）与导演壳切模组/刷新（`director_shell.dart`）改走 `runLeaveGuards()`，
  剧情画布/工作室的旧单槽 `leaveGuard` 保持兼容。
- ✅ **N3 删除确认统一**：新增 `confirmDelete()`（`core/app_dialogs.dart`）；
  人物（`person_workbench.dart`）、社交（`social_workbench.dart`）补齐确认，与其它工作台一致。
- ✅ **N6 兑现/止血快捷键**：移除 UI 中并未实现的 `Ctrl+F` / `Ctrl+P` / `Ctrl+S` 文案
  （经典工具栏、创作欢迎页、导演操作说明）。真正接入全局快捷键列为 P1。
- ✅ **N7 命名对齐**：`全局搜索` → `剧情库检索`（导演功能名/主页卡片/经典工具栏/弹窗标题），
  描述改为「原版事件与台词全文检索」，与 `BaseSearchPage`（标题「剧情库」）一致。
- ✅ **N2 窄窗右栏可达**：新增 `core/workbench_scaffold.dart`；窄于
  `WorkbenchLayout.sideBreakpoint`（1000）时右栏收成右侧常驻 rail，点击以浮层抽屉展开
  （带遮罩、关闭按钮），不再整块丢弃。12 个工作台（含积木库）全部迁移。
- ✅ **N8 布局 token**：`WorkbenchLayout` 统一断点（1000 / 1320）与栏宽
  （左 240/300、右 300/340、rail 36），删除各工作台 980/1000/1040/1080 与 188–350 的魔法数。

待办（P0 剩余 + P1）：

- ⬜ **N5 模式直接选择**（浮层选四种模式，替代循环切换）。
- ⬜ **N9 公共工作台骨架**（保存条 / 冲突弹窗 / `_SyncedText` 收敛）、
  **N10 导演文档级历史**、**N11 导演 AI 停靠一致化**、**N12 工作台撤销**、**N13 保活回收**。

---


## 0. 背景

编辑器有 **4 种桌面界面模式**（创作 / 经典 / 剧情图 / 导演）+ **移动壳**，同一份数据（`Cfgs/zh-cn/*.json`）在不同模式下由**不同的界面**编辑。最近几个里程碑集中把「导演」模式做成了以功能总览为首页的工作台，并新增了 12 个专属工作台（人物 / 社交 / 空间 / 物品仓库 / 小游戏 / JSON / 外部对话 / 手机消息 / 目标 / 积木库 / 事件 / 闲聊）。

功能在快速堆积，代价是：**入口、能力、布局、反馈在不同模式/页面之间逐渐分叉**。本轮目标不是再加功能，而是把这些分叉收敛、把明显卡点修掉。

---

## 1. 目标与原则

| 原则 | 含义 | 反面例子（本轮要治的） |
| --- | --- | --- |
| **一致优先** | 同类操作在所有模式/页面行为一致 | 有的删除有确认、有的没有；AI 在导演模式永远是浮层 |
| **入口唯一且可达** | 一个功能有唯一权威入口，任何宽度都能到达 | 窄窗下右侧「设置」栏被直接丢弃、无法打开 |
| **状态可见、破坏可逆** | 脏状态/保存结果明确；破坏性操作可撤销或需确认 | 人物/社交「删除」无确认，用户不知道可回退 |
| **降级不丢功能** | 响应式收窄时改形态，而不是砍掉能力 | 宽度 <1000 时设置栏整块消失 |
| **复用而非复制** | 公共流程沉淀为共享组件 | 12 个工作台各自复制粘贴同一套保存/冲突/保存条逻辑 |
| **多模式=同一能力的皮肤** | 模式只换布局，不换「能做什么」 | 专属工作台只在导演模式存在 |

一句话目标：**让用户在任意模式、任意窗口宽度下，都能找到同一个功能、得到同一套反馈、不会静默丢数据。**

---

## 2. 现状盘点 A：整体交互与导航

### A1. 模式与壳的分工

| 模式 | 壳文件 | 顶层导航 | 内容区 | 是否有「主页/总览」 | 多文档标签 |
| --- | --- | --- | --- | --- | --- |
| 创作 `creation` | `features/shell/editor_shell.dart` | 图标活动栏 `activity_bar.dart` + 侧栏 `shell_widgets.dart:22` | `EditorArea`（`editor_area.dart`，带标签） | ❌ | ✅ |
| 经典 `classic` | `classic_shell.dart` | 顶部工具栏 + 左侧**硬编码分组**导航（`classic_shell.dart:684-718`） | `ClassicPageLayouts` | ❌ | ❌ |
| 剧情图 `storyFlow` | `story_flow_shell.dart` | 顶部标签条 `StoryFlowTopTabs` | 画布 + `_DocView`（复用 `EditorController`） | ❌ | ✅（标签条） |
| 导演 `director` | `director_shell.dart` | 顶部工程栏 + **功能下拉 + 主页卡片网格** | 专属工作台 / `_DirectorPagesView` | ✅（`_DirectorHome`） | ❌（靠 back/forward） |
| 移动 `MobileShell` | `mobile_shell.dart`（宽度 <720 自动启用，`app.dart:446`） | 底部 5 tab + 抽屉 | `SidePaneView` → `PagesList` → `EditorArea` | ❌ | ✅ |

模式选择在 `app.dart:443-460`，按 `ValueKey(_uiMode)` 整壳重建。

### A2. 关键发现

- **专职工作台只活在导演模式。** 12 个工作台全部只在 `director_shell.dart:701-759` 实例化（`grep` 确认无其它引用）。人物、社交、事件等页面在创作/经典/剧情图/移动下走的是通用 `SchemaEditorView`（`editor_area.dart:91-102`、`page_view.dart:172-178`）。→ 同一个「人物」功能，四套体验；用户在创作模式里根本看不到人物工作台。
- **模式切换是「循环」而非「选择」。** 状态栏 `status_bar.dart:101-125`、经典头部 `classic_shell.dart:230-231`、导演头部 `director_shell.dart:562-567` 都是 `nextCycle()` 逐次轮转。直接选择只有设置页（`settings_page.dart:1176-1245`），而该区块在移动端被隐藏（`settings_page.dart:1177`）。按钮文案「切换到 X 布局」有歧义（点了会循环四种）。
- **只有导演模式有「主页」。** 其它模式没有任何功能总览，新用户进去是一组图标/分组/标签，靠猜。全局搜索 `BaseSearchPage` 只覆盖剧情（原版事件 + 台词，`base_search_page.dart:212-214`），不是功能启动器。
- **命名/语义漂移。**
  - 导演模式把 `search` 描述成「跨配置表检索字段与条目」（`director_shell.dart:65`），但实际页面只搜事件与台词。
  - 经典模式叫它「全局功能搜索」（`classic_shell.dart:379`），创作欢迎页也叫「全局功能搜索配置」（`editor_area.dart:593`）。
  - 活动栏「基础库（原数据/读取）」（`activity_bar.dart:218`）与导演功能名「素材库/基础库」口径不一。
- **承诺了没兑现的快捷键。** `Ctrl+F`（`classic_shell.dart:379`、`editor_area.dart:593`、`director_shell.dart:1985`）与 `Ctrl+P`（`classic_shell.dart:385`）在多处被写进 UI 文案，但 `grep` 全仓未发现对应按键处理；全项目唯一落地的全局快捷键是 `Ctrl+Z/Ctrl+Y`（`editor_area.dart:56-64` + `core/history_client.dart:100-105`）。**这是明确的 false affordance。**
- **AI 行为跨模式不一致。** 创作/经典/剧情图在宽布局下停靠、窄布局浮层（`ai_dock.dart:147-213`）；导演模式**永远**是浮层（`director_shell.dart:659-668` 无条件加 `AiOverlayDock`）。且 AI 开关散落在活动栏、状态栏、经典头部、导演头部、导演托盘、移动抽屉等 6+ 处。
- **撤销/重做只在通用编辑区的标签栏。** `editor_area.dart:269-282`。工作台没有撤销，只有「放弃修改」整表回滚（如 `person_workbench.dart:287-293`）。切模式会整壳重建（`app.dart:444`）并销毁 State，工作台脏数据无声丢失。
- **导演历史栈只到功能级。** `director_shell.dart:204-222`，不记录进入的是哪张配置表/哪个页面。

### A3. 数据安全相关（导航引发）

- **切换模组不守卫、不重载工作台。** `_selectMod`（`director_shell.dart:237-263`）只调用 `state.leaveGuard`，而全项目只有剧情相关两处注册了 guard（`story_flow_workspace.dart:242`、`story_studio_editor.dart:383`）。工作台加载数据用 `/api/cfg/<表>`（无模组参数，`person_workbench.dart:136-140`），保存用 `PUT /api/cfg/<表>`（`person_workbench.dart:246`）——**切模组后工作台仍持旧模组数据，保存会写进新模组**（跨模组污染）。工作台也没有监听 `state.modName` 变化重载。
- **导肮切功能靠 Offstage 保活但从不回收。** `director_shell.dart:638-658` 只要访问过就常驻内存；`_refresh`（`226-235`）只重挂当前视图。长时间使用内存与陈旧数据累积。

---

## 3. 现状盘点 B：具体工作台/页面

### B1. 已形成的良好模式（应沉淀为公共件）

12 个工作台几乎逐字复制了同一套流程，说明这套流程本身是被验证过的：

- 快照对比式脏检测：`_dirty`（`person_workbench.dart:208-211`、`social_workbench.dart:126`、`goals_workbench.dart:174`、`event_workbench.dart:163`、`messages_workbench.dart:113` 等）。
- 整表读 + 整表写 + `expect_mtime_ns` 乐观锁 + 409 冲突弹窗（`person_workbench.dart:228-318`）。
- 底部统一保存条：「有未保存的修改 / 已与磁盘同步」+「放弃修改」+「保存修改」（`person_workbench.dart:991-1036`、`social_workbench.dart:1009-1052` 等，`grep` 显示 9+ 处同款）。
- 值同步输入框 `_SyncedText` / `_NumBox`（`person_workbench.dart:2283+`，每个工作台各一份）。
- 三栏结构：列表 | 中心编辑 | 右侧设置/预览。

**问题不是流程不好，而是它被复制了 12 份**：改一处要改 12 处，且已经开始漂移。

### B2. 关键发现

- **窄窗右栏直接被删，功能不可达。** 每个工作台自带一套 `showRight` 阈值，低于阈值时右侧栏**整块不渲染**，且没有替代入口（Tab / 抽屉 / 悬浮按钮）：
  - 社交 `social_workbench.dart:582-594`（<1000 丢弃「动态设置」）
  - 手机消息 `messages_workbench.dart:636-648`（<1000 丢弃「短信设置」）
  - 空间 `space_workbench.dart:632-643`（<1040）｜事件 `event_workbench.dart:712-723`（<1040）｜闲聊 `idle_chat_workbench.dart:640-651`（<1040）
  - 目标 `goals_workbench.dart:600-611`（<1000）｜小游戏 `minigames_workbench.dart:527-538`（<1080）｜仓库 `warehouse_workbench.dart:831-842`（<1080）｜JSON `json_workbench.dart:417-428`（<1080）｜外部对话 `external_dialogues_workbench.dart:892-903`（<1080）
  - 人物 `person_workbench.dart:782-793`（<980 丢弃立绘预览）｜积木库 `blocks_workbench.dart:56-67`（<1040）
  - 导演壳在 720–1000 宽度之间可用，因此这是**常见窗口宽度下的真实功能缺失**。
- **响应式阈值是散落的魔法数。** 断点 980/1000/1040/1080 混用；左栏 188–350、右栏 262–350 各不相同（见上）。没有 token，视觉与手感不统一，也无法用一处调整。
- **破坏性操作确认策略不一致。** 有确认：小游戏 `minigames_workbench.dart:397-402`、JSON `json_workbench.dart:377-381`、仓库 `warehouse_workbench.dart:667-679`、闲聊 `idle_chat_workbench.dart:377`、外部对话 `external_dialogues_workbench.dart:600`。**无确认（立即删）**：人物 `person_workbench.dart:411-428`、社交 `social_workbench.dart:433-451`。虽可「放弃修改」回退，但界面没告诉用户，且与其它工作台行为相反。
- **`BlocksWorkbench` 是异类。** `blocks_workbench.dart:116` 有 `emptyHint`、有「清空」（`:158`）但没有保存条与冲突弹窗——它更像构建器而非整表编辑器，容易被误当成「和别的工作台一样会自动保存」。
- **每个工作台重复实现输入同步控件。** `_SyncedText`/`_NumBox`/`_ListNumField` 多处重复（如 `minigames_workbench.dart:1360/1402/1454`、`goals_workbench.dart:1615/1657`）。

---

## 4. 问题清单（带 ROI）

严重度：🔴 高（数据安全 / 功能不可达）· 🟠 中（一致性与效率）· 🟡 低（打磨）。
ROI = 影响面 ÷ 实现成本。

| # | 问题 | 证据 | 严重度 | 影响面 | ROI |
| --- | --- | --- | --- | --- | --- |
| N1 | 切模组后工作台不重载、保存写进新模组 | `director_shell.dart:237-263`；`person_workbench.dart:136-140,246` | 🔴 | 全体（导演） | 高 |
| N2 | 窄窗右栏整体消失、设置不可达 | 见 §B2 首条（12 处） | 🔴 | 桌面窄窗 | 高 |
| N3 | 破坏性删除确认不一致（人物/社交无确认） | `person_workbench.dart:411`；`social_workbench.dart:433` | 🔴 | 两个高频工作台 | 高 |
| N4 | 专属工作台只在导演模式 | `director_shell.dart:701-759` | 🟠 | 创作/经典/剧情图/移动 | 中 |
| N5 | 模式切换只能循环、无直接选择 | `status_bar.dart:101-125`；`settings_page.dart:1177` | 🟠 | 全体 | 高 |
| N6 | Ctrl+F / Ctrl+P 文案承诺但未实现 | `classic_shell.dart:379,385`；`editor_area.dart:593`；`director_shell.dart:1985` | 🟠 | 桌面 | 高 |
| N7 | 「全局搜索」名实不符（只搜剧情） | `director_shell.dart:65`；`base_search_page.dart:212-214` | 🟠 | 全体 | 高 |
| N8 | 响应式断点/栏宽无 token、各页不一 | 见 §B2 | 🟠 | 全体工作台 | 中 |
| N9 | 保存/冲突/保存条/输入控件重复 12 份 | `person_workbench.dart:208-318` 等 | 🟠 | 维护与一致性 | 中 |
| N10 | 导演无「文档级」历史；无主页的其它模式 | `director_shell.dart:204-222`；各壳 | 🟠 | 全体 | 中 |
| N11 | 导演 AI 恒浮层、AI 开关散落 | `director_shell.dart:659-668`；`ai_dock.dart:147-213` | 🟡 | 导演 | 中 |
| N12 | 工作台无撤销（仅整表回滚） | `editor_area.dart:269-282`；`person_workbench.dart:287-293` | 🟡 | 全体工作台 | 中 |
| N13 | 模式级保活永不回收 | `director_shell.dart:638-658` | 🟡 | 长会话 | 低 |

---

## 5. 优化举措

### 主题一：数据安全兜底（对应 N1/N3/N12）

1. **工作台统一接入「离开守卫 + 模组重载」。**
   - 反对「永远靠 `state.leaveGuard` 单槽」：多文档/多工作台保活时单槽会互相覆盖。建议扩展为**守卫栈**（`List<Future<bool> Function()>`），或给 `AppState` 增加 `registerLeaveGuard(owner, guard)`。
   - 工作台在 `_dirty` 时注册守卫（切模式 `app.dart:134`、切模组 `director_shell.dart:239`、壳刷新 `director_shell.dart:226` 三处统一询问）。
   - 工作台监听 `state.modName` 变化：脏则先问、再 `_loadAll()`。
2. **删除确认统一**：抽 `confirmDelete(context, 描述)` 公共方法，人物/社交补上，其余改用同一文案风格（「确定删除 X 吗？保存前可放弃修改回退」）。
3. **保存条与快捷键**：底部保存条增加 `Ctrl+S` 提示并接入全局保存；确认后写。

### 主题二：响应式「降级不丢功能」（对应 N2/N8）

4. **统一三栏响应式组件 `WorkbenchScaffold`**：输入左/中/右三栏 + 阈值，**低于阈值时右栏自动折叠为可唤起的抽屉/标签**（而不是消失）。
5. **抽出布局 token**：`WorkbenchLayout.{leftW, rightW, railBreakpoint, sideBreakpoint}`，全工作台替换魔法数（`social_workbench.dart:583-584` 等）。建议断点统一为 `compact=1000` 一档，与 `Breakpoints.compact=1100` 对齐讨论。

### 主题三：入口与一致性（对应 N4/N5/N7/N11）

6. **模式切换改为「直接选择」**：状态栏/头部按钮点开浮层，列出四种模式（当前项打勾），点击即切换；保留 `nextCycle` 仅作无障碍/快捷循环。移动端设置页恢复只读提示或至少在「更多」页给选择。
7. **按能力对齐入口**：明确「专属工作台」为人物/社交/事件/…的**权威编辑界面**，在创作/经典/剧情图的 `pages_list`/导航分组里，对已有工作台的页面显示「打开工作台」入口（至少导航跳转到导演模式对应功能）。避免「同功能两套 UI 且能力不同的沉默分叉」。
8. **修正命名**：`BaseSearchPage` 更名/改文案为「剧情库检索（事件 + 台词）」；导演 `search` 描述改为实际能力。若确需跨表检索，单独立项（本轮不做，仅消除误导）。
9. **AI 停靠一致化**：导演改为 `AiDockHost`（可直接复用 `ai_dock.dart:147`），宽度足够时停靠、不足时浮层。

### 主题四：公共骨架，消灭 12 份复制（对应 N9/N10）

10. **抽 `WorkbenchController` + `WorkbenchScaffold`**：把 `_loadAll/_saveAll/_dirty/快照/409 冲突弹窗/保存条` 收敛为一个 mixin/控制器；`_SyncedText`/`_NumBox` 提为 `features/editor` 公共控件。
11. **导演能力历史**：历史栈由「功能」扩展为「功能 + 页面/选中项」，back/forward 更符合直觉。

### 主题五：兑现承诺的快捷键（对应 N6）

12. 要么接入真正的全局快捷键（`Ctrl+F` 开剧情库检索、`Ctrl+P` 开预览、`Ctrl+K` 功能面板），要么从所有 UI 文案里删掉。**不允许继续展示不生效的提示。** 建议实现：本轮实现 `Ctrl+K`（功能面板，见下）并把 `Ctrl+F/P` 接到实际动作。

---

## 6. 路线图（按 ROI，分三批）

### 第一批 · P0（数据安全 + 功能可达，约 1 个迭代）

- [ ] N1 工作台离守/模组重载（守卫栈 + `modName` 监听）
- [ ] N2 `WorkbenchScaffold` 窄屏右栏折叠为抽屉（先覆盖 `social/messages/goals/events` 四个 <1000 的）
- [ ] N3 删除确认统一
- [ ] N6 先**删除**虚假快捷键文案（最小改动止血），或直接接上

### 第二批 · P1（一致性 + 可发现性）

- [ ] N5 模式直接选择浮层
- [ ] N8 布局 token 替换全工作台魔法数
- [ ] N9 抽公共控制器的前两刀（保存条 + 冲突弹窗 + `_SyncedText`）
- [ ] N7 搜索命名/语义修正
- [ ] 新增 `Ctrl+K` 功能面板 / 或让导演主页成为跨模式的「功能总览」入口

### 第三批 · P2（打磨）

- [ ] N4 工作台入口贯通到其它模式
- [ ] N10 导演文档级历史
- [ ] N11 导演 AI 停靠一致化
- [ ] N12 工作台级撤销
- [ ] N13 保活回收策略（超过 N 个功能后 LRU 卸载）

> 依赖关系：N8/N9 是 N2/N4 的前置（先有公共骨架，再谈统一入口）。N1 独立，可立即做。

---

## 7. 验收与守门

- **N1**：新增 widget 测试——脏工作台 + 切模组 → 弹确认；确认后新模组数据已重载。`director_shell_test.dart` 扩展。
- **N2**：新增黄金/尺寸测试——宽度 900 时右栏以抽屉可用，`find` 能定位「保存设置」等控件。
- **N3**：为人物/社交补确认弹窗测试。
- **N5/N6**：`_nextModeIcon` 相关测试改为下拉选择；补快捷键生效测试。
- **主题四**：新增 `workbench_scaffold_test.dart`，并让既有 12 个工作台测试继续通过（防回归）。
- 视觉一致性由既有 `test/light_theme_audit_test.dart` / `app_theme_test.dart` 继续守门；新增布局 token 后补一条「无硬编码栏宽」的静态检查（可选）。

---

## 8. 后续轮次（本轮未覆盖）

按用户确认的范围，以下四项排在第二/三轮，届时各自单独成文：

1. **新用户体验（OOBE）**：`features/oobe/` 流程完整性、空状态与首启引导、帮助内容时效性。
2. **移动端/响应式专项**：`core/responsive.dart`、`mobile_shell.dart` 与工作台在移动端的能力落差（目前专属工作台在移动端完全缺失，见 N4）。
3. **无障碍与视觉一致性**：键盘可达性、Semantics、对比度、减少动效、间距/字号 token。
4. **性能体验**：冷启动、长任务进度与可取消、错误呈现、骨架屏与反馈一致性。

---

## 附：本轮盘点覆盖的文件

- 壳层：`frontend/lib/features/shell/*.dart`、`frontend/lib/app.dart`
- 工作台：`frontend/lib/features/{person,social,messages,goals,events,blocks,chats,json,minigames,space,warehouse,external}/`
- 页面与通用编辑器：`frontend/lib/features/{pages,editor}/`
- 响应式：`frontend/lib/core/responsive.dart`
