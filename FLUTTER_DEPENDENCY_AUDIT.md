# Flutter 依赖度审查与重构代价评估

> 对象：`frontend/`（Flutter/Dart 前端）、`native/`（C++ 后端三件套）、
> `build_release.py` + `.github/workflows/`（构建发布链）。
> 方法：静态计量（文件 / 行数 / import / API 面）+ 架构边界走查 + 构建链引用核查。
> 日期：2026-10。**未执行** `flutter build/analyze/test`（当前环境 PATH 无 Flutter SDK），
> 所有数字为源码静态统计，口径见 §10。

---

## 0. 结论先行

| 判断项 | 结论 |
| --- | --- |
| 依赖**深度** | **5/5**：GUI 的全部像素、交互、状态、动画都由 Flutter 绘制，没有任何 DOM/HTML 回退层 |
| 依赖**扩散面** | **2/5**：Flutter 只存在于 `frontend/` 一个目录；后端、CLI、TUI、网关、打包脚本均不依赖 Dart |
| 跨进程耦合 | **0**：前后端唯一契约是 HTTP（168 条路由 + `X-Backend-Token`），换前端不影响后端 |
| 可替换性 | **中**（边界干净是最大利好，但 UI 层代码复用率≈0） |
| 全量重写代价（1:1 复刻，不含新功能） | **中性 18–24 人月**（乐观 8–10，悲观 30–36） |
| 折日历 | 3 人 8–10 个月；5 人 5–6 个月（含回归与双端并行期） |
| **建议** | **不要为「去 Flutter」而重写**。若动机是首屏/体积 → 优化 Flutter Web（1–2 人月）；若动机是长期可维护性/招人 → 先做 2–3 人月内部解耦，再按模块渐进迁移 |

一句话：**「单点深依赖、低横向蔓延」**——Flutter 像一颗整块镶进前端的宝石，
取出来不伤及内脏，但要重新打磨整块宝石。

---

## 1. 依赖边界地图

```
┌──────────────────────────── frontend/ (Flutter, 132k 行 Dart) ────────────────────────────┐
│  main.dart → app.dart → 5 套 Shell（classic / director / editor / mobile / story_flow）      │
│  30 个 feature 域 · 19 条页面定义（1 条隐藏）· 12 个工作台 · 8 个 >2000 行巨型文件           │
│  自绘引擎：剧情图节点画布 / 小地图 / 事件预览（CustomPainter + 原生指针手势）                 │
│  core/：ApiClient(单例) · WorkbenchController · Theme/Tokens · Shortcuts · 条件导入 io/web  │
└───────────────────────────────────────────┬───────────────────────────────────────────────┘
                                            │ HTTP 127.0.0.1:8765（桌面/Android 子进程）
                                            │ 同源 /api/*（Web 由 backend --web-root 托管）
┌───────────────────────────────────────────┴───────────────────────────────────────────────┐
│ native/ (C++20, 77k 行)  server 37.7k · tests 19.7k · tui 6.7k · cli 5.0k · core 3.8k · gw │
│ 3 个可执行文件 + Android .so + gateway；零 Flutter/Dart 依赖                                  │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

**关键事实**：`native/` 里搜不到任何 Flutter/Dart 字样；`frontend/` 里也没有业务数据
落盘逻辑（全部走 API）。这意味着「换前端」在架构上是一次**可切除的外科手术**，
而不是全系统重写。

---

## 2. 依赖程度量化

### 2.1 代码规模（排除生成代码与 `ephemeral` 软链）

| 区域 | 文件 | 行数 | 说明 |
| --- | --- | --- | --- |
| `frontend/lib` | 192 | **102,027** | 其中 UI 类文件 106 个 / 83,965 行；非 UI 86 个 / 18,062 行 |
| `frontend/test` | 124 | **30,175** | 测试/源码 ≈ 30%；213 处 `pumpWidget`，0 个 widget 视觉 golden（对比基线靠断言而非截图） |
| 原生平台壳 | 89 | ~1,600 | Windows 828 + Android 460 + Linux 252 + macOS/web 少量，基本是模板 |
| `native/` C++ | 255 | **77,159** | server 37.7k / tests 19.7k / tui 6.7k / cli 5.0k / core 3.8k / gateway 3.1k |
| 工具链 Python | 39 | 7,844 | `build_release.py`、`packaging/`、`tools/` |
| **自有代码合计** | — | **≈ 217k** | Dart 占 **61%**，C++ 占 36% |

前端按域分布（`lib/features`，92,767 行）：

| 域 | 行数 | 域 | 行数 | 域 | 行数 |
| --- | --- | --- | --- | --- | --- |
| story | 25,836 | editor | 7,679 | shell | 7,059 |
| ai | 8,790 | resources | 4,874 | nocode | 4,075 |
| pages | 3,687 | settings | 3,196 | person | 2,698 |
| preview | 2,415 | warehouse | 1,916 | blocks | 1,781 |
| external | 1,523 | events | 1,511 | space | 1,481 |
| mods | 1,482 | goals | 1,450 | social | 1,377 |
| chats | 1,170 | cloud | 1,159 | messages | 1,093 |
| minigames | 1,087 | oobe | 923 | plugins | 810 |
| 其他（auth/base/files/json/extensions/bugfix） | 3,695 | | | | |

### 2.2 第三方依赖清单（`pubspec.yaml`）

| 依赖 | 类型 | 迁移影响 |
| --- | --- | --- |
| `flutter` (SDK) | 框架 | 100% UI |
| `fluent_ui` ^4.16 | 设计系统（83 处 import） | 需换 `@fluentui/react-components`（React 有近 1:1 对应） |
| `fluentui_system_icons` ^1.1 | 图标字体（71 处，两个 TTF 共 3.6 MB） | 需按图标名逐个映射 |
| `flutter_markdown` | Markdown 渲染（AI 消息） | `react-markdown` 可替代 |
| `audioplayers` | 平台插件（TTS/音频预览） | Web Audio / `<audio>` |
| `file_selector` | 平台插件（导入导出） | File System Access API / 原生对话框 |
| `shared_preferences` | 平台插件（10 处，UI 偏好） | localStorage |
| `http` ^1.6 | **纯 Dart**，可移植 | 逻辑等价重写 |
| `web` ^1.1 | JS interop（2 文件） | 直接删除 |

**利好**：直接依赖只有 9 个，没有 Provider/Riverpod/Bloc/GetX、没有 codegen
（`build_runner`）、没有本地数据库、没有路由包、没有国际化框架。
换句话说，**Flutter 生态的锁定几乎为零**，锁定的是 Flutter 本身。

### 2.3 Flutter API 面（`lib/` 内命中次数）

| 维度 | 命中 | 含义 |
| --- | --- | --- |
| `package:flutter/*` import | 186 | 全量 UI 依赖 |
| `StatelessWidget` / `StatefulWidget` 类 | 128 / 201 | 198 个 `State<...>` 子类 |
| `setState` | **1,231** | 无状态管理框架，逻辑住在 State 里 |
| `showDialog` | 122 | 大量模态编辑（迁移需逐个重建） |
| `Navigator.pop` | 221 | 命令式导航，**0 个路由表/URL 路由** |
| `GestureDetector` | 255 | 手势交互密集 |
| `AnimationController` / `TickerProvider` | 25 / 12 | 自定义动效 |
| `CustomPainter` / `CustomPaint` | 3 个文件 / 8 处 | 剧情图、小地图、事件预览 |
| `MediaQuery` | 51 | 响应式断点（720 / 1024 / 1100） |
| `MethodChannel` | **4**（3 文件） | 桌面外观桥 + Android 后端桥 |
| `dart:io` / `dart:js_interop` | 6 / 2 | 已用条件导入隔离（`*_io.dart` / `*_web.dart`） |

**结构性判断**：这是一个「**逻辑即界面**」的前端——1,231 次 `setState`、198 个 State 类、
8 个超过 2,000 行的文件（最大 `story_director_view.dart` 4,924 行）。
`WorkbenchController` 已抽出 12 个工作台的加载/保存/冲突处理（472 行），
是眼下唯一成规模的可复用逻辑层；其余业务判断仍与 widget 生命周期交织。

### 2.4 分层依赖矩阵

| 层 | Flutter 依赖 | 迁移时可复用 |
| --- | --- | --- |
| native 后端（server/cli/tui/gateway） | **无** | 100% |
| HTTP 契约 / golden 测试（19.7k 行） | **无** | 100%（迁移安全网） |
| 数据模型 / Schema（`assets/schema.json`） | 无 | 100% |
| `frontend/lib/core`（8.4k 行） | 高（含 theme/shortcuts/scaffold） | 约 30%（ApiClient、models、拼音、zip 暂存需重写为 TS） |
| `frontend/lib/features`（92.8k 行） | 100% | ≈ 0 |
| `frontend/test`（30.2k 行） | 100% | 0（用例语义可参考） |
| 构建/发布（`build_release.py`） | 高（34 处 flutter 调用） | 结构可留，`flutter build *` 步骤需换 |

---

## 3. 强耦合点（重构时真正贵的地方）

| # | 位置 | 规模 | 为什么贵 |
| --- | --- | --- | --- |
| 1 | `features/story/story_flow_graph.dart` + `story_flow_workspace.dart` + `minimap` | ≈ 6k 行 | 自绘节点画布：指针命中、框选、吸附、捏合缩放、长按菜单、撤销重做全部手写；Web 需重做 hit-test / transform 数学 |
| 2 | `story_director_view.dart` / `story_studio_editor.dart` | 9.6k 行 | 导演台 / 编剧台两块「应用内应用」，多面板联动 + 内联积木编辑 |
| 3 | `shell/*`（5 套壳）+ `app_theme.dart`（744 行）+ `design_tokens`（30 个 token） | ≈ 11k 行 | 多形态布局 + 亮暗两套调色板 + WCAG 守门测试，换栈即换整套设计系统 |
| 4 | 12 个工作台与 `WorkbenchScaffold` 体系 | ≈ 16k 行 | 表单/表格/三栏布局同构，但每个都有定制交互；迁移可批量但需逐个验收 |
| 5 | `core/backend_launcher_io.dart`（444 行）+ 平台壳 | 444 行 + 模板 | 后端子进程拉起、端口探测、令牌装载、退出清理、debug 源码构建；Tauri/Electron 需重写等价物 |
| 6 | Android 形态（`MainActivity.kt` 161 行 + JNI + `.so`） | 小但关键 | 进程内后端 + 账号缓存 + 导航返回栈，Web 栈无对应物，只能 PWA 或保留 Flutter |

---

## 4. 可复用资产（决定「重写不等于从零」）

- **后端与契约零改动**：168 条路由、19.7k 行测试、golden JSON 快照可直接用来验收新前端。
- **schema 驱动**：字段规则来自 `native/assets/schema.json` + `field_ref_data.dart`（生成物），
  换栈后仍是同一份数据，只是渲染器重写。
- **页面/工作台目录**（`pages_catalog.dart` 266 行、`workbench_registry.dart` 115 行）是纯数据，
  可 1:1 翻译成 TS 路由表。
- **UX 规格文档**：`design/*.md`、`plan/ux_roadmap_*.md` 记录了每个工作台的布局与交互，
  是重写时最好的验收基线（也说明「设计债」很低）。
- **发布工程**：Inno Setup / macOS 重签 / Linux / Android / web 打包流程已验证，
  换栈主要替换「前端构建产物」这一环。

---

## 5. 重构代价模型

### 5.1 口径与假设

- 目标栈按最常见的 **TypeScript + React + Tauri/Electron** 估算（Vue 亦可，
  但 Fluent 设计系统只有 React 官方实现，Vue 需自建组件库，成本 +15%）。
- 「人日」= 1 名熟悉目标栈的工程师 1 天，**含该模块自测**，不含项目管理。
- 基线产能取 **450 行/人日**（AI 辅助、有设计系统对标）；剧情画布按 300 行/人日，
  测试重写按 650 行/人日。
- 不含新功能、不含视觉改版；要求 1:1 复刻现有交互（含快捷键与移动端布局）。

### 5.2 分模块代价

| 组 | 内容 | 行数 | 人日 | 难度 |
| --- | --- | --- | --- | --- |
| A | 应用骨架：5 套 Shell、主题/令牌、快捷键、命令面板、响应式、OOBE/登录 | 16,319 | 55 | 高 |
| B | 剧情域：剧情舞台 / 编剧台 / 剧情图（含画布与小地图）/ 移动端剧情页 / 模板与导入导出 | 25,836 | **110** | 极高 |
| C | 通用编辑内核：Schema 编辑器、19 页面布局、积木库、无代码模式 | 17,222 | 60 | 高 |
| D | 12 个工作台（人物/社交/消息/目标/空间/仓库/小游戏/闲聊/事件/外部对话/JSON/积木） | 16,130 | 45 | 中 |
| E | AI：对话控制器、流式渲染、工具调用与 diff 审批、MCP 客户端、技能/策略 | 8,790 | 30 | 中高 |
| F | 资源与系统：素材库、图片选择、预览、云同步、插件面板、模组管理、更新检查 | 17,730 | 50 | 中 |
| G | 测试重写（124 个文件 / 30.2k 行 → 目标覆盖不变） | 30,175 | 45 | 中 |
| H | 平台壳与发布：窗口/单实例/后端子进程、安装器、macOS 签名、Android（若保留）、CI | — | 35 | 高 |
| I | 联调 / 回归 / 性能 / 输入法 / 快捷键验收（跨 5 平台） | — | 40 | 中 |
| | **合计** | 132k | **≈ 470 人日 ≈ 21 人月** | |

### 5.3 区间与日历

| 口径 | 人月 | 说明 |
| --- | --- | --- |
| 乐观 | **8–10** | 沿用本仓库节奏（AI 重度辅助、1:1 复刻、不做新设计）；质量与回归风险最高 |
| 中性（建议用于预算） | **18–24** | 2–3 人 + AI 辅助，含完整回归与 5 平台验收 |
| 悲观 | **30–36** | 无对标设计系统、移动端与桌面壳全部重做、团队不熟新栈 |

日历：**3 人 ≈ 8–10 个月**，**5 人 ≈ 5–6 个月**（A/C/H 为关键路径，B 可并行但不可压缩）。
若新旧双端并行维护，另加 **20–30%** 成本。

### 5.4 方案对比

| 方案 | 一次性成本 | 风险 | 长期收益 | 适用前提 |
| --- | --- | --- | --- | --- |
| **A. 保留 Flutter，内部解耦重构** | **2–3 人月** | 低 | 中（可维护性↑，为将来迁移降本 10–15%） | 无强制去 Flutter 诉求 |
| **B. 仅做 Web 版（React）+ 保留现有 Flutter 桌面/移动** | 15–18 人月 | 中高（双端分叉） | 高（首屏、SEO、招人） | 有 Web 优先战略 |
| **C. 全量迁移（React + Tauri/Electron，弃 Flutter）** | **18–24 人月** | 高 | 高 | 愿意冻结功能 1–2 个月 |
| **D. 渐进替换（strangler：先工作台后剧情）** | 22–30 人月（总） | 中 | 高 | 不能停功能迭代 |
| E. 换 Compose Multiplatform / Avalonia / Qt | 25–35 人月 | 很高 | 低（同样重写，生态与中文输入细节更差） | 不推荐 |

> 注意：方案 C/D 都会**丢掉 Flutter 的最大红利**——一套代码覆盖 Win/Linux/macOS/Android/Web。
> 若 Android 形态（进程内 `.so` 后端）仍是产品目标，迁移后要么保留 Flutter 移动端，
> 要么退化 PWA，二者都需额外预算。

---

## 6. 隐性成本（最容易漏算的部分）

1. **测试归零**：30.2k 行 widget/单元测试无法迁移；`app_theme_test` / `light_theme_audit_test`
   这类「视觉守门」测试在新栈要重建等价物（对比度、令牌禁用硬编码颜色）。
2. **输入法（IME）**：中文组合输入、候选窗定位在 Flutter 与 DOM 上行为不同，
   所有文本框（AI 对话、JSON 编辑、参数表单）需重新验收。
3. **桌面能力**：窗口尺寸记忆、单实例、退出拦截、剪贴板、右键菜单、
   拖拽文件入窗——Flutter 侧已有实现，Tauri/Electron 需逐项重做并过 3 个平台。
4. **大表性能**：万级记录列表当前用 `ListView.builder`；Web 需虚拟滚动 + 内存管理。
5. **字体与体积**：现有 web 包 **16.1 MB**（`main.dart.js` 5.08 MB、`canvaskit.wasm` 6.95 MB、
   图标字体 3.6 MB）——迁移到 React 首屏可降到 1–2 MB，这是**收益**而非成本。
6. **打包链**：`build_release.py` 有 34 处 Flutter 调用；Windows Inno、macOS 重签、
   Android keystore、Linux/WSL、web zip 五条产物链都要改（约 0.5–1 人月）。
7. **无 i18n 层**：界面中文全部硬编码，迁移只能逐字搬运（顺带抽 i18n 会 +5%）。
8. **版本锁定**：CI 固定 `FLUTTER_VERSION: 3.47.0`，`pubspec` 要求 Dart `^3.13`。
   留 Flutter 也需把「大版本升级」列入固定预算（每次 3–5 人日）。

---

## 7. 风险登记

| 风险 | 概率 | 影响 | 缓解 |
| --- | --- | --- | --- |
| 剧情画布/导演台交互回归 | 高 | 高 | 迁移前录「行为基线」用例；画布最后迁 |
| 双端并行导致功能分叉 | 高 | 中 | 冻结 UI 新需求、契约 golden 兜底 |
| Android/桌面原生能力缺失 | 高 | 高 | 保留 Flutter 移动端，或先做 Tauri 2 能力验证（2 周） |
| 打包/签名链路重做踩坑 | 中 | 高 | 复用一个平台先跑通，再复制到其余 4 个 |
| IME / 快捷键 / 右键菜单差异 | 高 | 中 | 建立跨栈交互验收清单（40+ 项） |
| 新栈性能（大表/长列表/IPC 延迟） | 中 | 中 | 早期做 10k 行表格压测 |
| 团队学习曲线 | 中 | 中 | 若团队只有 Flutter 经验，方案 C 的悲观口径更接近现实 |

---

## 8. 建议

### 8.1 先分清动机（不同动机的答案完全不同）

| 动机 | 建议 | 预算 |
| --- | --- | --- |
| **Web 首屏慢 / 包体 16 MB** | 优化 Flutter Web，不重写：图标字体子集化（-3 MB）、延迟加载剧情/AI 模块（`deferred as`）、复用 CDN 的 canvaskit、按需加载资源 | **1–2 人月**，首屏可望降 60–80% |
| **招人难 / 生态锁定** | 先做方案 A（解耦 + URL 路由 + 状态外置），把「重写成本」降下来，再决定 | 2–3 人月 |
| **要 Web 优先产品形态** | 方案 B/D：新 Web 版按模块替换，Flutter 继续覆盖桌面与移动 | 15–18 人月（首期 6 人月见效果） |
| **必须彻底去 Flutter** | 方案 C：冻结功能 1–2 个月，2–3 人 8–10 个月；先做契约与测试基线 | 18–24 人月 |

### 8.2 若走迁移，推荐的落地顺序

1. **第 0 期（2–3 周）**：冻结前端新功能；把 `native/tests/contract/golden/*.json` 扩成
   前端可复用的契约测试；录 20 条关键交互基线（画布拖拽、保存冲突、快捷键）。
2. **第 1 期（6–8 周）**：搭新栈骨架（Fluent React 组件库、API Client、权限/令牌、
   主题令牌、路由表），迁 3 个低风险页（设置 / JSON 工作台 / 关于与更新）。
3. **第 2 期**：12 个工作台批量迁移（同构，收益最大）+ 资源/素材库。
4. **第 3 期**：AI 面板（流式 + diff 审批）与通用 Schema 编辑器。
5. **第 4 期**：剧情域三件套（编剧台 → 导演台 → 剧情图画布），最后做画布。
6. **第 5 期**：桌面壳（Tauri/Electron）+ 打包签名 + 移动端决策 + 全量回归 4 周。

### 8.3 无论选哪条路，都值得先做的三件事（共 2–3 人月，可复用）

- 把 `story_director_view` (4,924 行)、`story_studio_editor` (4,684)、
  `story_flow_workspace` (3,571)、`schema_editor_view` (3,213) 按「视图 / 状态 / 用例」拆开；
- 把 `WorkbenchController` 模式推广到剧情域与 AI 域（业务逻辑脱离 `BuildContext`）；
- 引入 URL 路由表（当前 221 处 `Navigator.pop`、0 个路由），为任何 Web 化铺路。

---

## 9. 一句话总结

**依赖不浅，但边界极干净**：Flutter 占自有代码 61%、占 GUI 100%，
却只占一个目录、一道 HTTP 边界。真正的代价不在「换框架」，
而在于 84k 行「逻辑住在 widget 里」的界面代码要逐屏重写、30k 行测试要重建。
按中性口径准备 **18–24 人月 / 3 人 8–10 个月**；若只是为了 Web 首屏或可维护性，
**优化与解耦的性价比比迁移高一个数量级**。

---

## 10. 附：复核口径

```powershell
# 前端规模（排除生成代码）
Get-ChildItem frontend/lib -Recurse -Include *.dart -File |
  ForEach-Object { (Get-Content $_.FullName | Measure-Object -Line).Lines } |
  Measure-Object -Sum

# Flutter API 面
$f = (Get-ChildItem frontend/lib -Recurse -Include *.dart -File).FullName
'package:flutter', 'fluent_ui', 'setState', 'showDialog', 'CustomPainter' |
  ForEach-Object { "$_ => $((Select-String -Path $f -Pattern $_ -AllMatches |
    ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum)" }

# 后端路由数
(Select-String -Path (Get-ChildItem native/server -Recurse -Include *.cpp -File).FullName `
  -Pattern '\br\.(get|post|put|del|patch|any)\s*\(\s*R?"' -AllMatches).Count

# Web 产物体积（主包 / canvaskit / 图标字体）
Add-Type -AssemblyName System.IO.Compression.FileSystem
([System.IO.Compression.ZipFile]::OpenRead(
  "dist\web-app-Alpha-v0.7.5.zip")).Entries |
  Sort-Object Length -Descending | Select-Object -First 10 FullName, Length
```

**口径说明**

- 行数含注释与空行；`frontend/windows|linux/flutter/ephemeral/**`（jni 绑定生成物，
  单份 29,019 行）与 `build*` 目录已排除。
- `frontend/test` 计入「前端总量」，但不计入「UI 代码 84k」。
- 人日为估算值（±40%），基于「1:1 复刻 + 现有交互不降级」；若允许简化交互
  （例如放弃框选/捏合/自定义右键菜单），方案 C 可降到 14–18 人月。
