# native/assets — 波次0 数据资产（Python 后端 → C++ 后端）

C++ 后端不再 import Python 模块，而是直接加载本目录的静态 JSON 资产。
资产由 `tools/export_assets.py` 在仓库根目录生成（幂等，重复运行输出逐字节
一致；仅标准库 + backend/editor 自身，无需 pip）：

```
python tools/export_assets.py
```

| 文件 | 内容 | 来源 |
| --- | --- | --- |
| `schema.json` | `editor.core.game_schema.GAME_SCHEMA` 原样导出：`{表名: {字段: 类型}}`，406 个表名（其中非空 `*Cfg` 游戏配置表 303 个、非空 `*Attribute` 辅助表 4 个、空壳 `*Define` 占位 99 个），字段条目合计 1901 | 静态 dict |
| `dicts.json` | `GET /api/dicts` 响应体原样，顶层 key：`key_maps`(9) / `game_dicts`(14) / `story_dicts`(0)；items 369、roles 200、attrs 66、maps 21、bgs 525、turns 62、evt_types 65 条等 | 进程内隔离后端实测抓取 |

## dicts.json 的自包含性说明

`editor/core/data_dicts.py` 导入时会从 `csv_dicts/` 目录（`_resolve_csv_dict_dir()`
多候选路径）读取 ROLE/ATTR/ITEM/BG/MAP/STATE/TEXT/GAME/KZONE_*/PHONE_MSG/
CONDITION_TYPE/EFFECT_TYPE/…_SECONDARY/SECONDARY_CODE_ALL 等 CSV 并合并进字典。
本仓库当前 checkout 中不存在任何 `csv_dicts/` 目录（仅发行包
`参考资料/友商产品/_internal/csv_dicts` 内有原版，运行时不参与开发态解析），
因此导出结果 = 硬编码字典 + 空 CSV 合并，与开发环境 `GET /api/dicts` 实测完全一致。
导出走「真实起服务→请求端点」路径，动态读取结果已烘进 JSON；C++ 侧只需读
`dicts.json`，不需要（也不应）再实现 CSV 目录扫描。
若未来在任一候选路径放入 `csv_dicts/`，重跑导出脚本即可刷新本资产。

`game_dicts.audios` 在干净进程为空对象：它由 `STATE.base.data["AudioCfg"]`
派生（本体数据经 POST /api/base/load 装载后才非空）。契约端点（golden）同样
录制于未装载态，故 C++ 首启契约即 `audios: {}`；带本体数据时的动态扩展属
波次1+ 的 base-data 契约，不在本资产范围。

## 赞助图/图标 base64 外置调研（backend/editor/core/sponsor_data.py）

- 文件 2201 行、173,684 字符，仅含一个常量 `APP_ICON_B64`；base64 解码后为
  118,704 字节 PNG（magic `89504e47`），即应用图标原图。
- **消费方调查结果：Python 侧完全无人引用。**
  全仓 grep `sponsor_data` / `APP_ICON_B64` / `sponsor`（含 run_*.py、
  build_release.py、backend/**、frontend/lib 全部 Dart）：无任何 import、
  无任何 HTTP 端点读取该常量、前端也无对应字段消费。
  仅有的同名匹配是 `frontend/windows/runner/*` 与 `packaging/pyinstaller/
  backend.spec` 里的 `IDI_APP_ICON` / `APP_ICON` —— Flutter Windows 工程与
  PyInstaller 打包的原生 `.ico` 资源标识，与这个 Python 常量无关。
- 结论：它不是「经 HTTP 给 Flutter」的资产（无端点，故无 golden 可录；
  第 2 项录制清单不含相关端点），也不是 Python UI 直读，而是**当前无人引用的
  内嵌死数据**（推测为早期赞助/关于页图标方案的遗留）。迁移铺垫即本文档：
  C++ 侧不需要任何 base64 常量。

### C++ 侧外部二进制资源的挂载点

用外部二进制文件替代内嵌 base64 的落点约定：

```
native/assets/img/app_icon.png        # 由 sponsor_data.APP_ICON_B64 解码导出
```

一次性导出命令（仓库根目录，产物放 `native/assets/img/`，由后续波次实际
放置时执行；本波次按最小改动原则不预放二进制）：

```
python -c "import base64,sys; sys.path.insert(0,'backend'); \
from editor.core.sponsor_data import APP_ICON_B64; \
open('native/assets/img/app_icon.png','wb').write(base64.b64decode(APP_ICON_B64))"
```

挂载方式（二选一，C++ 侧实现时定）：
1. 随 CMake install / CPack 把 `native/assets/**` 整目录拷入发布目录，运行时
   以「可执行文件相对路径 assets/img/app_icon.png」读取；
2. 或以 CMake `add_custom_command(XXD/嵌入生成 .S/.h)` 把 PNG 编进二进制资源段
   （若要求单文件分发）。
桌面平台注意：Windows exe 图标继续用 `frontend/windows/runner/resources/app_icon.ico`
（Packaging 已接好，与本资产无关）；`APP_ICON_B64` 常量在 C++ 后端上线、Python
后端下线时随 `sponsor_data.py` 一并删除即可，无需等价移植。
