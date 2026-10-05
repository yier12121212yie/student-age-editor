# 扩展系统（资源包 + 插件合并）

> 自本次合并起，**资源包（resource pack）与插件（plugin）统一为「扩展」**：
> 同一个列表、同一套启用模型、同一个管理页。既有 `/api/plugins` 与
> `/api/resource_packs` 端点保持兼容（形状不变），新代码应使用 `/api/extensions`。

## 1. 模型

一个「扩展」= 一个目录 + `manifest.json`，可同时携带：

| 贡献 | 内容 | 目录探测 |
| --- | --- | --- |
| 界面插件 | `ui.flow_cards` / `ui.panels`、`service`（HTTP 服务插件） | `manifest.json` |
| 资源包 | `aa_index.json`、`base_data.json`、`Cfgs/`、`tex/`、`aud/` | 同名文件/目录是否存在 |

- **统一根**：`EDITOR_PLUGINS_ROOT`（默认 `<editor_root>/plugins`）。统一安装
  （`/api/extensions/install*`）落此根。
- **兼容根**：资源包仍可经 `/api/resource_packs/*` 安装到
  `EDITOR_PACKS_ROOT`（默认 `<editor_root>/_cache/resource_packs`）；两个根都会被
  扫描、其启用目录都参与资源解析（`aa`）。
- 同名扩展：插件根优先。

## 2. 启用模型（多选）

- **插件默认启用**；**资源包默认不启用**（opt-in）。
- 启用列表：
  - 插件：`<plugins_root>/plugins.json` -> `{"enabled":[id, ...]}`；文件缺失
    == 全部启用（默认启用）。
  - 资源包：沿用 `packs.json` 的 `active_ids`（同时保留兼容字段 `active`=首项）。
- 资源解析（`/api/aa/*`）与插件 UI 聚合（`/api/plugins/ui*`、
  `/api/plugins/agent/tools`）都只消费「已启用」的扩展。

## 3. HTTP 端点

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/extensions` | `{enabled:[...], extensions:[{id,name,version,author,description,kind,source,enabled,builtin,resources:{aa,base,cfgs,tex,aud}}]}` |
| POST | `/api/extensions/active` | `{"ids":[...]}` 设置启用集（兼容 `{"id":"..."}`）；未知 id -> 400 |
| POST | `/api/extensions/install` | base64 zip（`{data, filename}`），落 `plugins_root` |
| POST | `/api/extensions/install_path` | 本机路径 zip（托管网关禁用，见下） |
| POST | `/api/extensions/install_upload` | 网页版 `{filename, data_base64}` |
| POST | `/api/extensions/reload` | 重扫目录 + 重拉 §4 服务自描述 |
| GET | `/api/extensions/<id>` | 统一详情 |
| DELETE | `/api/extensions/<id>` | 插件删目录 / 资源包删包 |

安装/卸载后，新装插件默认启用并从启用列表移除被卸载者。

## 4. 兼容

- `GET /api/plugins` 与 `GET /api/resource_packs` 的响应形状**不变**（既有
  goldens/前端可用）。插件条目的 `enabled`/`loaded` 现在反映启用态。
- `POST /api/plugins/<pid>/enable|disable` 仍返回 410；请改用
  `/api/extensions/active`。
- 设置页「扩展 (Zip)」与资源包管理页、插件侧栏现共用统一页
  （`frontend/lib/features/extensions/extensions_page.dart`）。

## 5. for-server / 托管网关

- `/api/extensions/install_path` 接受调用方提供的本机路径，托管模式下与
  `/api/plugins/install_path`、`/api/resource_packs/import_path` 一样被网关
  **禁用**（`native/gateway/gw_proxy.cpp` 的 `kPathImportPrefixes`）。
- 网页版请用 `install_upload`（字节走 body）。
- 人物图片资源扩展见 [`gateway/PORTRAITS.md`](gateway/PORTRAITS.md)。
- 背景图片资源扩展见 [`gateway/BACKGROUNDS.md`](gateway/BACKGROUNDS.md)。
