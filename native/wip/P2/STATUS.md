# P2（工作区与 Steam 探测）接手工作日志

> 前代理因机器休眠中断（波次 2 P2）。本文件由接手者维护，供再次中断时接力。
> 分支 cpp-backend，禁 git 写操作。构建目录 native/build-P2（-DSA_GROUP_WIP=P2）。

## 状态速览（最后更新：2026-09-08）

- [x] official 树可编译自证：`cmake -G Ninja -S native -B native/build-P2 -DSA_GROUP_WIP=P2 -DCMAKE_BUILD_TYPE=Release` + ninja → exit 0
- [x] 盘点完成度：steam_paths / env_store / state.cpp 接线 / workspace_routes 路由 / [p2] 测试 / smoke.py 均已由前代理落地大半
- [x] 修复 P2Fixture 析构自我死锁（持 mu_ 再调 invalidate_mods_cache → fastfail 0xC0000409）
- [x] 修复 oobe complete+setup 测试的 mod 落盘路径断言（workspace 参数换根后 mod 应落新根=data 目录，与 api.py:816 一致）
- [x] env_store::atomic_merge_write 补 _WRITE_LOCK 等价串行锁（env_store.py:96）
- [x] state.h 陈旧 TODO(P2) 注释更新
- [x] [p2] Catch2 全绿：100 assertions / 14 cases
- [x] official 全量 sa_tests 回归（build-P2 含 wip：606/90；纯 official 临时目录：506/76 后删除）
- [x] golden 差分 smoke.py 全 PASS（api_state/api_mods/api_oobe_status → RESULT: PASS）
- [x] selftest 白名单打 backend_wip：3 mods 例 OK（隔离 temp 环境 + --workspace-root + EDITOR_DISABLE_STEAM_DETECT=1）
- [x] 交付报告（见 wip/P2/README 无 —— 报告在接手会话最终消息中，要点即下方坑点/偏差记录）

## 文件地图

- official（豁免编辑面）：
  - native/core/include/sa_core/steam_paths.h / core/steam_paths.cpp —— steam_paths.py 移植（注册表/VDF/多库/Proton/workshop/LocalLow + EDITOR_DISABLE_STEAM_DETECT）
  - native/core/include/sa_core/env_store.h / core/env_store.cpp —— editor_env.json 容错读写 + 原子 merge
  - native/core/http_client.{h,cpp} —— 简报外附赠（WinHTTP，供后续组用；已编入 sa_core）
  - native/core/CMakeLists.txt —— 新增上述 3 个 cpp + advapi32/winhttp
  - native/server/state.{h,cpp} —— TODO(P2) 落地：user_mods_dir()/workshop_mods_roots() 接 sa_core；init_state CLI>env>LocalLow；list_mods 多根（path_key 去重）
- wip/P2：workspace_routes.{h,cpp}（/api/workspace + /api/oobe/status|setup|complete）、main.cpp（backend_wip 挂 extra_routes）、test_p2_workspace.cpp、smoke.py

## 坑点/偏差记录（供报告）

- POST /api/workspace 显式 root 持久化进 editor_env.json：api.py:768-775 不写（简报要求的 P2 增量），root="" 回退不持久化
- /api/oobe/setup 的 ai_settings/cloud_provider 属波次 4 域，静默降级（Python 本就 swallow）
- list_mods 去重键：Python os.path.normpath（大小写敏感），C++ 用 path_key（abs+normcase）——Windows 上更严格不误伤，等价语义
- snapshot workspace_root：Python 经 str(Path(ws))（分隔符归一），C++ 原样 strip——对自家写入的值等价，第三方 env 值可能差斜杠形态
- workshop 内容只读：mods/delete 拒删（api.py:936-939 中文错误原样）
- manifest.json CRLF：Windows 文本模式翻译先例（波次 1 偏差 6）
- body 键 `false`/`0` 等假值：Python `x or ""` 短路为 ""，C++ 已按 py_truthy 归一

## 命令备忘

```
# 构建（Git Bash，仓库根）
cmd //c "call D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat >nul 2>&1 && D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe -G Ninja -S native -B native/build-P2 -DSA_GROUP_WIP=P2 -DCMAKE_BUILD_TYPE=Release && D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe -C native/build-P2"

# [p2] 测试（注意 Git Bash 里 .exe 直调可能 127，走 cmd；catch 过滤别加引号套娃）
cmd //v:on //c "cd native\build-P2\bin & sa_tests.exe [p2] > p2.log 2>&1 & echo RC=!ERRORLEVEL!"

# golden 差分
python native/wip/P2/smoke.py

# selftest（外部模式，白名单见交付报告）
cd backend && STUDENT_AGE_BACKEND_URL=http://127.0.0.1:<port> python -m unittest editor.server.selftest -k <pattern>
```

## 里程碑日志

- 2026-09-08 R1：接手。编译确认 OK（前代理半成品全量可编）。读码盘点如上。
- 2026-09-08 R2：[p2] 测试崩溃定位 = P2Fixture 析构自锁（非路由/核心代码 bug）。修测试 + env_store 加锁 + state.h 注释。`[p2]` 100/100 绿。
- 2026-09-08 R3：workspace_routes body_str 改 `(get(k) or "")` 假值归一；全量 sa_tests 606/90 绿；golden 差分 3/3 PASS；selftest mods 白名单 3/3 OK；纯 official 目录（无 SA_GROUP_WIP）编译+76 例全绿自证后清理。任务收尾。
