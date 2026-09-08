# P1 工作日志（表语义与校验）— 接手自休眠中断的前代理

## 盘点结论（接手时状态，2026-09-08）

前代理已完成（`native/wip/P1/`，编译全绿）：

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| semantic_assets.{h,cpp} | schema/dicts 加载、pool 表、_semantic_db 内嵌 DB 访问器、effect_editor_db 派生 | 半成品（见 D1 偏差） |
| semantic_db_data.{h,cpp} + _semantic_db.json | data_dicts.py 模板 DB 内嵌快照 | 完成（已与 Python 逐字段核对：COST 3 / CONDITION 235 / EFFECT 372 / EFFECT_EDITOR 373 / SCREEN 15 / ACTION 16 / PLACEHOLDER_MAP 14 全 MATCH） |
| semantic_logic.h | 语义引擎声明 | 完成 |
| semantic_core.cpp | guide_rules + ref_rules(36 规则) + data_dicts 二次模板引擎 | 半成品（见 D2-D5） |
| semantic_bugfix.cpp | bugfix_service scan/apply + format/parse | 半成品（见 D6-D9） |
| semantic_routes.cpp | 9 条路由 | 半成品（见 D10-D14） |
| main.cpp | backend_wip 入口 | 完成 |

未动：test_*.cpp（0 个）、smoke.py、STATUS.md、selftest 跑绿。

对照真相源逐行核查（api.py / guide_rules.py / ref_rules.py / data_dicts.py /
bugfix_service.py / selftest.py / test_ref_rules.py / golden 6 份）发现偏差清单：

- D1 effect_editor_db 前置两行顺序反了（Python [移除,获取]，C++ [获取,移除]；golden api_effect_suggest_mode_effect_q_ 铁证）。
- D2 validate_record EvtCfg.rate 消息应打 float 值（str(fv)，"2"→"2.0"），且 type=2 时 npc=0 也触发 warn（Python not int(...)）。
- D3 validate_cross nextTalk/nextTalk2 检查顺序应为 nt+nt2（C++ 反了）。
- D4 describe_action_row npc_txt 应查 str(int(row[0])) 而非原始字符串。
- D5 validate_secondary_item 非匹配错误分支 translation 应 = str(item_arr)（Python 原样 repr）。
- D6 apply_fix FIX_OPTION_1/FIX_TALK_1 分支 talk_cfg 取的是拷贝，TalkCfg 的 option 重指丢失。
- D7 scan_bugs TalkCfg option/roles 缺键时应默认 []（C++ 传 null 会假报 SCHEMA_HEAL bug）。
- D8 _next_option_suffix tail stoi 溢出会抛（Python 任意精度→>99 放弃）。
- D9 parse_from_display Number/int 强转分支未复刻 Python int(v) 语义（float 截断、str "12.0" 应失败）。
- D10 bugfix/fix 未复刻 Python 的「broken 先入账再匹配、remaining 末尾再入账」→ remaining 里 broken 条目出现两次（Python 真实行为）。
- D11 bugfix/fix 写失败必须 raise（Python _save_mod_cfg `raise OSError`→500），C++ 静默吞。
- D12 /api/validate、/api/effect_validate 的 cfg/text 取值应走 Python `or ""` 真值语义（null→""，C++ py_str(null)="null" 错）。
- D13 /api/dicts audios/evt_types 覆盖名 `str(v.get("name") or 兜底)`：空串也要兜底。
- D14 effect_suggest 关键词逐字符判定应按 UTF-8 码点（C++ 逐字节会把中文误判命中）；cfg_ids preview [:20] 同理按码点截。
- D15 cfg_ids 数字键相等时 Python 稳定序（不比较字符串），C++ 多了 a<b tie-break。
- 偏差记录（不改）：effect_suggest 简报写 POST、api.py 实为 GET → 以 api.py/golden 为准注册 GET；json_error detail 文案无法逐字节复刻 CPython json 报错（非 golden 端点）；Python 侧若干 Unicode 数字/下划线字面量边界（str.isdigit("１")、float("1_000")）C++ 按 ASCII。
- D16（**上游行为复刻**，smoke --equiv 实测发现）：api.py `_load_mod_cfgs` 返回
  `MappingProxyType` 包装的表，而 scan_bugs 的 S1 断层/S2 降维越界（表级 isinstance
  门）、S4 schema 格式环、S5 `check_refs`（表级 isinstance 门）在代理下**整段空转**
  ——即 Python 生产的 /api/bugfix/scan 只上报 S3/S4 级（恶性 FIX/RENAME/致命断层记录级
  等）+ B16 broken 条目；REF 悬挂、格式错乱 heal、严重越界只出现在普通 dict 直调
  （Python 自己的 test_ref_rules.py 也是普通 dict）。C++ 复刻该行为：
  scan/fix 路由首扫传 `read_only_view=true`；touched 重扫（Python 是 fork 后的普通
  dict）传 false 全语义。引擎层保持全语义。**建议主代理在 Python 侧修复**（把门改成
  `isinstance(x, Mapping)`），修复合入后 C++ 只需路由端去掉 flag；在此之前前端拿到的
  scan 结果两边一致（等价测试为证）。
- D17（跨组，非 P1 可修）：broken 表 desc 的解析器错误串——Python 为 CPython
  "JSONDecodeError: Expecting property name..."，C++ 为 cfg_cache.cpp（波次 1 官方件）
  的 "JSONDecodeError: file is not valid JSON"。前缀契约一致，尾串不同；等价比对
  以 <PARSER-ERROR> 哨兵归一，合并时主代理可统一成 CPython 文案。

## 里程碑日志

- [x] 09-08 接手：通读 wip/P1 全部文件 + CONVENTIONS §2/3/4/8/9 + 波次1 参考（cfg_routes/test_s1/test_support）+ Python 真相源；build-P1 全绿（backend/sa_tests/backend_wip 三产物）。
- [x] 09-08 数据销账：_semantic_db.json vs data_dicts.py 全 MATCH；dicts.json vs 运行时 ROLE/ITEM/.../key_maps/badminton 全 MATCH（turns/evt_types 仅 int→str 键形态，序列化后一致）；schema.json == GAME_SCHEMA（406 表）。
- [x] 09-08 修复 D1-D15 + D16（MappingProxyType 门复刻，smoke --equiv 实测发现）+ D17（记录）
- [x] 09-08 test_p1_semantic.cpp（test_ref_rules.py 16 例全移植 + 引擎级 scan/fix/secondary/标量，共 21 例）+ test_p1_routes.cpp（9 路由黑盒，15 例）；[p1] 36 例绿
- [x] 09-08 smoke.py：golden 6 例 PASS；--equiv 追加 Python 实后端 vs backend_wip 等价（validate×3/scan/fix/磁盘回读全 PASS）
- [x] 09-08 全量 sa_tests 112 例绿（波次 1 76 例未破坏）；brief 全量构建命令重跑绿
- [x] 09-08 selftest 白名单 5 例（STUDENT_AGE_BACKEND_URL 打 backend_wip）：test_schema_content / test_guide_validate_and_effect_modes / test_bugfix_scan_smoke / test_bugfix_scan_and_fix_option_1 / test_bugfix_scan_requires_mod → OK
- [x] 09-08 补对外别名 sa::game_schema()/sa::game_dicts()（简报钉死命名）
- [x] 09-08 交付报告（见主会话最终消息）
