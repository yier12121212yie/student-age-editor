# P3a 工作日志（剧情/预览/搜索/舞台）

接手自休眠中断的前任代理。分支 cpp-backend，只在 native/wip/P3a/ 写。

## 接手盘点（已完成）
- 可复用半成品：
  - `content_util.h/.cpp`：UTF-8 码点工具、py_truthy、story_str/repr、clean_floats、
    clean_id、value_error_int 等已实现；**dicts_json()/role_dict() 只有声明、无实现**（待补）。
  - `story_service.h`、`stage_service.h`：接口已定（parse_script/export_story；
    get_stage_dicts/describe_roles/encode_commands/get_talk_stage/encode_talk_stage）。
  - 缺：story_service.cpp、stage_service.cpp、preview_service.{h,cpp}、
    content_routes.{h,cpp}、main.cpp、test_p3a_content.cpp、smoke.py。
- 基线构建：`native/build-P3a`（SA_GROUP_WIP=P3a, Release）成功；sa_tests 76 例 506 断言全绿。

## 关键契约勘察结论
- 路由以 api.py 为准（简报里 "GET /api/preview/event" 实为 **POST**）：
  POST /api/story/export、POST /api/story/import、POST /api/preview/event、
  GET /api/search/talk、GET /api/ai/stage/dicts、GET /api/ai/stage/roles、
  POST /api/ai/stage/encode。
- 预览失效链：cfg_routes.cpp 写路径/undo 已调 `sa::invalidate_preview_cache()`
  （api_router.h 接缝 `sa::set_preview_invalidator_hook`）；state.cpp select_mod
  经 `set_preview_invalidator` 同链。register_content_routes() 注册 hook。
  Python 的 `_save_mod_cfg`（story import 落盘）**不**失效预览缓存（api.py:594-603
  只三联动）——移植保持一致；preview 三缓存的 _mod_fp_cache/_meta_fp 带指纹自愈，
  hook 的真实意义在无指纹的 _table_cache（base 侧），P4 落地后凸显。
- story import 的 write/append 用裸 bool()（py_truthy），不是 _truthy。
- stage 链路 role_dict 不合并 mod PersonCfg（golden api_ai_stage_dicts 佐证）；
  story export/import 合并（api.py:2461-2464/2489-2492）。
- stage _load_talk 用 ai_domain_service 语义：错误消息「未选择模组」是中文
  （golden api_ai_stage_roles_talk_id_0），与 api._cfg_path 的 "no mod selected" 不同！
- /api/search/talk：STATE.base 在 _init_state 后恒为未加载的 BaseDataService
  （data={}），golden 空降级 = 本体表按空表参与；C++ 经 sa::base_store()
  （available()==false → 空表），mod 表走 load_mod_cfgs()。
- dicts.json：native/assets/dicts.json 的 game_dicts.roles 与 golden roles 逐键序全等
  （已验证）；加载顺序照抄 P1 semantic_assets（EDITOR_ASSETS_ROOT 等）。
- 解析器坑（story_service.h 注释）：Python re \d/\s 为 Unicode 语义、效果行含
  (?<!屏幕) 变长后顾 → 全部手写码点匹配器。

## 里程碑
- [x] M0 接手盘点 + 基线构建绿
- [x] M1 content_util 补 dicts_json/role_dict/int_digits_str/findall_digits + preview_service 移植
- [x] M2 story_service 移植（码点匹配器 + CPython set 槽位序仿真）
- [x] M3 stage_service 移植
- [x] M4 content_routes（7 路由）+ main.cpp
- [x] M5 [p3a] Catch2 全绿（7 例 168 断言；全量 83 例 674 断言含波次 1 基线）
      invalidate 接线：进程内断言 table_cache_size/meta 清 0 + HTTP 黑盒
      （PUT /api/cfg/EvtCfg 改标题 → preview event_title 即时更新；undo 同样生效）
- [x] M6 smoke.py golden 3 PASS（search_talk_q_limit_5 / ai_stage_dicts / ai_stage_roles_talk_id_0）
- [x] M7 selftest 白名单：12 例 = 8 ok / 2 skipped（aa_index 守卫按设计跳过）/
      2 FAIL（归因：test_stage_encode_and_write_roundtrip 中段用 P3b 的
      PUT /api/ai/domain/item——本组 wip 构建不含该路由，404；前后 stage 断言全过。
      test_preview_bg_meta_merges_mod_and_base 需要本体 BgCfg 202361 参与
      load_table_merged——base_store 为 P4 域，未注册时本体侧恒空，语义正确）
- [x] M8 交付报告（见会话输出；差分对 Python oracle：story export/import、
      stage encode/describe、search rows 全部逐字段一致）

## 关键坑记录（再接手/集成时注意）
- `out[story_str(item["id"])] = std::move(item)` 在 MSVC /O2 下会从已 move 的
  对象算键（实测得 "None"）——先取键再 move（story_service.cpp run() 已注释）。
- preview_event 的 talk_count 同样必须 move 前取（已修）。
- stage 域错误消息中文「未选择模组」(ai_domain_service) 与 api 域英文
  "no mod selected" 并存，两条链路各自逐字。
- story 域 truthiness 用裸 bool()（py_truthy），非 _truthy。
