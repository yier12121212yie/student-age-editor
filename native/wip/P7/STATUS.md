# P7（CLI 重建 / backend_cli）STATUS — 波次 3

> 交付代理：接管代理（前序代理写完全部源码后在 STATUS/验收前因机器重启中断）。
> 本文所有验收命令均在接管后的最终二进制上原样复跑，输出逐字粘贴（§4）。

## 0. 接管时状态

- `wip/P7/` 已有：`p7_cli_logic.{h,cpp}`（CLI11 语法 → Command → HTTP 请求规格 → 渲染/退出码，
  纯逻辑，被 SA_GROUP_WIP glob 编进 sa_tests）、`cli/p7_cli_main.cpp`（main + 内嵌服务器引导，
  不被 glob）、`test_p7_cli.cpp`、`group.cmake`（backend_cli 目标）、`build_p7.cmd`、
  `smoke.py`、`third_party/CLI11/CLI11.hpp`。无 STATUS.md，无任何构建/测试通过证据。
- `native/build-P7/` 存在遗留缓存：`CMAKE_BUILD_TYPE:STRING=Debug`（正踩中 CONVENTIONS §10
  「门禁配置备注」预言的坑），已 wipe。
- 源码从未编译过：首建即链接成功，但 sa_tests 2 条断言失败 + smoke 4 项失败（§3 逐条记录）。

## 1. 形态概要

- 默认内嵌模式：`sa::init_state + sa::build_router + sa::Httpd` 在进程内起真后端
  （与桌面同一组 route handler），CLI 经 `sa_core::http`（WinHTTP）走 loopback HTTP 自调自，
  响应 `--json` 时**原样透传后端字节**；`--url` 切纯客户端模式打既有实例。
- 内嵌端口：bind `127.0.0.1:0`（OS 临时端口 ≥49152）。简报建议 8780-8787 固定段，
  一次性 CLI 进程改用临时端口是**有意偏差**：多个 CLI 并行各起一个内嵌服务器时固定段必然
  互相抢绑，临时端口从源头规避，且与 8765/8766（编排者）与 8790-8799（P5）按构造不相撞。
  smoke 的「死端口 exit 3」用例占用 8789（不在任何服务段），实测通过。
- `env` 子命令为本地 `editor_env.json` 操作（Python 后端从未有过该 HTTP 路由），
  与 oobe/workspace 共读写同一 `sa_core::env_store` 层。
- `mods select/create/add` 成功后把选择镜像到 `editor_env.json` 的 `cli_selected_mod`
  （`{name, root}`）。已核对 Python `cli/oobe.py:mark_done` 为「读全量→改键→写回、保留其它键」，
  该附加键对 Python 端读方（只取已知键）无害。

## 2. 命令面覆盖映射（C++ backend_cli ↔ Python 真相源）

Python 真相源 = `backend/editor/cli/`（app.py / oobe.py / utils.py / interactive.py）。
Python CLI 是**离线文件模式**（不经 HTTP）；C++ CLI 经内嵌服务器复用桌面语义——
「功能相似即可」口径下逐命令映射如下。

| backend_cli 命令 | Python 对应 | 移植度 |
| --- | --- | --- |
| `mods list` | `mods list`(cmd_mods_list) | 完整（文本渲染降级为平铺行，无 rich 表） |
| `mods create <title> [--desc]` | `mods create` | 完整 |
| `mods add <title>` | —（create 别名，brief 指定） | 完整 |
| `mods add --path DIR [--name]` | 无对应（Python 无导入动词） | C++ 新增能力：本地复制进工作区 + 按 root 精确 select |
| `mods add --zip FILE [--name]` | 无对应 | C++ 新增能力：miniz 解包 + zip 条目防穿越筛查（CONVENTIONS 11 bundled_zip 同款）+ 单顶层模组目录改名抬升 |
| `mods select <name> [--root]` | 无对应（桌面靠 GUI 点击；CLI 靠每命令 `--mod`） | C++ 新增：持久化选中（见 §1） |
| `mods remove <name>` | `mods delete` | **有意降级：去掉 y/N 二次确认**（一次性进程无人值守语义；smoke 按此断言） |
| `mods show` | `mods show` | 未移植——信息 = `mods list` 单条 + `cfg list`，合并渲染价值低 |
| `cfg list` | `cfg list` | 完整 |
| `cfg get [--id --field --keys --meta --prefix --suffix --limit]` | `cfg get --id --key --fields --all` | 完整移植 `--id`/`--key→--field`；`--fields/--all`（rich 表列选择）**有意降级**为 `--limit` 预览 + `--json` 全量；`--keys/--meta/--prefix` 是后端投影（5.3）的直取便利 |
| `cfg set (--data\|--file) [--expect-mtime] [--force]` | `cfg set --id --key --value/--file` | **形态不同**：C++ 走整表 PUT（5.4 全量写）；Python 的记录级/字段级写由 `cfg patch --set {id:record}` 覆盖（行级补丁 + if_match/expect_mtime/force 全保留） |
| `cfg patch [--set\|--set-file --remove --if-match --expect-mtime --force]` | 无对应 | C++ 新增：POST 判别在 body 的 S2 契约直连 |
| `cfg history [--undo\|--redo]` | 无对应（undo 红点在 GUI） | C++ 新增：GET /api/history + POST /api/history/undo\|redo（5.5.6 语义） |
| `validate <cfg> [--data\|--file --strict]` | `cfg validate` | 完整；自动模式先 GET 现表再 POST；`--strict` 有 error 时 exit 1 |
| `bugfix scan` / `bugfix fix [--from-file]` | 无对应（仅服务器 API） | C++ 新增直连 `/api/bugfix/*` |
| `story export --evt [--out --dual --opts]` | 无对应（仅服务器 API/前端） | C++ 新增直连 `/api/story/export`；`--out` 落盘文本 |
| `story import --start-id (--text\|--file) [--write --append]` | 无对应 | C++ 新增直连 `/api/story/import`；默认预览、`--write` 才落库 |
| `oobe status` / `oobe done` / `oobe setup [--workspace --mod --desc --no-mark-done]` | `oobe.py` snapshot / mark_done / apply_setup + `--oobe` 自动弹窗 | 完整移植为显式子命令；**有意降级**：不做「首次访问自动弹引导」（REPL 交互特性，`EDITOR_OOBE/EDITOR_NO_OOBE` 由环境变量消费方自理，smoke 从 env 剥离两键） |
| `env get <k>` / `env set <k> <v> [--json-value]` | `workspace show/set`（editor_env.json 的 workspace_root 键） | 泛化为任意键；get 缺键 exit 1（smoke 断言） |
| 全局 `--json` | `--json` | 完整（后端响应字节原样） |
| 全局 `--mod` | 每子命令 `--mod` | **提升为全局**（CLI11 全局选项），等价覆盖 |
| 全局 `--workspace` | `--workspace` | 完整（内嵌模式 init_state 注入） |
| 全局 `--data-root` | 无（Python 靠 `EDITOR_DATA_ROOT` 环境变量） | CLI flag 覆盖 env（CONVENTIONS 11 同名键），env 兜底 |
| 全局 `--url` / `--timeout` | 无 | C++ 新增（传输失败 exit 3，smoke 断言 8789 死端口） |
| 交互 REPL（无参启动）/ `tui` | interactive.py / cmd_tui | 未移植——brief 排除项（形态定死 CLI11 子命令进程） |
| `schema` / `search` | cmd_schema / cmd_search | 未移植——离线富渲染命令；等价信息 `--json cfg get --keys` + 后端 `/api/schema` 直取可满足脚本场景 |
| `cfg edit/add/delete`（内置逐字段编辑器 / $EDITOR） | cmd_cfg_edit/add/delete | 未移植——依赖 TTY 编辑器交互；行级写删 = `cfg patch`，新记录模板 = `cfg patch --set` |
| `cfg export/import` | `_cfg_export/_cfg_import` | 已覆盖：`cfg get --json` 重定向 = export；`cfg set --file` = import |
| `server start` / `doctor` / `update` | cmd_server/doctor/update | 未移植——server 由内嵌模式吸收；doctor/update 是 Python 发行版自检/网络升级逻辑，非本次形态目标 |
| `agent *` / `cloud *` / `tts *` / `plugin *` | 对应子族 | 未移植——桌面生态（AI 会话/网盘/配音/Python 插件宿主），后端路由仍在，前端直用；CLI 复刻无消费场景 |

退出码契约：0 成功；1 HTTP 错误响应 / validate --strict 有 error / 死 --url→3 之外的运行期失败；
2 用法错误（CLI11 parse + 本地输入前置检查）；3 传输失败。smoke 对 0/1/2/3 均有断言且通过。

## 3. 构建与测试修复记录（全部落在 wip/P7 范围内）

1. **build_p7.cmd 首配落成 Debug**（§10 门禁备注同款病根，实测复现）：
   `if "%1"=="config" ( ... )` 块内 `%BUILD_TYPE_P7%` 在**解析期**展开，块内 `set` 默认值
   对同一块的 cmake 行无效 → `-DCMAKE_BUILD_TYPE=`（空）→ root CMakeLists.txt:17-18
   FORCE 成 Debug。修复：默认值移到块外 + 块内改用 `!BUILD_TYPE_P7!`。
2. **Edit 工具重写 build_p7.cmd 丢 CRLF + REM 中文触发 GBK 误解码**：cmd.exe 需要 CRLF，
   LF-only 导致行解析错乱（'VCVARS" >nul' 碎片报错）。修复：整文件 ASCII 化注释 + 显式转 CRLF。
   经验：*.cmd/*.bat 必须 CRLF-only。
3. **test_p7_cli.cpp 全部 22 个 TEST_CASE 无标签** → `sa_tests "[p7]"` 报
   `No test cases matched`。按主树惯例（`[p1][routes]` 等）统一补 `"[p7]"`。
4. **失败①** `build_url("/api/cfg/a/b")` 期望 `%2F`：与传输层契约矛盾——
   `httpd.cpp:379` 在路由 fullmatch **之前** URL-decode（CONVENTIONS 2 / httpd.py:132-134），
   `%2F` 必还原为 `/`，编码与不编码落到服务端**逐字节相同**（同一 404）。判测试错，
   改断言为透传 `/` 并在 `p7_cli_logic.cpp` 修正原自相矛盾的注释（Python quote(safe='/') 同形）。
5. **失败②** `import_target_name("bad/name")` 期望 `""`：会误杀一切相对路径
   （`--path ./mods/MyMod`）。实现取 basename（Python `Path(src).name` 语义）判对；
   改测试为 `"name"`，并补一条 `--name "a/b"` 拒绝断言保住非法名筛查意图（`:` 等非法集断言原样保留）。
6. **smoke 4 连红（mods add --zip 命名）**：zip `zipmod.zip` 内含单顶层 `ZipMod/` 时，
   原 hoist 只把内容搬进 `ws/zipmod`，模组名落在 zip 文件名干上，smoke 期望内层目录名 `ZipMod`。
   改为改名抬升（rename lift）后，踩中 **Windows 大小写不敏感**真坑：
   `ws\ZipMod` 经文件系统解析 == `ws\zipmod`（husk 自身）→ `fs::exists(target)` 恒真、
   直接 rename 永不可行（首轮实测 32/36）。终版：名仅差大小写时先把 husk 改名让位
   （`dst + ".p7stage"`）→ 内层目录 rename 进真名 → 删空壳；让位/改名失败或真名被占
   则回退原地内容上移（保留 `--name` 显式语义）。main 的 select 名改从最终目录 basename 反推。
   实测补验：`ZipMod2.zip` 内含 `Alpha/` → 落 `ws/Alpha` 名 `Alpha`。
7. **C4005 WIN32_LEAN_AND_MEAN 宏重定义**（root 已在编译命令行定义）：`#ifndef` 守卫。
8. 过程性自纠：一次性验收时两条构建日志曾短暂落在 `native/` 根目录（越界），已当即
   `mv` 回 `native/build-P7/log-config.txt` / `log-build.txt`；证据文件（含
   `p7_test_out.txt`、`full_test_out.txt`、`smoke_out.txt`、`help_out.txt`）全部留存于
   `build-P7/` 可复查。`.gitignore` 等工作区既有 `M` 项均为用户/编排侧 WIP，非本组改动
   （本组只写过 `wip/P7/**` 与 `build-P7/**`）。

以上 1-7 之外未改任何文件；**未触碰任何共享文件**（native/CMakeLists.txt、
tests/CMakeLists.txt、server/**、core/**、backend/**、frontend/**、tools/** 全部只读，
最终 `git status` 见 §5 证据）。零 git 写操作；smoke/手工复现全程 temp 数据根
（`EDITOR_DATA_ROOT` + `EDITOR_DISABLE_STEAM_DETECT=1`），未写真实游戏 Mods 目录。

N1 销账：全模块扫描——`value(k, json字面量)` 仅用于标量默认值即用即弃
（`value("name","")`/`value("error",0)` 等），取对象子成员一律 `contains + at`
（p7_cli_main.cpp run_env/选择持久化处），无「绑引用跨语句」形态。

## 4. 验收（命令原样，输出逐字）

Git Bash，仓库根 `D:\Program Files\Steam\steamapps\common\StudentAge\editor`。
以下为首配 wipe 后全新序列的最终一轮，全部复跑可重放。

### 4.1 全新 Release 配置 + 构建（验收步骤一）

```
$ rm -rf native/build-P7
$ cd "D:/Program Files/Steam/steamapps/common/StudentAge/editor/native/wip/P7" && cmd //c build_p7.cmd config
-- The CXX compiler identification is MSVC 19.44.35228.0
...
-- Configuring done (1.1s)
-- Generating done (0.1s)
-- Build files have been written to: D:/Program Files/Steam/steamapps/common/StudentAge/editor/native/build-P7
config rc=0

$ grep -m1 "CMAKE_BUILD_TYPE:" native/build-P7/CMakeCache.txt
CMAKE_BUILD_TYPE:STRING=Release

$ cmd //c build_p7.cmd        # 完整日志存 build-P7/log-build.txt
build rc=0
[79/80] Linking CXX executable bin\sa_tests.exe
（bin/ 目录实测含 backend.exe  backend_cli.exe  sa_tests.exe —— 两目标链接成功）
```

### 4.2 [p7] 全绿

```
$ cd native/build-P7/bin && ./sa_tests.exe "[p7]" ; echo "rc=$?"
rc=0
All tests passed (247 assertions in 22 test cases)
```

### 4.3 全量回归不回归

```
$ ./sa_tests.exe "~[slow]" ; echo "rc=$?"
rc=0
All tests passed (2257 assertions in 215 test cases)
```

（1 条运行时提示非失败：`EDITOR_BASE_ARTIFACT_DIR unset: real-artifact check skipped`，
P4 组环境开关，主树既有行为。）

### 4.4 黑盒冒烟

```
$ python native/wip/P7/smoke.py ; echo "SMOKE_RC=$?"
oobe status first_run                                PASS
...（35 项全 PASS，含 mods add --zip / mods list selected + complete /
   sandbox error keeps envelope + exit 1 / dead --url -> exit 3 /
   cfg set without data -> exit 2）
RESULT: PASS (35/35)
SMOKE_RC=0
```

注：失败轮里 `Ctx.run(expect_rc 不符)` 会额外打一行 `rc(...)` 失败项（计数会变 36），
全绿时即 35 具名检查，不矛盾。

### 4.5 附加：--help 机器面（对齐 MERGE_P7.md 门禁 G1）

```
$ native/build-P7/bin/backend_cli.exe --help ; echo "rc=$?"
rc=0
学生时代 Mod编辑器 — native CLI (C++ 后端)
Usage: backend_cli [OPTIONS] SUBCOMMAND
...（含 --data-root / bugfix 等标记，全文存 build-P7/help_out.txt）
```

## 5. 需主代理处理（合并期动作；本组未动共享文件）

合并布局与接线以 **`native/MERGE_P7.md`**（主代理侧调研清单）为准：
`native/cli/{p7_cli_logic.*, p7_cli_main.cpp}` + `sa_cli` 静态库（**勿 glob**，防双 main）+
`test_p7_cli.cpp → native/tests/`（通配自动收）+ `sa_tests` 链 `sa_cli` +
CLI11 单头入 `native/third_party/CLI11/`（README 记版本行）+
`smoke.py → native/tests/smoke_cli.py`（find_cli 落 build/bin，见其 §5 补丁）。
本 STATUS 即填补 MERGE_P7 §7.9-① 的「STATUS.md 缺失」——`p7_cli_main.cpp` 头部
「see STATUS.md」不再悬空。其 §3.3 结论与本组实测一致：`EDITOR_ASSETS_ROOT` 自定位注入块
合并后必须保留（exe 在 build/bin 时靠 p1::find_asset 深搜找 native/assets/schema.json）。

需主代理知悉的**接管后增量**（MERGE_P7.md 快照早于以下改动，引用行号需当日重 grep，
其 §7.4 已有预案）：

1. `cli/p7_cli_main.cpp`：zip 导入改为**改名抬升**（`lift_single_top_dir`，含 Windows
   大小写不敏感的 `.p7stage` 让位步骤）+ select 名取自最终目录 basename + C4005 守卫，
   行数较其 583 行快照再变。
2. `p7_cli_logic.cpp`：`build_url` 注释修正（%2F 语义，无行为变更）。
3. `test_p7_cli.cpp`：22 例全部补 `"[p7]"` 单标签（与其 §4 实测一致）；两条断言按 §3-4/§3-5 修正。
4. `build_p7.cmd`：Release 首配修复（§3-1）；按其计划该脚本合并后退役，但教训实证了
   §10 门禁备注的预言，请在波次 3 其它组脚本里排查同款块内 `%VAR%` 写法。
5. 待裁决项：无 `--version`（其 §7.9-②，本组确认现状即无）；`mods remove` 免二次确认
   （§2 表，若需 `--yes` 门槛属 CLI 本地小改）。

## 6. 遗留风险与偏差备忘

- `mods remove` 无二次确认（§2 表）——脚本化友好，但误删防线比 Python 少一层；
  若主代理认为需 `--yes` 门槛，属 CLI 本地两行改动。
- `cli_selected_mod` 是 editor_env.json 的**新增键**：Python 读方只取已知键、写方
  mark_done/merge 保留其它键（已核 `oobe.py:69-80`），判定兼容；前端若有全量覆盖写
  editor_env.json 的路径未核（P7 范围外）。
- 内嵌服务器 bind 端口 0（OS 临时端口）与简报「8780-8787」字面不同，理由见 §1；
  如编排层需要「CLI 内嵌端口可预测」，请回话，本组可改成段内自增探测。
- 文本渲染为平铺行（无 rich 表格/配色），`--json` 是机器面契约的主通道。
- `validate` 自动模式=先 GET 再 POST 两步，GET 失败按 HTTP 错误路径 exit 1（非 2），
  与「数据缺失」的 usage 2 有意区分。
