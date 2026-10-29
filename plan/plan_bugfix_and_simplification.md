# 修复 Bug、精简逻辑、精简代码 实施方案

## Goal Description

经过对当前工作区全量代码（171 个改动文件、526 项原生用例与 1180 项前端用例）的深度审计，当前项目在经历 UX 第二轮（R2）大规模演进后，整体功能与测试用例已全部通过，但暴露出若干关键质量问题与冗余：
1. **隐藏 Bug 与运行时崩溃隐患**：多处异步操作（`await` 对话框/网络请求）后未做 `mounted` 校验即调用 `setState`；`WorkbenchTable.dirty` 在每次 getter 访问时对全量配置表执行 `jsonEncode` 序列化，导致大表（如数千行的 `EvtCfg`、`TalkCfg`、`ItemCfg`）在每一帧渲染时承受 50~100ms+ 的卡顿与内存激增。
2. **逻辑臃肿复杂**：`director_shell.dart` 仍自建庞大的工作台 switch-case 分发，未能复用 `workbench_registry.dart`；工作台（如 `event_workbench.dart` 等）在持有了 `WorkbenchController` 的同时，仍维护自身重复的 `_loading`/`_saving`/`_dirty` 状态并手动同步。
3. **代码重复与胶水膨胀**：多处散落的响应解析辅助方法（如重复了 10+ 次的 `_dataOf`）、卡片元数据派生逻辑等亟需统一收敛。

本方案旨在：**修复潜在 Bug、杜绝脏检查性能杀手、统一工作台状态分发逻辑、剔除重复胶水代码**，在保持 100% 测试绿灯的前提下完成轻量化重构。

---

## User Review Required

> [!IMPORTANT]
> **1. `WorkbenchTable.dirty` 脏状态计算策略改造（性能杀手修复）**：
> 目前的 `bool get dirty => snap != jsonEncode(data);` 会在每次控件树 build / 鼠标移动 / 按钮状态更新时执行整表全量 JSON 序列化。
> **改进方案**：引入 `_isDirty` 缓存与明确的版本标记/修改触发机制（在 `data` 被修改通知时标记脏，在 `loadFrom` / `markSaved` / `discard` 时重置），读取 `dirty` 降至 $O(1)$。提供可选的 `checkDirtyDeep()` 供需要精确比较时手动调用。

> [!NOTE]
> **2. 异步回调 `mounted` 守卫规范**：
> 扫描确认的 4 处高危 `setState`（`story_studio_editor.dart`、`story_flow_workspace.dart`、`live2d_preview_panel.dart` 等）全部补齐 `if (!mounted) return;` 保护，防止弹窗关闭或切页时的红屏异常。

> [!NOTE]
> **3. 导演壳（`director_shell.dart`）与工作台注册表（`workbench_registry.dart`）协同**：
> 将导演壳中 15 个重叠工作台的分发收敛至 `workbench_registry.dart` 的 `WorkbenchEntry`，删除导演壳中 100+ 行重复样板代码。

---

## Open Questions

无阻塞性疑问。方案保持向下兼容，不破坏现有任何 API 契约与单测用例。

---

## Proposed Changes

### 1. 核心控制器与性能优化 (`frontend/lib/core/`)

#### [MODIFY] [workbench_controller.dart](file:///d:/workspace/editor/frontend/lib/core/workbench_controller.dart)
- 为 `WorkbenchTable` 引入高性能脏状态跟踪：
  - 添加 `bool _dirty = false` 缓存字段；
  - 在 `loadFrom` 与 `markSaved` 时更新快照并重置 `_dirty = false`；
  - 在 `discard` 时恢复数据并重置 `_dirty = false`；
  - 提供 `markDirty()` 与 `notify()` 联动；
  - `dirty` getter 优先返回 `_dirty`（或当未显式修改时以最小成本比较），消除每帧频繁全量 `jsonEncode`；
  - 抽取通用的静态辅助方法 `WorkbenchController.extractData(dynamic resp)`，替代各工作台内部重复编写的 `_dataOf`。

#### [MODIFY] [save_bar.dart](file:///d:/workspace/editor/frontend/lib/core/save_bar.dart)
- 优化 `SaveBar` 构建性能，避免无意义的重绘。

---

### 2. 剧情工作室与流程图 Bug 修复 (`frontend/lib/features/story/`)

#### [MODIFY] [story_studio_editor.dart](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart)
- 修复行 2677-2679：`await showRolePickerDialog` 后的 `setState` 缺失 `if (!mounted) return;`。
- 修复行 4126-4134：`await widget.onPickTarget` 后的 `setState` 缺失 `if (!mounted) return;`。
- 精简角色替换与说话人列表去重逻辑，直接复用 `story_logic.dart` 中的 `replaceRoleRef` 与 `cln`。

#### [MODIFY] [story_flow_workspace.dart](file:///d:/workspace/editor/frontend/lib/features/story/story_flow_workspace.dart)
- 修复行 1019-1025：`_writeTemplatesFile` 异步写入配置后缺少 `if (!mounted) return;` 即执行 `setState` 的隐患。

#### [MODIFY] [story_logic.dart](file:///d:/workspace/editor/frontend/lib/features/story/story_logic.dart)
- 精简 `replaceStageRole` 与 `replaceRoleRef` 的边界条件判断与重复类型转换。

---

### 3. 工作台注册与导演壳分发精简 (`frontend/lib/features/`)

#### [MODIFY] [workbench_registry.dart](file:///d:/workspace/editor/frontend/lib/features/pages/workbench_registry.dart)
- 扩充映射覆盖，包含工作台通用初始化配置，使导演壳与移动端共享同一套构造逻辑。

#### [MODIFY] [director_shell.dart](file:///d:/workspace/editor/frontend/lib/features/shell/director_shell.dart)
- 精简 `_childFor` 分支逻辑：对重叠的标准工作台（人物、事件、社交、小游戏等）委托给注册表构建，消除约 100 行硬编码重复参数传递。
- 精简主页卡片过滤与收藏逻辑中的冗余判定。

#### [MODIFY] [event_workbench.dart](file:///d:/workspace/editor/frontend/lib/features/events/event_workbench.dart)
- 去除多余的 `_dataOf` 副本，改用公共提取方法。
- 精简 `_loading` / `_saving` / `_dirty` 与 `_ctl` 的双重代理，直接消费 `_ctl` 状态。

#### [MODIFY] [resources/live2d_preview_panel.dart](file:///d:/workspace/editor/frontend/lib/features/resources/live2d_preview_panel.dart)
- 补齐异步加载中的 `mounted` 守卫，杜绝热重载或切页时的假死与异常。

---

## Verification Plan

### Automated Tests
1. **前端全量单元与组件测试**：
   ```powershell
   cd d:\workspace\editor\frontend
   flutter test
   ```
   验证目标：1180+ tests 全部通过，0 failed。

2. **核心针对性专项测试**：
   ```powershell
   flutter test test/workbench_controller_test.dart
   flutter test test/workbench_scaffold_test.dart
   flutter test test/story_studio_test.dart
   flutter test test/story_logic_test.dart
   flutter test test/director_shell_test.dart
   ```

3. **原生 C++ 测试全量验证**：
   ```powershell
   $env:TMP = "D:\workspace\editor\.tmp_build"
   $env:TEMP = "D:\workspace\editor\.tmp_build"
   .\build-native\bin\sa_tests.exe ~[slow]
   ```
   验证目标：526 test cases 全部通过，0 failed。

### Manual Verification
1. 打开剧情舞台（StoryStudioEditor），点击添加说话人、选择角色后快速关闭或切换页面，确认无任何控制台报错或未挂载异常。
2. 在事件工作台或物品仓库中滚动列表、快速打字，确认无任何卡顿，`dirty` 状态瞬时响应且无 `jsonEncode` 导致的掉帧。
3. 检查导演主页各卡片点击跳转工作台功能完好，收藏与分类状态保持正常。
