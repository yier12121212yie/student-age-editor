# UX 优化 · 第三轮路线图(R3)

> 前情:第一轮 P0(N1–N8,见 `plan/ux_optimization_plan.md`)与第二轮 21 项(见 `plan/ux_roadmap_r2.md`)均已收官。本轮(R3)四个方向经确认全做:
> **① 快捷键断链修复 ② 交互遗留收口(N10–N12) ③ 视觉一致性(复活 R2 暂缓项) ④ 无代码「搭」侧第二轮(A 系列 P0 批)**。
> 文档整理:`design/ux_optimization_plan.md` 与 `design/nocode_optimization_plan.md` 已迁入 `plan/`;其余 design 文档按 `git restore design/` 恢复。

## Goal Description

| 轨道 | 方向 | 状态 |
| --- | --- | --- |
| **W** | 快捷键断链修复:SaveHub + Ctrl+S/F 全壳接通 | ✅ 已完成(实测) |
| **N** | 交互遗留收口:N11 导演 AI 停靠、N10 文档级历史、N12 工作台撤销 | ✅ 已完成(实测) |
| **V** | 视觉一致性:设计 token + 共享组件 + 棘轮冻结 | ✅ 已完成(实测) |
| **A** | 无代码「搭」侧第二轮:family/ops 元数据、概念折叠、自然标签、初始值 | ✅ 已完成(实测) |

---

## 进度快照

| 轨道 | 条目 | 状态 |
| --- | --- | --- |
| W | W1 `SaveHub`(注册栈 + TickerMode 可见性) | ✅ `core/save_hub.dart`;SaveBar 转 Stateful 自注册/注销 |
| W | W2 Ctrl+S = 活动工作台保存(所有壳);SaveBar 提示不再骗人 | ✅ 实测:`app_shortcuts_test` 22 例 |
| W | W3 Ctrl+F 全壳接通(含 story_flow/mobile 注册 openSearch) | ✅ 实测:各壳解析链 host→sheet→SidePane.base |
| W | W4 命令面板「保存当前」按活动对象出现 | ✅ `app_command_builder` 现场解析 `SaveHub.active` |
| N | N11 导演壳改用 `AiDockHost`(宽停靠/窄浮层) | ✅ `ai_dock_adaptive_test` 含导演壳用例 |
| N | N12 工作台撤销/重做(快照栈 50、600ms 合并、SaveBar 按钮 + Ctrl+Z/Y) | ✅ 实测:`workbench_undo_test` 6 例,全工作台回归绿 |
| N | N10 导演历史记到「功能 + 配置表」级,back/forward 恢复 | ✅ 实测:`director_shell_test` 11 例 |
| V | V1 `core/design_tokens.dart`(AppText/AppSpace/AppRadius) | ✅ 画布 token 迁入并 re-export;`.xs`→`.xxs` 值等价重映射 10 处 |
| V | V2 共享组件 `EmptyState` / `SectionHeader` / `StatusPill` | ✅ 实据:8 空态 / 3 头 / 3 徽标(删 2 个重复类) |
| V | V3 基础设施与壳层迁移(token 化) | ✅ save_bar / workbench_scaffold / app_dialogs / app_feedback / mobile_widgets |
| V | V4 `design_ratchet_test.dart` 棘轮冻结(字面量 + 颜色白名单) | ✅ 基线 fontSize 1442 / box 1591 / insets 941 / radius 402;色白名单 7 文件 |
| A | A1 后端 `family` / `ops[]` / 参数 label / `description` | ✅ 实测:`sa_tests "[graph]"` 9 例(含 family/ops 一致性);金标 `api_effect_suggest_*` 同步 |
| A | A2 目录按概念(family)折叠 + 行内算符切换 | ✅ 实测:`blocks_library_test` 4 例(折叠入库/切算符保留值/范围 `[1,3,X,Y]`+记忆值/摘要成句);`effect_block_editor_test` 行内 chips |
| A | A4 自然参数标签 + 非法数值禁用「确定」 | ✅ 实测:label 来自模板(范围=下限/上限);`numberSlotError` 整数规则 + 非法值不关表单。min/max/step 经核实无数据源(DB 仅 desc/code)→ 整数为默认规则 |
| A | A7 新增候选自动带出第一个合法引用 | ✅ 实测:`effect_block_editor_test` 2 例(池首条预填/空池提示「参数「X」没有可用候选」) |
| A | D `singleRow` 三处判定单点化 | ✅ `singleRowForType`/`kSingleRowHint`/`blockCanAddRow`/`applyRowsWithSingleRow` 收于点内;单行约束用例绿 |

> 备注:`pixel_overflow_test` 现存 4 例溢出(SettingsPage/BugfixPanel)经创建链核实,全部来自未提交的用户 WIP(`McpTokenSection` 新文件、`BugfixPanel` 修改),不含任何本轮迁移组件,与 R3 无关。
> 全量 `flutter test` 收尾实测 1233 通过 / 10 失败;10 例已逐例定位到**未提交的用户 WIP 文件**(`mcp_token_section.dart:610` Row 溢出 → creation_shell / pixel_overflow×4 / widget_test;`bugfix_panel.dart` 文案改动 → classic_shell / widget_test;`ai_script_generator` 等 6 个 WIP 文件共 36 处 `Colors.*` → light_theme_audit;`file_upload_client.dart` 漂移未兜底 → r2_fixes),无一本轮改动文件;R3/A 轨自身用例全绿。
> A 轨新增的字号/间距/圆角字面量已同步换算为 `design_tokens`(AppText/AppSpace/AppRadius),`design_ratchet_test` 四项维持基线内(1442/1591/941/402);编译探针 `test/_probe_test.dart` 用后已删。

---

## 轨道 W · 快捷键断链(独立可发布)

**问题(已核实)**:SaveBar 默认显示 `Ctrl+S`(`save_bar.dart` `showShortcutHint=true`)但无人注册 `AppCommandHost.save` → 按了只提示「当前界面没有可保存的内容」;Ctrl+F 仅导演壳注册 `openSearch`,其余壳静默。

**方案**:
1. 新增 `core/save_hub.dart`:`SaveHub` 持 `SaveHandle{dirty, save(), undo?, redo?}` 注册栈(LIFO),`active` 取栈顶;
2. `SaveBar` 转 Stateful,读 `TickerMode.of(context)` 判定可见性——可见即注册、隐藏/卸载即注销(导演壳 Offstage 保活与移动壳 IndexedStack 的 `TickerMode(enabled: 当前)` 天然只留当前一个);
3. `app.dart` `onSave/onSearch` 改走 SaveHub/统一 searchAction 解析:host → 移动壳 sheet → `selectPane(SidePane.base)`;
4. story_flow_shell 与 mobile_shell 各注册 `AppCommandHost(openSearch: …)`,修「假降级」;
5. 命令面板「保存当前」现场解析 `SaveHub.active` 决定是否出现。

**验收**:`app_shortcuts_test` 扩展(挂载→Ctrl+S 调 save;未挂载→提示;Ctrl+F 各壳解析)。

## 轨道 N · 交互遗留收口

- **N11**:导演壳内容栈外包 `AiDockHost`(复用现有组件,`minDockedContentWidth=560` 自适应),删除无条件 `AiOverlayDock`;`ai_dock_adaptive_test` 加导演壳用例。
- **N12**:`WorkbenchController` 有界快照栈(50):在 `_Rev.n` 递增处挂钩子,600ms 去抖窗口合并;`undo()/redo()` 还原 + notifyListeners;SaveBar 加按钮;AppShortcuts 加 Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z(文本输入框自身快捷键更深、先消费)。
- **N10**:历史元素 `_DirectorFeature` → `_NavEntry{feature, cfg?}`,`_openFeatureTable` 入栈配置表,back/forward 恢复并 bump refreshToken。条目级选中不做(后续)。

**验收**:`director_shell_test`(历史恢复)、`ai_dock_adaptive_test`、工作台撤销用例(去抖用 `pump(700ms)`)。

## 轨道 V · 视觉一致性(token + 棘轮)

- `core/design_tokens.dart`:AppText(12/11.5/11/10.5/13/14…按现状簇心)、AppSpace(2–16)、AppRadius(4/6/8/10/12);颜色不新建(app_theme 单一源)。
- 共享组件:EmptyState(≥8 处自写空态实据)、SectionHeader(director_shell / story_detail_mobile_page / story_flow_side_toolbar)、StatusPill。
- 迁移范围:**仅** save_bar / workbench_scaffold / app_dialogs / app_feedback / mobile_widgets / shell 层。
- `design_ratchet_test.dart`:字面量计数(基线=迁移后剩余,只降不升)+ 颜色棘轮(app_theme 外 `Color(0x` 白名单化)。
- 不动 `ExcludeSemantics`(Windows 崩溃有意规避)。

**验收**:每次迁移跑 `light_theme_audit_test` / `app_theme_test`;棘轮先迁移后锁。

## 轨道 A · 无代码「搭」侧第二轮(A 系列剩余)

> 现状核实(R3 开工时):`block_library` 已成句(`,且` 连接 + `toHumanText`),`catalog_visuals` 已人话化标题;A1/A2/A4/A7 未做——现已全部落地(见上方进度快照)。

- **A1(前置,后端)**:`effect_suggest` item 与 `effect/parse` row.template 增 `family` / `ops[]{op,code,valueIndex,upperIndex}` / 参数 `label,min,max,step,unit,choices` / `description`(源:CONDITION_DB/COST_DB 二次索引)。
- **A2**:目录按 `family` 折叠一行,行内算符循环(`= > ≥ < ≤ ≠ 范围`)。
- **A4**:数字槽自然标签替换统一「数值」;非法值禁用「确定」。
- **A7**:新增候选自动带出字典池第一个合法引用;无引用给友好错误。
- **D**:`singleRow` 判定收敛(原清单中 `semantic_graph.cpp:459` 经核实非 singleRow,剔除)。

**验收**:`test_semantic_graph.cpp`(同概念 suggest/parse family/ops 一致、label 非统一);前端回归 blocks_library / effect_block_editor / nocode_zero_input / nocode_workbench_coverage / parse_outcome。

---

## 本轮不做(防蔓延)

无代码 B/C 轨(条件索引、前提库、预设、动作可视化编辑器、事件绑定表单化)、A5/A6/A8、schema 驱动字段判定;N13 保活回收;N10 条目级选中;无障碍/语义专项;视觉全量迁移;后端长任务「真中止」(C5 已单开)。

## 验证命令

```bash
# 前端(flutter test 本机不可用,用仓库驱动脚本)
cd frontend && bash tools/run_flutter_test.sh test/app_shortcuts_test.dart test/save_review_test.dart \
  test/person_workbench_test.dart test/workbench_scaffold_test.dart test/mobile_ux_test.dart \
  test/director_shell_test.dart test/ai_dock_adaptive_test.dart test/design_ratchet_test.dart \
  test/light_theme_audit_test.dart test/app_theme_test.dart test/blocks_library_test.dart \
  test/effect_block_editor_test.dart test/parse_outcome_test.dart test/nocode_zero_input_test.dart \
  test/nocode_workbench_coverage_test.dart
# 全量:flutter test(design_ratchet 四项 + 颜色白名单已锁基线内)

# 原生(TMP/TEMP 指到工作区内)
cd native && bash build/bw.sh -j 1 sa_tests
TEMP='D:\workspace\editor\native\build\tmp' TMP='D:\workspace\editor\native\build\tmp' build/bin/sa_tests.exe "[graph]"
```

## 手工验收

1. 工作台改字段 → Ctrl+S 落盘、SaveBar 变「已与磁盘同步」;无工作台时提示不变。
2. Ctrl+F 在创作/经典/剧情图/移动壳均到检索。
3. 导演壳宽窗 AI 停靠、窄窗回浮层。
4. 工作台改字段 → Ctrl+Z 回退、Ctrl+Y 重做;文本框内 Ctrl+Z 仍是文本撤销。
5. 导演壳「人物工作台→配置表」→ 切走 → 后退回到该配置表。
6. 简易模式:目录按概念折叠、算符行内切换、参数自然标签。
