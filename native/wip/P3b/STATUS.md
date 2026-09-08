# P3b 工作日志（接手代理）

任务：AI 领域 / 文件沙箱（tools）/ 附件解析 / 资源包 + plugins 只读桩 + manifest/status。
分支 cpp-backend；开发目录 native/wip/P3b/，构建目录 native/build-P3b/（-DSA_GROUP_WIP=P3b）。

## 盘点（接手时状态）

- 前一代理已留下：
  - `p3b_support.{h,cpp}` — base64（loose/strict 双语义）、UTF-8 码点截断、py_strip、
    ZipReader（miniz reader-only）、game_schema/role_dict/field_cn 资产加载、find_asset。
  - `p3b_miniz_config.h` + `miniz_reader_tu.cpp` — MINIZ_NO_DEFLATE_APIS + NO_ARCHIVE_WRITING 的
    reader-only TU（miniz.c 以 C++ TU 编译）；`_probe_miniz.obj` 编译探针（已删）。
  - `gen_domain_table.py` + `p3b_domain_table.h` — AI_DOMAINS 烘表（14 域 247 表）。
  - `p3b_fs_tools.h` — fs_tools 移植声明（.cpp 未写）。
- `third_party/miniz/`（miniz.h/miniz.c/LICENSE）**已 vendored**，third_party/README.md 已登记
  （miniz 3.0.2 release zip，MZ_VERSION 11.0.2，双 sha256 记录在案）。位置正确，直接沿用。
- 修复：`p3b_support.h` 里 `ZipReader() = default;` 与 .cpp 的 `ZipReader::ZipReader() = default;`
  重复定义（MSVC C2084）——头文件改纯声明。

## Domain 表 ↔ golden 对账（前断点，已完成）

- `python native/wip/P3b/gen_domain_table.py` 可复现（重跑 diff 为空）。
- 逐域比对 `golden/api_ai_domains.json`：14 个具名域的 id/name/desc/tables(key+val) **全一致**；
  golden 各域 tables 按 cfg 排序（C++ 表存源顺序，get_domains 输出时排序）。
- fallback 域 `table`（159 表）：golden == Python `{cfg: _TABLE_CN.get(cfg,_auto_cn(cfg)) for cfg in
  sorted(set(GAME_SCHEMA)-assigned)}` 重建；`native/assets/schema.json` 与 backend GAME_SCHEMA
  键、值逐表一致（406 表）→ C++ 运行时由 game_schema() 重建 fallback 与 golden 一致（smoke PASS）。
- `native/assets/dicts.json`：game_dicts.roles == data_dicts.ROLE_DICT（200 项）；9 张
  key_maps == DEFAULT_*_KEY_MAP 且 field_cn 合并结果逐键一致；roles[101]=罗晓纯、
  roles[102]=薛诗蕾（selftest 依赖）。

## 里程碑（全部完成）

- [x] M0 盘点 + domain 表对账
- [x] M1 build-P3b 配置 + 基线编译（ZipReader 修复）
- [x] M2 p3b_fs_tools.cpp — resolve/list(deep≤4,2000)/read(8MB 上限、utf-8 严格含 BOM、
  GBK-CP936 replace 回退)/write(原子写、b64 loose、binascii.Error→500 "Error: ")/stat
- [x] M3 p3b_ai_files.{h,cpp} — 手写 XML 骨架解析器（命名空间 Clark、五实体+数字实体、
  CDATA/注释/PI/DOCTYPE、unbound prefix→ParseError）+ docx（iterparse end 后序）+
  xlsx（workbook/rels/sharedStrings/sheet，r:id 属性解析）；txt/md BOM 剥离；png/jpg 魔数
- [x] M4 p3b_domain_service.{h,cpp} — get_domains/CRUD/_coerce_patch/_ensure_content_role/
  _match_role_id_by_name；save_cfg = .bak 滚动 + cfg_store::write_cfg(snapshot) + 写四连
  （invalidate_table_cache→seed→note_mod_cfgs_write→preview invalidate）
- [x] M5a p3b_resource_pack.{h,cpp} — packs_root/系统根/元数据/install(hostile-entry 校验→
  miniz extract→manifest 补全→has_content 探针)/active/uninstall/info/import_path
- [x] M5b p3b_ai_settings.{h,cpp} — env_store AI 半（normalize 逐分支对齐 golden 的
  apiKey/baseUrl/model=null 语义；0 合法值不被 or-default 吞）
- [x] M6 p3b_domain_tools_routes.{h,cpp} + main.cpp — register_domain_tools_routes(Router&)
  挂 tools/ai.domains/ai.domain.item(s)/ai.settings/ai.upload/resource_packs*/manifest.status/
  plugins 只读桩（flow_cards 附声明型 manifest 目录读取器）
- [x] M7 test_p3b_domain_tools.cpp — [p3b] 20 例 354 断言全绿；zip fixtures 由 Python
  zipfile 生成（DEFLATED+STORED 混合走 miniz inflate 路径）→ p3b_zip_fixtures.h
- [x] M8 smoke.py — **RESULT: PASS (12/12)**：简报 10 件 golden + URL 编码/点分逃逸 2 件黑盒
- [x] M9 run_selftest.py — **RESULT: PASS (26 tests OK)**：AiUpload 9 + AiDomain 15 +
  BackendApiTest 两逃逸例打 C++ backend_wip 全绿；test_basic_endpoints 逐路径打印，
  P3b/wave-1 段全 200，仅跨组 404（/api/schema /api/dicts=P1、/api/aa/status=未落地）
- [x] 全量回归：sa_tests 96 例 860 断言 OK；ctest 1/1 Passed (43.4s)

## 验收命令（复跑）

```
cmd //c "call D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat >nul 2>&1 && \
  D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe -G Ninja \
  -S native -B native/build-P3b -DSA_GROUP_WIP=P3b -DCMAKE_BUILD_TYPE=Release && \
  D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe -C native/build-P3b"
native/build-P3b/bin/sa_tests.exe [p3b]
python native/wip/P3b/smoke.py
python native/wip/P3b/run_selftest.py
```

fixtures 再生成（M7）：Python zipfile 造 docx/xlsx/pack（含 ../ 条目、/abs 条目负例）→
base64 → 写 `native/wip/P3b/p3b_zip_fixtures.h`（`inline const std::string kNAME = "..."`
邻接字面量拼接；勿写 `+`，勿把两段 begin()/end() 拼到一个容器外——见坑点）。
期望串以 `backend` 下 `editor.server.ai_files.parse_file` 为 oracle 校验（已对账一致）。

## 坑点与偏差记录（交付报告同步）

1. **names() 临时对象 UB（真 bug，测试逼出）**：`set(zf->names().begin(), zf->names().end())`
   两个独立临时 vector 配对迭代 → 越界读（Catch 里 bad_alloc/黑盒里 SEGV）。必须先物化 vector。
2. **XML 属性默认命名空间**：expat/ET 规范——无冒号的属性**不**继承 xmlns 默认值
   （`sheet.get("name")`/`c.get("r")` 都是裸名）。首版误把默认 ns 加到属性上 → xlsx rels
   全空 →「未提取到文本内容」。resolveQ(name, default_ns) 区分元素/属性。
3. **元素自身 xmlns 要先入作用域再解析自己的 tag/属性**（`<w:document xmlns:w=...>`）。
4. **env_store ttsProvider**：Python `provider not in ("", "minimax", "aliyun")` 对 None
   判 True → 重置 ""；照抄 tp!="" 会漏（golden ttsProvider="" vs 我们 null 首跑 FAIL 抓到）。
5. run_selftest 必须设 `os.environ["STUDENT_AGE_BACKEND_URL"]`（首版只设了子进程 env，
   unittest 静默回落到**进程内 Python 后端**跑了个假绿，且在真实 LocalLow 建删过
   `_ai_domain_test_mod`——已确认无残留）。
6. fs_tools.read 文本解码是 **utf-8 严格（BOM 保留为 U+FEFF）**，非 utf-8-sig；
   失败回退 gbk replace 用 Win32 CP936 近似（与 CPython gbk 表仅欧空号等极少量槽位差异）。
7. `_pack_id_from_name` 的 str.isalnum 用「ASCII alnum + 非 ASCII 字节保留」近似（CJK 名可用）。
8. list_packs 未注册目录的枚举 Python 走 set（哈希随机序），C++ 取 sorted（确定性超集）。
9. 第二次同名安装 Python 落 `<id>_1`（while 先改名再判存在），不是 `_2`——测试对齐 Python。
10. binascii.Error / ValueError / OSError / AttributeError 等 Python 异常名经
    ApiError(type, msg) 还原进 500 信封；detail 文本近似（golden 环境不触发）。
11. resource_pack：system_packs_root 依赖 sys.frozen → C++ ""（EDITOR_SYSTEM_PACK_ROOT 可注入，
    波次 3 安装包接线）；alt 拷贝源 backend/editor/data 不存在（近似锚定 <data>/../data，
    dev/golden 恒 no-op）。
12. plugins 桩：进程内插件引擎废弃；GET /api/plugins、/ui、/agent/tools = 空数组（golden 形），
    GET /api/plugins/<pid> = 404 "plugin not found"，flow_cards = 空 + 声明型
    `<plugins_root>/<pid>/manifest.json` 的 `ui.flow_cards`/顶层 `flow_cards` 读取器
    （10 键形状对齐 engine 聚合，plugin_id 注入）。完整规范波次 3。
13. test_basic_endpoints 整例含跨组端点（/api/schema、/api/dicts=P1 wip；/api/aa=status 未落地），
    波次 2 单组 build 不可能全绿；「落地后整例应绿」归合并构建验收。P3b 负责的 /api/tools/list
    及 wave-1 五端点均 200（run_selftest 逐路径打印为证）。
14. /api/ai/dicts、/api/tts/settings、/api/ai/stage/*、图片生成等 api.py 相邻族不在 P3b 简报
    范围（golden 10 件清单不含 api_ai_dicts），未注册——归各自组。
