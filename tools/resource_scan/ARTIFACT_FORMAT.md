# resource_scan 产物格式契约（v1）

> 读者：C++ 后端（P4 组）。本文件是 `tools/resource_scan` 全部产物的**唯一格式规范**；
> `selfcheck.py` 是它的可执行子集。工具只读游戏文件，产物全部写到 `--out`，不写别处。
>
> 通用约定（适用于下面所有文件）：
> - **编码：UTF-8 无 BOM**（与 backend `_cache/aa_index/aa_index.json` 现状一致；
>   backend Python 读取端用 `utf-8-sig`，即兼容有无 BOM，C++ 端按无 BOM 生成即可）。
> - JSON 序列化：`ensure_ascii=false`、默认分隔符（`", "` / `": "`）。**空白不是语义**，
>   比对内容时解析后再比，不要比字节。
> - 数值陷阱：`path_id` 为 **int64**（可达 ±9.2e18，如 `-6961645949212346451`）。
>   C++ 侧禁止按 double 解析（精度截断！），必须 int64（nlohmann `long long`、
>   simdjson `int64` 均安全）。行数/字节数均为非负 int。
> - 落盘方式：先写 `*.tmp` 再原子 `rename`，读者不会看到半文件（OS 级原子性前提下）。
> - 时间戳 `generated_at`：本地时钟，`"YYYY-MM-DDTHH:MM:SS"`，无时区无毫秒。仅作参考，
>   勿用于失效判断。

## 产物总览（文件布局）

```
<index --out>/            # py -m resource_scan index
  aa_index.json           # §1  v3 bundle 引用索引（与 backend _cache 逐字段兼容）
  keys.json               # §2  键清单（/api/aa/keys 替代数据源）
  index_meta.json         # §3  本次扫描的元信息/诊断（工具自有，backend 不读）

<base-tables --out>/      # py -m resource_scan base-tables
  base_data/<Table>.json  # §4  每张原版配置表一个文件，<Table> ∈ 46+ 标准表名
  base_meta.json          # §5  源指纹 + 表清单 + 诊断（替代 base_data.pkl 的头部）

<decoded-pack --out>/     # py -m resource_scan decoded-pack（进程内调用 decoded_export.py）
  <预解码资源包 zip/目录>  # §6  仅格式提示；契约仍以本文档冻结，产物由
                          #     tools/resource_scan/decoded_export.py 生成
```

---

## 1. `aa_index.json` — v3 bundle 引用索引

**逐字段兼容** backend 现有 `_cache/aa_index/aa_index.json`（Python
`UnityFsIndex.try_load_cached()` 可直接加载本工具产物；实测后端缓存键集即此结构：
`["v","fp","tex","aud","txt","cabs","texmeta","bundles"]`）。

| 字段 | 类型 | 语义 | 后端对应物 |
|---|---|---|---|
| `v` | int | 恒 `3`。格式版本，结构变化时递增（`unityfs_res.CACHE_VERSION`） | 加载校验 `data["v"]==3` |
| `fp` | string | 恒 `""`。backend aa 模式构造索引时不传 fingerprint，缓存里就是空串；C++ 侧**只要求存在且为字符串**，值不参与决策 | `try_load_cached` 比对 `data.get("fp")==""` |
| `tex` | object | 纹理/图集页索引：`key -> [bundle_path, path_id]` | `UnityFsIndex._tex`，`preview_tex_png` |
| `aud` | object | 音频索引：`key -> [bundle_path, path_id]` | `_aud` |
| `txt` | object | 文本资源索引：`key -> [bundle_path, path_id]`（**不只配置表**，含 spine `.skel/.atlas` 等全部 TextAsset） | `_txt`，`export_text` |
| `cabs` | object | SerializedFile CAB 名（小写，如 `"cab-26d5...dc1"`）→ 所在 bundle 路径。跨 bundle 引用（本地化 Sprite 引图集纹理）解码时按它补加载依赖包 | `_cabs`，`_load_dependencies` |
| `texmeta` | object | `key -> [width, height]`（像素，int>0）。**v3 新增**，CG 判定信号；仅收录扫描时成功读到头部的键，**允许稀疏**（键可不在 texmeta 里） | `_texmeta`，`tex_meta()` |
| `bundles` | array[string] | **已尝试**扫描的 bundle 绝对路径（含解析失败的——失败包贡献空键集；backend 同语义）。排序后为确定性次序 | `sorted(_bundle_set)` |
| `partial` | bool（可选） | **工具扩展键，仅采样时存在**：`--limit` 截断产物时写 `true`。全量产物**没有**这个键。backend 老读取端忽略未知键（兼容）；C++ 消费方**必须**按 `data.get("partial", false)` 处理 | — |

### 键（key）的规范形态

`key = os.path.splitext(对象名)[0].split(" #")[0].strip().lower()`（复制自
`unityfs_res._norm_key`）：去最后一个 `.` 起的扩展名、去 `" #…"` 后缀、trim、小写。
特征与边界：
- 恒小写；**可含点**（如 `a.b.json` → `a.b`）、中文、`-`、`_`；不含 ` #`、不含扩展名尾缀。
- C++ 端做 key 查询前要对用户输入套同一规范化（backend 的 `has_tex()` 就这么做：
  先 `_norm_key` 再查表）。
- 不同对象规范到同 key 时 **first-wins**，胜者次序 = `(CLI 源目录序, 折叠路径,
  原始路径)` 升序；折叠路径 = 小写后剔除非 `[0-9a-z]` 字符（`util.collapse_path`），
  标点折叠使本体包排在地域变体包前（实测 `cfgs_assets__…` < `cfgs-zh-hant_…`、
  zh-hans < zh-hant < en），即重复键胜者恒为语言中性/简体正源包。backend 原实现
  按进程桶完成序合并、跨桶重复键胜者不确定；本工具为确定序（键集与 backend
  全量缓存一致，仅跨包重名键的 `[bundle, path_id]` 指向可能不同）。

### 值的语义与路径可移植性

`[bundle_path, path_id]`：
- `bundle_path`：Windows 绝对路径（JSON 内为 `\\` 转义），**生成机器的路径**。
  换机器/换 Steam 库后可能失效。backend 的缓解措施（C++ 应照做）：文件不存在时
  按 `basename(bundle_path)` 在当前 aa 目录递归重定位（`decoded_export._remap_bundles`
  语义）；重定位成功则 `cabs` 不可信需丢弃重建。
- `path_id`：Unity SerializedFile 对象 ID（int64，见上）。解码 = 打开 bundle →
  找 path_id 对象（backend `_find_object`：只查主 bundle 的 SerializedFile 对象表，
  不查依赖包，避免跨包 path_id 撞号）。

### 「bundle 文件名分组」语义（必须保留）

Addressable 分组编码在 bundle **文件名**里，`flow_assets.py`（C++ 将直接移植）据此
判 CG/BGM，因此 C++ 侧加载索引后**不要**把值扁平成纯路径表，保留
`key -> [path, id]` 结构、路径含原始文件名。实测分组样例：
`textures_assets_cg_<hash>.bundle`、`textures_assets_role_…`、
`audios_assets_bgm_…`、`cfgs_assets__…`、`dlc_cfgs_assets__…`。

### 损坏 / 部分标记

- 采样（`--limit` 截断）：顶层 `"partial": true`。**禁止**把 partial 产物复制进
  backend `_cache/aa_index/`（backend 无法识别该键，会当全量用）。
- 单 bundle 解析失败：不标 partial；该包进 `bundles`（已尝试）、键贡献为空，详情见
  `index_meta.json.errors`。
- 文件级损坏由生成端原子替换保证不会出现；消费端 JSON parse 失败应回退重扫。

### 示例（截样）

```json
{"v": 3, "fp": "",
 "tex": {"img_brickgame_tri": ["D:\\...\\brickgame_f83284d28d95601afe637999a538060f.bundle", -6961645949212346451]},
 "aud": {"ingame_get_common_fly": ["D:\\...\\audios_assets_ogg_4be02589f9be795da5d947415674cd5c.bundle", -9059115929332620942]},
 "txt": {"personcfg": ["D:\\...\\cfgs_assets__5511f207679e32ec9da13b1d2a97c239.bundle", 1234]},
 "cabs": {"cab-cdee755dc00829c1788204d4ef707887": "D:\\...\\localization-locales_assets_all.bundle"},
 "texmeta": {"badminton_enermy_boy_0_tex": [256, 512]},
 "bundles": ["D:\\...\\ach_2321b2b3e177ce156201bbfdd79c8ab1.bundle"]}
```

## 2. `keys.json` — 键清单（`/api/aa/keys` 数据源）

api.py `/api/aa/keys` 本质返回 `idx.tex_keys()/aud_keys()/txt_keys()` 的过滤截断。
C++ 后端不需要重放扫描即可应答该接口：读 `keys.json`。

```json
{"v": 1, "partial": false, "generated_at": "2026-09-07T20:30:00",
 "tool": "resource_scan/1.0.0", "sources": ["D:\\...\\aa"],
 "bundles_scanned": 148, "bundles_failed": [],
 "counts": {"tex": 9501, "aud": 463, "txt": 350, "cabs": 148, "texmeta": 1537},
 "tex": ["ab_buy_confirm", "..."], "aud": ["..."], "txt": ["..."]}
```

- 三个列表**升序排序**（backend 返回的是 dict 插入序，仅供展示分页，无排序语义）。
- `partial`：布尔，恒存在（与 aa_index.json 的"缺省即 false"不同，这里显式给全）。
- 与 §1 的一致性：`tex` == `aa_index.json.tex` 的键集排序，aud/txt 同理。
  selfcheck 校验这点。

## 3. `index_meta.json` — 扫描诊断（工具自有）

字段：`v,index_version,partial,generated_at,tool,aa_dirs,skip_slow,limit,jobs,
bundles_total_found,bundles_scanned,elapsed_sec,counts,errors[{bundle,error}]`。
C++ 侧仅在排障/CI 需要时读；**不属于**backend 兼容契约。

## 4. `base_data/<Table>.json` — 原版配置表

替代 pickle `base_data.pkl`（其内容 `{"fp":..., "data": {表名: {id: record}}}`，
C++ 无法读 pickle，这是本产物存在的理由）。**每张表一个文件**，内容即
`base_data["<Table>"]`：`{"行id": 行对象}`，与 backend 内存中的
`BaseDataService.data[表名]` 及解包资源包 `Cfgs/zh-cn/<表名>.json`
（`decoded_export.export_cfgs` 同款 `json.dump(ensure_ascii=False)`）逐字段一致。

- 文件名：标准表名（下表 46+ 个，PascalCase，如 `EvtCfg.json`、`TalkCfg.json`）。
- 顶层键（行 id）：JSON 里**恒为字符串**（Python dict 键序列化即如此；原表存在
  数字形态键时，落盘后读取方拿到的仍是字符串键——C++ 按 `map<string, row>` 处理）。
- 行对象内部字段原样透传（游戏 JSON 的所有类型：int/float/string/bool/null/嵌套
  数组对象）。**不要**假设行 schema 稳定——按 backend 现有做法宽松取字段。
- 编码同通用约定（UTF-8 无 BOM）。

标准表名全集（来自 `base_service._CFG_KEY_MAP`，`missing_expected` 即对照此集）：

```
ActionCfg ActionEvtCfg AudioCfg BadmintonModelCfg BgCfg BookCfg CGCfg
EndingDatingCfg EndingOptionCfg EndingPartCfg EvtCfg EvtTypeCfg ExploreCfg
FriendRequestCfg IntentCfg InteractCfg ItemCfg JobCfg KZoneAvatarCfg
KZoneColorCfg KZoneCommentCfg KZoneContentCfg KZoneFontCfg KZoneProfileCfg
LoveBadmintonCfg LoveBreakfastCfg LoveDrawCfg LoveRibbonCfg LoveVindicateRateCfg
MapCfg MinigameCfg MinigameActionCfg MovieCfg NegotiationPlayerCfg
NegotiationTeammateCfg OptionCfg PaperCfg PersonAttrCfg PersonCfg
PersonStateCfg PhoneMsgCfg RelationCfg ShopCfg TalkCfg TextCfg ToggleCfg TvCfg
```

表识别/清洗规则（与 backend 逐行为一致，移植自 `base_service.py`）：
1. TextAsset/文件名 → `norm_key` 后，最长前缀匹配 `_CFG_PREFIXES`（全小写）→ 标准表名；
2. 键含 `_CFG_LANG_BAD_TOKENS`（`-en/_en/-hant/hk/_tw/traditional/en_/en-` 等，
   原表 `_CFG_LANG_BAD_TOKENS` 列表）→ 整条丢弃（繁体/英文表）；bundle 模式另对
   **bundle 文件名**套同一 token 过滤（`cfgs-zh-hant_assets…`、
   `dlc_cfgs-zh-hant…`、`localization-*english(en)*` 整包跳过——繁体包内
   TextAsset 对象名与简体同名无标记，backend 靠索引 first-wins 遮蔽，本工具
   texts 模式逐包保留贡献，若不过滤繁体行会覆盖本体行）；
3. `_clean_cfg_json`：采样前 20 万字符统计 `_TC_CHARS` 繁体字，**>2 次即整表丢弃**
   （注：表内简中也偶含列表字如「鞋」，实测本体 `ItemCfg` 因此在 aa 模式被丢——
   backend 行为相同，非工具 bug）；JSON 解析失败再走脏 JSON 强洗（去 `//`、`/*…*/`
   注释、尾逗号），仍失败/结果非 object → 丢弃；
4. 多来源合并：CLI 源顺序 → 同屏内 bundle 按折叠路径序（§1）、Cfgs 目录按文件名
   排序，逐行 `dict.update`（后来源同 id 行覆盖）。base 与 DLC 各 bundle 表名可
   重复（实测 DLC 4 包 × 15 表名与本体重叠），DLC 作为后置 `--aa` 源传入即得
   「本体 + DLC 覆盖」结果；繁体包（`cfgs-zh-hant`、`dlc_cfgs-zh-hant`）会被扫到
   但内容整体过不了第 3 条清洗，自然出局。

## 5. `base_meta.json`

```json
{"v": 1, "tool": "resource_scan",
 "generated_at": "2026-09-07T20:31:00", "elapsed_sec": 3.8,
 "partial": false, "limit": 0, "bundle_name_filter": ["cfgs_assets"], "jobs": 2,
 "sources": [{"path": "D:\\...\\aa", "mode": "aa",
              "files": [{"name": "catalog.json", "mtime_ns": 1757000000000000000, "size": 1234}]}],
 "fingerprint": "9dd9558e48...",
 "contributions": ["StandaloneWindows64/cfgs_assets__5511....bundle"],
 "bundles_scanned": 1, "bundles_failed": 0,
 "table_count": 46, "total_bytes": 40234567,
 "tables": {"EvtCfg": {"file": "base_data/EvtCfg.json", "rows": 12345,
                        "bytes": 2917431, "sha256": "…",
                        "sources": ["StandaloneWindows64/cfgs_assets__….bundle"]}},
 "missing_expected": ["ItemCfg"],
 "merge_semantics": "dict-of-rows; per-row update in source order (later source overwrites same row id)",
 "encoding": "UTF-8 no BOM; JSON compact (ensure_ascii=false)",
 "errors": []}
```

要点：
- `partial/limit`：`--limit` 截断 bundle 时为 `true`（表集可能不全）。
  `bundle_name_filter` 只作溯源记录（不标 partial：本体表实测全在 `cfgs_assets`
  命名的包内，过滤是操作者显式决定）。
- `missing_expected`：全集（§4 列表）中本次未产出的表。**注意与旧行为对齐**：
  backend 会把缺失表进 `BaseDataService.missing_keys` 上报 API；C++ 直接读此字段。
- `tables.*.sha256`：对**文件落盘字节**的规范化序列化（§4 生成方式，即
  `json.dumps(ensure_ascii=False)`）再 UTF-8 编码取 sha256。CI 可比对文件字节；
  若你的 JSON 库序列化空白/键序不同，改为解析后深比对。
- `tables.*.sources`：贡献过该表的来源标签（bundle 相对首个 `--aa` 源的路径，
  或 Cfgs 目录绝对路径），按贡献顺序。
- `sources[].files`：每个 `--aa` 源目录**顶层文件**（不递归）的 name/mtime_ns/size，
  失效判断素材。

### 指纹算法（失效判断，照抄 base_service）

`base_service.BaseDataService._fingerprint` =
`sha1( ∪ str(stat元组) + mode字符串 )`，元组来自 `_stat_parts`：
目录 → 其**顶层每个文件**一个 `(dir, name, st_mtime_ns, st_size)` 四元组
（`os.listdir` 排序序），单文件 → `(path, st_mtime_ns, st_size)` 三元组；
`str(tuple)` 按 Python repr 形式取 utf-8(errors=ignore) 依次喂入 sha1，最后追加
`str(mode)`。**不含**文件内容哈希、不递归子目录。

本工具版 `fingerprint` 与之逐元组同构，唯一差异：无 `editor_env.json` 项（CLI
无该文件），mode 取 `"aa"`（任一源含 bundle）或 `"studio"`（纯 Cfgs 目录源）。
C++ 侧失效判断的**推荐做法（不必复现 sha1）**：重扫 `--aa` 各源目录顶层文件，
与 `sources[].files` 逐项比 `mtime_ns/size`——任一项变化即产物过期。对 aa 源这
只覆盖 `catalog.json/settings.json`（顶层），与 backend 现状一致：游戏更新必改
catalog。**bundle 内容变而顶层清单不变的情形 backend 本就检测不到**，工具不引入
新问题；若 P4 要更严格，可自行哈希 bundle 文件（契约会另行升 `v`）。

## 6. `decoded-pack` 子命令（独立实现，非本工具冻结格式）

`py -m resource_scan decoded-pack -- <args...>` 进程内调用
`tools/resource_scan/decoded_export.py`（W5-3 起零 `backend/editor` 依赖；其参数集
`--out/--tier/--max-side/--quality/--limit/--no-audios/--no-zip`，索引覆盖
`--index/--aa-dir/--cache-dir`，`decoded-pack --show-help` 查看）。
`packaging/export_decoded_pack.py` 保留为同实现薄壳入口（历史脚本引用）。
产物 zip 布局：
`manifest.json`、`aa_index.json`（**另一形态的 v3**：
`{"v":3,"decoded":true,"tex":[…],"aud":[…],"txt":[…]}`——键列表而非 bundle 引用，
判别标志是 `"decoded": true`，读取类为 `decoded_pack.py`
`DecodedPackStore`）、`base_data.json`、`Cfgs/zh-cn/<表>.json`、`tex/*.webp`、
`aud/*.ogg|wav|m4a`。C++ 若消费预解码包：先查 `"decoded"` 标志再选解析路径。

消费/生产闭环都在本目录：`decoded_export.py`（生产，桌面 UnityPy 解码）↔
`decoded_pack.py`（消费，扫描解压后目录映射 key→文件）；索引类 `Index` 语义由
`unityfs_res.UnityFsIndex` 提供（从后端剥离，含内联的游戏 aa 目录探测，
`SA_GAME_AA_DIR` 可覆盖）。本文档 §1–§5 不受影响。

## 7. testdata/ 与 selfcheck.py

- `testdata/index/`：真实全量产物（aa 148 bundle）的**截样**——每表保留排序后
  前 12 键、`bundles` 收敛到被引用包（13.8KB < 200KB），顶层带 `partial: true`。
  配套 `keys.json`/`index_meta.json` 由截样派生（带 `"sample": true` 声明来源）。
- `testdata/base/`：`base-tables --bundle-name-filter cfgs_assets` 真实产物的
  `base_data/` 仅保留最小 3 张表**全量**（NegotiationTeammateCfg/LoveVindicateRateCfg/
  BadmintonModelCfg），`base_meta.tables` 清单同步裁剪并标 `"sample": true`；
  真实产物**恒无**该键、清单恒与 `base_data/` 目录一一对应。
- `selfcheck.py`（仅 stdlib，无 UnityPy）：校验上述所有结构不变量
  （字段存在性/类型/键规范/键集一致性/表文件与 meta 清单 rows+sha256 相符/
  无 BOM/partial 语义），CI 与 C++ 侧移植后可直接 `python selfcheck.py` 当冒烟。

## 8. C++ 最小消费路径（P4 速览）

只读 `base_data/*.json + aa_index.json` 时需要处理：
1. JSON int64 `path_id`（§通用约定）；键查询前套 `norm_key`（§1）。
2. `bundles`/值路径的**重定位**（换机路径失效，按 basename 重扫 aa 目录）；
   重定位后 `cabs` 丢弃（§1 值语义）。
3. `partial`（缺省 false）与 `base_meta.missing_expected`、`errors`：任何采样产物
   不得当全量入库；表缺失要上报（对齐 `/api/base/status` 的 missing 语义）。
4. `texmeta` 稀疏：CG 判定按 `flow_assets.is_cg_image` 的「尺寸缺失→回退不过滤」
   处理（api.py 已有回退先例）。
5. 行 id **字符串**语义（§4）；`EvtCfg` 等表行内 `npc` 字段可能是单值或数组，
   查询侧做类型容错（对齐 `search_events` 的 `npc_set` 构造）。
6. 失效：比 `base_meta.sources[].files` 的 mtime_ns/size（§5），过期即重跑 CLI。
7. 解码资源不在产物里：索引只定位不内嵌；按 `[bundle, path_id]` 自行用 UnityFS
   解析器读对象（跨包引用经 `cabs` BFS 补载，`unityfs_res._load_dependencies` 语义）。
