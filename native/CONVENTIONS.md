# native/ 工程接口约定（CONVENTIONS.md）

> 波次 0 产出，主代理维护。所有子代理任务简报必须引用本文件；与本文冲突以本文为准，
> 与 **Python 后端实际行为**冲突时以 Python 行为为准并回报差异（真相源：golden fixtures）。
> Python 语义出处均标注 `文件:行号`（backend/editor/ 下）。

## 0. 铁律（对所有任务生效）

1. 只创建/修改任务简报中列出的 owning 路径；**根 CMakeLists.txt、`server/api_router.cpp` 组装点、
   `core/include/` 公共头、本文档**只有主代理能改。
2. 子代理不执行任何 git 写操作。
3. 验收 = 简报中写死的命令输出；没有跑过的命令不许写进报告。
4. 不改 `backend/`（0b 的 selftest.py 除外）、`frontend/`、`.gitignore`。

## 1. 工程结构与构建

```
native/
  CMakeLists.txt            # C++20; sa_core(静态库) / backend(可执行) / sa_tests(Catch2)
  build.cmd                 # 一键：vcvars64 + cmake -G Ninja → build/ → 测试
  third_party/              # vendored 单头: httplib.h, json.hpp, catch_amalgamated.*（版本记录于其 README）
  core/include/, core/src/  # libcore：types、paths、atomic_io、json 工具、schema 加载
  server/main.cpp           # 入口：--port / --write-port
  server/api_router.cpp     # 路由总线组装：逐个调用各服务的 register_<name>_routes(Router&)【主代理专属】
  server/services/<name>.cpp/.h  # 一服务一文件，导出 register 函数【子代理各自 owning】
  server/httpd.{h,cpp}      # 传输层（第 2 节）
  server/cfg_store.{h,cpp}  # 写管线（第 5 节）
  server/perf.{h,cpp}       # 计数器（第 7 节）
  assets/                   # schema.json（406 表名，非空 *Cfg 303 张）/ dicts.json（0b 产出；
                            #   构建期嵌入二进制的接线在波次 2 落地，先经文件路径加载）
  tests/contract/           # normalize.py + golden/（黑盒契约，任意实现后端可打）
```

本机工具链（勿安装别的东西）：
- cmake `D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`
- ninja `D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe`
- `D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat`（MSVC 19.44 / SDK 10.0.26100）
- Git Bash 调 .bat：`cmd //c "..."`

**并行隔离**：每个子代理用独立构建目录 `native/build-<组名>/`（`cmake -B build-xxx`），
互不共享 build 树；只有主代理集成时回归默认 `native/build/`。

新增服务**不需要改 CMakeLists**（glob 收集 `services/*.cpp`）；注册函数在
`api_router.cpp` 的挂载由主代理完成——子代理在交付报告里给出需要挂载的函数签名清单。

## 2. HTTP 传输层契约（移植自 `server/httpd.py`）

| 项 | 规定 |
| --- | --- |
| 监听 | 仅 `127.0.0.1`；`--port 0` 自动选口，`--write-port <f>` 写实际端口 |
| 协议 | HTTP/1.1，keep-alive 空闲超时 **65s**（`httpd.py:94`） |
| 并发 | 线程模型，槽位信号量 **64**；抢不到槽位直接回裸 `503`（Content-Length: 0，Connection: close，**不是 JSON**）（`httpd.py:218-245`） |
| 路由 | `(method, regex)` 全匹配（`fullmatch`，非 search），注册序优先；未命中 404 |
| path 解码 | 先取 `?` 前段再 URL-decode（`unquote`），query 用 `parse_qs` 后**每 key 取最后一个值**（`httpd.py:132-134`） |
| body 解析 | `Content-Length` 非法 → 400 `{"error":"invalid Content-Length"}`；JSON 解析失败 → 传给 handler 的 body 为 `{"_raw": <utf-8 replace 解码文本>}`（`httpd.py:135-147`） |
| 来源校验 | Host（去端口，处理 IPv6 方括号 `[::1]:port` → `::1`）∈ {127.0.0.1, localhost, ::1}，否则 403 `{"error":"forbidden host"}`；有 Origin 时 hostname 同上集合，否则 403 `{"error":"forbidden origin"}`；**无 Origin 放行**（CLI/本机直连）（`httpd.py:76-115`） |
| OPTIONS | 同一套来源校验；通过则 204 + CORS 头 + Content-Length: 0（B12：不再无条件 `*`）（`httpd.py:192-211`） |
| 响应头 | `Content-Type: application/json; charset=utf-8`、`Content-Length`、`Cache-Control: no-store`、`Access-Control-Allow-Origin: http://127.0.0.1`、`Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`、`Access-Control-Allow-Headers: Content-Type`（`httpd.py:155-176`） |
| bytes 直发 | handler 返回**字节**时原样发送、跳过序列化（大表缓存命中路径的命脉）（`httpd.py:157-160`） |
| 异常边界 | handler 抛异常 → 500 `{"error":"<异常类型>: <消息>"}`；**响应已开始发送后不得再补**（B11），用 responded 标志控制（`httpd.py:117-129,70-72`） |
| 序列化失败 | payload 不可序列化 → 500 `{"error":"non-serializable response"}`（`httpd.py:162-165`） |
| shutdown | `POST /api/shutdown` → 200 `{"ok":true}` 后进程自退（Python 是 `os._exit(0)` 线程；C++ 用同样的"先回响应再退出"语义，**不得在响应前退出**）（`api.py:777-782`） |
| 方法 | 只有 GET/POST/PUT/DELETE/OPTIONS。**没有 PATCH**——补丁走 PUT body 判别（第 5.4 节），新增端点方法需先改传输层并同步简报 |

### 2.1 错误信封

所有错误响应统一 `{"error": "<消息>"}` + 该端点契约要求的附加字段（如 `cfg`、`reason`）。
状态码语义：400 入参/沙箱拒绝/坏 JSON；403 来源校验；404 `{"error":"no route: GET /x"}`；
409 冲突（见 5.x）；500 兜底。**不要发明新信封字段名**——以 golden fixtures 为准。

## 3. JSON 与文本语义

- **序列化唯一入口** = `sa_core::py_dumps`（`core/include/sa_core/json_wire.h`，0a 已交付并逐字节
  锁死）：`ordered_json` 保插入序 + CPython 分隔符（紧凑 `", "` / `": "`；落盘 `indent=2` 变体
  波次 1 补）。**禁止**直接调 nlohmann 默认 `dump()`（紧凑无空格）或默认 `json`（字母序 key）——
  两者都不符 Python 字节契约。`?keys=1` 的 `sorted(keys)`、history `entries` 等显式排序点照常复刻。
- **响应序列化** = Python `json.dumps(obj, ensure_ascii=False)` 的 UTF-8 字节；落盘文件 =
  `ensure_ascii=False, indent=2`。非 ASCII 一律原样 UTF-8，不转 `\uXXXX`。
- **浮点**：Python `repr(float)`（最短往返）与 nlohmann 的最短往返在常规值下一致；
  整数在 JSON 里必须保持整数形态（98963 不能写成 98963.0）。测试比对走 JSON 树等值（第 8 节）。
- **BOM**：读一律 `utf-8-sig`（有 BOM 剥掉，无 BOM 照常）；**写回保留源文件原 BOM**
  （cfg_store `_encode_with_bom`，`cfg_store.py:237-242`，B5）。
- **lossy 语义**（B2）：字节流按 utf-8 严格解码失败 → 用 `replace` 容错解码并标 `lossy=true`
  （响应里仅当 lossy 才出现该字段）；任何写路径检测到源 lossy 且无 `force` → 409
  `{"error":"non-utf8-source","cfg":...,"detail":"源文件不是合法 UTF-8，覆盖写入会毁掉非 ASCII 内容；确认放弃原文请带 force=true"}`
  （`api.py:1049-1053,1119-1123`，detail 中文原文逐字保留——前端按 error 码分支，但测试可能比对全文）。
- **布尔参数 `_truthy`**：`v is True or str(v).strip().lower()=="true"`——字符串 `"false"`/`"0"` 是
  **假**，数字 1 是**假**（`api.py:327-330`）。所有 query/body 布尔开关按此解析。
- **空文件/纯空白** JSON 视为 `{}`；解析失败视为坏表（`cfg_store.py:133-141`）。
- **表数据顶层必须是 object**；顶层是数组/标量时按 `{}` 处理（`api.py:572-573`）。

## 4. 沙箱与路径

- `_cfg_path(name)`：未选 mod → `SandboxError("no mod selected")`（HTTP 400 `{"error":..., "cfg":...}`）；
  实际 `<mod_root>/Cfgs/zh-cn/<name>.json`，`name` 先做 `_norm` 拒 `..` 逃逸（`api.py:319-324`）。
- `/api/tools/*` 的 scope：`mod` → mod 根、`workspace` → 工作区根；`..` 逃逸 400 且
  error 含 `"escapes"` 字样（selftest 断言此子串）。
- 路径键统一小写归一（Windows 盘符大小写不敏感，`os.path.normcase`，`cfg_store.py:71-73`）。
  C++ 侧实现 `PathKey()`：`abs` + Windows 上 `lower`。

## 5. cfg 读写管线规格（波次 1 核心；行号引用 `api.py` / `cfg_store.py`）

### 5.1 大表解析缓存 `_TABLE_CACHE`（`api.py:466-591`）

- `map<PathKey, {mtime_ns, size, parsed_data, body_bytes, lossy}>`，上限 **3** 项、
  仅当响应 body ≥ **256KB** 才入缓存（`_TABLE_CACHE_MIN_BODY`），满则按插入序淘汰最旧（FIFO，非 LRU）。
- 命中条件：`(mtime_ns, size)` 双元组全等（`api.py:541`）。
- miss 流程：读盘（bump `cfg.read_bytes`）→ 严格解码失败则 replace+lossy → 解析
  （bump `cfg.parses`）→ 构造响应 payload 序列化（bump `cfg.dumps`）。
- **写后播种** `_seed_table_cache`（`api.py:488-506`）：写入成功后用已知 data 造 body_bytes 入缓存，
  指纹取写后 stat。下一次热 GET：命中缓存 → `cfg.parses==0 && cfg.dumps==0 && 读盘==0`，
  且 bytes 直发（**不 bump dumps**——计数只统计真实序列化，准出断言 `api.py:1004-1009`）。

### 5.2 Mod 全表缓存 `_MOD_CFGS_CACHE`（`api.py:333-456`）

- 逐表指纹 `{fname: (mtime_ns,size)}`；每请求只 stat 全目录，指纹全等则零解析复用。
- 对外返回**只读视图**（G3/B1：C++ 侧用 const 引用/返回拷贝，任何就地修改都是 bug）；
  写方落笔前必须 `_fork_mod_table()` 从磁盘重解析私有副本（`api.py:433-456`）。
- 坏表记入 `_MOD_CFGS_BROKEN` 并如实上报（B16，绝不伪装空表）；重写成功即销账。
- `CustomKeyMap.json` 排除在全表缓存外（`api.py:383`）。

### 5.3 GET `/api/cfg/<name>` 投影（`api.py:957-1019`）

| query | 响应 |
| --- | --- |
| 无 | `{cfg, data, exists:true, mtime_ns}`（bytes 直发缓存项） |
| `keys=1` | 额外 `"keys": sorted(data.keys())`（**显式排序**） |
| `meta=1` | `{cfg, exists:true, mtime_ns, count}`（无 data） |
| `prefix=a,b,c&suffix=N` | data 过滤为键满足 `str(key)[:-N]`（长度≤N 时取全串）∈ prefixes；N clamp [1,8] 默认 3；与前端 PrefixMatcher 同式（`api.py:508-519`） |
| 文件缺失 | 200 `{"cfg":..., "data":{}, "exists":false, "mtime_ns":null}`（**不是 404**） |
| 解析失败 | 400 `{"error":"JSON parse failed: 文件内容不是合法 JSON","cfg":...}` |
| lossy 表 | 上述响应附加 `"lossy": true` |

### 5.4 PUT `/api/cfg/<name>`（`api.py:1039-1159`）

- body 含 `patch` 字段 → 补丁分支（不新增路由！）：`patch:{set:{},remove:[]}`，可选
  `if_match:{key:期望值}` 行级深比对、`expect_mtime_ns`、`force`。
- 行级冲突 → 409 `{"error":"conflict","cfg":...,"reason":"rows","conflicting_keys":[...],"mtime_ns":...}`
  （**不回全表**）；表级冲突 → 409 `{"error":"conflict","cfg":...,"mtime_ns":...,"data":磁盘当前内容}`。
- 成功 200 `{"ok":true,"cfg":..., "applied_set":n,"applied_remove":n,"mtime_ns":...,"snapshot":...|null}`。
- 全量写：`data` 非 dict → 400 `{"error":"data must be a dict"}`；成功 200
  `{"ok":true,"cfg":...,"mtime_ns":...,"snapshot":...}`。
- 写成功后四连：`_invalidate_table_cache` → `_seed_table_cache` → `_note_mod_cfgs_write` →
  预览缓存失效（`api.py:1083-1091`）。

### 5.5 写管线 `_commit`（`cfg_store.py:245-301`，一次读盘 A7）

顺序固定：**冲突检测 → 序列化+BOM → 内容未变短路 → 历史快照 → 原子写 → undo 登记 → 修剪**。

1. 冲突检测优先 `sha1(raw)` 摘要比对（B6：Windows mtime 粒度 ~15.6ms 会同刻度漏检），
   无 digest 才退回 `expect_mtime_ns`；`force=true` 跳过。
2. 新字节 == 磁盘字节 → `{"ok":true, "unchanged":true}`，**不快照不写盘不动栈**（`cfg.writes` 不 bump）。
3. 快照：覆盖已有文件前把**原始字节**（含 BOM）写
  `<mod根>/.editor_history/<stem>_<ms>_<seq>.json`，同毫秒 seq++；每表滚动留 **10** 份（A9）。
4. 原子写（`atomic_io.py:45-82`）：父目录创建 → 同目录唯一临时文件
   `名.tmp_<pid>_<tid>_<hex12>` → 写+fsync → rename 替换，Windows `ERROR_ACCESS_DENIED`/
   `ERROR_SHARING_VIOLATION`（对应 PermissionError/FileExistsError）**退避重试 5 次 × 20ms**；
   末次失败清临时文件报 500。
5. undo 条目 `{snap|None, text|None, existed, had_bom, lossy}`：有快照**绝不存整表文本**（A8）；
   栈 `HISTORY_LIMIT=50`；新写入清空 redo。
6. undo/redo（`cfg_store.py:444-517`）：peek → 恢复成功 → 才动栈（B3）；快照缺失且 lossy →
   拒绝恢复（防 U+FFFD 写盘）；快照缺失有文本 → 补 BOM 文本恢复；恢复用**原始字节**路径避免
   BOM 漂移（B4 强制 LF）。`POST /api/history/undo|redo {cfg}`：失败（含 "nothing to undo"）
   回 **400** + 原 result 体，成功 200 + `{ok, mtime_ns, data}`。`GET /api/history?cfg=X` →
   `{cfg, entries:[{file,ts,size}]}` 新→旧。
7. 云同步类整体覆盖文件后必须 `forget(path)` 清该表内存栈（`cfg_store.py:424-431`）。

## 6. 锁与并发规范

Python 用「全局 GIL + 少量 RLock」，C++ 真并发，**锁序必须显式**（死锁红线）：

```
L1 cfg_store 栈注册表锁（_STACK_LOCK）
L2 cfg_store 按路径锁（_PATH_LOCKS[k]）      —— 获取顺序：先 L2 后嵌套 L1（见 _commit 调用方）
L3 _TABLE_CACHE 锁
L4 _MOD_CFGS 锁
```

规则：**同时持有多把时按 L2 → L1、独立获取 L3/L4 且不得在持 L3 时拿 L4（反之亦然）**；
缓存读=shared_mutex 共享锁，写=独占锁；handler 内禁止边持缓存锁边做磁盘 IO。
fork/只读视图语义见 5.2：C++ 侧缓存值用 `shared_ptr<const nlohmann::json>`，
写方需要改动时从磁盘 fork 新对象——**永远 not mutate cached**。

## 7. perf 计数器与准出（`server/perf.py`、`test_s1_read_exit.py`、`test_s2_write_path.py`）

- 计数键（名称逐字一致）：`cfg.reads` `cfg.read_bytes` `cfg.parses` `cfg.dumps`
  `cfg.writes` `cfg.write_bytes` `cfg.snapshot_bytes` `cfg.snapshots_written`。
- **bump 位置纪律**：只在「每请求一次」处计数，**绝不在行循环内**；`cfg.dumps` 只统计真实序列化
  （bytes 直发不计）；内容未变短路不 bump writes。
- C++ 新增只读端点 `GET /api/perf` → `{"counters": {...全量字典}}`（**additive**，Python 无此端点，
  仅供黑盒契约与调试；不进 golden，不参与等值比对）。
- 波次 1 准出（对 40MB benchdata 表，语义抄自 S1/S2 测试）：
  热 GET `Δparses==0 && Δdumps==0 && Δread_bytes==0`；单字段补丁保存响应 body<2048B 且
  `Δwrites==1`；undo 栈内存指标（新增 `debug_stack_bytes()` 等价函数 + `/api/perf` 附带字段）。

## 8. 契约测试设施（0b 已落地为可跑 harness，非纸面规则）

- golden 库：`native/tests/contract/golden/<slug>.json`，每端点一份
  `{endpoint, method, status, response}`，存**归一化后**的响应体；命名按端点族前缀
  （`api_cfg*`/`api_mods*`/`api_ping*`…，见 golden/README.md）。当前 38 份。
- 比对器：`native/tests/contract/normalize.py`——JSON 树等值（key 序无关、数组有序、float
  容差 abs 1e-6+rel、bool≠数字）、`VOLATILE_KEYS`/`PATH_KEYS` 哨兵化，FAIL 输出最小差异路径。
  新增易变字段先在 normalize 常量表登记再比对，不得放宽成"整 key 忽略"。
- 一键门禁：`python tools/record_golden.py --check`（独立进程起 Python 后端逐端点比对 golden，
  当前 `RESULT: PASS (38/38)`）；打任意实现后端未来用同思路的 URL 模式。
- 录制隔离方式见 golden/README.md（temp data/workspace + `EDITOR_DATA_ROOT` 等 + 进程内补丁
  steam_paths），**绝不写用户真实 Mods**。
- `mtime_ns`、时间戳类字段在**功能断言**里用「与写前比较」而非绝对值。
- 响应头逐条比对第 2 节表格（bytes 直发路径额外比对 body 字节全等）。
- 现状基线：`backend/editor/server/selftest.py` 已支持外部模式
  （`STUDENT_AGE_BACKEND_URL=http://127.0.0.1:<port> python -m unittest editor.server.selftest`），
  对 Python 后端 `Ran 83 tests / OK (skipped=1)`——同一命令打 C++ 后端即波次门禁。

## 9. 服务文件模板

```cpp
// server/services/mods.cpp —— 服务导出 register，不自行挂总线
#include "server/router.h"
namespace sa {
void register_mods_routes(Router& r) {
    r.get(R"(/api/mods)", [](const Req& req) -> Resp {
        json body = json::object();
        // ... 语义照第 5 节与各组简报坑点清单 ...
        return Resp{200, std::move(body)};          // dict → 序列化
        // return Resp{200, Resp::Bytes{cached_bytes}}; // 免序列化出口
    });
}
} // namespace sa
```

- `Req`：method/path/query(map<string,string> 取 last)/body(可空 json，含 `_raw` 语义)。
- `Resp`：status + json 或 bytes；handler 抛异常由 httpd 层转 500 信封（与 Python dispatch 一致）。
- 命名：文件/类型 PascalCase 函数、`snake_case` 方法内变量；中文注释仅写「为什么」（对齐现有
  Python 注释风格，坑点编号沿用 A/B/C/G/S 前缀）。

## 10. 坑点清单索引（按波次分组，交付时逐条销账）

- **波次 1（cfg 链路）**：A7 一次读盘；A8 快照化 undo 栈；A9 滚动 10 份；A10 逐表指纹；
  A15 mods 列表 2s TTL；B2 lossy 409；B3 peek-then-pop；B4 LF；B5 BOM 保留；B6 sha1 优先 mtime；
  B11 响应已发不补刀；B12 OPTIONS 同校验；B13 64 槽 503；B16 坏表如实；G3/B1 只读视图；
  S1 免序列化三零计数；S2 patch 判别在 body（无 PATCH 路由）。
- **波次 2**：B9（选项 id 后缀≥100 不自动分配）→ bugfix/validate 组；B8/B7/A11/A12/A16 →
  见 `still-stone-stickleback.md` 与 IMPLEMENTATION_STATUS.md 行为变更节，各组简报会带子集。
- **全局**：`_truthy` 只认真 true/"true"；错误 detail 中文逐字；`sorted()` 显式排序点；
  「假完成」教训——准出证据必须能复跑。

## 11. 环境注入与 EditorState（已核实，出处 `server/__init__.py:14-29`、`api.py:151-307`）

- `start_server(port, on_ready, data_root, packs_root, bundled_zip)`：`data_root`/`packs_root`
  经 `os.environ.setdefault` 注入 `EDITOR_DATA_ROOT` / `EDITOR_PACKS_ROOT` /
  `EDITOR_PLUGINS_ROOT`（Android 专用）；`bundled_zip` 首次启动按 md5(前 1MB) 指纹解压到
  `packs_root/bundled`（zip 条目含 `/`、`..`、`:` 的跳过）。C++ 侧 CLI 参数与
  环境变量同名保留（波次 1 起实现）。
- `_init_state()` 优先级：`workspace_root` 已设→保持；否则 `editor_env.json` 的
  `workspace_root`（须存在）；再否则 `_user_mods_dir()`（LocalLow 游戏 Mods 目录，**不存在则
  自动创建**）。未显式选 mod 时**自动选中 `list_mods()` 第一项**。
- `list_mods()`：多根（workspace + 编辑器根含 `Cfgs/zh-cn` 者 + 创意工坊订阅目录）逐根
  `sorted(listdir)`；子目录含 `Cfgs/zh-cn` 或 `manifest.json` 算 mod；单根不可读跳过不炸
  （`api.py:196-200`）。A15：结果 2s TTL 缓存，select/create/set_workspace 后主动失效。
- `_mod_info`：`cfg_files` = 目录内 `.json` 去后缀、**排除 `CustomKeyMap.json`**、sorted；
  manifest 读 `utf-8-sig`，解析失败静默当无 manifest。
- `select_mod(name, root)`：置 mod + 作废 aa_index（回 "idle"）+ 失效 mods/全表/预览缓存
  （**不清 `_TABLE_CACHE`**——切 mod 靠路径变化自然 miss，`api.py:248-264`）。
- `sandbox_root(scope)`：workspace→workspace_root∨编辑器根；mod→mod_root∨workspace∨编辑器根。
- 配置落盘文件名契约不变：`.editor_flow.json`、`.editor_history/`、`editor_env.json`、
  `.editor_ai.json`、`.editor_cloud.json`、`.editor_realtime.json`。
- 就绪输出行 `API server listening on 127.0.0.1:<port>`（`server/__init__.py:73`，
  run_dev 实际靠轮询 /api/ping 判就绪，但这行日志保持同款便于人肉排查）。
