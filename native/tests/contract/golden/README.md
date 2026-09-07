# golden — 后端 HTTP 契约基线（波次0）

Python 后端只读 GET 端点的响应基线，作为后续所有波次 C++ 重写的契约门禁。
文件名 = 端点路径消毒（非 `[A-Za-z0-9_.-]` 一律换 `_`），内容为归一化后的
信封：`{endpoint, method, status, response}`。

## 生成与门禁

```
python tools/record_golden.py            # 录制，重写本目录 *.json（38 个端点）
python tools/record_golden.py --check    # 复跑比对：逐端点 PASS/FAIL + RESULT 行，FAIL 退码 1
python native/tests/contract/normalize.py <golden.json> <actual.json>   # 单文件比对 CLI
```

## 录制状态固定方式（保证跨机器可复现、零污染真实环境）

实现见 `tools/golden_env.py`（record_golden / export_assets 共用）：

1. **tempfile 独立目录**：`<tmp>/data` 作为应用数据根、`<tmp>/workspace` 作为
   Mod 工作区；环境变量 `EDITOR_DATA_ROOT` / `EDITOR_PLUGINS_ROOT` /
   `EDITOR_PACKS_ROOT` 指向其子目录（后端各模块原生支持的覆盖入口，零改码）。
2. **预写 `<tmp>/data/editor_env.json`**：`workspace_root=<tmp>/workspace`、
   `oobe_completed=true`，使 `EditorState` 只见空工作区；AI/TTS/云配置走同
   目录（`.editor_ai.json` 不存在 → 返回默认空配置，不会把用户 apiKey 泄进 golden）。
3. **进程内补丁**（仅影响录制进程，不落任何代码改动）：
   - `editor.core.paths._APP_DATA_DIR_CACHE=<tmp>/data`——`env_store`/`oobe`/
     `realtime_sync` 等直接调 `app_data_dir()` 的模块不认 `EDITOR_DATA_ROOT`，
     必须靠这个缓存预置才能真正隔离；
   - `steam_paths.steam_library_paths → []`、`user_mods_dir → <tmp>/user_mods`
     ——屏蔽注册表/创意工坊扫描，否则 `/api/mods` 会混入本机订阅内容、跨机器
     必然不稳定，也会读到真实游戏 Mods；
   - 清 `EDITOR_OOBE` / `EDITOR_NO_OOBE` 宿主环境变量。
4. 录制后 temp 目录整体删除；HTTP 服务是进程内 daemon 线程，进程退出即回收。

## 归一化（录制前烘进 golden，比对前同样施加）

规则表为 `native/tests/contract/normalize.py` 顶部显式常量：

- `VOLATILE_KEYS` → `<VOLATILE>`：`mtime_ns/mtime`、`ts/timestamp/unix_ms/epoch`、
  `pid/port`、`updated_at/created_at`、`last_sync/last_check/generated_at/
  next_remote_poll`、`duration_ms/elapsed_ms/uptime*`。
  （录制实测：`/api/cloud/realtime/status` 的 `next_remote_poll` 等。）
- `PATH_KEYS` → `<PATH>`（值形似绝对路径时）：`workspace_root/mod_root/
  server_workspace/suggested_workspace/editor_root/env_path/detected/dirs/
  aa_dirs/root/path/dir/file/zip_path/source_file`。
  实测命中：`/api/ping /api/state /api/mods(root) /api/oobe/status /
  /api/base/status(env_path) /api/tools/list(root) `。
- 任意 key 下 Windows 盘符路径（`C:\`/`C:/`）与 UNC 路径一律 `<PATH>`。
- float 容差 `FLOAT_ABS_TOL=1e-6`（含相对项）；对象 key 序无关；数组有序逐位。
- 比对失败输出最小差异路径列表（`/a/0/b: x != y`，一处不同即止不再下钻）。

## 录制端点清单（38，全部只读 GET）

system：`/api/ping` `/api/state` `/api/oobe/status` `/api/ai/settings`
mods/cfg：`/api/mods` `/api/cfg` `/api/cfg/EvtCfg` `/api/cfg/TalkCfg`
`/api/cfg/OptionCfg` `/api/history?cfg=EvtCfg` `/api/cfg_ids?name=EvtCfg`
`/api/base_ids?cfg=EvtCfg` `/api/manifest/status`
schema/dicts：`/api/schema` `/api/dicts` `/api/effect_suggest?mode=effect&q=`
`/api/effect_suggest?mode=condition&q=`
sandbox tools：`/api/tools/list?scope=workspace&path=` `/api/tools/list?scope=mod&path=`
AI：`/api/ai/domains` `/api/ai/dicts` `/api/ai/stage/dicts` `/api/ai/stage/roles?talk_id=0`
资源/本体：`/api/aa/status` `/api/aa/keys?q=&limit=20` `/api/base/status`
`/api/base/events`（409 契约）`/api/search/talk?q=&limit=5` `/api/resource_packs`
云/配音/插件：`/api/tts/settings` `/api/cloud/providers` `/api/cloud/status`
`/api/cloud/realtime/config` `/api/cloud/realtime/status` `/api/plugins`
`/api/plugins/ui` `/api/plugins/ui/flow_cards` `/api/plugins/agent/tools`

## 有意排除项及原因

- 所有 POST/PUT/DELETE 与 `/api/mods/create|delete|select`、`/api/base/load`、
  `/api/aa/scan`、`/api/cloud/sync`、`/api/shutdown` 等：写盘/起后台线程/杀进程。
- `/api/tts/voices` `/api/tts/test`：可能发起外网请求（provider 网关），非确定性。
- `/api/tts/list` `/api/tts/audio`：读当前 Mod 音频目录且带 base64 二进制载荷。
- `/api/cloud/drivers`：枚举本机盘符/挂载点，机器绑定且非契约语义。
- `/api/cloud/list` `/api/cloud/local_files`：需 provider 凭证/本机目录，无法
  在无凭证隔离环境稳定复现（`/api/cloud/status` 隔离态为纯空进度结构，已录）。
- `/api/ai/domain/items` `/api/ai/domain/item`：需具体 domain/item 参数，空载
  意义弱；端点存在性已由 `/api/ai/domains` 契约覆盖，留波次1 补参数化 golden。
- `/api/base/events` 在 409 分支录制（本体未装载是隔离环境的确定态）。
- sponsor/app icon：`backend/editor/core/sponsor_data.py` 经全仓调研无任何
  HTTP 端点或 Python 消费方（死数据），无响应可录；处置见 `native/assets/README.md`。

## 已知契约特征（供 C++ 侧对齐）

- 无 mod 选中时 `/api/history?cfg=EvtCfg` 返回 400 `{"error": ...}`——错误契约
  同为基线一部分。
- `/api/ai/settings` 空配置文件时各必填项序列化为 `null`（`normalize_ai_settings`
  对缺省 dict 的真实行为）——照抄语义，不做“修复”。
- `/api/state.schema_count = 406`（与 schema.json 顶层表数一致，含空壳 Define）。
