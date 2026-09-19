# 学生时代模组编辑器 — 多平台发行版构建

前端为 Flutter，后端为 **native C++**（源码在 `native/`，CMake 构建，不依赖 Python
运行时）。后端以本地 `127.0.0.1:8765` HTTP 服务与前端通信，各平台启动方式一致；
HTTP API 契约与旧 Python 版保持兼容（104 端点），Flutter 前端零改动。

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
- **AI 助手**：GUI 对话式改模（工具调用 + 字段级 diff 审批）；TUI 内置轻量
  AI 对话面板（`openai_compatible` 协议、纯对话），二者共用配置约定。
- **云同步**：GUI 提供 WebDAV / OpenList / 百度网盘等 7 种驱动，手动或实时同步
  Mod；CLI/TUI 的云同步命令尚未移植（见 `CLI_TUI_GUIDE.md`）。
- **插件系统**：**声明型**插件——插件是「目录 + `manifest.json`」的静态声明，
  不执行任何代码；可声明流程卡片（flow card）与 UI 面板（外部 HTTP 服务插件
  为规范先行、尚未实现）。**无启用 / 停用状态（安装即可用，常开）**。详见
  [`PLUGIN_GUIDE.md`](PLUGIN_GUIDE.md)，规范以
  [`native/PLUGIN_SPEC.md`](native/PLUGIN_SPEC.md) 为唯一真相源。

## 支持平台

| 平台 | 产物 | 后端形态 |
| --- | --- | --- |
| Windows | `dist/*.zip` | native C++ 三件套 `backend.exe` / `backend_cli.exe` / `backend_tui.exe`（子进程 + 本地 HTTP） |
| Linux | `dist/*-linux.zip` | native C++ 三件套 `backend` / `backend_cli` / `backend_tui`（子进程 + 本地 HTTP） |
| macOS | `dist/*-macos.zip`（.app） | native C++ 三件套（内置于 .app/Contents/MacOS） |
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
与 Catch2 测试 `sa_tests`）。

### WSL（Ubuntu 24.04）构建 Linux
1. 首次环境准备：`packaging/wsl_setup.sh`（安装 clang / cmake / ninja 工具链 +
   Flutter + Python venv + pyinstaller / unitypy）。
2. 同步代码到 WSL ext4，执行 `packaging/wsl_build_linux.sh`。
   > WSL NAT 模式下用不了宿主机的 localhost 代理，脚本已切换
   > `PUB_HOSTED_URL`/`FLUTTER_STORAGE_BASE_URL` 到国内镜像。

## GitHub Actions 自动出包

推 tag（`Alpha-v0.1` 等）或手动 `workflow_dispatch` 触发
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
- macOS 为 ad hoc 签名（未做 Apple 公证）：`assemble_macos` 在注入内置
  backend 与 official_pack 后统一做由内向外重签（不用 `--deep`），DMG/PKG
  构建脚本同样重签并校验封印，故 app 签名封印完整；便携 zip 用 `ditto`
  打包以保留符号链接与扩展属性。用户从浏览器下载后文件带隔离标记，首次打开
  若提示「已损坏，无法打开」，执行
  `xattr -dr com.apple.quarantine "/Applications/学生时代模组编辑器.app"`
  即可，详见 `packaging/notes/使用说明-macos.txt`。需彻底免除此提示，请在 CI
  配置 Developer ID 证书与公证后再发布。
# Bug Hunt Test
