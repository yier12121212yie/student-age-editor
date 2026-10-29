# 缺陷修复 + 冗余精简 + 性能优化 计划（R2 轮次）

> 状态：**仅计划，未做任何代码修改**。待确认后进入实施阶段。
> 排查方式：四路只读全量审计（前端 Dart 186 文件 / 原生 C++ 466 文件）+ 关键结论逐一人工复核。
> 上一轮 `plan/plan_bugfix_and_simplification.md` → `implementation_plan.md` 已于 2026-10-12 落地，本计划**不重复**已修项。

---

## 0. 前置说明：当前工作区处于「未完成的未提交重构」状态

`git status` 显示：

```
 M frontend/lib/core/models.dart
 M frontend/lib/features/mods/mods_page.dart          (+87 / -109)
?? frontend/lib/features/mods/mod_distribution_hub.dart   ← 新文件，全仓零引用
?? frontend/lib/features/mods/workshop_publish_dialog.dart ← 新文件
 M ... (另有 171 个文件处于改动态)
```

**P0 的三条编译错误全部源于这次未完的 mods 重构**，不是历史遗留。因此第一步必须先决定这次重构的处置方式（见 §7 待确认决策点 Q1），否则后续 P0 修复会与在途改动相互覆盖。

---

## 1. 问题根因定位

### P0-A｜编译错误：`ModInfo` 构造缺参（阻断构建）

- **文件**：`frontend/lib/features/mods/mods_page.dart:372-375`
- **现象**：`ModInfo(name: name, root: '')` 只传 2 个参数，而 `core/models.dart:5-7` 已将 `cfgFiles` / `hasManifest` / `manifestTitle` 全部声明为 `required`。
- **根因**：`models.dart` 的 `ModInfo` 构造函数被扩为 5 个 required 参数后，`mods_page.dart` 中 `firstWhere` 的 `orElse` 兜底分支未同步补齐。
- **影响面**：`mods_page.dart` 被 `classic_shell.dart:16/169/203`、`director_shell.dart:30/612/1114`、`shell_widgets.dart:12/53`、`story_flow_shell.dart:17/243` 引用 → **属于 App 主入口可达路径，整个前端无法编译**。

### P0-B｜编译错误：访问不存在的 `manifestDesc`

- **文件**：`frontend/lib/features/mods/mods_page.dart:379`
- **现象**：`curMod.manifestDesc`，但 `ModInfo`（`core/models.dart:4-24`）只有 `manifestTitle`，无 `manifestDesc`。
- **根因**：同一批重构中新增的「发布到创意工坊」流程需要一段描述文本，误以为 `ModInfo` 已带 `manifest_desc`。`models.dart` 的 diff 只加了 `displayName` getter 与 `AppState.modDisplayName/currentModDisplayName`，**没有**加 `manifestDesc`。
- **影响面**：同 P0-A，编译阻断。

### P0-C｜编译错误：不存在的图标常量（2 处）

- **文件**：`frontend/lib/features/mods/mod_distribution_hub.dart:126` 与 `:207`
- **现象**：`FluentIcons.cloud_backup_24_regular`
- **实测复核**（包已逐字节核对）：
  - 项目 `FluentIcons` 来自 `fluentui_system_icons: 1.1.273`（`pubspec.yaml:38`），**不是** `fluent_ui`。
  - 在 `fluentui_system_icons-1.1.273/lib/src/fluent_icons.dart` 中：`cloud_backup_24_regular` **不存在**（regular/filled 两种形态均无）；同文件中 `qr_code_24_regular`、`globe_24_regular`、`folder_zip_24_regular` **均存在**。
  - 因此该文件**只有** `cloud_backup_24_regular` 是错的，`const Icon(...)` 进一步触发 `const_with_non_constant_argument`。
- **影响面**：该文件目前**全仓零引用**（`ModDistributionHub` 仅自身出现），故不阻断 `flutter build`，但会挂在 `dart analyze`，且一旦接入即刻断链。

### P1-D｜安全问题：tex 资源接口路径穿越 / 任意文件读取

- **入口**：`native/server/services/aa_routes.cpp:457-460`（`GET /api/aa/tex?key=`）、`:465-470`（`GET /api/aa/raw?kind=tex&key=`）
- **根因链**（已逐行复核）：
  1. `aa.cpp:806` `resolve_mod_local_tex_path(key, ...)` 对 `key` 只做两件事：`\`→`/` 归一（`:817-821`）、剥前导 `/`（`:822`）。**既不剥离 `..` 段，也不拒绝绝对路径/盘符**。
  2. `aa.cpp:953-956` 第一轮精确匹配时 `if (sa_core::paths::is_file(norm_k)) exact_paths.push_back(norm_k);` —— 直接对**用户原始串**做 `stat`，命中即返回该路径。
  3. `native/core/paths.cpp:75-80` `join(a, b)`：`if (pb.is_absolute()) return from_fs(pb);` —— 拼接时若 `b` 是绝对路径则**直接丢弃 `a`**，沙箱根失效。
  4. 返回的路径交给 `aa.cpp:1162 fetch_tex_raw` → `aa.cpp:1094 serve_path_bytes`，**无二次沙箱校验**。
- **触发条件**：
  - 相对穿越：`GET /api/aa/tex?key=../../../../<任意文件>`
  - Windows 绝对路径：`GET /api/aa/tex?key=C:/Windows/win.ini`（不以 `/` 开头，故不被 `:822` 剥离）
- **可达性约束**：受 `httpd.cpp:759` 的 `X-Backend-Token` / Origin 门控；**桌面直跑时 `auth_token` 为空，无需令牌**，故本地/内网暴露面内可直接利用。

### P1-E｜并发可用性：全局锁内做网络 IO

- **文件**：`native/server/services/file_transfer.cpp:1422-1481`（`reclaim_expired`）
- **根因**：`std::lock_guard<std::mutex> lk(g_store_mu);`（`:1422`）覆盖**整个回收循环**，而循环体内 `ops.remove(cfg, key, &derr)`（`:1445`）、`ops.multipart_abort(...)`（`:1467`）是对象存储**网络请求**（含超时）。
- **后果**：回收线程运行期间，任何 `files.json` 读写（上传/下载登记 `update_record`、`mark_linked` 等）都会被网络 IO 阻塞。

### P1-F｜并发可用性：锁内做磁盘遍历，与文件自述契约冲突

- **文件**：`native/server/revision_manager.cpp:124-131`
- **根因**：`files = collect_target_files(root);`（`:129`）位于 `std::lock_guard<std::mutex> lk(g_revision_mu)` 临界区内，而 `collect_target_files` 内部做 `exists/is_dir/listdir_sorted` 递归磁盘 IO。
- **自相矛盾**：同文件 `:114-117` 的注释明确写「`g_revision_mu` 只保护元数据……**绝不跨磁盘 IO 持有**」。
- **后果**：大工作区下 revision 轮询会串行化 `set_workspace_root`、缓存读写等所有 revision 元数据操作。

### P2-G｜前端：`await` 后未校验 `mounted`（8 处，已逐处核对）

| # | 文件:行 | 问题 |
|---|---|---|
| 1 | `features/person/person_workbench.dart:439 → :456 / :460` | `await showImageAssetPicker` 后 `AppFeedback.warning(context,…)` 与 `setState` 无守卫（**同文件 `_addOutfit():491` 有正确写法**，属遗漏） |
| 2 | `features/story/story_detail_mobile_page.dart:124 → :161` | `await showDialog<List<String>>` 后 `setState` |
| 3 | `features/story/story_transfer_dialogs.dart:99 → :108` | `:98` 有守卫，但紧接着 `:99` 第二个 async gap 后的 `setState` 落在守卫**之后** |
| 4 | `features/extensions/extensions_page.dart:113 → :115` | `await openFile(...)` 后 `setState` |
| 5 | `features/mods/workshop_publish_dialog.dart:124 → :137` | `async void _startPublish()`（异常无人接收）+ `catch` 内 `setState` 无守卫 |
| 6 | `features/ai/ai_script_generator.dart:105 → :146/:151` 与 `:157 → :159` | `await Future.delayed` 后 `setState`（两个方法） |
| 7 | `features/story/story_studio_tts_panel.dart:133 → :136-137` | `await` 后直接用 `context`（`use_build_context_synchronously`）；`:128` 的守卫在本 await **之前** |
| 8 | `core/app_shortcuts.dart:163/166 → :169` | `ctx = _root.context`，`await` 后仅用 State 的 `mounted` 守卫 **subtree context**（lint 明确报 `guarded by an unrelated 'mounted' check`）→ 应改 `ctx.mounted` |

> 资源泄漏维度：脚本核对 `TextEditingController/ScrollController/AnimationController/FocusNode/ValueNotifier/Timer/StreamSubscription` 均在 `dispose` 中释放，`addListener/removeListener` 配对完备。**唯一泄漏**：`app.dart:127` `pluginState.addListener(匿名闭包)` 未在 `dispose`（`:101-111`）移除。

### P2-H｜前端：后端响应裸强制转换，字段漂移即抛 `TypeError`

- `core/file_upload_client.dart:61-66`：`json['file_id'] as String`、`json['upload_mode'] as String`、`json['threshold_bytes'] as int`、`json['method'] as String` 全无 `is` 判断/兜底。同文件 `:249 (result['errors'] as List)[0]['error'] as String`、`:253 (result['saved'] as List)[0]['path'] as String?` 未校验元素类型。
- `features/ai/ai_chat_controller.dart:1222 / 1247 / 1255 / 1277`：`(r['domains'] as List)`、`(r['dicts'] as List)`、`(r['items'] as List)`、元素 `d as Map<String, dynamic>` 均无兜底（`r['dicts'] != null` 只判空不判型）。

### P2-I｜前端：共享基础设施的状态一致性缺陷

1. **`core/workbench_controller.dart:307` `load()` 无重入/代际保护** — `save()`（`:333`）有 `_saving` 门，`load()` 没有。多表 `await` 循环（`:313`）期间若再次触发 `load()`，两次响应的 `loadFrom` 会交错，**旧响应可能覆盖新响应**。
2. **`core/workbench_controller.dart:203` `dirty => _rev.n != _savedRev`** — `_rev.n` 单调递增，**用户把字段改回原值后内容与快照一致，但仍判为脏**，保存按钮/离开守卫会弹无谓的「未保存」确认。逃生口 `checkDirtyDeep()`（`:206`）经 grep 确认**生产代码零调用**（仅 `test/workbench_controller_test.dart:176` 一处）。
3. **`core/save_service.dart:83` + `_adoptRevision():162`** — `SaveService.instance` 只持**一个**进程级 `_cachedRevision`，多个工作台/云同步并发保存时按「最后写入者覆盖」，可能读到过期指纹 → 假冲突/漏冲突。
4. **`features/mods/workshop_publish_dialog.dart:54` `_ready` 只写不读** — `_checkStatus()` 写入（`:87/:94`）但 UI 从不读取；工坊未就绪（`ready=false`）时发布按钮仍可点击。

### P2-J｜原生：健壮性缺陷

1. **`native/server/services/semantic_bugfix.cpp:611` 未捕获 `std::stoll`** — `buf` 由 `snprintf("%s%02d", evt_id, suffix)` 生成（`:610`），`:608` 只校验**长度**防截断，**未校验 `evt_id` 为纯数字**。`apply_fix` 与调用点 `semantic_routes.cpp:1177` 均无 try/catch → `std::invalid_argument` 冒泡至 `httpd.cpp:777` 兜底为 **HTTP 500**。
2. **`native/server/state.cpp:31-32` 无锁全局 `std::function` 回调** — `g_mod_cfgs_invalidator` / `g_preview_invalidator` 供 `select_mod():355-356` 直接调用；写入点 `api_router.cpp:51-52`、`content_routes.cpp:329` 均在启动期，**目前仅靠启动顺序保证无竞争**，运行期重挂即数据竞争（`std::function` 读写撕裂为 UB）。
3. **`native/server/cfg_store.cpp:55-62` `g_path_locks` 只增不删** — 按路径缓存 `shared_ptr<recursive_mutex>`，无清理路径，长跑时随不同表路径缓慢增长。
4. **`native/server/services/aa.cpp:1130-1140` 嵌套加锁** — 持 `g_aa_mu` 后（`:1131`）再锁 `g_pack_mu`（`:1134`），固定加锁序；仅测试路径调用，但存在反向序即死锁面。
5. **`native/gateway/gw_refresh.cpp:33-35` refresh 令牌哈希用 legacy SHA-256 变体** — `hash_token` 调 `sa_core::sha256_hex`（legacy K 表，`core/sha256.cpp:29-41` 中 `K[27]=0xbf53c9d2` 为已知错误值），而 `gw_api_tokens.cpp:41-45` 用的是真 FIPS 的 `sha256_hex_strict`。`sha256.cpp:16` 注释明确「legacy 表绝不允许参与口令哈希、任何新用途都不得引用」。
   **⚠️ 仅 Linux/WSL 可验证**（`native/gateway/` 为 `if(UNIX)` 专属，Windows 不编译）。

---

## 2. 涉及的模块与文件

| 模块 | 文件 | 关联问题 |
|---|---|---|
| 前端 · mods | `frontend/lib/features/mods/mods_page.dart`、`mod_distribution_hub.dart`、`workshop_publish_dialog.dart`、`frontend/lib/core/models.dart` | P0-A/B/C、P2-G5、P2-I4 |
| 前端 · 公共基础设施 | `frontend/lib/core/workbench_controller.dart`、`save_service.dart`、`app_shortcuts.dart`、`app.dart`、`file_upload_client.dart` | P2-G8、P2-H、P2-I1/2/3 |
| 前端 · 工作台 | `features/person/person_workbench.dart`、`features/extensions/extensions_page.dart` | P2-G1/G4 |
| 前端 · 剧情 | `features/story/story_detail_mobile_page.dart`、`story_transfer_dialogs.dart`、`story_studio_tts_panel.dart` | P2-G2/G3/G7 |
| 前端 · AI | `features/ai/ai_script_generator.dart`、`ai_chat_controller.dart` | P2-G6、P2-H |
| 原生 · 服务 | `native/server/services/aa.cpp`、`aa_routes.cpp`、`file_transfer.cpp`、`semantic_bugfix.cpp`、`semantic_routes.cpp`、`state.cpp` | P1-D/E、P2-J1/J2/J4 |
| 原生 · 核心/存储 | `native/core/paths.cpp`、`native/server/revision_manager.cpp`、`cfg_store.cpp` | P1-F、P2-J3 |
| 原生 · 网关（UNIX-only） | `native/gateway/gw_refresh.cpp` | P2-J5 |

---

## 3. 修复方案步骤

### 阶段 A：P0 解除编译阻断（最小改动，先恢复可构建）

1. **P0-A**：`mods_page.dart:373` 的 `orElse` 分支补齐 `cfgFiles: const [], hasManifest: false, manifestTitle: ''`（或改用 `ModInfo.fromJson(<String, dynamic>{'name': name})` 保证字段与解析逻辑同源）。
2. **P0-B**：`mods_page.dart:379` 的 `initialDesc` 改为取 `AppState.currentModDisplayName` 之外的既有能力 —— **二选一**（见 Q2）：
   - 方案 B1（轻量，推荐）：该处直接传 `''`，由 `WorkshopPublishDialog` 内部空描述处理；不动 `ModInfo` 契约。
   - 方案 B2（完整）：`ModInfo` 增 `manifestDesc` 字段并解析 `manifest_desc`，需确认后端 `/api/mods` 是否已返回该键（**未确认前不得实施**）。
3. **P0-C**：`mod_distribution_hub.dart:126/:207` 将 `cloud_backup_24_regular` 换为**已实测存在**的常量（如 `FluentIcons.history_24_regular` 或 `save_24_regular`），并去掉 `:207` 处的 `const`（`:126` 为构造实参，`:207` 为 `const Icon(...)`）。
4. **验收**：临时 `test/_probe_test.dart` 只 import 上述 3 个文件跑一次编译（沙箱 `flutter analyze` 不可用，见 §5）。

### 阶段 B：P1 安全与并发

5. **P1-D（tex 路径穿越）**：
   - 在 `resolve_mod_local_tex_path` 入口新增拒绝规则：含 `..` 段、以 `/` 或盘符（`X:`）开头、含 NUL → 直接返回 `""`。
   - 保留现有 `\`→`/` 归一与 `Mods/<any>/` 前缀剥离（这是正常业务路径，不可删）。
   - 沿用 `static_routes.cpp:47-67 rel_is_safe` 的范式：候选路径生成后统一做「解析结果必须位于允许根目录内」校验；或在 `sa_core::paths` 增加 `join_within(root, rel)`。
   - **顺带**修正 `paths.cpp:75-80 join()` 的绝对路径短路语义（或改为仅在调用方显式允许时短路）——需评估改动面（见 Q3）。
   - 第二轮表情差分回退路径（`:965-972`）必须走同一套校验。
6. **P1-E**：`reclaim_expired` 改为两段式 —— 锁内只扫出待删除列表 `[(id, key, upload_id, is_multipart)]` 并置中间态；**释放锁**后执行 `ops.remove`/`ops.multipart_abort`；再短暂持锁回写状态。注意 `read_store_unlocked`/`write_store_unlocked` 的 `_unlocked` 语义必须保持。
7. **P1-F**：`compute_revision` 锁内只取 `root` 快照，`collect_target_files(root)` 移到锁外；之后再短暂持锁写 `g_files_scanned_count`。**必须保持** `:114-117` 所述的「非递归 mutex 不得重入」约束（`compute_revision_cached` 曾有自死锁前科）。

### 阶段 C：P2 前端健壮性

8. **P2-G**：8 处逐条补 `if (!mounted) return;`；其中
   - `workshop_publish_dialog.dart:101` 的 `void _startPublish() async` → 改 `Future<void>` 并在 `catch` 内加 `if (mounted)`；
   - `app_shortcuts.dart:169` 用 `if (ctx.mounted)` 而非 State 的 `mounted`；
   - `story_transfer_dialogs.dart:107` 守卫需覆盖**第二个** async gap。
9. **P2-H**：`file_upload_client.dart:61-66` 与 `:249/:253`、`ai_chat_controller.dart:1222/1247/1255/1277` 全部改为 `as String? ?? ''` / `(x as num?)?.toInt() ?? 0` / `(r['items'] as List?)?.whereType<Map>()` 模式。
10. **P2-I1**：`load()` 增代际序号（`_loadSeq`），过期响应丢弃；或加 `_loading` 门与 `save()` 对齐（参考 `features/editor/base_search_page.dart:98-121` 的 `_evtSeq` 范式）。
11. **P2-I2**：两个可选方向 ——
    - **I2-a（保守）**：在保存按钮启用态与离开守卫（`core/workbench_guard.dart:69`、`core/save_bar.dart:36`）改用 `checkDirtyDeep()`，`dirty` 仍作快速预判（`dirty || checkDirtyDeep()` 的短路写法）。
    - **I2-b（彻底）**：`_TrackedMap.operator[]=` 在写入值与旧值 `_valueEquals` 相等时不推进 `_rev.n`。**风险更高**（嵌套容器写入路径多），需全量回归 `workbench_controller_test` 的 3 条嵌套置脏用例。
12. **P2-I3**：`save_service.dart` 的 revision 改为随保存批次局部传递，或在采用时校验「请求发出时的 revision」未被改写。
13. **P2-I4**：用 `_ready` 控制发布按钮启用态，或在未就绪时前置提示。
14. **`app.dart:127`**：把匿名闭包提升为命名方法并保存引用，在 `dispose` 中 `removeListener`。

### 阶段 D：P2 原生健壮性

15. **P2-J1**：`semantic_bugfix.cpp:611` 的 `stoll` 外包 try/catch（或复用同文件 `try_int`（`:118`）先做纯数字校验）。调用点 `semantic_routes.cpp:1177` 一并加保护。
16. **P2-J2**：`state.cpp` 两个全局回调改为「启动期写入 + 运行期只读」，或加互斥/`std::atomic`。
17. **P2-J3**：`cfg_store.cpp` 的 `g_path_locks` 改 `weak_ptr` + 惰性重建，或加容量上限清理。
18. **P2-J4**：`aa.cpp:1130-1140` 拆分两个临界区，或统一全局加锁序。
19. **P2-J5**：`gw_refresh.cpp:33-35` 改用 `sha256_hex_strict`，并配套旧 token 哈希的兼容判定/迁移（**仅 Linux/WSL 可验证**）。

---

## 4. 冗余逻辑精简改动点

> 以下均为**实际确认**的重复实现，非风格问题。所有收敛目标均已存在，属「删重复、不改行为」。

### 4.1 前端 Dart

| # | 冗余形态 | 位置 | 收敛目标 | 预估删除 |
|---|---|---|---|---|
| 1 | **剧情两大编辑器整文件分叉**：`_save` / `_putTableWithConflictCheck` / `_confirm` / `_showInfo` / `_insertTalk` / `_appendTalk` / `_addOption` / `_removeOption` / `_deleteSelectedTalks` / `_talkDisplayName` / `_roleName` / `_asMap` / `_asInt` 逐字重复（去空白后约 520 行相同行） | `features/story/story_director_view.dart:781-1000, 614-772, 467-493, 295-298` ⟷ `story_studio_editor.dart:819-1070, 608-794, 538-541` | 抽 `story_stage_ops.dart`（save/conflict/confirm/talk-op 纯操作），两视图只留布局 UI | **约 380–500 行** |
| 2 | **私有 `_SectionCard` 复制 11 份**（其中 8 份逐字节相同） | events:1298 / chats:1074 / goals:1391 / person:2034 / external:1493 / warehouse:1623 / messages:1162 / minigames:982 / json:815 / social:1463 / space:1292 | `features/editor/section_card.dart`（现 API 用 `child`，其余用 `children`，加一个 `children` 重载即可统一） | **约 450 行** |
| 3 | **行访问/数值解析辅助家族重复**：`_intOf`(7)、`_intList/_listInt`(9)、`_lenOf`(3)、`_row/_rowOf/_rowIn`(7)、`_newId/_nextId/_allocId`(7+)、`_sortedIds`(6+)、`_roleName`(6)、`_nameMap`(2) | 跨 events/chats/goals/minigames/external/warehouse/space/messages/person/social/json | 新增 `features/editor/record_utils.dart`（`intOf/intList/lenOf/rowOf/nextNumericId/sortedNumericIds`）；`_roleName` 收敛到 `features/nocode/entity_picker.dart`（差异仅在默认名，应参数化） | **约 200–250 行** |
| 4 | **9 个工作台双份状态**：自留 `_loading/_saving/_error` + `_onCtl` 镜像赋值 + `status` 三元，实际只是抄 `_ctl` 的值 | idle_chat:65-67/86-93/523-528/824、external:119-121/138/779/1312、goals:81-83/104/519/844、minigames:68-70/85/441/816、messages:61-63/81/548/854、person:98-100/125/660/866、space:73-75/93/522/942、social:65-67/84/470/905、warehouse:87-89/109/759/1462 | 直接读 `_ctl.loading/saving/error`（`event_workbench.dart:102-105/616/621/1070` 已是正确写法）；可在 controller 加 `WorkbenchStatus get status` 消除三元 | **约 110 行** |
| 5 | **`json_workbench` 重造 `WorkbenchController`**：自带 `_save():169-227`、`_loadTable():129-161`、`_mtimeOf():105-106`、`_conflictDialog():243-266` | `features/json/json_workbench.dart` | 改用 `WorkbenchController(cfgs:[_table])`，逐条 JSON 编辑建立在 `table(_table).data` 上 | **约 120 行** |
| 6 | **6 份自建 409 弹窗 + 10 份 `_onConflict` 薄转发** | minigames:171（死代码）/ json:243 / schema_editor_view:523 / story_director_view:913 / story_studio_editor:908；转发 10 处（idle_chat:159 / event:194 / external:224 / warehouse:213 / goals:221 / minigames:168 / messages:153 / person:228 / space:167 / social:158） | `core/workbench_scaffold.dart:92 showWorkbenchConflictDialog`；转发可改为 controller 内置默认弹窗。（`story_flow_workspace.dart:1410` 的「行级三选」**语义不同，保留**） | **约 130 行** |
| 7 | **未用 import / 未引用成员**（`dart analyze` 已确认） | ai_script_generator:5、idle_chat:5、messages:1/7、json:13、person:1、social:5 的 import；`_tableDirty`(external:205 / minigames:153 / warehouse:196)、`_conflictDialog`(minigames:171，约 24 行)、`effect_block_editor.dart:685/706/721 _move/_delete/_duplicate`、`effect_health_panel.dart:140 _knownCfgs`、`story_list_mobile_page.dart:32/35/278/509`、`story_detail_mobile_page.dart:807 _buildJumpChip`、`story_director_view.dart:32` / `story_studio_editor.dart:32` 的 `unused_shown_name` | 按分析器逐条删除 | **约 100 行** |
| 8 | **重复判断 / 回退片段** | `event_workbench.dart:274-278`（`_intList` 调两次）、`:735/737` 与 `:1116/1118`（`_lenOf` 求值两次）、`person_workbench.dart:164-165`（`_sortedIds` 两次）、`messages_workbench.dart:120-121`（`_roots()` 两次）、`goals_workbench.dart:143-146/206-209/214-217` 同一「选中项回退」片段 3 份（event:144-146/188-190、social:124-126/150-153、messages:121-123/145-147 同样 2 份） | 提 `_ensureSelectionValid()`；`if (force) 'force': true else 'expect_mtime_ns': mtime` 三目合并（5 处同款：workbench_controller:344-345、json:183-184、schema_editor_view:474-475、story_director_view:863-864、story_studio_editor:895-896） | 约 60 行 |
| 9 | **`_SegButton` 5 份 / `_Chip` 2 份**、**`_normalizeList` 3 份**、**角色字典手工构建 2 份**、**basename+去扩展名 3 份** | external/goals/person/space/warehouse（`_SegButton`）；events/social（`_Chip`）；`story_editor_mobile.dart:53/114/153`；`story_list_mobile_page.dart:77-82` / `story_detail_mobile_page.dart:96-101`；`story_flow_workspace.dart:2581` / `resources/local_import.dart:65` / `resources/image_asset_picker.dart:236` | 公共分段按钮；复用 `story_logic.dart:60 ensureList`、`story_flow_suggest.dart:276 mergeNameDict`；新增 `core/` 下 `baseNameNoExt(path)` | 约 180 行 |

### 4.2 原生 C++

| # | 冗余形态 | 位置 | 收敛目标 | 预估删除 |
|---|---|---|---|---|
| 1 | **`py_truthy` 独立实现 8 份** | `semantic_routes.cpp:48`、`semantic_graph.cpp:59`、`semantic_bugfix.cpp:42`、`p5_util.cpp:37`、`tts.cpp:1192`、`content_util.cpp:145`、`workspace_routes.cpp:38`、`p3b_domain_service.cpp:34` | 提到 `sa_core::util`（与 `py_int/py_str` 同处）；`p3b_domain_service.cpp:34` 已示范转调写法 | **约 90 行** |
| 2 | **`strip`/`lstrip` 家族 10+ 份** | `p4_util.cpp:46`、`ai_dicts_route.cpp:34`、`content_util.cpp:119/127`、`p3b_support.cpp:213/229`、`semantic_bugfix.cpp:28`、`android_bundled.cpp:23`、`realtime.cpp:291`、`stage_service.cpp:271` | 统一到一个 Unicode 空白实现（`content_util` 或 `p3b_support` 二选一） | **约 120 行** |
| 3 | **路由薄封装成对重复** | `lstrip_neg`（semantic_routes:40 ⟷ semantic_graph:53）、`join_str`（story_service:176 ⟷ stage_service:162，**逐字节相同**）、`read_json_text`（content_util:395 ⟷ semantic_assets:20，**逐字节相同**）、`body_str`（mods_routes:33 ⟷ workspace_routes:125，空值判定已漂移）、`str_field`（mod_files_routes:107 ⟷ mod_refs_routes:98）、`qget`（aa_routes:50 / base_routes:32 / assets_routes:42 / cloud_routes:36）、`is_forbidden_char + sanitize_name`（mod_files_routes:63/75 ⟷ mod_refs_routes:60/70，**逐字节相同**）、`now_iso_seconds`（mods_routes:42 ⟷ workspace_routes:135，注释自承「另抄一份」） | 新增 `sa_server/http_util.h` 承载 `body_str/str_field/qget/err_json/sanitize_name`；其余下沉 `sa_core` | **约 120 行** |
| 4 | **「写成功四连 + mtime 提取」6–7 份** | `cfg_routes.cpp:202-209 / 443-449 / 644-650`、`content_routes.cpp:69-75`、`p3b_domain_service.cpp:428-435`、`base_routes.cpp:111-114`；mtime 提取片段在 cfg_routes(×3)/content_routes/p3b_domain_service/semantic_routes 各写一遍 | 把 `semantic_routes.cpp:483 after_write()`（唯一正确做法）提升为公共函数 | **约 50 行** |
| 5 | **`cloud_sync.cpp:4271-4382` 同步主循环**：`if(upload)/else if(download)/else if(sync)` 内嵌 `if(!dry_run)` 实测缩进 28 空格（≈7 层）有 6 处；同一「读本地 size/mtime/sha1 → 取远端 Obj → `need_sync` → push_action」块**复制 3 次**（4290-4303、4321-4337、4356-4377） | `cloud_sync.cpp` | 抽 `resolve_both(...)` + `upload_one/download_one/sync_one` 三个小函数，各分支 early-return | 约 40 行 + 复杂度显著下降 |
| 6 | **`director_shell.dart` 半迁移**（`_childFor:1007-1130` 已引入 `kWorkbenchRegistry`，但 `space/warehouse/external/goals/chats` 在 `:1036/1041/1047/1052/1059` 绕过注册表直接 new） | `features/shell/director_shell.dart` | 5 个入口改走注册表 | 约 60 行 |
| 7 | `revision_manager.cpp:28 sha256_hex` 纯转发适配 | — | 直接调 `sa_core::sha256_hex` | 3 行 |

> 注：`switch-case` 实测最大仅 16 个 `case`，**未发现**需注册表化的超长 switch（真正需注册表化的只有 §4.2-6）。注释掉的代码块前端 0 处、C++ 0 处，**此项无收益**。

---

## 5. 性能瓶颈优化改动点

### 5.1 高收益

| # | 瓶颈 | 位置 | 复杂度 | 改法 | 预期收益 |
|---|---|---|---|---|---|
| 1 | **排序 getter 每次 build 全表排序 + 搜索无防抖** | `person_workbench.dart:255-264`（`_leftPanel:678` 调用；搜索 `onChanged:706` 无防抖）、`goals_workbench.dart:236-245`（`:537`/`:559`）、`idle_chat_workbench.dart:179-184`、`minigames_workbench.dart:211-216`（`:460`/`:503` 各一次） | O(n log n) 每次 build/按键 → O(1) | 排序结果缓存为字段，仅在增删改名时失效；搜索加 200ms 防抖（对齐 `schema_editor_view.dart:231-239`）；`minigames` 的两次调用合并 | 数千行表格输入从每键数十毫秒级降为局部增量刷新，**直接决定能否稳定 60fps** |
| 2 | **同一次 build 内重复全量组装** | `warehouse_workbench.dart:322-356`（`:777` 一次、`:865` 再一次）、`external_dialogues_workbench.dart:318-367`（`:844` + `:847`）、`minigames_workbench.dart:460/503` | 每帧 ≥2 次 O(n log n) → 1 次 | `_allEntries`/`_sortedGames` 结果缓存并在 build 内复用同一引用 | 列表页每帧工作量**减半以上** |
| 3 | **itemBuilder 内做图遍历 + 每行重编译正则** | `event_workbench.dart:729` 对每个可见行调 `_reachableTalks`（`:323-351`，含反复 `_intList` 解析），另在 `:937`/`:1106` 再算；`_plain:290-293` 每次调用 `RegExp(r'<[^>]*>')` 重新编译；`goals_workbench.dart:610` itemBuilder 内同样重编译 | O(可见行 × 对白图) + 正则编译 ×N | 可达数按事件缓存（数据变更时重算一次）；`RegExp` 提为 `static final` | 对白链大的事件，滚动不再每帧重走图 |
| 4 | **Dart 侧 `_roleName` 线性扫 `_roles`** | `goals_workbench.dart:276-281`（每行调，`:615`）、`event_workbench.dart:263-268`、`idle_chat_workbench.dart:209-214` | O(可见行 × 角色数) → O(1) | `_roles` 建 `Map<String, RoleEntry>` 索引 | 可见行渲染常数因子下降 |
| 5 | **原生：删除/patch/缓存播种深拷贝整表** | `services/cfg_routes.cpp:626`（`json updated_data = data;` 只为 `erase(id)`，TalkCfg 达 98,963 行）、`cfg_store.cpp:621-622`（`data = *cached;`，`ordered_json::operator=` 是深拷贝，注释误以为浅）、`cfg_cache.cpp:212`（`make_shared<const json>(data)` 再深拷贝） | O(表行数) 深拷贝 → O(1) | `cfg_routes` 走 `cfg_store::apply_patch`（remove 分支）；`cfg_store` 改引用 + 局部修改；`cfg_cache` 复用同一份 | 大表单次写/删/patch 延迟由数十~数百 ms 显著下降，降低内存峰值 |
| 6 | **原生：`base_store::extract_event` 全表扫描** | `base_store.cpp:476-504`（`:491` 遍历 TalkCfg、`:499` 遍历 OptionCfg） | O(TalkCfg + OptionCfg) ≈ 10 万级 → O(匹配数) | 复用已有雏形 `build_evt_index_locked` 建 `evt_id → talk/option ids` 前缀索引 | 单事件提取从毫秒-数十毫秒降到微秒级 |

### 5.2 中收益

| # | 瓶颈 | 位置 | 改法 |
|---|---|---|---|
| 7 | build 内调用 async `TexBytesCache.loadSmartSource`（每次 rebuild 新 Future，`FutureBuilder` 重订阅） | `image_asset_picker.dart:1126`（对照正确写法 `:1994-1999` 在 initState 存 future） | 改为 initState 存 future |
| 8 | `_sameValue` 用 `jsonEncode(a)==jsonEncode(b)` 深比较，对**每个可见字段每 build** 调用一次 | `story_flow_inspector.dart:753` → `story_flow_workspace.dart:2489-2504` | 改用 `workbench_controller.dart:67 _valueEquals` 纯树比较 |
| 9 | `_allBgs()`/`_allAudios()` 每次调用重建整张 Map，一次 build 内被调 **6 次** | `story_director_view.dart:522-550`（调用点 `:1429/:1443/:1482/:1498/:3690/:3691`） | 缓存这两个映射 |
| 10 | `_eventTalkIds()` 每次 build 对 `_stageTalks.keys` 排序 | `story_director_view.dart:462-465`（`:1195/:3267`） | 缓存排序结果 |
| 11 | `_levelsOf` 对每个可见游戏卡扫全量 `_actionCfg` | `minigames_workbench.dart:218-229`（`:522`） | 一次构建 `game → levels` 分组索引 |
| 12 | `_personOfGame` 对每个 MinigameCfg 条目完整扫 `_grow`，构成嵌套 | `external_dialogues_workbench.dart:304-312` | 为 `_grow` 建 `minigame → personId` 反向索引（一次 O(G)） |
| 13 | `_pickRole` 弹窗在 builder 内 `where` 全量过滤 + 非 builder 的 `ListView` 一次性构建全部角色行 | `event_workbench.dart:450-475` | 改 `ListView.builder` + 预建索引 |
| 14 | 写盘触发两轮全工作区扫描/stat | `revision_manager.cpp:197-200` + `cfg_routes.cpp:55-58`（`verify_revision` 强制全量重算 `compute_revision_cached(true)`，写后 `invalidate_cache()+compute_revision_cached(false)`） | 合并/复用同一快照 |
| 15 | `BaseStore::load` 全程持 `mu_` 跨逐表读文件+解析（可能 ~38MB），期间阻塞 `table()/table_ids()/search_*` | `base_store.cpp:213-316`（`:214` 加锁、`:272` 读） | 读入局部变量后一次性 swap |
| 16 | `seed_table_cache` 写后再深拷贝整表并重新序列化 | `cfg_cache.cpp:201-218` | 复用已序列化结果 |
| 17 | 纯读路径用 `unique_lock` 独占做 LRU 提升，串行化并发 GET | `cfg_cache.cpp:136 / 241 / 256` | 改 `shared_lock` 或轻量 LRU |

### 5.3 低收益（顺手做）

- `ListView.builder` 未设 `itemExtent`/`prototypeItem`：`event_workbench.dart:720`、`person:751`、`goals:601`、`idle_chat:592`、`minigames:507`、`external:851`、`warehouse:869`（对照正确写法 `schema_editor_view.dart:980/1268` 已设 `itemExtent`）。
- 列表项普遍缺 `ValueKey`（如 `event_workbench.dart:730`），复用时会串用行内 State（`_EventListItemState._hover`）。
- `warehouse_workbench.dart:358-365` `_typeFilterOptions()` 每次 build 重建 `Set` 并排序（`:816`）。
- `asset_explorer_panel.dart:286-290` `_tagsOf` 每卡每 build 新分配。
- `schema_editor_view.dart:858` `KeyTranslator(widget.state)` 每次 build 新建。
- 反复 `_rowOf(id)` → `v.cast<String,dynamic>()` 新建 CastMap 包装（`event_workbench.dart:202-205`、`goals:231-234`），在排序比较器中被高频调用（`event_workbench.dart:213-216`）。
- `cfg_store.cpp:565-574` 全局 `workspace_gate()` 一个 `recursive_mutex` 串行化所有表的写，粒度过粗。
- `semantic_core.cpp:103-110` `std::regex_match(kVarRe)` 在 `render_template`/`build_secondary_index`/行校验中按 token 调用。
- `revision_manager.cpp:206-219` `compute_revision_async` 每次 `std::thread(...).detach()` 新建线程。
- `base_store.cpp:141-143` `table()` 未命中时每次新分配空对象。

---

## 6. 潜在副作用与回归风险

| 改动 | 风险 | 缓解 |
|---|---|---|
| **P0-A/B** | `ModInfo` 契约若改（方案 B2）会波及 `ModInfo.fromJson` 与所有构造点 | 优先 B1（不动契约）；B2 需先确认后端 `/api/mods` 是否返回 `manifest_desc` |
| **P0-C** | 换图标会改变视觉 | 选语义最接近且已实测存在的常量；仅 1 处图标 |
| **P1-D 路径穿越修复** | ① 过严会误杀正常 key（后端 key 含反斜杠 `Bg/xxx`、含 `Mods/<id>/` 前缀）；② 表情差分 `strip_expr` 回退路径若漏改则仍有洞；③ 改 `paths.cpp join()` 语义会波及**所有**调用方（含 `static_routes`、`mod_files_routes` 等） | 归一与前缀剥离**必须保留**；优先在 `resolve_mod_local_tex_path` 内做校验而非改 `join()` 全局语义（见 Q3）；两轮候选路径共用同一校验函数 |
| **P1-E 回收两段式** | 锁外执行网络删除期间，记录状态可能被并发修改；`_unlocked` 函数语义若被破坏会引入新竞争 | 锁内先置中间态（如 `reclaiming`），锁外删除，再持锁用 `read_store_unlocked` 复核 `updated_at` 未变才回写 |
| **P1-F revision 锁外遍历** | `compute_revision_cached` 曾有「持锁调 compute_revision → 非递归 mutex 自死锁」前科 | 改动后必须保持「任何持锁路径都不再调用会加锁的函数」；新增静态断言/注释固化该约束 |
| **P2-I2-b 版本号等值不推进** | 嵌套容器（`_TrackedMap`/`_TrackedList`）写入路径多，可能漏判导致「改了却判未脏」——比当前「误报脏」更危险 | 优先 **I2-a**（守卫处用 `checkDirtyDeep`）；I2-b 必须全量回归 `workbench_controller_test` 的 3 条嵌套置脏用例并新增「改回原值」用例 |
| **P2-I1 load 代际** | 新增 `_loadSeq` 后，`onLoaded` 回调与 409 reload 路径可能被判为过期而丢弃 | 仅丢弃**表数据**的过期回填，`onLoaded` 仍执行；对齐 `base_search_page.dart` 既有范式 |
| **P2-I3 revision 局部化** | 改动 `SaveService` 会影响**所有**工作台的乐观锁指纹 | 必须回归全部 10 个工作台的 409 用例与 `save_service` 相关用例 |
| **冗余收敛（剧情双子合并）** | 两文件各约 5,000 行，且 `_save` 中 `_replaceTalkCfg` 有唯一差异；合错即**写坏用户配置表** | 分步：先只抽 `_showInfo/_confirm/_confirmSaveDiscard/_showConflictDialog` 等**纯 UI/无数据写入**的方法，`_save`/`_putTableWithConflictCheck` 留到第二步；每步跑 `story_logic_test` + `story_studio_test` + `story_replace_role_test` |
| **冗余收敛（`_SectionCard` 11→1）** | 8 份逐字节相同、1 份变体（person）、2 份同组（events/chats）；person 变体若强行合并会改样式 | person 保持独立或抽出可配置项；`const` 构造差异需保留以维持重建性能 |
| **冗余收敛（C++ 公共化）** | `py_truthy`/`strip` 关系到与 Python 黑盒的**字节级一致性**，合并时选了「另一套」空白定义会静默改变语义 | 合并前先写等价性单测（对同一批输入比对两套实现的输出）；`strip` 家族先确认 Unicode 空白集合是否一致 |
| **冗余收敛（`body_str` 合并）** | `mods_routes:33` ⟷ `workspace_routes:125` 的**空值判定已漂移**，属两种行为 | 合并前先确认哪个是期望行为，不能直接二选一 |
| **性能 §5.1-1 排序缓存** | 缓存失效点遗漏会导致「新增了却不显示」 | 缓存在 `_person`/`_rows` 变更的唯一入口处失效，并加针对「增删后列表即时更新」的用例 |
| **性能 §5.1-5 去深拷贝** | `ordered_json` 值语义被代码多处依赖「赋值为副本」；改引用会引入别名修改 bug | `cfg_routes` 只改删除分支且改走 `apply_patch`；`cfg_store` 改前确认「inner values are never mutated」的假设成立 |
| **性能 §5.1-2 缓存 `_allEntries`** | 缓存后若数据变更未失效，会显示陈旧条目 | 与 §5.1-1 同一失效机制 |
| **网关 P2-J5** | 改哈希算法会使**已签发**的 refresh token 全部失效（用户需重登） | 需配套「旧哈希兼容判定 + 渐次迁移」；**仅 Linux/WSL 可验证** |

---

## 7. 验证方式

### 7.1 前端

> ⚠️ 沙箱内 `flutter analyze` 不可用（管道耗尽，`process_win.cc:744`）。类型检查用「临时 `test/_probe_test.dart` 只 import 改动文件跑一次」代替，**用后删除**。

```bash
cd /d/workspace/editor/frontend
PY="C:/Users/acber/.workbuddy/binaries/python/versions/3.13.12/python.exe" \
  bash tools/run_flutter_test.sh test/<目标>_test.dart
```

- **全量**：`bash tools/run_flutter_test.sh`（**跳过**会连真实后端/网络而挂起的 `backend_integration_test.dart`、`manifest_test.dart`、`mcp_client_test.dart`）。基线：**1180+ 用例全绿**。
- **针对性必跑**：
  - `workbench_controller_test.dart`（含 3 条嵌套置脏回归）— 覆盖 P2-I1/I2
  - `workbench_scaffold_test.dart`（含 2 条窄屏编辑页/滑出层非快照回归）— 覆盖 §4.1-4/6
  - `story_studio_test.dart`、`story_logic_test.dart`、`story_replace_role_test.dart` — 覆盖 §4.1-1
  - `entity_picker_test.dart`、`nocode_workbench_coverage_test.dart`、`nocode_page_coverage_test.dart`
  - `light_theme_audit_test.dart`（硬编码白色守门）
  - 全部 10 个工作台的 409 冲突用例 — 覆盖 P2-I3
- **新增用例（必须）**：
  1. `ModInfo` 兜底分支构造（P0-A/B）
  2. `dirty` — 编辑后**改回原值**应判为未脏（P2-I2）；当前预期**失败**，用于反向验证
  3. `load()` 并发触发 → 旧响应不得覆盖新响应（P2-I1）
  4. `file_upload_client` 收到缺字段/类型漂移响应不抛异常（P2-H）
  5. 排序缓存：新增/删除后列表即时更新（§5.1-1）

### 7.2 原生 C++

```bash
cd /d/workspace/editor
bash native/build/bw.sh -j 1 sa_tests.exe          # 必须 -j 1（sa_server.lib 单文件 522MB，并行会 OOM）
```

运行（**沙箱关键约束**）：
- `TEMP`/`TMP` 必须指向工作区内，否则 `sat::make_temp_dir()` 在 `%TEMP%` 被拒绝（`create_directories: Access is denied`）
- 新编译的 exe 在本沙箱无写权限（`ec=5` → `abort()` / 退出码 `0xC0000409`）→ **复制到受信目录**（如 `C:\Users\acber\.workbuddy\binaries\python\versions\3.13.12\`）再运行，跑完删除副本
- `PATH` 需含 `D:\BuildTools\VC\Redist\MSVC\14.44.35112\x64\Microsoft.VC143.CRT`
- `EDITOR_ASSETS_ROOT=D:\workspace\editor\native\assets`，cwd 用 `build-native/bin`

```bash
TEMP='D:\workspace\editor\.tmp_build' TMP='D:\workspace\editor\.tmp_build' \
  ./bin/sa_tests.exe '~[slow]' '~[network]'
```
基线：**All tests passed (6781 assertions in 526 test cases)**，0 失败。

- **针对性**：`sa_tests.exe "[mcp]"`（10 用例）、`"[httpd],[cors],[web],[auth],[security],[router],[routes]"`（68 用例 1178 断言）。
- **新增用例（必须）**：
  1. **P1-D 路径穿越**：`?key=../../../../etc/passwd`、`?key=C:/Windows/win.ini`、`?key=..%2f..%2f`、`?key=/etc/passwd` 全部必须被拒（返回空/404）；同时正常 key（`Bg/xxx`、`Mods/<id>/...`、表情差分回退）仍能命中
  2. **P2-J1**：`evt_id` 非数字时 `/api/bugfix/fix` 返回业务结果而非 500
  3. **P1-E**：回收进行中并发调用上传登记，验证不被网络 IO 阻塞（可注入假 `ops.remove` 加延时）
  4. **P1-F**：`compute_revision` 期间并发 `set_workspace_root` 不死锁、不重入
  5. **等价性单测**（若做 §4.2-1/2 合并）：新旧 `py_truthy`/`strip` 对同一批输入输出一致

### 7.3 手工验证

1. **mods 页**：进入模组页 → 发布到创意工坊 → 确认弹窗文案不为空白、按钮态正确（P0-A/B、P2-I4）。
2. **异步守卫**：人物工作台加脸 → 弹图片选择器期间切走页面；AI 编剧生成动画 300ms 内关弹窗；TTS 合成中关面板 → 控制台无 `setState() called after dispose`（P2-G）。
3. **脏状态**：改一个字段 → 改回原值 → 保存按钮应恢复禁用、离开不弹确认（P2-I2）。
4. **性能**：在人物/目标/仓库工作台输入搜索、快速滚动长列表 → 稳定 60fps、无卡顿（§5.1-1/2/3）。
5. **大表写删**：对 `TalkCfg`/`ItemCfg`（数万行）执行单条删除/打补丁 → 延迟明显下降（§5.1-5）。
6. **单事件提取**：反复请求单事件 → 响应时间从毫秒级降到亚毫秒（§5.1-6）。

---

## 8. 待确认决策点

- **Q1｜未提交重构的处置**：当前 `mods_page.dart`（+87/-109）、`mod_distribution_hub.dart`、`workshop_publish_dialog.dart` 处于半成品状态，另有 171 个改动文件未提交。建议**先固化/提交**（或 `git stash`）这批改动，再开始 P0 修复，避免相互覆盖。**请确认采用哪种处置。**
- **Q2｜P0-B 的修法**：走 **B1**（`initialDesc` 传 `''`，不动 `ModInfo` 契约，轻量、符合 rule.md「轻量化」）还是 **B2**（给 `ModInfo` 加 `manifestDesc` + 后端返回 `manifest_desc`）？
- **Q3｜P1-D 的修复边界**：只在 `resolve_mod_local_tex_path` 内加校验（局部、风险小），还是同时修正 `paths.cpp:75-80 join()` 的绝对路径短路语义（全局、影响 `static_routes`/`mod_files_routes` 等所有调用方）？
- **Q4｜P2-I2 的修法**：**I2-a**（守卫处改用 `checkDirtyDeep()`，保守）还是 **I2-b**（版本号等值不推进，彻底但风险高）？
- **Q5｜本轮范围**：是否包含 §4.1-1（剧情双子合并，约 380–500 行但风险最高）？建议本轮**先不做**，单独作为一轮专项。
- **Q6｜P2-J5（网关哈希）**：涉及已签发 token 失效，是否本轮处理？若处理，因 `native/gateway/` 为 UNIX 专属，Windows 侧只能逐行复核、无法本地验证。
- **Q7｜优先级确认**：建议执行序为 **P0（解锁构建）→ P1-D（安全）→ P2 守卫/空安全 → P1-E/F → 冗余精简 → 性能**。是否认可，或需调整。

---

## 9. 预期收益汇总

| 维度 | 收益 |
|---|---|
| 可用性 | 解除 3 类编译阻断，恢复前端可构建；消除 8 处 dispose-after-setState 崩溃路径 |
| 安全 | 关闭 tex 接口任意文件读取（唯一「严重」级安全问题） |
| 并发 | 消除 2 处「锁内做 IO」，回收/写入路径不再被网络或磁盘遍历阻塞 |
| 一致性 | 修复 `dirty` 误判、`load()` 竞态、全局 revision 竞态、`_ready` 未生效 4 项共享基础设施缺陷（**一次修复、12 个工作台受益**） |
| 健壮性 | 后端响应形状漂移不再抛 `TypeError`；`stoll`/`ustoll` 类未捕获异常清零 |
| 精简 | 前端约 **1,600–1,900 行**、原生约 **420–450 行** 冗余可删（合计 **约 2,000–2,350 行**） |
| 性能 | 列表页每帧工作量减半以上（稳定 60fps）；大表写/删/patch 延迟显著下降；单事件提取 O(10 万) → O(匹配数) |
