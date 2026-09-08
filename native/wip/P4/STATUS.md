# P4 工作日志（联网：TTS/生图/更新检查 + 资源产物消费）

接手自休眠中断的前序代理。分支 cpp-backend，禁 git 写操作。构建目录 native/build-P4（`-DSA_GROUP_WIP=P4`）。

## 里程碑

### M0 接手盘点（完成）
- 初始编译：`cmake -G Ninja -S native -B native/build-P4 -DSA_GROUP_WIP=P4 -DCMAKE_BUILD_TYPE=Release && ninja` → **exit 0**（基线绿，仅编译了 p4_util.cpp 进 sa_tests）。
- 已有产物：
  - `native/core/http_client.{h,cpp}` + `core/include/sa_core/http_client.h`（official 例外，**已完成**：WinHTTP 同步+流式 request、parse_url、quote_component、hex/base64(含 py b64decode validate=False 语义)、非 Win stub）。sa_core/CMakeLists 已收集 http_client.cpp 且链 winhttp。
  - `wip/P4/p4_util.{h,cpp}`（已完成：split_ext/basename/dirname/lower/strip/utf8_len/fs_resolve/random_hex/json_int/raise_int_error）。
  - `wip/P4/env_store_ai.h`（仅头，**待实现 cpp**）。
- 关键接缝/参考已通读：CONVENTIONS 全文、ARTIFACT_FORMAT §1/§5/§8、stores_api.h/.cpp（base_store 接缝 + 默认空对象）、cfg_routes.cpp（TTS 写链参考）、cfg_store.h、httpd.h、run.cpp（server_main + extra_routes）、P1/main.cpp（backend_wip 模式）、env_store 现状（core 只做了 editor_env，AI 半边缺）。
- Python 真相源已通读：tts_service.py(全)、tts_store.py、ai_image_service.py、update_check.py、decoded_pack.py、base_service.py、flow_assets.py、env_store.py、api.py 相关路由体 + helpers。
- golden 四件形状核对：api_tts_settings（apiKey/baseUrl/model=null，image*/tts*=默认，normalize({}) 结果）、api_aa_status（idle/空/detected=""）、api_base_status（idle/空/env_exists=true）、api_base_events（409 + status_dict；注意 `{"error":"base data not ready",**status_dict}` 后 unpack 覆盖 → error:""）。
- 附带 golden（他人路由，本 build 不注册）：api_aa_keys、api_search_talk、api_base_ids（数据方经 register_base_store 接缝）。

### 路由归属决策
- 本 build 注册：`/api/tts/*`、`/api/ai/image/{generate,edit}`、`/api/update/check`（additive，Python 无 HTTP 路由，仅 CLI/TUI）、`/api/aa/{keys,preview,status,export,scan}`、`/api/base/{status,load,events,extract}`（smoke 需 /api/base/status + /api/base/events）。
- 提供接缝（不注册路由，避免与 P1/P3a 合并冲突）：`register_base_store()` → 供 P1 `/api/base_ids`、P3a `/api/search/talk` 消费；base_store 内含 `search_talks/extract_event/search_events/table_ids` 数据方法。
- `/api/aa/scan`：C++ 永不扫 bundle → 返回引导性错误（对齐 UnityPy 不可用形态 500 {"error":"unityfs unavailable"}）。
- 解码：C++ 无 UnityFS 解析器 → 游戏索引命中但无预解码包时 preview/export 回 422 "decode failed"（对齐 §8.7）；预解码包（decoded pack）直读 tex/aud + mime。

### M1 sa_core http_client — 前序已完成，本组验证
- [x] http_client.{h,cpp} 编译进 sa_core（见初始 build 日志 [16] Linking sa_core.lib）。

### M2–M9 实现（全部完成，编译/测试/golden 全绿）
- M2 env_store_ai.cpp：normalize_ai_settings 逐坑（absent→null、0 合法不 or、别名键、域校验）。读端对齐 api_tts_settings golden。
- M3 flow_assets.{h,cpp}：is_cg_image / is_music / music_url_basenames 纯函数移植。
- M4 base_store.{h,cpp}：实现 BaseStoreApi（available/table_ids(A13 缓存)/table(shared_ptr 只读)/loaded_tables）+ 产物读取（base_data/*.json + base_meta）+ 查询（status_dict/search_events/search_talks/extract_event/infer_evt_id）。register_base_store 接线（register_p4_base_store）。
- M5 base_routes.{h,cpp}：/api/base/{status,load,events,extract}。events 409 体 = status_dict（error 后 unpack 覆盖为 ""）。
- M6 aa.{h,cpp}：AaIndex（v3 只读、norm_key、int64 path_id、tex_bundle 分组、tex_meta 稀疏、relocate_bundles）+ DecodedPack（tex/aud 扫描、decoded 索引 txt、PNG/JPEG/WebP 头部尺寸）+ active_pack_dir/env 覆盖。
- M7 aa_routes.cpp：/api/aa/{keys(含 scope=flow)/preview/status/export/scan}。scan=引导性 500（永不扫包）；游戏索引命中但无解码→422；解码包直读+mime。
- M8 tts.{h,cpp}：provider 协议（MiniMax hex→b64 兜底、DashScope SSE 分块各自 b64 解码后拼字节 + 非流式 url/data）、test_connection、detect_encoder/encode_ogg（ffmpeg|oggenc，未命中不缓存，无编码器→不转码）、tts_store（save/register/bind(B7 expect_mtime)/list/read/delete）、/api/tts/*。writeCfg 用 Python 真值（非 _truthy）、ogg 用 _truthy——已核对 api.py:1891 vs :1882。
- M9 ai_image.{h,cpp}：generate/edit + multipart + update_check（版本线数值比较/跨线判同发行）+ /api/ai/image/* 与 /api/update/check(additive)。

### §8 六条 → 测试名对账
1. int64 path_id + norm_key：`§8.1 AaIndex: int64 path_id preserved` + `norm_key: splitext...` + `§8.1 table_ids int64-ify row keys`
2. bundle basename 重定位后丢 cabs：`§8.2 bundle relocation by basename; cabs not relied upon`（C++ 不解码，cabs 不存储/不依赖，已在测试注释说明）
3. partial/missing_expected 处理：`§8.3 partial defaults false; decoded-pack form rejected` + `base load: ready, sorted loaded, missing_expected`
4. texmeta 稀疏→CG 回退：`§8.4 texmeta sparse -> missing key yields nullopt` + `is_cg_image...`（缺失尺寸→false）
5. 行 id 恒字符串 + EvtCfg.npc 单值/数组两态：`base load`(表键字符串) + `search_events: natural-id sort + npc single/array (§8.5)`
6. 失效比 sources[].files mtime/size：`§8.6 staleness: source mtime/size drift -> error`
（§8.7「解码 [bundle,path_id]+cabs BFS」：C++ 无 UnityFS 解析器 → 表现为 `/api/aa/preview of a game-index tex answers 422`）

### register_base_store 接线（P1/P3a 复验）
- base_routes.cpp 的 register_base_routes() 首行调用 register_p4_base_store()：`sa::register_base_store(base_store_instance())` 后 best-effort load()。
- P1 复验：注册后 `sa::base_store()->available()/table_ids(cfg)` 返回真产物 int64 键集；未注册→默认空对象 available()=false（对齐 STATE.base is None）。测试 `register seam: stores_api base_store() sees tables after register`。
- P3a 复验：`sa::base_store()->search_talks(q, mod_talk, mod_evt, limit)` 返回 [{src,evt_id,evt_title,talk_id,content}]。P3a 路由本体不注册于本 build（避免合并冲突），仅经接缝取数。
- 集成挂载建议：build_router() 内 register_base_routes→register_aa_routes→register_tts_routes→register_ai_image_routes→register_update_routes。

### 验证证据
- 编译：`ninja -C native/build-P4` exit 0（backend.exe / backend_wip.exe / sa_tests.exe）。
- 测试：`sa_tests "[p4]"` 42/42（276 断言）；全量 `sa_tests` 118/118（782 断言，无波次1回归）。real-artifact 例经 EDITOR_BASE_ARTIFACT_DIR 注入真产物（46 表 / ItemCfg 缺失）→ 全绿。
- golden：`py native/wip/P4/smoke.py` → RESULT: PASS (4/4)（steam off、无产物）。
- selftest（external，共享空 data 根 + steam off）：AaPreviewTest + ImageApiTest + base 两例 → Ran 13, OK (skipped=3)（3 skip 恰为依赖真 aa 缓存的 tex/aud/txt 与 cross-bundle，符合 Python skip 语义）。
- mock 证据：MiniMax hex/base64 双分支 + 「hex 恰合法 b64」陷阱、DashScope SSE 分块各自解码拼接（QUI=+Q0Q=→ABCD 验证 padding）、非流式 data/url、生图 b64_json/url 下载、update GitHub 列表。全部 httplib::Server 本地，零真网络。

### http_client（official）
- P2 已交付收编（协调通知）。本组 **零 diff**，仅消费 sa_core::http（request/request_stream/b64/hex/parse_url）。无增量。

