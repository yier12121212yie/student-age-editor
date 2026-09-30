# 学生时代模组编辑器 — 多平台发行版构建

前端为 Flutter，后端为 **native C++**（源码在 `native/`，CMake 构建，不依赖 Python
运行时）。后端以本地 `127.0.0.1:8765` HTTP 服务与前端通信，各平台启动方式一致；
HTTP API 契约与旧 Python 版保持兼容，并随功能持续扩展（GUI / CLI / TUI 三端共用
同一后端），Flutter 前端零改动。

除 GUI 外提供 CLI / TUI，发行产物为三个**相互独立**的可执行文件：`backend`
（HTTP 服务）、`backend_cli`（CLI）、`backend_tui`（TUI）；Windows 下带 `.exe`
后缀。CLI/TUI 不再是 `backend tui` / `backend cli` 子命令（旧 Python 版的
`run_cli.py` / `run_tui.py` 与 `editor_cmd.exe` 已随 Python 后端退役）。详见
[`CLI_TUI_GUIDE.md`](CLI_TUI_GUIDE.md)。AI 助手与云同步的配置文件
（`.editor_ai.json` / `.editor_cloud.json`）位置不变；TUI 另支持
`--agent-config` / 环境变量注入 AI 配置。

## 功能一览

- **模组编辑**：GUI / CLI / TUI 三端编辑 `Cfgs/zh-cn/*.json` 与资源，
  Schema 驱动、校验、搜索、导入导出。
- **无代码模式（三端共享开关）**：打开后不必手写效果码 DSL——效果/条件字段聚焦
  即出候选（空输入给「最近使用 + 目录」默认候选，支持中文与模糊匹配），带参数的
  候选接受后 GUI 弹参数表单、TUI 进二级槽列表按字典池选值（CLI 给候选与中文描述，
  槽位按提示手改）；人物字段走带立绘缩略图的浏览面板（GUI 网格，TUI·CLI 列表）。
  入口：GUI 设置页、TUI `Ctrl-N`、CLI `settings no-code on|off|show` 与 REPL
  `/settings`；开关持久化在后端 `editor_env.json`，三端读同一份。补全排序同步升级
  （高频/最近使用加权）。
- **白日模式（GUI 外观）**：外观可跟随系统 / 强制亮色 / 强制暗色。亮色不是反相，
  是另配一套白底深字调色板（图形元素同步提/降明度），正文与小字对比度按 WCAG AA
  由 `frontend/test/app_theme_test.dart` 守门；自定义控件一律从调色板取色，
  写死颜色会被 `frontend/test/light_theme_audit_test.dart` 拦下。入口：GUI 设置页
  「外观」；值持久化在后端 `editor_env.json`（键 `appearance_mode`），经
  `GET/PUT /api/settings/editor` 读写。终端（CLI/TUI）暂只出暗底色表，外观切换
  尚未接线。
- **AI 助手**：GUI 对话式改模（工具调用 + 字段级 diff 审批）；TUI 内置轻量
  AI 对话面板（`openai_compatible` 协议、纯对话），二者共用配置约定。
- **云同步**：GUI 提供 WebDAV / OpenList / 百度网盘等 7 种驱动，手动或实时同步
  Mod；CLI（`backend_cli cloud …`）与 TUI（`c` 云同步页）均已移植，详见
  [`CLI_TUI_GUIDE.md`](CLI_TUI_GUIDE.md)。
- **插件系统**：**声明型**插件——插件是「目录 + `manifest.json`」的静态声明，
  编辑器不加载插件代码；可声明流程卡片（flow card）与 UI 面板。需要代码贡献时
  用 **HTTP 服务插件**（已实现）：插件作为独立进程监听 loopback，后端只做聚合
  与代理，服务进程需自行启动（见 `PLUGIN_GUIDE.md` §5）。
  **无启用 / 停用状态（安装即可用，常开）**。三端管理入口：GUI 插件页、
  CLI `backend_cli plugin list|install|uninstall|reload|tools`、TUI `p` 插件弹窗。
  详见 [`PLUGIN_GUIDE.md`](PLUGIN_GUIDE.md)，规范以
  [`native/PLUGIN_SPEC.md`](native/PLUGIN_SPEC.md) 为唯一真相源。
- **检查更新（三端）**：查询 GitHub Releases 最新发行版并与本机版本比较——版本
  抓取与比较都在后端 `GET /api/update/check`（三端同一套规则），本机版本由构建期
  `-DSA_APP_VERSION` 注入、经 `GET /api/version` 读取。入口：GUI 设置页
  「关于 · 检查更新」（手动 + 启动静默检查，最多 24 小时一次，可「跳过此版本」）、
  CLI `backend_cli update check` 与 REPL `/update`、TUI `u` 弹窗。**不做自动
  更新**：发现新版本只展示发行说明与发行页链接（可一键复制到浏览器），下载安装仍走人工。
- **网页版（本机浏览器 / 自托管 Linux）**：同一 native 后端的浏览器形态——本机
  `backend --web-root` 打开即用，或 Linux 上 `backend_gateway` 多账号自托管；
  详见 [`WEB_GUIDE.md`](WEB_GUIDE.md)（随本里程碑交付生效）。

## 支持平台

| 平台 | 产物 | 后端形态 |
| --- | --- | --- |
| Windows | `dist/*.zip` | native C++ 三件套 `backend.exe` / `backend_cli.exe` / `backend_tui.exe`（子进程 + 本地 HTTP） |
| Linux | `dist/*-linux.zip` | native C++ 三件套 `backend` / `backend_cli` / `backend_tui`（子进程 + 本地 HTTP） |
| macOS | `dist/*-macos.zip`（.app） | native C++ 三件套（内置于 .app/Contents/MacOS） |
| 网页版（本机浏览器） | `web-app.zip`（独立发行，不在桌面包内） | 本机 `backend --web-root <目录>`，浏览器打开 `http://127.0.0.1:8765` |
| 网页版（自托管 Linux） | server-linux 包 | `backend_gateway`（Caddy TLS 反代 + 每账号一个懒启动 `backend` 实例） |
| Android | `dist/*-android.apk` | native `libbackend_shared.so` + JNI（应用进程内 `nativeStart`，无独立进程、无 CPython） |

> native 后端由 CMake 构建，桌面发行版须在对应平台构建（不支持交叉编译）。
> Android 的 `.so` 由 NDK 交叉编译（`native/android/android_build.sh`）。

## 本地构建

依赖：CMake + Ninja + C++20 编译器（Windows 用 MSVC / VS BuildTools；
Linux / macOS 用 g++ 或 clang++）；Flutter SDK。可选冻结 `aa_scan` 资源扫描
工具时另需 Python 3.12 + `pyinstaller` + `unitypy`（缺失时仅本次不随包，不阻塞）。

```bash
# Windows（在 Windows 上）
python build_release.py --target windows --version Alpha-v0.1

# Linux（在 Linux / WSL 上）
python build_release.py --target linux --version Alpha-v0.1

# macOS（在 Mac 上）
python build_release.py --target macos --version Alpha-v0.1

# Android（先交叉编译 native 后端 .so，再构建 APK）
bash native/android/android_build.sh
cd frontend && flutter build apk --release --target-platform android-arm64,android-x64
```

跳过子步骤（复用上次产物）：`--skip-backend` / `--skip-frontend`。
CI 预构建场景可用 `--prebuilt-backend <dir>` 传入现成的 native 三件套目录，
跳过本地 CMake 构建。手动构建 native 后端与跑测试：Windows `native/build.cmd`，
Linux / macOS `native/build.sh`（构建 `backend` / `backend_cli` / `backend_tui`
与 Catch2 测试 `sa_tests`；加 `--no-tests` 跳过测试、`--target backend` 只编
后端目标）。

## 从源码启动（开发模式）

仓库根一键入口（纯标准库 Python，Windows / Linux / macOS 通用）：

```bash
python run_dev.py                # 缺则自动构建后端 → 拉起后端 → flutter run
python run_dev.py -d windows     # 其余参数原样透传给 flutter run
python run_dev.py --build        # 强制增量重编 backend 目标
python run_dev.py --no-backend   # 不代起后端（由 debug 前端自动拉起源码构建产物）
```

分步做法（与脚本等效）：

1. `native/build.cmd`（或 `native/build.sh`）构建后端，产物在
   `native/build/bin/backend[.exe]`；
2. `cd frontend && flutter run`——debug 构建的后端探测会回退到源码构建产物
   （`native/build/bin` 或 `build-native/bin`，资源目录 `native/assets` 由
   后端从 exe 目录逐级向上自动解析），无需拷贝到前端产物目录；
3. 若后端尚未构建，启动失败页上有「编译并启动后端」按钮，点击即自动增量
   编译（`--no-tests --target backend`）并拉起。

> 源码回退仅在 debug 构建生效；发行版仍只认「与主程序同目录的 backend.exe」，
> 也可用环境变量 `STUDENT_AGE_BACKEND_EXE` 显式指定后端路径。

### WSL（Ubuntu 24.04）构建 Linux
1. 首次环境准备：`packaging/wsl_setup.sh`（安装 clang / cmake / ninja 工具链 +
   Flutter + Python venv + pyinstaller / unitypy）。
2. 同步代码到 WSL ext4，执行 `packaging/wsl_build_linux.sh`。
   > WSL NAT 模式下用不了宿主机的 localhost 代理，脚本已切换
   > `PUB_HOSTED_URL`/`FLUTTER_STORAGE_BASE_URL` 到国内镜像。

## GitHub Actions 自动出包

推 tag（`Alpha-v0.6` 等）或手动 `workflow_dispatch` 触发
`.github/workflows/release.yml`，矩阵同时构建 Windows / Linux / macOS / Android，
产出 zip / apk 并自动创建 GitHub Release（含发布说明）。native 后端的独立
构建 / 测试由 `.github/workflows/native-ci.yml` 负责。

## 注意事项
- Android：native 后端 `.so` 仅提供 64 位 ABI（arm64-v8a / x86_64）；已在
  `gradle.properties` 关闭 Flutter 的 ABI 强制注入，并在
  `app/build.gradle.kts` 限定 `arm64-v8a, x86_64`。
- Android 不内置纹理(ASTC/ETC/BC)/FSB 音频的原生解码库，相关压缩资源的解码/
  导出暂不可用（需改用桌面侧导出的预解码资源包），核心 JSON 编辑与资源浏览不受影响。
- `aa_scan` 是当前唯一保留的 Python 组件（独立工具，与后端进程无关）：
  `aa_scan index --aa <AA目录> --out <目录>` / `aa_scan base-tables --aa <目录> --out <目录>`。
- 安全基线（细节与剩余风险见 `SECURITY_AUDIT_REPORT.md`）：后端默认只绑定
  `127.0.0.1` 并自动生成 `.backend_token` API 令牌（`X-Backend-Token` 头）；
  出站 HTTP 默认不跟随重定向，云同步在 `--cloud-public-only` 下对每一跳重定向
  复查公网地址；发布物以 SHA-256 清单发布。
- macOS 为 ad hoc 签名（未做 Apple 公证）：`assemble_macos` 在注入内置
  backend 与 official_pack 后统一做由内向外重签（不用 `--deep`），DMG/PKG
  构建脚本同样重签并校验封印，故 app 签名封印完整；便携 zip 用 `ditto`
  打包以保留符号链接与扩展属性。用户从浏览器下载后文件带隔离标记，首次打开
  若提示「已损坏，无法打开」，执行
  `xattr -dr com.apple.quarantine "/Applications/学生时代模组编辑器.app"`
  即可，详见 `packaging/notes/使用说明-macos.txt`。需彻底免除此提示，请在 CI
  配置 Developer ID 证书与公证后再发布。
# Bug Hunt Test

全量用户视角 bug 测试（CLI/TUI/GUI 三端 + 自动化基线）结论见 [BUG_HUNT_REPORT.md](BUG_HUNT_REPORT.md)。
