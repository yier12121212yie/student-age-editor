# Implementation Status Report（第二轮：大表读写链路）

> 本文件是大表链路优化（still-stone-stickleback.md）的最终状态报告。
> 2026-09-03 的旧报告描述的「S1 部分完成」实为**死代码**（api.py 未导入
> perf，NameError 被 `except Exception: pass` 吞掉，缓存从未建立），已在
> 2026-09-05 的会话中修正并以计数器为准出证据重做归档。

## ✅ 全部完成（S0–S7）

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| S0 | perf.py 计数器 + benchdata.py 40MB 合成表 + 前端 7 个 debug 计数器 | ✅ |
| S1 | 表解析缓存 + 免序列化出口 + `?prefix=/meta/keys` 投影 + 写后播种缓存 | ✅（准出测试 `test_s1_read_exit.py`） |
| S2 | `core/atomic_io.py` + cfg_store 重写（A6-A9/B3-B6）+ `apply_patch` + ping 能力门 | ✅（准出测试 `test_s2_write_path.py`） |
| S3 | 前端去整表往返：删 Talk/Option 全表缓存、`?prefix=` 舞台拉取、`diffStage` patch 保存、409 三选 UI、`getBig` compute 分叉 | ✅（`test/cfg_patch_equivalence_test.dart`） |
| S4 | C1/C2/C3/C4/C5/C6/C7 帧路径 + C10 ValueNotifier | ✅ |
| S5 | D1/D2/D3/D4/D5 前端 bug | ✅ |
| S6 | G2 atomic_io 推广 9 文件 / B10 / B7、G3 MappingProxyType / B16、G4 B9 / B8 / A11 / A12 / A16 | ✅ |
| S7 | backend_integration 环境性 skip + 文档 | ✅ |

## 📊 指标终值（对照计划目标）

| 指标 | 基线 | 目标 | 终值 | 证据 |
| --- | --- | --- | --- | --- |
| 画布拖节点帧耗时 | 101.40 → 14.81 ms/帧 | <5ms（M4） | **3.85 ms/帧** | `story_flow_bench_test.dart` 头注释读数 |
| 拖拽帧宿主重建 | ≥1 次/帧 | 0（C10） | **0 / 30 帧** | bench B2 `workspaceBuilds == 0` 断言 |
| 拖拽帧卡片重建 | 4.0 张/帧 | 0（C2） | **0** | bench B2 `cards == 0` 断言 |
| 热 GET /api/cfg 大表 | 40MB 读盘+解析+编码 ≈3s | 零读盘零解析零编码（M1） | **缓存命中三项计数全 0** | `test_s1_read_exit.py` |
| 保存单字段编辑 | ~100MB 往返 | <2KB body（M2） | **set+remove==1 且 body<2048B** | `cfg_patch_equivalence_test.dart` |
| 启动解码大表行数 | 98,963 行全量 | 0（M3，`?meta=1`） | **0**（Talk/Option 只拉 meta） | workspace `_load()` |
| undo 栈内存 | ~2GB（50×40MB 文本） | ≈0（A8） | **0**（快照化条目） | `debug_stack_bytes()` 准出 |
| diffStage ≡ mergeStageBack | - | 逐 key 等价 | **200 轮随机用例通过** | `cfg_patch_equivalence_test.dart` |

## 🧪 测试水位（最终）

- 后端：`cd backend && python -m pytest editor -q` → **293 passed**（基线 248 + 本轮新增 45）
- 前端：`cd frontend && flutter test` → **392 passed / 7 skipped / 0 失败**
  （skip 均为 backend_integration_test 的「活后端未运行」环境性跳过，
  `setUpAll` 探测 8765 端口实现，后端在跑时照常执行）
- 画布：`flutter test test/story_flow_bench_test.dart` 全部确定性计数断言通过

## ⚠️ 行为变更（用户可见，逐条标注）

1. **B2/lossy**：GBK 等非 UTF-8 源文件在 GUI 保存时被 409 `non-utf8-source` 拒绝
   （覆盖会把 U+FFFD 占位符永久写盘）；带 `force` 可确认放弃原文。
2. **B9**：选项 id 后缀 ≥100 时不再自动分配（会跨进其他事件的 id 段），
   一键修复放弃该项交回 remaining 让用户手工分配。
3. **B16**：解析失败的配置表在 bugfix 扫描中如实报 ERROR（不再伪装成空表）。
4. **A9**：`.editor_history` 每表滚动只保留最近 10 份快照——磁盘层可撤销深度
   从 50 缩短到 10（内存 undo 栈仍为 50，且纯内存撤销不受影响）。
5. **S1-3**：`GET /api/cfg/<t>` 的 `keys` 字段改为显式 `?keys=1` 才返回。
6. **B12**（前批）：跨站 OPTIONS 预检不再无条件放行。

## 👀 GUI 目视验证清单（无法自动化，需人工跑 `python run_dev.py`）

- [ ] 小地图节点块跟手拖动（D1）
- [ ] 候选浮层在宿主 setState 时不消失（D2）
- [ ] 409 冲突对话框列出被外部改动的行，三动作可用（S3-4）
- [ ] 输入框逗号不吞光标、不跳到末尾（D5）
- [ ] 拖拽画布流畅度提升（14.81→3.85ms/帧）
- [ ] 切换事件无假死或异常重载（`?prefix=` 拉取路径）
- [ ] 保存一句对白后 Network 面板确认 PUT body 为小补丁

## 🔴 已知限制 / 后续建议

- `TransferableTypedData` 在当前 Flutter 3.47 已不可用，`getBig` 用
  `compute(Uint8List)` 传字节（一次 ~40MB 拷贝 ≈ 十几毫秒，远小于解析收益）。
- 表级 mtime 冲突的 409 响应体携带磁盘全表（大表场景 ~50MB）；补丁保存
  已不传 `expect_mtime_ns`，该路径只在显式传 expect 的调用方（事件删除、
  TTS 绑定）触发，窗口极小。
- 云同步一致性（`_need_sync` 永不重传等）仍在「本轮不做」清单，未动。

---

*报告更新：2026-09-05*
