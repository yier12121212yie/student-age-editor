# 修复选择人物卡片只有向上滑动时才会加载人物图片的问题

## 根因分析

排查全库「选择人物」卡片网格（剧情舞台工作台的 [`_StudioPlaceRoleDialog`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L4350-L4757) 与通用/简易模式人物选择器 [`_EntityPickerDialog`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart#L261-L457)）后，定位到导致**首次打开人物卡片网格时不显示立绘、只有向上滑动（滚动网格触发新卡片构建）后才加载人物图片**的四个叠加原因：

1. **弹窗与宿主异步目录/元数据脱节，首屏卡片定格在占位图标（核心原因）**
   - 在 [`_StudioPlaceRoleDialog`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L4444-L4541) 中，`widget.allRoles` 直接合入了 `gameDicts['roles']` 的 200 个角色 ID，因此弹窗打开首帧 `filteredKeys` 即为非空，`GridView.builder` 立即构建首屏可视区卡片。
   - 但常规模组的 `PersonCfg`（仅含模组覆写行）往往为空，官方角色的立绘 key 依赖两个异步数据源：
     1. `/api/roles`（由 [`_StoryStudioEditorState._loadRoleCatalog`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L519-L525) 或弹窗自身 `initState` 的 [`loadRoles('')`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L4409-L4417) 异步拉取）；
     2. `/api/preview/meta` 的 `charKeys`（由 [`_loadStageMeta`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L530-L534) 异步拉取并递增 [`mergedMetaRevision`](file:///d:/workspace/editor/frontend/lib/features/resources/image_asset_picker.dart#L421)）。
   - **脱节 1**：弹窗 `itemBuilder` 调用的 `widget.portraitKeyCandidates(id)` 绑定在 [`_StoryStudioEditorState._portraitKeyCandidates`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L1114-L1133) 上，它只读宿主 `_StoryStudioEditorState._roleCatalog`，**完全不读弹窗自己拉取的 `_catalog`**。若打开弹窗时宿主 `_roleCatalog` 尚未就绪，即使弹窗自己的 `_catalog` 拉取完成，`widget.portraitKeyCandidates` 仍返回空列表 `[]`；回退到 `thumbKey = _catalog[id]?.portrait` 时传给 [`TexThumb`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L4693-L4699) 的 `keyCandidates` 又是空列表 `[]`（丢失 `portrait2` → `portrait1` 候选回退）。
   - **脱节 2**：当宿主 `_loadRoleCatalog()` 或 `_loadStageMeta()`（`mergedMetaRevision`）在弹窗打开期间异步完成时，独立路由中的 `_StudioPlaceRoleDialog` **既不监听 `mergedMetaRevision`，也不会随宿主 `setState` 重建**，也没触发 [`ensureMergedMeta()`](file:///d:/workspace/editor/frontend/lib/features/resources/image_asset_picker.dart#L398-L402)。
   - 结果：首屏卡片在构建时 `cands` 与 `thumbKey` 均为空，直接落入 `else` 分支渲染静态 `Icon(FluentIcons.person_24_regular)`（根本未挂载 `TexThumb`）。直到用户**向上滑动（向下滚动网格）**，`GridView.builder` 为新进入视口的卡片重新执行 `itemBuilder`，此时异步数据已到位，新卡片才加载出人物图片。

2. **`_StudioPlaceRoleDialog` 首行角色被伪 ID 与误写逻辑占满**
   - `game_dicts.roles`（[`dicts.json`](file:///d:/workspace/editor/native/assets/dicts.json)）包含 `-1`（旁白）、`0`（白雨）、`00`（主角）、`000`（你）。按 `int.tryParse` 升序排列后，这 4 项排在网格最顶部（第 1 行前 4 格）：
     - `0`（白雨）在 [`PersonCfg.json`](file:///d:/workspace/editor/native/assets/PersonCfg.json) 中明明拥有立绘（`role_male2` / `role_male`），但 [`_StudioPlaceRoleDialog._roleCard`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L4682-L4691) 却硬编码了 `if (id == '0')` 显示喇叭图标（把主角 `0` 误当成了旁白 `-1`），导致 `0` 白雨永远不加载立绘。
     - `-1`（旁白）、`00`（主角别名）、`000`（你）在 `PersonCfg.json` 中没有独立记录，排在首行最前面导致首行大面积无图，用户必须向上滑动滚过首行才能看到有立绘的角色卡片。

3. **通用人物选择器 [`_EntityPickerDialog`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart) 缺少立绘候选回退与元数据联动**
   - [`EntityEntry`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart#L106-L117) 只保留单个 `thumbKey: r.portrait`，丢弃了 `[r.portrait2, r.portrait1]` 候选链及 `charKeysMapOrNull` / `modRecords` 中的 `url2`/`url` 兜底。
   - [`_EntityPickerDialogState.initState`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart#L290-L299) 只在 `EntityKind.bgs` 时拉取合并元数据，在 `EntityKind.roles` 下不调用 `ensureMergedMeta()` 也不监听 `mergedMetaRevision`；若首次打开时 `/api/roles` 尚未就绪或瞬时失败退回 `_localEntries`，所有卡片 `thumbKey` 均为空且不会自动恢复。
   - [`_thumbGrid`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart#L436) 中的 `TexThumb` 未设置稳定 `ValueKey` 与 `keyCandidates`。

4. **嵌套滚动容器与滚动预取配置**
   - [`_StudioPlaceRoleDialog`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L4476-L4542) 将纵向 `GridView.builder` 嵌套在纵向 `SingleChildScrollView` 内，未设置独立 `ScrollController`、`primary: false` 与 `scrollCacheExtent`。

---

## 修改方案

### 1. 剧情舞台人物选择/登场/更换弹窗（[story_studio_editor.dart](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart)）

- **打通弹窗内立绘候选解析与异步数据刷新**：
  - 在 [`_StudioPlaceRoleDialogState.initState`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L4401-L4418) 中：
    - 调用 `ensureMergedMeta()` 确保 `/api/preview/meta`（`charKeys`）已触发拉取；
    - 监听 `mergedMetaRevision`，当合并元数据到达或刷新时自动触发弹窗 `setState` 重建首屏卡片；
    - 无论初始 `widget.roleCatalog` 是否为空，若缺少立绘信息则拉取 `loadRoles('')`，拉取完成后除了更新弹窗 `_catalog`，还回调同步给宿主 `_roleCatalog`（避免下次打开重复拉取）。
  - 在弹窗内封装立绘候选计算方法 `_candidatesFor(String id, {required int expr})`：
    - 先调用 `widget.portraitKeyCandidates(id, expr: expr)`；
    - 再结合弹窗自身已就绪的 `_catalog[id]`（依次补充 `portrait2`、`portrait1`、`portrait`）与 `charKeysMapOrNull?[id]`（`base2`、`base`）去重合并，确保即使宿主 `_roleCatalog` 在弹窗打开瞬间尚未就绪，弹窗也能拿到完整的候选链 `cands` 并传给 `TexThumb(keyCandidates: cands)`。
- **修正首行角色立绘与排序**：
  - 在 [`_StudioPlaceRoleDialog._roleCard`](file:///d:/workspace/editor/frontend/lib/features/story/story_studio_editor.dart#L4682) 中：将 `if (id == '0')` 修正为仅对真正的旁白 `id == '-1'` 显示旁白图标，让 `0`（白雨）正常通过 `TexThumb` 加载主角立绘；对 `00` / `000`（主角别名）回退复用 `0` 的立绘候选。
  - 在角色排序中，将有立绘候选的实体角色排在无立绘的伪角色（如 `-1`）之前（或将 `-1` 置后），保证首屏第一行即展示有效人物立绘卡片。
- **优化网格滚动容器**：
  - 为 `_StudioPlaceRoleDialog` 的 `GridView.builder` 配置独立的 `ScrollController`、`primary: false`、`addAutomaticKeepAlives: false` 与 `scrollCacheExtent: const ScrollCacheExtent.pixels(210)`；若初始选中角色不在首屏，首帧后自动滚动至可视区域。

### 2. 通用/简易模式人物选择器（[entity_picker.dart](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart)）

- **补齐人物立绘候选链与本地/元数据兜底**：
  - 为 [`EntityEntry`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart#L106-L117) 增加 `thumbCandidates`（`List<String>`，默认 `const []`）。
  - 在 [`loadEntities`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart#L216-L234) 与 [`_localEntries`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart#L170-L204) 中：
    - `RoleEntry` 转换时填入 `thumbCandidates: [if (r.portrait2.isNotEmpty) r.portrait2, if (r.portrait1.isNotEmpty) r.portrait1, if (r.portrait.isNotEmpty) r.portrait]`；
    - 对 `00` / `000` 主角别名回退主角 `0` 的立绘；
    - 当使用本地 `modRecords` / `charKeysMapOrNull` 兜底时，同样从 `modRecords[id]['url2'/'url']` 及 `charKeysMapOrNull?[id]['base2'/'base']` 提取立绘 key，避免 `/api/roles` 瞬时未就绪时整页白板。
- **监听元数据就绪与自愈重试**：
  - 在 [`_EntityPickerDialogState.initState`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart#L290-L299) 中，当 `widget.kind == EntityKind.roles` 时同样调用 `ensureMergedMeta()` 并监听 `mergedMetaRevision`；若首次 `_fetch` 未拿到立绘（如后端冷启动），在元数据到达或短暂延迟后自动重拉一次 `/api/roles` 并刷新网格。
  - 在 [`_thumbGrid`](file:///d:/workspace/editor/frontend/lib/features/nocode/entity_picker.dart#L408-L456) 中，为 `TexThumb` 传入 `key: ValueKey('entity-role-${e.id}-${e.thumbKey}')`、`keyName: e.thumbKey`、`keyCandidates: e.thumbCandidates` 以及 `scrollCacheExtent: const ScrollCacheExtent.pixels(210)`。

---

## 验证与测试计划

1. **新增/扩展组件测试**：
   - 在 [story_studio_test.dart](file:///d:/workspace/editor/frontend/test/story_studio_test.dart)（或 [story_replace_role_test.dart](file:///d:/workspace/editor/frontend/test/story_replace_role_test.dart)）中新增用例：
     - 打开「人物登场」/「更换人物」弹窗时，无需任何滚动操作，首屏角色卡片（含 `[0] 白雨`、`[1] 妈妈` 等）立即挂载 `TexThumb` 并請求/渲染出人物立绘图片；
     - 模拟 `/api/roles` 或 `/api/preview/meta` 在弹窗打开后才异步返回，验证弹窗无需向上滑动即可自动重建并显示首屏人物立绘。
   - 在 [entity_picker_test.dart](file:///d:/workspace/editor/frontend/test/entity_picker_test.dart) 中新增用例：
     - 验证 `showRolePickerDialog` 打开后首屏卡片带完整 `thumbCandidates`（当 `url2` 缺失但 `url` 存在时能自动回退显示小学立绘），且无需滚动即可加载首屏立绘。
2. **回归测试**：
   - 运行 `flutter test test/story_studio_test.dart test/story_replace_role_test.dart test/entity_picker_test.dart test/image_asset_picker_test.dart` 确保全部通过且无残留定时器或异常。
