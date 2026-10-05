# 背景图片资源扩展 · 自托管服务器配置

编辑器「背景展示」（资源页「背景」页签）按 `BgCfg.url`（去 `bg/` 前缀后的
tex key）展示场景背景。背景纹理默认来自游戏资源或本地/内置资源包；对**没有
游戏资源的服务器/网页版**，可另行提供**背景图片资源扩展**，由
`/api/aa/preview` 在活动资源包未命中时回退：本地目录直接返回图片字节，对象
存储只返回公开 URL，由**客户端**自行 GET 取图（服务端不代下载整张图）。

其链路与「人物图片资源扩展」完全同构（见 [`PORTRAITS.md`](PORTRAITS.md)），
只是环境变量换成了 `EDITOR_BG_DIR` / `EDITOR_BG_BASE_URL`。

支持两种安装方式（可同时配置，本地优先）：

| 方式 | 配置键 | 后端环境变量 | 数据来源 |
| --- | --- | --- | --- |
| 1. 安装到本地 | `backgrounds.dir` | `EDITOR_BG_DIR` | 服务器磁盘上已解包的背景目录（`tex/` 布局，与资源包一致） |
| 2. 对象存储 | `backgrounds.base_url` | `EDITOR_BG_BASE_URL` | 任意对象存储的公开基址，按 `<base_url>/tex/<key>.webp` 取图 |

两种方式都会透传给网关 fork 的每个账号 `backend` 实例。

## 1. 生成背景包

**推荐（无游戏也能成包）**：直接吃参考资料里已解码的背景图片目录：

```bash
python packaging/export_background_pack.py
# 等价：python packaging/export_background_pack.py --from-dir 参考资料/背景 --out dist/background_pack.zip
# 底层：py -m resource_scan decoded-pack -- --tier backgrounds --from-dir 参考资料/背景 --out dist/background_pack.zip
```

未显式指定来源时，脚本会自动探测 `参考资料/背景`；目录不存在则回落到游戏
bundle（装有《学生时代》的 Windows 机器 + UnityPy/Pillow）：

```bash
python packaging/export_background_pack.py --aa-dir "D:\...\StudentAge" --out dist/background_pack.zip
# 等价：py -m resource_scan decoded-pack -- --tier backgrounds --out dist/background_pack.zip
```

产物 zip：`manifest.json`（`kind=backgrounds`）、`aa_index.json`（v3 decoded）、
`tex/<key>.webp`。解包后即为 `backgrounds.dir` 期望的目录；`tex/` 目录整个上传
对象存储即为方式 2 的数据源。

## 2. 配置 gateway.json

```json
{
  "backgrounds": {
    "dir": "/opt/editor/backgrounds",
    "base_url": "https://editor-assets.example.com/backgrounds"
  }
}
```

- `dir` 留空 = 不用本地方式；`base_url` 留空 = 不用对象存储方式。
- 两者都留空 = 关闭（默认）。
- 也可以不写 `backgrounds`，改由 systemd 单元的 `Environment=EDITOR_BG_DIR=...`
  / `Environment=EDITOR_BG_BASE_URL=...` 注入（网关会把父进程环境透传给
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
因此对象存储**无需额外配置 CORS**。建议直接把 `background_pack.zip` 解包后的
`tex/` 目录上传为 `<base_url>/tex/`。

## 4. 桌面端（Windows 安装包）

`packaging/installer/setup.iss` 的「背景图片资源扩展包」可选组件把同一 pack
装到 `{app}\_cache\resource_packs\backgrounds`；构建期由 `build_release.py` 调
`export_background_pack.py` 生成（参考资料/背景 或游戏依赖缺失时自动隐藏该
组件）。
