# 学生时代模组编辑器 — 多平台发行版构建

前端为 Flutter，后端为 Python（PyInstaller / Chaquopy）。后端以本地
`127.0.0.1:8765` HTTP 服务与前端通信，各平台启动方式一致。

除 GUI 外提供 CLI / TUI（`python run_cli.py`、`python run_tui.py`，详见
`CLI_TUI_GUIDE.md`），CLI 支持 `/update` 检查更新、`/agent` 直接进入 AI
对话；AI 助手（`agent`）与云同步（`cloud`）的配置为
GUI / CLI / TUI 三端共享（`.editor_ai.json` / `.editor_cloud.json`）。

## 功能一览

- **模组编辑**：GUI / CLI / TUI 三端编辑 `Cfgs/zh-cn/*.json` 与资源，
  Schema 驱动、校验、搜索、导入导出。
- **AI 助手**：对话式改模（工具调用 + 字段级 diff 审批），配置三端共享。
- **云同步**：WebDAV / OpenList / 百度网盘等 7 种驱动手动或实时同步 Mod。
- **插件系统**：第三方 Python 代码扩展——HTTP 端点 / AI Agent 工具 /
  GUI 面板 / CLI 命令，安装默认停用、**启用需高危确认**。详见
  [`PLUGIN_GUIDE.md`](PLUGIN_GUIDE.md)，完整范例见
  [`examples/plugins/hello_plugin`](examples/plugins/hello_plugin)。

## 支持平台

| 平台 | 产物 | 后端形态 |
| --- | --- | --- |
| Windows | `dist/*.zip` | PyInstaller `backend.exe`（子进程） |
| Linux | `dist/*-linux.zip` | PyInstaller `backend`（子进程） |
| macOS | `dist/*-macos.zip`（.app） | PyInstaller `backend`（内置于 .app） |
| Android | `dist/*-android.apk` | Chaquopy 内嵌 CPython |

> PyInstaller 不支持交叉编译，桌面发行版须在对应平台构建。

## 本地构建

依赖：Python 3.12 + `pyinstaller` + `unitypy`；Flutter SDK；各平台原生工具链。

```bash
# Windows（在 Windows 上）
python build_release.py --target windows --version Alpha-v0.1

# Linux（在 Linux / WSL 上）
python build_release.py --target linux --version Alpha-v0.1

# macOS（在 Mac 上）
python build_release.py --target macos --version Alpha-v0.1

# Android（先同步后端，再构建 APK）
python packaging/sync_android_python.py
cd frontend && flutter build apk --release --target-platform android-arm64,android-x64
```

跳过子步骤（复用上次产物）：`--skip-backend` / `--skip-frontend`。

### WSL（Ubuntu 24.04）构建 Linux
1. 首次环境准备：`packaging/wsl_setup.sh`（安装工具链 + Flutter + Python venv）。
2. 同步代码到 WSL ext4，执行 `packaging/wsl_build_linux.sh`。
   > WSL NAT 模式下用不了宿主机的 localhost 代理，脚本已切换
   > `PUB_HOSTED_URL`/`FLUTTER_STORAGE_BASE_URL` 到国内镜像。

## GitHub Actions 自动出包

推 tag（`Alpha-v0.1` 等）或手动 `workflow_dispatch` 触发
`.github/workflows/release.yml`，矩阵同时构建 Windows / Linux / macOS / Android，
产出 zip / apk 并自动创建 GitHub Release（含发布说明）。

## 注意事项
- Android：Python 3.12 仅支持 64 位 ABI；已在 `gradle.properties` 关闭 Flutter
  的 ABI 强制注入，并在 `app/build.gradle.kts` 限定 `arm64-v8a, x86_64`。
- Android 缺纹理(ASTC/ETC/BC)/FSB 音频原生解码器，相关导出暂不可用（见
  `sync_android_python.py` 生成的占位模块），核心 JSON 编辑不受影响。
- macOS 为 ad hoc 签名，分发前可在 CI 接入签名/公证。
