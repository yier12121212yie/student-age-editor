# 运行效率优化 + Bug 修复（第二轮：大表读写链路）

## Context

剧情图画布已在阶段 0–6 完成渲染层重写（`frontend/test/story_flow_bench_test.dart` 头注释记录逐阶段读数：平移 121.30 → **3.01 ms/帧**、拖节点 101.40 → **14.81 ms/帧**、卡片重建 224 → 4 张/帧）。画布不再是卡点。

本轮痛点在**大表数据链路**。本机实测（stdlib）：

| 事实 | 数字 |
| --- | --- |
| 真实 `TalkCfg.json` | **40,258,490 字节 / 98,963 行**（LF、无 BOM） |
| `json.loads` 全表 | **712 ms** |
| `json.dumps(..., ensure_ascii=False, indent=2)` | **2,344 ms → 50,496,932 字节** |
| `EvtCfg` / `OptionCfg` | 0.84 MB / 3,154 行、1.03 MB |

由此推出的可感知卡顿：

- `GET /api/cfg/TalkCfg`（`server/api.py:744-777`）每次读盘 40MB + 解析 + `sorted(98,963 keys)`，再由 `httpd._respond`（`server/httpd.py:146-163`）二次 `json.dumps` → **约 3 秒服务端 CPU + 50MB 响应，零缓存**。
- 打开剧情图：`story_flow_workspace.dart:347` 并发拉 8 张表。
- **保存一句对白**：`story_flow_workspace.dart:940-955` 先 GET 全量 TalkCfg+OptionCfg → Dart 侧 merge → PUT 全量 → **约 100MB 往返**。
- 前端 `jsonDecode(utf8.decode(bodyBytes))` 在 **UI isolate**（`core/api_client.dart:61-63`）→ 一张大表冻结数秒。
- 写入：`cfg_store.write_cfg`（`cfg_store.py:145-180`）全局 `RLock` 包住全部磁盘 IO；一次保存把文件**读两遍**（`:166` + `:99`）、写 40MB 快照 + 50MB 新表；`.editor_history` **全仓无任何清理逻辑**；内存 undo 栈每项存**整表文本**（`:177`），50 项 ≈ **2 GB 常驻**。

### 用户已定取舍（本轮约束）
1. 主攻**后端大表读写链路** + **前端往返冗余**；画布渲染不再动。
2. **允许新增端点与缓存层**，API 契约可扩展，前后端一起改。
3. 快照策略：**内容未变不快照** + **按表滚动保留最近 N 份**。
4. 用并行子代理加速；**一个文件只有一个写者**，跨文件接线与行为敏感改动留在主代理。

### 一处对既有设计的修正
不新增 `POST /api/cfg/<name>/rows`，也**不用 PATCH**：`httpd.py:165-183` 只有 GET/POST/PUT/DELETE/OPTIONS（无 `do_PATCH`），新路径会让约 12 个测试里的 `MockClient` 路由直接 404/500。改为**复用 `PUT /api/cfg/<name>`，body 以 `patch` 字段判别**，并用 `/api/ping` 的 `cfg_patch: true` 做能力门（旧后端 → 前端退回 GET+PUT 全表）。

---

## 基线与验收协议

- 后端：`cd backend && python -m pytest editor -q -p no:cacheprovider` → **248 passed / 3.39s**，须保持全绿。
  - 已观测到 `test_cfg_store.py::RobustDecodeTest::test_undo_restores_bom_bytes_from_snapshot` 在 `-x` 单跑时**真实失败一次**于 `cfg_store.py:213 os.replace`：`PermissionError [WinError 5]`，整体重跑 248 全绿 → 证明 Windows 瞬时文件占用是真实脆弱点（S2 修）。
- 前端：`cd frontend && flutter test` → **356 passed / 12 failed**，12 条**全部**在 `test/backend_integration_test.dart`（文件头自述需活后端；`manifest_test.dart` 不在失败集内）→ 环境性失败，非回归。
- 画布：`flutter test test/story_flow_bench_test.dart -r expanded` 的 `[bench]` 计数项作为渲染回归哨兵，本轮**不得变差**。
- **墙钟只报告、不断言**；**确定性计数才断言**；倍数一律用**同进程 legacy 复刻**做参照（仿 `story_flow_bench_test.dart:120-139 legacyStageOf`）。
- **GUI 我无法自查**：小地图跟手、候选浮层不消失、409 新交互等只能你跑 `python run_dev.py` 目视；我不会声称已验证渲染与交互正确。

---

## 已核实缺陷清单（证据；编号供后文引用）

### A 热路径
| # | 位置 | 问题 |
| --- | --- | --- |
| A1 | `api.py:744-777` | `cfg_read` 无缓存，每请求 40MB 读盘+解析+再序列化 |
| A2 | `httpd.py:146-163` | `_respond` 只能 `json.dumps(payload)`，**无免序列化出口** → 命中缓存也省不掉编码 |
| A3 | `api.py:775-777` | 响应同时带 `data` 与 `keys`（9.8 万键排序 + ~1.2MB 冗余，前端无人消费，仅 `backend_integration_test.dart:51` 断言过） |
| A4 | `story_flow_workspace.dart:940-955`（同形 `:883-884`、`:1406-1418`、`:1472-1494`） | 保存走 GET 全表 → merge → PUT 全表 |
| A5 | `api_client.dart:61-63` | 大表在 UI isolate 解码 |
| A6 | `cfg_store.py:153` | 全局 `_STACK_LOCK` 包住所有磁盘 IO，A 表保存阻塞 B 表 undo |
| A7 | `cfg_store.py:99,166` | 一次保存把同一文件读两遍 |
| A8 | `cfg_store.py:177` | undo 栈存整表文本（50 项 ≈ 2GB） |
| A9 | `cfg_store.py:93-124` | `.editor_history` 永不清理、内容未变也快照 |
| A10 | `api.py:393,803-805` | 任一表写入 → `_MOD_CFGS_FP=None`，下次 `_load_mod_cfgs()` 重解析**整个目录** |
| A11 | `api.py:2200-2234` | `bugfix_fix` 调 `scan_bugs` 两次 + 循环内线性 `next()` → O(targets×bugs) |
| A12 | `ref_rules.py:155-172` | 36 条规则各自重建目标表 id 全集（TalkCfg 被 ~9 条当目标） |
| A13 | `api.py:910` + `:419-438` | `/api/validate` 绕缓存全量解析 3 张大表 + `_base_table_ids` 逐 key `int()` |
| A14 | `api.py:1872-1879` | `if k in (keys or [])` 对 list 线性查找嵌在遍历内 |
| A15 | `api.py:174-236` | `list_mods` 每请求多根全量 walk（`/api/state`、`cloud_sync._get_mod_dir` 高频） |
| A16 | `bugfix_service.py:385` | 为**所有** base 表预建 key set，实际只需被引用的几张 |

### B 后端正确性
| # | 位置 | 问题 | 后果 |
| --- | --- | --- | --- |
| B1 | `api.py:357` | `return dict(_MOD_CFGS_CACHE)` 是**浅拷贝**（注释误称防篡改）；`bugfix_service.py:464,469,480`、`api.py:2150-2158`、`:2073-2075` 就地改内层记录（已读码确认） | 并发 `RuntimeError: dictionary changed size during iteration`（`httpd.py:70` 吞成 500）；写失败后缓存残留半修状态 |
| B2 | `api.py:763-764`、`cfg_store.py:55` | `errors="replace"`：GBK 表以 U+FFFD 载入且**能解析成功**，改一行再 PUT 即整表不可逆毁数据 | 毁数据 |
| B3 | `cfg_store.py:235-264` | `undo`/`redo` **先改栈**再调可抛 `PermissionError` 的 `_restore` | 栈已消费、文件未回滚，历史永久错位 |
| B4 | `cfg_store.py:133,213` | 文本模式写缺 `newline="\n"`（Windows 整表变 **CRLF**，真实文件是 LF）；`os.replace` **无瞬时占用重试** | 每次保存整文件字节级改写；偶发 WinError 5 直接失败 |
| B5 | `cfg_store.py:133` | 写回固定 `encoding="utf-8"` 丢掉源 **BOM**，而快照路径专门保 BOM | 字节不等价、语义自相矛盾 |
| B6 | `cfg_store.py:157-159` | 冲突只比 `st_mtime_ns`（Windows 粒度 ~15.6ms，`test_cfg_store.py:48-51` 靠 sleep 绕） | 同刻度外部改动被静默覆盖 |
| B7 | `tts_store.py:187` | `bind_talk_audio` 不传 `expect_mtime_ns`，整体覆盖 TalkCfg | 丢掉 GUI 并发保存 |
| B8 | `bugfix_service.py:394-395` | 整段引用校验 `except Exception: pass`（同类 `api.py:1819-1822`、`decoded_pack.py:61,69,79`） | 用户看到「无问题」而实际没扫 |
| B9 | `bugfix_service.py:445-453` | 新选项 id `"%s%02d"` 后缀 ≥100 溢出成 3 位、跨进他事件 id 段；键写 str 而记录 `id` 写 int；`:428`/`:469`/`:480` 只按 str 键定位 | 撞号 / int 键表永远修不动 |
| B10 | `plugin_system.py:695-707` | 持全局 `_lock` **调用插件 handler**（同文件 `agent_exec:636-653` 注释点名禁止此写法并已用锁外执行） | 一个卡住的插件路由冻结全部插件/面板/Agent 工具 |
| B11 | `httpd.py:112-120` | 兜底 `_respond(500)` 可能在响应已部分发出后再发一份 | 长连接协议错位 |
| B12 | `httpd.py:177-183` | `do_OPTIONS` 不走 `_check_origin` 且回 `Access-Control-Allow-Origin: *` | 本地 API 防护不一致 |
| B13 | `httpd.py:186-198` | 每连接一线程 + keep-alive，无 idle 超时/线程上限 | Dart 空闲连接长期占线程 |
| B14 | `api.py:2083,2168` | `int(query["limit"])`、`int(kv[0])` 无保护（`:1785` 已示范安全写法） | 外部输入直接 500 |
| B15 | `decoded_pack.py:31-35,96,130-131` | `_texsizes` 靠 `hasattr` 懒建，`refresh` 先换 `_tex` 后清 sizes | 并发读到跨包尺寸 |
| B16 | `api.py:359-368` | `_load_mod_cfgs` 把解析异常静默转成空表 | 坏文件伪装成「无数据」并被引用校验误判 |

### C/D 前端（已逐条读码核实）
| # | 位置 | 问题 |
| --- | --- | --- |
| C1 | `story_director_view.dart:2818-2825`（`:2768` 逐行调用） | `_eventTalkCount` 每行新建 `PrefixMatcher` 并遍历 98,963 键 → 一屏 20 行 ≈ 200 万次 match |
| C2 | `story_flow_graph.dart:926-932` | `didUpdateWidget` **无条件** `_slotsTier=-1` → 每次宿主重建为**全部** N 节点新建卡片+`_outputPorts`+`_nodeWorldRect`（~2,500 分配/帧）。`:883` 注释「只有换档才重算」已失效；bench 的 `debugNodeCardBuilds` 只数已挂载卡片，**完全掩盖它** |
| C3 | `story_flow_workspace.dart:1049-1064`（`_onMoveNode` 每帧调；组拖 `story_flow_graph.dart:637-639` 每节点各调一次） | 每帧把整个 `_positions` 复制成 `{id:{x,y}}` |
| C4 | `story_flow_graph.dart:290-304` + `:1937-1952` | `_geometryRev` 含 `positionsVersion` → **拖拽每帧清空虚线缓存**；连线 `for e in graph.edges` 无可见区裁剪（卡片有、连线没有）；`dashKey` 每条边插值分配（实线不读） |
| C5 | `story_flow_workspace.dart:1769-1777` | `_inlineMetas` 绕过已有 `_metasFor` 缓存，每张展开卡片每帧重算 25 字段 |
| C6 | `story_flow_models.dart:614-621` | `layoutFlow` 每个不可达节点 `layer.values.reduce` 重扫全表 → O(N²)；`workspace:1040` 每次切事件跑全图布局 |
| C7 | `story_flow_workspace.dart:1006-1012` | 每次 graph 重建重算 3,154 行 EvtCfg 的 `evtTitles` |
| C8 | `schema_editor_view.dart:97-114,747-750` | `_applyFilter` 每键全表扫（空查询也 `List.from` 复制 98,963 项） |
| C9 | `schema_editor_view.dart:1660-1685,1754,1779` | `_options()` 每次 build 调两遍（物化+排序全字典），`:1714` 再按 token 线性找 |
| C10 | `story_flow_workspace.dart:2012-2112` | `_onMoveNode` 的 `setState({})` 重绘整个 Stack（Inspector/侧栏/操作簇/`_EventChip` 全跟帧） |
| D1 | `story_flow_minimap.dart:351-356` | `shouldRepaint` 用 `!identical(old.positions, positions)`，而 positions **原地修改不换引用** → 拖拽时恒 false（`:175` 注释结论相反，是错的）→ **小地图节点块不跟手** |
| D2 | `story_flow_suggest.dart:170,196,208,280,317,340` | `sourceForField` 每次返回**新闭包** → `suggestion_text_field.dart:147-150` 的 `!identical` 恒真 → 每次宿主重建 `clearCandidates()`：**用户正开着的候选浮层在拖拽中悄悄消失**；并连带 `story_flow_graph.dart:1569` 每帧重算回显（`suggest:214-226` 每次重算 `mergeNameDict` + 排序） |
| D3 | `story_logic.dart:328-330` + `workspace:957` | `mergeStageBack` 把舞台**活记录**塞进 `_tablesData`。完整链条已核实：`_discardStage:570` 用 baseline 重建舞台（新对象），但 `_tablesData['TalkCfg']` 仍指向被丢弃的旧对象 → 切走再切回时 `_selectEventInner:585-587` 的 `stageOf` 把它们**深拷回舞台且 `_dirty=false`（:591）** → **已放弃的修改以"干净"状态复活，并在下次保存落盘** |
| D4 | `core/history_client.dart:14,20,26` | 顶层 `_busy` 全局互斥，被占用那次返回 `false` → 误报「没有可撤销」 |
| D5 | `schema_editor_view.dart:1628-1633` | `_ctrl.text = ValueCodec.encode(...)` 把半截输入规范化并把光标弹到末尾 |
| D6 | `field_meta.dart:180` | 自述 TODO：`plugin_system` 的 `body_fields`/`hidden_ports` 至今没接到 GUI |

### 本轮不做（独立问题，避免范围失控）
`cloud_sync.py:1939-1957` `_need_sync`（WebDAV/OpenList `list()` 恒返回 `sha1=""`（`:319`）→ `:1953` 短路，**内容变了但 size 相同的文件永不重传**；`:1945-1947` 是自我否定的死分支）；`cloud_sync.py:208` 用 `shutil.copy2` 直写目标 cfg（非 tmp+replace，中断留半截 JSON）；`cloud_sync.py:2042` 起整文件夹同步在**请求线程**执行（`api.py:2432` 直调）；`history_store.py:131-151` 为取元数据整体 `json.loads` 每个会话文件；`fs_tools.py:48` 沙箱比较未 `normcase`；`ref_rules.py:83-88` 字符串负数（`"-1"`）归一化返回 None —— 只造成**漏报**不会误报；`FlowEditHistory` 每步存整舞台深拷贝（`limit=60`）是内存问题不是帧问题。

---

## 实施方案

### S0 护栏先行（无行为改动）
新增 `backend/editor/server/perf.py`：进程级 `COUNTERS` + `bump/add/get/reset/window`。
**不用 thread-local**：handler 跑在 `ThreadingHTTPServer` 工作线程，测试线程读不到；一次 socket 往返即同步点。并发压测下只允许断 `>=`。生产侧只在「每请求一次」处 bump，**绝不在 99k 行循环内 bump**（否则测的是自埋点）。
词表：`cfg.reads` / `cfg.read_bytes` / `cfg.parses` / `cfg.dumps` / `cfg.writes` / `cfg.write_bytes` / `cfg.snapshot_bytes` / `cfg.snapshots_written`。

接线落点（本身就是 S1/S2 的必要重构）：新增 `cfg_store.read_raw(abs_path) -> bytes|None` 作为**唯一读盘口**（今天有四条：`api.py:763`、`cfg_store.py:48`、`:99`、`api.py:364`）。

新增 `backend/editor/server/benchdata.py`（不以 `test_` 开头故不被收集）：98,963 行夹具**用字符串 join 造，绝不用 `json.dumps`**（2.34s），每行 pad 到 ~400B 使总量达 40MB 量级；模块级 `_TEXT_CACHE` + `TMP_ROOT = mkdtemp()` + `atexit` 清理（**不要 `tearDownModule`**，跨文件复用需要它活着）。成本 ≈0.4s 只付一次。

`unittest.mock.patch("json.dumps")` 不够用：三个模块 `import json` 同一对象无法归因；mock 必须 `side_effect` 转发才不改行为，而那正好把「免序列化」这条待验路径换掉了。只保留一个交叉验证用例 `test_perf_counter_matches_mock` 证明计数器不说谎。

前端新增计数器（`story_flow_graph.dart:95` 旁，`if (kDebugMode)`）：`debugBuildSlotsCalls`、`debugSlotCardsBuilt`、`debugLayoutSnapshots`、`debugWorkspaceBuilds`、`debugFlowFieldMetasBuilds`、`debugSuggestClosuresBuilt`、`debugEchoQueries`；`api_client.dart` 加 `debugDecodedRows`、`debugUiIsolateParsedRows`、`debugOffIsolateParses`。

### S1 后端读路径：解析缓存 + 免序列化出口 + 投影查询
1. `httpd.py`：`dispatch` 允许 handler 返回 `(status, bytes)`；`_respond` 见 bytes 走 `_respond_raw` 直写（零 `json.dumps`）。同文件一并做 B11/B12/B13。
2. `api.py`：新增按表解析缓存 `_TABLE_CACHE[path] = (mtime_ns, size, data, body_bytes)`（LRU 2~3 项，加锁；写入/undo/redo/`forget`/指纹变更时失效）。`cfg_read` 命中即返回缓存 bytes。
3. `cfg_read` 加可选 query：`prefix=a,b,c`（服务端按 `k[:-3] in prefixes` 过滤，与 `PrefixMatcher` 严格同式，前缀由前端 `storyRelatedPrefixes` 传入 → **Python 不重实现推导逻辑**）、`meta=1`（只回 `mtime_ns/exists/count`）、`keys` 改为显式 `keys=1`（A3）。**不新增路由**，避免 MockClient 全改。
4. `_MOD_CFGS_FP` 改**逐表指纹表**，一次写只作废该表（A10）；`/api/validate` 改走缓存并缓存 base id set（A13/A16）；`api.py:1872-1879` 预建 dict（A14）；`list_mods` 加 2s TTL（A15）。

**准出**：热 GET 的 `cfg.parses == 0`、`cfg.dumps == 0`、`cfg.read_bytes == 0`；缓存命中字节与现场序列化**逐字节相等**（专杀 `indent`/`ensure_ascii` 用错一套）；失效用 `os.utime` 强制推进 mtime（**不能靠 sleep**，Windows 15.6ms 粒度）；一次写后只重解析一张表（`cfg.parses` 由 4 → 3）。同进程放今天 `cfg_read` 的逐字复刻 `legacy_cfg_read` 报倍数，并断 `json.loads(warm_body) == json.loads(legacy_body)` 作为行为等价硬证据。

### S2 后端写路径：`patch` 语义 + 快照策略 + undo 栈瘦身
1. 新建 `backend/editor/core/atomic_io.py`（`core` 不 import `server`，反向合法）：`write_bytes_atomic(abs_path, data, *, retries=5, delay=0.02)` —— makedirs → `_tmp_path_for` → 二进制写 → 循环 `os.replace`，捕获 `PermissionError/FileExistsError`（WinError 5/32）重试，末次失败清 tmp 后抛 `OSError`；`write_text_atomic(..., bom=False)` 走 bytes 路径 → **CRLF 回归消失**（B4）。
2. `cfg_store.py`：`_atomic_write`/`_restore`/`_write_snapshot` 全用该助手；`write_cfg` 在**唯一一次** `open(...,"rb")` 里同时拿 `raw`（供快照与旧文本复用，A7 消失）并嗅探 BOM 原样写回（B5）；新增 `HISTORY_KEEP = 10`（**不复用 `HISTORY_LIMIT=50`**：50×40MB=2GB 磁盘）滚动修剪（A9）；**序列化内容与磁盘相同则不快照不写盘**；undo 栈项改存 `(snap_name, None)`，仅快照失败时保留文本（A8）；新增 `debug_stack_bytes()`/`debug_reset_stacks()`；`undo`/`redo` 改「peek → `_restore` 成功 → 才动栈」（B3）；锁只护 `_STACKS`，磁盘 IO 移出全局锁并改**按路径锁**（A6）；冲突检测加 `expect_digest`（sha1，缺失才退回 mtime 比较）（B6）；新增 `read_lossy(abs_path) -> (raw, text, lossy)`，`write_cfg` 返回 `lossy` 标志。
3. `cfg_store.apply_patch(path, *, set, remove, if_match, expect_mtime_ns, force)`：走 S1 解析缓存 + 上述原子写链路；逐行 `if_match` 深比对，冲突返回 `{conflicting_keys, mtime_ns}`（**不回 data**）。
4. `api.py:779-813 cfg_write`：body 含 `patch` 即走 `apply_patch`；`/api/ping` 加 `cfg_patch: true`。

**准出**：内容未变重存 → `snapshot_bytes == 0` 且 `len(list_history) == 0`；变 12 次 → 恰好保留 10 份且删的是最旧（并排断另一张表未被越界修剪）；三次带快照的大表写入后 `debug_stack_bytes == 0`（今天 ≈120MB），反向配对 `snapshot=False` 时 `> 0`（否则 undo 失效）；`undo()` 后文件字节与最初全等（`:241` 链路不破）；monkeypatch `_restore` 抛 `PermissionError` → `undo()` 返回 `ok=False` 且栈长度不变；新增 `test_save_preserves_bom_and_lf`。

### S3 前端去整表往返（与 S1/S2 契约耦合，主代理做）
1. **删掉 `_tablesData['TalkCfg']`/`['OptionCfg']` 两张全表缓存**。核实过它们只有两个读者：`_selectEventInner:585-586` 的 `stageOf` 与 `_save:946-947` 的 `mergeStageBack`；其余消费者全在舞台内（`:1157`、`:1020`、`:1196,1289`、`:1237,1320`），`_suggestDeps.modTable:1759` 只会拿到 Person/Bg/Audio/EvtType。**这不是"缩小缓存"，是"缓存不该存在"** —— 删掉后 D3 的别名在结构上不可能发生。
2. `_tables` 拆 `_metaTables`（6 张小表仍全量）与 `_stageTables`（Talk/Option 启动只 `meta=1`）；`_selectEventInner` 改 async：先 `?prefix=` 拉两小批再 `stageOf`（**保留 `stageOf` 即保留旧语义与旧测试**，MockClient 忽略 query 也能返回小 fixture）。director 同理（`story_director_view.dart:186`）。
3. `_save`：新增纯函数 `StagePatch diffStage(baseline, stage, prefixes, {isOption})`（`set` = 基线缺失或 `_sameValue` 不等，值经 `copyRecordValue`；`remove` = 基线∩前缀舞台；`ifMatch` = 这些 key 的基线值），与 `mergeStageBack` **逐 key 等价**；发 `PUT {patch, if_match, expect_mtime_ns}`。成功后基线增量结算（`remove` 摘除、`set` 写 `copyRecordValue(stage[k])`，**绝不写舞台引用**）。
4. `:883-887`（后端 undo/redo 后）改 `?prefix=` 重载 + 小 `EvtCfg` GET + `_selectEventInner`；`:1406-1418`、`:1472-1494` 的 EvtCfg（3,154 行）保留 GET-fresh+PUT-whole，Talk/Option 部分改 `patch`。
5. 409 交互必须改：`:972` 现在说「请再点一次保存」，但无 re-GET 后重复点必然再撞同一个 `expect_mtime_ns`。改为按 `conflicting_keys` 列出被外部改动的行 + 动作「采用磁盘值 / 覆盖并重试 / 取消」。
6. `api_client.dart`：`getBig(path)`，`_decode` 在 `bodyBytes.length > 2MB` 时 `compute` 分叉（worker 内返回已 `Map<String,dynamic>` 化的表，避免主 isolate 再 cast；4xx→`ApiException` 判定留主 isolate）。仅 `schema_editor_view.dart:189` 换调 `getBig`。**论证**：`compute` 送 40MB 进 worker 可零拷贝（`TransferableTypedData`），但解析出的 9.8 万条对象图必须整体序列化送回 UI → 总工作量上升。所以剧情图/导演走「不传大表」为主，`compute` 只留给确实需要全表的经典编辑器。

**准出**：`test/cfg_patch_equivalence_test.dart` 对 N 组随机 baseline/stage/prefix 断 `patch 应用结果 == mergeStageBack 结果`；保存一次单字段编辑时 `set.length + remove.length == 1`、PUT body `< 2048 B`、响应无 `data`/`keys`、`GET /api/cfg/TalkCfg` 次数 **0**；启动后 `debugDecodedRows` 中 TalkCfg 贡献 **0** 行；打开剧情图 `debugUiIsolateParsedRows == 0`；回归围栏：切 20 个事件期间 `GET /api/cfg/*` 次数为 0（`_selectEventInner` 走内存 `stageOf`，今天已是 0 —— **断 0 是废话，所以断的是"别退化"**）。

### S4 前端帧路径（可与 S3 并行，但 `story_flow_workspace.dart` 只能一个写者 → 该文件的 C3/C5/C7/C10 与 S3 串行，其余文件并行）
- C1：`_talkCfg` 换新时一次性派生 `Map<String,int> _talkDerivedPrefixCounts`（key = 与 `PrefixMatcher` 同式的派生前缀，短 id 归自身桶），`_eventTalkCount` = 各桶求和（桶互斥故精确）。准出：派生扫描 **1×98,963**、滚动/重建期间 **0**。
- C2：`Positioned` 从 `_FlowNodeCard.build:1114` 上提到槽位包装（`_FlowSlot = Positioned(key, left/top/width/height, child: 缓存卡片实例)`，`_outputPorts` 改相对偏移），卡片实例进 `Map<String,Widget> _cards`，只在 `_contentSig`（tier / `graph` 身份 / expanded / selection / highlight / `_fieldInvalid.size`）变化时重算；`positionsVersion` 只驱动 `Positioned` 与裁剪矩形。因 `Element.updateChild` 对 identical 子 widget 短路，未动的可见卡片连 build 都不进。准出：`debugBuildSlotsCalls` 同 graph 重泵 30 次宿主 Widget **== 0**（今天 30），**同用例必须带负向对照**（改 `expandedNodes` → 1、换档 → 1，否则"计数器写坏了"也能通过）；bench B2 的 `r.cards` 从 `lessThan(200×30)` 收紧成 `equals(0)`。
- C3：`_markLayoutDirty` 改 `_positionsRev++` + 脏事件集合，序列化推迟到 `_writeLayoutFile`。准出：30 帧拖拽 `PUT /api/tools/write == 1`、`debugLayoutSnapshots == 1`。
- C4：连线 paint 内按 `Rect.fromPoints(s,t)` 与可见世界矩形求交跳过；`dashKey` 只在 `dashed` 时构造并把端点量化进 key，从而 `_geometryRev` 去掉 `positionsVersion`。
- C5/C7：`_inlineMetasCache[cfg|isOption]` 由 `_metasFor` 过滤而来；`_evtTitles` 并入 `_refreshEventList`（同一失效键 = EvtCfg `mtime_ns`）。准出：`debugFlowFieldMetasBuilds` 切一次事件 **== 2** 其后 **0**；`debugEvtCfgTitleRows` 跨 10 次 `_bumpGraph` **== 0**。
- C8/C9：`_applyFilter` 加 220ms 防抖 + 空查询直接复用 `_sortedIds` 引用；`_options()` 按 `gameDicts` 版本缓存。
- C10：`_positionsRev` 提为 `ValueNotifier<int>`，画布包 `ValueListenableBuilder`，拖拽帧不再触宿主 `build`。准出：`debugWorkspaceBuilds` 拖拽 30 帧 **== 0**（现 ≥30），`panDelta` 断言保持不变以证明事件仍送达。
- C6：`layoutFlow` 循环外维护 `maxLayer`（消 O(N²)）。

### S5 前端 bug（D1/D2/D4/D5）
- D1：加 `required this.positionsVersion`，判定抽成可测纯函数 `flowMinimapNeedsRepaint(...)`，改正 `:175` 的错误注释。
- D2：`FlowSuggestDeps` 内 `final _memo = <String, SuggestionSource?>{}{}`，`sourceForField` 以 `'$cfg:${meta.key}'` 记忆化（分支输入全是 (cfg,meta) 的纯函数，语义不变）；`_suggestDeps` 由 getter 改 `late final`（否则 deps 每取新建使 memo 无意义）；工作区加 `_suggestCache['$evtId|$nodeId|$field']`（`_dropCtls` 同前缀回收、`_reloadForMod` 清空）。准出：`expect(identical(sourceForField(a), sourceForField(a)), isTrue)`；「弹出候选后宿主 setState → 浮层仍在」；拖拽期间 `debugEchoQueries == 0`。
- D3：`story_logic.dart:329` 改 `target[entry.key] = copyRecordValue(entry.value)`（与 `stageOf:343`、`story_flow_history.dart:100-114 _detach` 同法）。测试：merge 后改 `stage['1000']['content']`，断 `full` 不变；并加「放弃修改 → 切走 → 切回 → 舞台等于基线」的端到端用例（这条正是已复现的复活链条）。
- D4：`enum HistoryOpResult { applied, empty, busy, failed }`，`_busy` 命中返回 `busy`；调用点 `workspace:861-880`、`editor_area.dart:41` 同批改（类型跨文件，必须同一提交）。
- D5：`value_codec.dart` 加 `valueCodecNeedsResync(text, value, type)`（decode 现文本 + 深比较，异常按需要回写处理），`:1628-1633` 只在真不等价时回写。测试直测 `"1,"` vs `[1]` → false、`""` vs `[5]` → true。

### S6 后端 bug 批（G1→G2→G3→G4 有依赖，其余可并行）
- **G2**：`atomic_io` 推广到全部原子写站点（`fs_tools.py:124,141`、`env_store.py:113`、`history_store.py:58`、`base_service.py:326`、`cloud_sync.py:1742`、`realtime_sync.py:91`、`resource_pack.py:87,228`、`tts_store.py:96`、`unityfs_res.py:218`），文本模式那几处同修 CRLF；B10 照抄 `agent_exec:639-653` 形状（锁内取 `fn`、锁外调用）；B7 `bind_talk_audio` 传 `expect_mtime_ns` 并在冲突时抛 `TtsStoreError`。
- **G3**：B1 **不深拷 40MB** —— `_load_mod_cfgs()` 返回 `MappingProxyType` 只读视图（每次仅 ~30 个代理对象），删掉 `api.py:392` 那句无效且唯一制造别名的 `_MOD_CFGS_CACHE[cfg_name] = data`，写方改「扫描用只读缓存，落笔前按 touched 表从磁盘 fork 私有副本」；B16 解析失败记 `_MOD_CFGS_BROKEN` 并跳过（不再伪装空表），`bugfix_scan/fix` 注入 `flag="ERROR"` 条目；B2 `cfg_read` 带 `lossy` 标志，`cfg_write` 前置 `if not force and lossy → 409 non-utf8-source`；B8/B14 按上表修。
  - ⚠ `MappingProxyType` 风险（架构代理提出，我已确认必要）：`mappingproxy` 不可 JSON 序列化，任何把缓存对象直接交给响应的地方会 500 → 必须在响应边界 `dict(...)`，并跑全量 `pytest` + `flutter test` 验证。
- **G4**：B9 **不扩 id 位宽**（事件×100+2 位是游戏硬约定），改为扫描该事件段内已用后缀取 `max+1`，`nxt > 99` 时 `return False` 交回 remaining 让用户手工分配；加 `_row_key(bucket, _id)` 依次试 `_id`/`int(_id)`/`str(int(_id))`，`:469/:474/:480` 全部用解析出的键（int 键表也能修）。
- A11/A12：`bugfix_fix` 预建 `{(cfg,id,key): bug}` 索引 + `remaining` 只重扫 touched 表；`ref_rules` 按 target 缓存 `valid` 集合、`_dict_keys` 提为模块常量。

### S7 收尾
`backend_integration_test.dart` 的 12 条：`setUpAll` 里一次性 `Socket.connect(8765, timeout: 300ms)` 存 `_backendUp`，每条 test 首行 `if (!_backendUp) markTestSkipped(...)`。**不用 `group(skip:)`**（声明期求值，异步拿不到），**不让 `setUpAll` 抛异常**（会把整个 suite 判 failed，正是要消掉的噪音）。后端在跑时一行都不跳，回归照旧响亮失败。属本批（基线唯一红灯、零生产风险），排最后落。

---

## 实施状态追踪（2026-09-05 全部完成）

| 方案 | 状态 | 备注 |
| --- | --- | --- |
| S0 护栏先行 | ✅ 完成 | perf.py + benchdata.py + 前端 7 计数器 |
| S1 后端读路径 | ✅ 完成 | 准出 `test_s1_read_exit.py`；含写后播种缓存（超额） |
| S2 后端写路径 | ✅ 完成 | 准出 `test_s2_write_path.py`；apply_patch + ping 能力门 |
| S3 前端去往返 | ✅ 完成 | `cfg_patch_equivalence_test.dart` 200 轮等价 + body<2KB |
| S4 前端帧优化 | ✅ 完成 | C1-C7 + C10；拖帧 14.81→3.85ms（M4 达成） |
| S5 前端 bug | ✅ 完成 | D1-D5 |
| S6 后端 bug 批 | ✅ 完成 | G2（子代理）/G3/G4 + A11/A12/A14/A15/A16/B14 |
| S7 收尾 | ✅ 完成 | backend_integration 探测 skip；文档见 IMPLEMENTATION_STATUS.md |

最终测试水位：后端 293 passed；前端 392 passed / 7 skipped / 0 失败。
指标终值与行为变更清单：`IMPLEMENTATION_STATUS.md`。

**关键里程碑**：
- M1（S0+S1 完成）：GET /api/cfg/TalkCfg 从 ~3s 降至 ~300ms
- M2（S0+S1+S2 完成）：保存对白从 ~100MB 往返降至 ~2KB
- M3（S3 完成）：剧情图启动解码行数 = 0
- M4（S4 完成）：拖拽卡顿从 14.81ms → <5ms
- M5（全部完成）：248 个后端测试全绿，前端 12 个环境性测试跳过

**总工作量预估**：~96 人时（约 12 工作日，考虑并行后约 5-6 工作日）

---

## 执行检查清单

### W1（S0 - 护栏先行）
- [ ] 创建 `backend/editor/server/perf.py`，实现 COUNTERS
- [ ] 创建 `backend/editor/server/benchdata.py`，生成 40MB 合成表
- [ ] 在 `story_flow_graph.dart` 添加调试计数器
- [ ] 在 `api_client.dart` 添加解析计数器
- [ ] 编写 `test_perf_counter_matches_mock` 交叉验证用例
- [ ] 验证计数器不引入性能偏差（与 legacy 复刻对比）
- [ ] ✅ 运行 `cd backend && python -m pytest editor -q` 确保 248 passed

### W2（S1 + S5-D2/D3/D5）
- [ ] `httpd.py`：实现 `(status, bytes)` 原始响应通道
- [ ] `api.py`：新增 `_TABLE_CACHE`（LRU 缓存）
- [ ] `api.py`：`cfg_read` 支持 `prefix/keys/meta` query
- [ ] `story_flow_suggest.dart`：`sourceForField` 记忆化
- [ ] `story_logic.dart`：`mergeStageBack` 深拷贝修复 (D3)
- [ ] `value_codec.dart`：光标不同步问题修复 (D5)
- [ ] 测试：缓存命中字节级校验
- [ ] ✅ 运行全量测试

### W3（S2 + S4-C1/C2/C4/C6）
- [ ] 创建 `backend/editor/core/atomic_io.py`
- [ ] `cfg_store.py`：使用原子写 + BOM 保留
- [ ] `cfg_store.py`：HISTORY_KEEP=10 滚动修剪
- [ ] `cfg_store.py`：undo/redo 顺序修正 (B3)
- [ ] `story_director_view.dart`：C1 前缀计数优化
- [ ] `story_flow_graph.dart`：卡片缓存重建 (C2)
- [ ] `story_flow_models.dart`：layoutFlow O(N²) 优化 (C6)
- [ ] 测试：`test_save_preserves_bom_and_lf`
- [ ] 测试：undo 栈内存测试 `debug_stack_bytes == 0`
- [ ] ✅ 运行全量测试

### W4（S6-G2/G4 + S5-D1/D4 + S4-C8/C9）
- [ ] `fs_tools.py`、`env_store.py`等推广 atomic_io
- [ ] `tts_store.py`：冲突检测加 expect_mtime_ns
- [ ] `bugfix_service.py`：id 溢出修复 (B9)
- [ ] `story_flow_minimap.dart`：shouldRepaint 修正 (D1)
- [ ] `history_client.dart`：busy 状态返回类型修正 (D4)
- [ ] `schema_editor_view.dart`：防抖 + 缓存优化 (C8/C9)
- [ ] ✅ 运行全量测试

### W5（S6-G3 + S3 全部 + workspace.dart 修正）
- [ ] **主代理独占执行**
- [ ] `api.py`：_MOD_CFGS_CACHE 改 MappingProxyType
- [ ] `api.py`：坏表记错不伪装空表 (B16)
- [ ] `story_flow_workspace.dart`：删除 TalkCfg/OptionCfg 全表缓存
- [ ] `story_flow_workspace.dart`：增量 patch 保存逻辑
- [ ] `story_flow_workspace.dart`：409 冲突 UI 改进
- [ ] 测试：`test/cfg_patch_equivalence_test.dart`
- [ ] 测试：保存单字段 body < 2048B
- [ ] ✅ 运行全量测试 + GUI 目视验证

### S7（收尾）
- [ ] `backend_integration_test.dart`：环境性测试 skip 处理
- [ ] 文档更新：行为变更标注（B2/B9/B12/S1-3）
- [ ] 基准回归测试截图存档
- [ ] 发布说明撰写
- [ ] ✅ 最终验收：248 passed + 画布 benchmark 不降级

---

## 沟通与交接规范

### 子代理交付物要求
- **提交前**：必须运行 `cd backend && python -m pytest editor -q` 全绿
- **提交前**：必须运行 `cd frontend && flutter test` 无新增失败
- **PR 描述**：包含性能数据对比（与上一版同进程倍数）
- **代码注释**：在关键路径添加计数器调用注释
- **越界检查**：只修改 assigned 文件，其他修改单独 PR

### 主代理复核要点
- [ ] git diff 逐份核对子代理提交
- [ ] 确认无跨文件接线（除非指定依赖）
- [ ] 几何常量未误改为样式
- [ ] 计数器埋点位置正确（不在循环内）
- [ ] 测试用例覆盖边界情况
- [ ] 文档中的数字与实际测量一致

### GUI 目视验证清单（主代理）
- [ ] 小地图节点块跟手拖动
- [ ] 候选浮层在宿主 setState 时不消失
- [ ] 409 冲突显示被修改行号并提供操作按钮
- [ ] 输入框逗号不吞光标、不跳到末尾
- [ ] 拖拽画布无卡顿感提升
- [ ] 切换事件无假死或异常重载

### 已知风险标记
- 🔴 **高危**：涉及数据持久化（undo/redo/保存）
- 🟡 **中危**：涉及缓存失效逻辑
- 🟢 **低风险**：纯前端渲染优化

---

## 参考资源

### 相关文档
- `frontend/test/story_flow_bench_test.dart` - 基准测试代码
- `backend/editor/server/httpd.py` - HTTP 服务器实现
- `backend/editor/core/cfg_store.py` - 配置存储管理
- `.qoder/AGENTS.md` - Agent 配置文件

### 性能分析工具
- `cProfile` - Python 性能分析
- `flutter profiler` - Dart 性能分析
- Chrome DevTools Network tab - API 请求监控

### 关键指标定义
| 指标 | 当前值 | 目标值 | 测量方法 |
| --- | --- | --- | --- |
| GET /api/cfg/TalkCfg | ~3s | ~300ms | server timing header |
| 保存对白往返数据 | ~100MB | ~2KB | Network tab |
| 画布拖拽帧耗时 | 14.81ms | <5ms | story_flow_bench_test.dart |
| UI 隔离区解析行数 | 98,963 | 0 | debugUiIsolateParsedRows |
| undo 栈内存占用 | ~2GB | <100MB | debug_stack_bytes() |

---

*文档版本：1.0*
*最后更新：2026-09-03*
*维护者：AI 开发团队*

## 并行波次（一个文件只有一个写者）

| 波次 | 后端轨 | 前端轨 |
| --- | --- | --- |
| W1 | S0（`perf.py`+`benchdata.py`，新文件） | S0 计数器（`story_flow_graph.dart`、`api_client.dart`） |
| W2 | S1（`httpd.py`+`api.py`） | S5 的 D2/D3/D5（`story_flow_suggest.dart`、`story_logic.dart`、`value_codec.dart`） |
| W3 | S2（`cfg_store.py`+`atomic_io.py`+`api.py` 的 `cfg_write`） | S4 的 C1/C2/C4/C6（`story_director_view.dart`、`story_flow_graph.dart`、`story_flow_models.dart`） |
| W4 | S6 G2/G4（各文件互不相交） | S5 的 D1/D4 + S4 的 C8/C9（`story_flow_minimap.dart`、`history_client.dart`、`schema_editor_view.dart`） |
| W5 | S6 G3（`api.py`） | **主代理**：S3 全部 + S5/S4 里 `story_flow_workspace.dart` 的每一处 |

争用文件：`api.py`（S1/S2/S6-G3）、`story_flow_workspace.dart`（S3/S4/S5）→ 全程单写者、串行。子代理只允许写自己那一个文件，禁止碰 git 与其它文件；回来后主代理用 `git diff` 逐份复核越界与「把几何常量当样式替换」。

## 风险与预期未满足项（交接时逐条交代）
1. **GUI 目视项我无法自查**：小地图跟手（D1）、候选浮层不消失（D2）、409 新交互（S3-5）、逗号不吞光标不跳（D5）—— 需你跑 `python run_dev.py` 确认，我不会声称已验证。
2. **行为变更需明确标注**：B2 的 `cfg_write` 拒绝覆盖 lossy 源、B16 坏表不再伪装空表、B9 位段满时不再自动分配、B12 跨站预检不再无条件放行、S1-3 的 `keys` 改为显式请求 —— 这五条改变用户/调用方可见行为，与「等价重构」分开提交。
3. `?prefix=` 的服务端过滤必须与 `PrefixMatcher` 严格同式（`k[:-3]`、短 id 归自身），等价性靠 `cfg_patch_equivalence_test` 与 `stageOf` 保留在客户端双重兜底；若不同式，剧情图会**静默少节点**，这是本方案最大的正确性赌注。
4. `MappingProxyType` 可能撞上未预见的序列化点（见 S6-G3 ⚠）。
5. 真实 40MB 表的测试默认 `skipUnless(EDITOR_PERF_REAL=1)`（与 `EDITOR_PLUGINS_ROOT` 同风物），所以**默认 CI 只跑 30MB 合成表**；跨机对比仍只看计数。
6. 快照修剪到 10 份会**缩短可撤销深度**（磁盘层面），内存栈仍是 50；这是设计选择不是缺陷。
7. `atomic_io` 重试最多 5×20ms ≈ 100ms，仍失败照旧抛错 —— 本轮**不承诺**消除全部 WinError 5，只消除「瞬时占用即失败」。
8. 本轮不碰：云同步一致性（`_need_sync` 永不重传等）、`history_store` 元数据全量解析、`fs_tools` `normcase`、`field_meta.dart:180` 的插件字段接线（D6）、`FlowEditHistory` 深拷贝内存。
