# P5 工作日志（云同步/实时同步域：/api/cloud/* 18 端点）

分支 cpp-backend（已检出，禁 git 写操作）。构建目录 native/build-P5（`-DSA_GROUP_WIP=P5`）。
端口只用 8790-8799。数据根只用 /tmp fresh temp + EDITOR_*_ROOT。

## 里程碑

### M0 接手盘点（进行中）
- [x] CONVENTIONS.md 全文已读（§9 服务模板、§10 坑点、§11 EditorState、§6 锁序、§7 perf、§8 契约）。
- [x] wip/P4 交付形态已读：STATUS.md 格式、main.cpp（server_main + extra_routes）、build_p4.cmd、
  smoke.py（temp 根起 backend_wip + golden 比对）、p4_mock.h（httplib::Server 本地 mock）。
- [x] 基建已读：sa_core/http_client.h（WinHTTP request/request_stream/parse_url/quote_component）、
  server/httpd.h（Router/Req/Resp/ApiError/dispatch_in_proc）、state.h（editor_root/truthy/STATE）、
  run.cpp（server_main）、shutdown 路径（system_routes.cpp:120-126 request_shutdown →
  httpd.cpp:555-559 响应写完后 std::_Exit(0)，后台线程天然不阻碍退出）。
- [x] tests/CMakeLists SA_GROUP_WIP：wip/P5/*.cpp（除 main/test_*）进 sa_tests + backend_wip。
- [x] Python 真相源全部通读：api.py 2714-3002（18 路由逐错误链）、cloud_sync.py(2346)、
  realtime_sync.py(718)、test_cloud_sync.py(87)、test_realtime_sync.py(143)。
- [x] golden 四件核对：api_cloud_providers（providers [] + drivers 11 键注册序）、
  api_cloud_status（8 键）、api_cloud_realtime_config（11 键默认）、
  api_cloud_realtime_status（16 键含 config/cloud_sync；last_sync/next_remote_poll VOLATILE）。
- [x] 关键语义确认：cloud config = workspace/.editor_cloud.json 优先、rt config =
  workspace/.editor_realtime.json 优先（都回退 <data>/_cache/*.json）；_sync_state_path
  定义未使用（无持久化）；rt_auto_start 在 api.py:3149 build_router 期调用（我在
  register_cloud_routes 尾部对齐调用）；shutdown 路径 = httpd 写响应后 std::_Exit(0)
  （watcher 为 detached 线程，等同 Python daemon，天然不阻碍退出）。
- [x] build_p5.cmd 就位（P4 模板替换）。api_router.cpp 无 cloud 路由（无冲突）；
  /api/plugins* 由 P3b 正树注册 → 本 build 基线缺的恰是 4 个 cloud GET。

### 路由归属/降级决策
- 本 build 注册全部 18 条（GET/POST/PUT/DELETE /api/cloud/... + realtime 7 条）。
- LocalDriver/WebDAVDriver/OpenListDriver(alist 别名) 全量移植（webdav/openlist 用
  本地 mock HTTP server 测）。
- baidu/123/google_drive/onedrive：root→Local、openlist_url→OpenList 代理两条腿
  完整移植（可 mock）；直连外联腿（OAuth/网盘 REST 硬编码域名）返回确定性
  ValueError/TypeError 信封（简报允许的最小可交付子集降级）；onedrive 的
  get（"OneDrive 直连下载需配置 openlist_url…"/NotImplementedError）与 stat/delete/
  mkdir 直连分支本就是纯逻辑，按 Python 原文移植。

### M1 引擎实现（进行中）
- p5_util.{h,cpp}：iso_now_local/epoch_now/py_truthy/py_list_repr/py_type_name/str_or_throw。
- cloud_sync.{h,cpp}：PyError(type+str)、norm_remote、parse_http_date(RFC1123+ISO)、
  parse_iso_time、7 个 Driver 类、DRIVERS 注册表(11 键含别名)、REMOVED_DRIVERS、
  get_driver、providers CRUD(文件锁 g_cfg_mu)、sync 引擎（sync_single_file/
  sync_mod_files/sync_mod_folder/_list_remote_recursive/_safe_rel_join/need_sync/
  local_files/_drv_get→cfg_store::forget）、_sync_state(8 键+history 20 上限)。
- realtime.{h,cpp}：config(load/update 钳位链)、state 16 键、events 环 120（视图 50）、
  watcher std::thread + condition_variable 可中断睡眠、rt_start 的 drain-race
  （5s 等待 + RuntimeError）、rt_stop 2s、auto_start 3s 延迟线程、ambig sha1 基线、
  _execute_sync/_poll_remote_and_sync。Python 在 watching-mods-changed 路径持锁
  再入 rt_log 会自死锁（Lock 非可重入）→ C++ 改为锁外 log（状态转换不变），已注释。
- cloud_routes.cpp：18 路由 + 各 except 链的 400/404/500 映射逐条对齐；main.cpp。
- 下一步：首轮编译 → 修错 → 测试（mock server）→ 验收 2/3。

---

# 接管报告（波次 3 P5 接管代理，2026-09-09）

## 1. 接管时状态
- 前任源码齐备（cloud_sync/realtime/cloud_routes/p5_util/main/p5_mock/build_p5.cmd），
  **无任何 test_p5_*.cpp**；[p5] 测试与验收为剩余工作。
- `build_4.log`（23:28）证实 23:25 的 7 个 sa::cloud 未解析外部符号（cloud_sync.cpp 改动后）
  **确已链过**：backend_wip.exe 与 sa_tests.exe 均链接成功——但那是 **Debug 缓存**
  （链接行 /debug /INCREMENTAL）。
- 前任的语义决策（路由归属 18 条全注册、driver 直连腿降级信封、golden 四键、
  rt_auto_start 在 register_cloud_routes 尾部、锁外 log 防自死锁）全部有效并已遵守。

## 2. 接管期修改（全部在 native/wip/P5/** 内）
1. **build_p5.cmd（B17）**：config 分支 `if ( ... set "BUILD_TYPE_P5=Release" ...
   -DCMAKE_BUILD_TYPE=%BUILD_TYPE_P5% ... )` 的 %VAR% 在块解析期展开成空串 →
   首配实际传空值、被顶层 CMakeLists 的 Debug FORCE 接盘（P8/P7 同坑；编排者随后把
   根兜底也改成了 Release，但脚本仍自修）：改用 `!BUILD_TYPE_P5!` 延迟展开，并注释成因。
   注：.cmd 里加中文注释会让 cmd 按 ANSI 码页解析炸掉批处理——脚本内注释保持 ASCII。
2. **realtime.cpp — default_config 链接缺口**：前任在头文件声明了公共
   `default_config()`，但定义落在匿名 ns（internal linkage）→ 测试引用即 LNK2019。
   内部 builder 改名 `make_default_config()`，导出块补公共包装。
3. **realtime.cpp — ambig 行为 bug（修）**：`ambig_content_changed` 先
   `g_ambig_sha[key] = sha` 覆盖、再用 `it->second != sha` 判定——`it` 指向同一
   map 槽，比较的是刚写入的新值 → **恒 false**，「同秒等长内容改动检出」这条
   test_realtime_sync.py 的核心防线实际失效。改为先存 prev 再覆盖再比较。
4. **cloud_sync.cpp — http_request 头去重（修）**：OpenListDriver.put 先经
   `json_headers()` 带 `Content-Type: application/json` 再压 `application/octet-stream`
   ——Python 侧是 dict（同键后写覆盖、线上一行），C++ vector 累积出重复头，
   WinHttpSendRequest 直接 **error 183** 全案失败。http_request 增加大小写不敏感的
   dict 语义合并（首出现位置 + 末次值）。函数为本文件私有，不影响其它组。
5. **p5_mock.h — 重写为 Winsock 迷你 server**：实测 vendored cpp-httplib 0.18.3 的
   Server 在 parse_request_line 就有方法白名单（不含 PROPFIND/MKCOL → 裸 400，
   routing 根本不执行），且 set_pre_routing_handler 在**读取请求体之前**应答——
   未消费的 body 字节污染 keep-alive 流，后续请求全部错乱。WebDAV 动词必需，
   故 mock 改为 ~250 行 Winsock 实现：任意动词、Content-Length 体、
   (method,prefix) 首匹配路由、调用记录。API 与旧版兼容（on/serve/start/stop/
   port/base/calls）。
6. 新增 **test_p5_cloud.cpp**（18 用例）/ **test_p5_realtime.cpp**（10 用例）/
   **golden_gate.py**。临时探针 test_p5_probe.cpp 已删除。

## 3. 验收（可复跑命令 + 逐字输出）

### 3.1 全新 Release 构建
```
cd native && rm -rf build-P5
cd native/wip/P5 && cmd //c build_p5.cmd config     # -> CONFIG_EXIT=0
cmd //c build_p5.cmd                                 # -> BUILD_EXIT=0（build_release_1.log）
```
- `build-P5/CMakeCache.txt`：`CMAKE_BUILD_TYPE:STRING=Release`
- 尾部：`[82/85] Linking CXX executable bin\sa_tests.exe`、
  `[84/85] Linking CXX executable bin\backend_wip.exe`；无 FAILED。
  bin/：backend_wip.exe 2,601,984B、sa_tests.exe 4,425,216B（Release 体量，无 .ilk 依赖）。

### 3.2 [p5] 测试
```
# build-P5/bin 下（PowerShell Start-Process + WaitForExit(300s) 守护，只杀自录 PID）
sa_tests.exe "[p5]"
```
逐字（p5_run4.out 尾）：
```
All tests passed (456 assertions in 28 test cases)
```
覆盖：norm_remote/parse_http_date/parse_iso_time/p5_util/safe_rel_join（含
test_cloud_sync.py 穿越用例逐条移植）/need_sync 决策表/remote_path_for（含
Python 尾斜杠 quirk）/DRIVERS 11 键序+get_driver 四类信封/网盘驱动双腿+降级腿/
LocalDriver 全链/**WebDAV 对 mock 全链**（test 207/401、list Depth1 过滤、
stat Depth0、get/put(MKCOL 分段)/delete(204|404)/Basic 头）/**OpenList 对 mock 全链**
（/api/me、fs/list modified 四形态、fs/get stat 解析三态=test_cloud_sync.py 意图、
raw_url 相对拼接、put File-Path、remove/mkdir payload、403-1010/403/code!=200/
invalid-json、renewapi 误填拦截、token 透传）/providers CRUD（工作区文件优先+
_cache 回退、*** 防脱敏回写、merge 语义、去重、错误链）/sync_single_file 六方向
矩阵+dry-run+sync 双向 mtime/sha1 判定/sync_mod_files 批量+校验/
sync_mod_folder 上传/增量/extra 删除/空目录消息/history/sync_status 8 键/
18 路由错误映射（mask、400/404/500 分家、/api/cloud/file FileNotFoundError→404 等）。

### 3.3 全量（零回归）
```
sa_tests.exe "~[slow]"
```
逐字（full_run.out 尾）：
```
All tests passed (2466 assertions in 221 test cases)
```
（221 = 官方树 193 + 本组 28；[perf][slow] 2 例按门禁约定排除。）

### 3.4 golden 38/38（本波核心准出）
```
python native/wip/P5/golden_gate.py        # GATE_EXIT=0
```
该脚本复刻 tools/golden_env.make_env()：fresh temp `data`+`workspace`、
`data/editor_env.json`（workspace_root、oobe_completed:true、steam_library_paths:[]、
user_mods_dir=<temp>/user_mods 哨兵）、EDITOR_DATA_ROOT/PLUGINS_ROOT/PACKS_ROOT 指 temp、
EDITOR_DISABLE_STEAM_DETECT=1、清除 EDITOR_OOBE/EDITOR_NO_OOBE（进程内补丁在独立进程下
用 env+CLI 等价实现），端口自 8790-8799 择空、只 kill 自启 PID、结束 POST /api/shutdown、
temp 全删。绝不触碰 backend/ 真实目录与用户 Mods。随后打
`python tools/record_golden.py --check --url http://127.0.0.1:<port>`（只读，不重录）。
逐字（golden_gate_out.txt 尾）：
```
PASS /api/tools/list?scope=workspace&path=
PASS /api/tts/settings
RESULT: PASS (38/38 端点全部一致)
```
四个云 GET 均 PASS：`/api/cloud/providers`、`/api/cloud/status`、
`/api/cloud/realtime/config`、`/api/cloud/realtime/status`。
过程记录：首轮 37/38，唯一 FAIL 是 `/api/state schema_count: 406 != 0`——backend 以
cwd=temp 启动导致 schema.json 搜索路径落空（系统域环境项，非云域回归），
golden_gate.py 设 `EDITOR_ASSETS_ROOT=native/assets` 后复跑 38/38。
`tasklist backend_wip.exe`：无残留进程。

## 4. 遗留风险 / 需主代理注意
- 修了 2 个**行为级** bug（ambig 覆盖后比较、http_request 重复头→WinHTTP 183）。
  合并 cloud_sync.cpp / realtime.cpp 时务必带上（golden/单测均已复验）。
- p5_mock.h 走 Winsock；sa_tests 已链 ws2_32，合并进 tests/ 无需改 CMake。
  若未来别组要 WebDAV 类动词的 mock，直接用本版（httplib Server 版不可用，见 §2.5）。
- `wait_thread_done(ms)` 是测试辅助导出的收口钩子；rt 用例夹具析构统一 rt_stop+join，
  auto_start 用例固定在 test_p5_realtime.cpp 文件末位（其 3s 延迟线程的失败事件
  不得干扰其它断言）——拆分/搬运文件时保持该顺序约束。
- golden_gate.py 可作后续组「make_env 等价复刻」模板（P4 smoke.py 是 4 端点子集版）。
- 无被 glob 漏目录等共享文件阻塞项；本组零 git 写操作，未触碰用户 WIP/staged 文件。
