# S1 读路径 + S2 写路径优化 - 实现总结（修订版）

> ⚠️ 本文件 2026-09-03 的旧版描述「S1 缓存已实现」是**假完成**：当时 api.py
> 并未导入 perf 模块，计数器查询被 `except Exception: pass` 吞成 None，
> `_TABLE_CACHE` 从未被写入。2026-09-05 修订：补上接线、补齐 parses/dumps/
> read_bytes 三个计数埋点，并新增真正的准出测试。以下为经测试验证的现状。

## 读路径（S1）

核心：`api.py` 的 `_TABLE_CACHE[path] = (mtime_ns, size, data, body, lossy)`
（LRU 3 项，仅缓存 body ≥ 256KB 的表）。

- **命中即免序列化**：`cfg_read` 命中缓存直接返回缓存的响应字节
  （`httpd` 支持 handler 返回 `(status, bytes)` 原始出口），零 `json.dumps`。
- **投影查询**：`?prefix=a,b,c[&suffix=2]`（与前端 PrefixMatcher 严格同式）、
  `?meta=1`（只回 mtime/count）、`?keys=1`（显式才回 keys，A3）。
- **写后播种**（本轮新增）：`_seed_table_cache` 在写成功后用已知内容直接建
  缓存项——写后首次 GET 也是零读盘零解析。
- **失效**：显式失效（写/undo/redo 后 pop 该表）+ 指纹校验（mtime+size，
  外部改动自然失配）。

准出（`test_s1_read_exit.py`）：
- 热 GET `cfg.parses/cfg.dumps/cfg.read_bytes` 增量全 0；
- 缓存命中字节与现场解析后序列化（legacy 逐字复刻）**字节级相等**；
- 失效用 `os.utime` 强制推进（不靠 sleep）；
- 一次写后只有被写表参与重解析，另一张表全程 0 解析。

## 写路径（S2）

- **`core/atomic_io.py`**：`write_bytes_atomic` / `write_text_atomic` ——
  唯一临时文件 + fsync + `os.replace` 对 WinError 5/32 瞬时占用重试
  （已推广到全部 9 个原子写站点，S6-G2）。
- **`cfg_store.py` 重写**：
  - 一次保存只读一遍文件（A7），BOM 原样保留（B5），LF 强制（B4）；
  - 内容未变 → 不快照、不写盘、不动 undo 栈；
  - 冲突检测优先 sha1 `expect_digest`（B6：Windows mtime 15.6ms 粒度补口）；
  - undo 栈条目快照化（A8：`debug_stack_bytes()==0`）；
  - `.editor_history` 每表滚动保留 `HISTORY_KEEP=10` 份（A9）；
  - 磁盘 IO 走按路径锁，全局锁只护内存栈（A6）；
  - undo/redo「peek → 恢复成功 → 才动栈」（B3），快照被修剪时安全失败。
- **`apply_patch`**：增量补丁写入，行级 `if_match` 深比对，行冲突回
  `{conflicting_keys}` 不回全表；`PUT /api/cfg/<t>` body 以 `patch` 字段
  判别（不新增路由），`/api/ping` 带 `cfg_patch: true` 能力门。
- **`read_lossy`**：非 UTF-8 源打 lossy 标，写回前拒绝（B2，409
  `non-utf8-source`，force 可越过）。

准出（`test_s2_write_path.py` / `test_cfg_store.py`）：
- 内容未变重存 `cfg.snapshot_bytes == 0` 且 `list_history` 为空；
- 变 12 次 → 恰保留 10 份且删的是最旧，不越界修剪其他表；
- 3 次带快照写入后 `debug_stack_bytes()==0`，`snapshot=False` 反向 > 0；
- undo 后文件字节与最初全等（含 BOM 表）；`test_save_preserves_bom_and_lf`；
- monkeypatch `_restore` 抛 PermissionError → undo 返回 ok=False 且栈不变。

## 前端契约（S3，联动）

- 启动：6 小表全量 + Talk/Option `?meta=1`；
- 切事件：`?prefix=` 两小批；保存：`diffStage` → `PUT {patch, if_match}`；
- 等价性：`test/cfg_patch_equivalence_test.dart` 200 轮随机用例证明
  patch 应用 == mergeStageBack；单字段编辑 body < 2048B；
- 409 行级冲突三选 UI：采用磁盘值 / 覆盖并重试 / 取消；
- 经典编辑器全表视图走 `getBig`（>2MB 在后台 isolate 解码）。

## 测试

`cd backend && python -m pytest editor -q` → 293 passed
`cd frontend && flutter test` → 392 passed / 7 skipped（环境性）

指标终值与行为变更清单见 `IMPLEMENTATION_STATUS.md`。
