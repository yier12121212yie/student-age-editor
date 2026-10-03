# 人物图片资源扩展 · 自托管服务器配置

编辑器「人物资源库」（经典「人物综合配置」页）按 `PersonCfg.url`（小学立绘）
与 `PersonCfg.url2`（中学立绘）展示角色立绘。立绘纹理默认来自游戏资源或
本地/内置资源包；对**没有游戏资源的服务器/网页版**，可另行提供**人物图片
资源扩展**，由 `/api/aa/preview` 在活动资源包未命中时回退：本地目录直接
返回图片字节，对象存储只返回公开 URL，由**客户端**自行 GET 取图（服务端不
代下载整张图）。

支持两种安装方式（可同时配置，本地优先）：

| 方式 | 配置键 | 后端环境变量 | 数据来源 |
| --- | --- | --- | --- |
| 1. 安装到本地 | `portraits.dir` | `EDITOR_PORTRAIT_DIR` | 服务器磁盘上已解包的立绘目录（`tex/` 布局，与资源包一致） |
| 2. 对象存储 | `portraits.base_url` | `EDITOR_PORTRAIT_BASE_URL` | 任意对象存储的公开基址，按 `<base_url>/tex/<key>.webp` 取图 |

两种方式都会透传给网关 fork 的每个账号 `backend` 实例。

## 1. 生成立绘包

在**装有《学生时代》**的 Windows 机器上（需 UnityPy + Pillow）：

```bash
# 默认游戏目录由 Steam 库探测；也可显式 --aa-dir "D:\Program Files\Steam\steamapps\common\StudentAge"
python packaging/export_portrait_pack.py --out dist/portrait_pack.zip
# 等价：py -m resource_scan decoded-pack -- --tier portraits --out dist/portrait_pack.zip
```

产物 zip：`manifest.json`（`kind=portraits`）、`aa_index.json`（v3 decoded）、
`tex/<key>.webp`。解包后即为 `portraits.dir` 期望的目录；`tex/` 目录整个上传
对象存储即为方式 2 的数据源。

## 2. 配置 gateway.json

```json
{
  "portraits": {
    "dir": "/opt/editor/portraits",
    "base_url": "https://editor-assets.example.com/portraits"
  }
}
```

- `dir` 留空 = 不用本地方式；`base_url` 留空 = 不用对象存储方式。
- 两者都留空 = 关闭（默认）。
- 也可以不写 `portraits`，改由 systemd 单元的 `Environment=EDITOR_PORTRAIT_DIR=...`
  / `Environment=EDITOR_PORTRAIT_BASE_URL=...` 注入（网关会把父进程环境透传给
  实例）。
- 修改 `gateway.json` 后需重启网关（`docker compose restart` 或
  `systemctl restart editor-gateway`）。

## 3. 对象存储布局约定

```
<base_url>/tex/<name>.webp      # name = key 归一（小写、去扩展名、非 [a-z0-9._-] → _）
```

后端会按 `<base_url>/tex/<safe_name>.webp` 生成 URL 并回给客户端（`safe_name`
= key 归一后非 `[a-z0-9._-]` → `_`），由客户端直接 GET。对象存储需允许匿名
`GET`（公开桶或 CDN），不支持私有桶签名。web 端用 HTML `<img>` 元素加载，
因此对象存储**无需额外配置 CORS**。建议直接把 `portrait_pack.zip` 解包后的
`tex/` 目录上传为 `<base_url>/tex/`。

## 4. 桌面端（Windows 安装包）

`packaging/installer/setup.iss` 的「人物图片资源扩展包」可选组件把同一 pack
装到 `{app}\_cache\resource_packs\portraits`；构建期由 `build_release.py` 调
`export_portrait_pack.py` 生成（无游戏/依赖时自动隐藏该组件）。
