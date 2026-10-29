# C++ / Python 依赖审计与重构代价评估

> 审计对象：`D:\workspace\editor` 当前工作树（HEAD `1a00d75`，含未提交改动）
> 审计日期：2026-10-27
> 口径：只统计 git 跟踪或工作树内的自有源码；排除 `native/third_party/`、`build*/`、`dist/`、`frontend/build/`、`参考资料/`（本地参考资料，未入 git）。
> 行数含注释与空行，用于横向比较，不代表有效代码量。

---

## 0. 结论摘要

**一句话：C++ 是承重墙，Python 是脚手架。拆脚手架便宜且有收益；拆承重墙等于重建整栋楼。**

| 维度 | C++ | Python |
| --- | --- | --- |
| 自有代码量 | **76,488 行 / 252 文件**（占全部自有代码约 35%） | **9,043 行 / 34 文件**（约 4%） |
| 运行时进程 | **100%**：`backend` / `backend_cli` / `backend_tui` / `backend_gateway` / Android `.so` | **0**：无 Python 进程；仅可选随包工具 `aa_scan` |
| 构建链 | **必需**：CMake 3.21+ / C++20 / MSVC 或 clang | **必需**：`build_release.py` + PyInstaller（仅发布时） |
| 测试体系 | **主体系**：Catch2 599 个 `TEST_CASE`、5,270 个断言、38 份 golden JSON | **辅助**：约 2.8k 行黑盒/契约脚本；`native-ci` 未跑 |
| 分发物 | 3 个可执行文件（合计约 5–9 MB）+ `libbackend_shared.so` + gateway | 1 个可选 `aa_scan.exe`（缺失时静默降级） |
| 可替换性 | **极低**：替换 = 重写后端 | **中**：工具链可替代，Unity 资产解析是真正难点 |
| 结论 | 核心资产，短期不应重写 | 可收敛的辅助依赖，建议"去 Python 化" |

**代价速览（中性口径，详见第 6 节）：**

| 目标 | 人力当量 | 本仓库 AI 并行节奏下的日历 | 风险 |
| --- | --- | --- | --- |
| 只去 Python，保留预编译 `aa_scan` | **1.8 人月** | 3–5 周 | 低 |
| 去 Python 且自研 Unity 资产解析 | **7.0 人月** | 2–3 个月 | 中高 |
| C++ 仅后端 → Rust（server+core+gateway，含测试/发布） | **9–16 人月** | 4–5 个月 | 高 |
| C++ 全量 → Rust（含 CLI/TUI/Android/测试） | **10–22 人月**（中性 15） | 4–6 个月 | 很高 |
| 前后端统一到 Dart/Flutter | **20–28 人月** | 8–12 个月 | 极高 |

**建议（第 8 节展开）：**
1. **不重写 C++ 后端**。收益（内存安全、招人）可以用 1–2 人月的加固（ASan/UBSan、fuzz、静态分析）拿到大部分，而不是 15 人月。
2. **把 Python 从"发布必经路径"降级为"固定版本的 CI 工具"**，优先做依赖锁定、`aa_scan` 预编译产物化、过期 UX 文案修正（1.5–2.5 人月）。
3. **不要让 Python 继续扩散**；也不要把后端逻辑搬进 Flutter/Dart，那会把一个干净的 HTTP 边界变成进程内强耦合。

---

## 1. 审计口径

```text
自有代码总盘子（约 217k 行）
├─ Dart/Flutter   132k 行（约 61%）  frontend/lib 102k + frontend/test 30k
├─ C++            76.5k 行（约 35%） native/（不含 third_party/build）
└─ Python         9.0k 行（约 4%）   构建、资产、测试、MCP、代码生成
```

- C++：`native/` 下 147 个 `.cpp` + 105 个 `.h`，共 252 个文件；不含 235 个 vendored 第三方文件（约 97k 行）。
- Python：34 个 git 跟踪的 `.py`，全部为工具/脚本/测试，**没有任何生产运行时模块**。
- 前端：`frontend/lib` 内没有 `dart:ffi`，没有直接加载 `.so`/`.dll`；与后端唯一的契约是 HTTP（168 条路由 + `X-Backend-Token`）。
- 已删除的 Python 后端（`backend/editor/**`）不计入当前代码量，但作为历史校准与"事实规范"在第 6.5 节单独讨论。

---

## 2. 依赖分层全景

| 层 | C++ 参与 | Python 参与 | 说明 |
| --- | --- | --- | --- |
| 用户运行时（桌面 GUI） | 是（子进程） | 否 | Flutter 拉起 `backend.exe`，走 `127.0.0.1:8765` |
| 用户运行时（CLI/TUI） | 是（同一套 HTTP 客户端） | 否 | `backend_cli` / `backend_tui` 是独立进程 |
| 用户运行时（Android） | 是（`.so` + JNI 进程内） | 否 | 无 CPython、无独立后端进程 |
| 网页版 / 在线托管 | 是（`--web-root` 静态托管；gateway 反向代理） | 否 | Linux 上 `backend_gateway` + Caddy |
| 资源扫描（可选功能） | 否（只读产物 JSON） | 是（`aa_scan.exe`，PyInstaller 冻结） | 缺失时 AA 资源功能不可用，其余功能正常 |
| 开发构建 | 是（CMake/Ninja） | 是（`run_dev.py` 便利脚本，可绕过） | `native/build.cmd` 本身不需要 Python |
| 发布构建 | 是（CMake） | **是（唯一编排器）** | `build_release.py` 负责 5 个平台产物 |
| 测试 | 是（Catch2 主体系） | 是（黑盒/契约/golden 辅助） | `native-ci` 只跑 ctest + curl 冒烟 |
| 代码生成 | 产物已入库 | 是（`tools/gen_field_*.py`） | 输入依赖未入库的 `参考资料/` |

---

## 3. C++ 依赖解剖

### 3.1 规模与分布

| 模块 | 文件数 | 行数 | 占比 | 性质 |
| --- | --- | --- | --- | --- |
| `native/server`（含 `services/`） | 128 | 37,714 | 49.3% | HTTP 服务、168 条路由、业务逻辑 |
| `native/tests` | 51 | 19,714 | 25.8% | Catch2 单元/集成/黑盒性能 |
| `native/tui` | 15 | 6,690 | 8.7% | FTXUI 终端界面（独立 HTTP 客户端） |
| `native/cli` | 7 | 4,954 | 6.5% | CLI + REPL（独立 HTTP 客户端） |
| `native/core` | 29 | 3,751 | 4.9% | 路径、编码、JSON、哈希、HTTP 客户端 |
| `native/gateway` | 17 | 3,078 | 4.0% | Linux 在线托管网关（账号/代理/会话） |
| `native/android` | 5 | 587 | 0.8% | JNI 桥 + NDK 构建 |
| **合计** | **252** | **76,488** | 100% | 其中非测试生产代码 **56,774 行** |

补充：Flutter 桌面壳还有标准模板 C++（`frontend/windows` 约 568 行），Android 有 Kotlin 301 行 + JNI。这些是平台壳，不是业务依赖。

### 3.2 交付形态

| 产物 | 体积 | 平台 | 作用 |
| --- | --- | --- | --- |
| `backend.exe` | 约 2–3.8 MB | Win/Linux/macOS | HTTP API 服务（核心） |
| `backend_cli.exe` | 约 2–4.1 MB | Win/Linux/macOS | CLI / REPL |
| `backend_tui.exe` | 约 0.9–1.0 MB | Win/Linux/macOS | 终端 UI |
| `libbackend_shared.so` | 约 388 KB | Android arm64/x86_64 | 进程内后端（JNI） |
| `backend_gateway` | — | Linux | 反向代理 + 多租户账号 |

关键事实：**后端是静态编译的单文件，无运行时依赖、无包管理器、无 JVM/Node/CPython**。这是它能同时覆盖桌面 + Android + 网页托管的主要原因。

### 3.3 功能面（168 条路由）

| 方法 | 数量 |
| --- | --- |
| POST | 79 |
| GET | 73 |
| PUT | 9 |
| DELETE | 7 |
| **合计** | **168** |

按业务域拆分（约数，按 `server/services` 行数归并）：

| 业务域 | 规模 | 代表能力 | 重写难度 |
| --- | --- | --- | --- |
| 配置读写 / 缓存 / 历史 / 回滚 | 约 2.2k | `cfg`、乐观锁 409、undo/redo、revision、tombstone | 中 |
| 语义 / 校验 / 修复 / 剧情图 | 约 4.8k | schema、dicts、validate、bugfix、linter、effect 解析 | 高（规则密集） |
| 模组 / 工作区 / 剧情 / 舞台 / 预览 | 约 5.9k | mods、workspace、story import/export、stage、preview | 高（zip/路径/兼容） |
| AA / 基底资源 | 约 2.3k | `aa_index`/`base_data` 消费、图片尺寸、导出 | 中（只读 JSON） |
| AI / TTS / Live2D | 约 2.1k | 多供应商 TTS、AI 图片、Live2D 离线渲染 | 高（外部 API + DLL） |
| 云同步 / 实时同步 | 约 6.2k | WebDAV、OpenList、百度网盘、S3 SigV4、COS 预签名 | 极高（7 家驱动） |
| 插件 / 扩展 / 资源包 / MCP / 工坊 | 约 4.5k | 声明型插件、zip 安装安全、MCP HTTP 端点 | 高（安全边界） |
| 文件流转 / 沙箱 | 约 2.3k | S3 分片上传、断点续传、路径沙箱 | 高 |
| 基础设施 | 约 2.1k | 手写 socket HTTP、连接池、异步 job、限流 | 极高（协议细节） |

### 3.4 真正"贵"的耦合点

1. **手写 HTTP 服务器**（`server/httpd.cpp`，1,086 行）：不是框架，自己实现 keep-alive、分块、multipart、Range、ETag、优雅退出、连接池、body 上限。任何语言重写都要重新踩一遍。
2. **双栈出站网络**（`core/http_client.cpp`，1,027 行）：Windows 走 WinHTTP（schannel TLS）；POSIX 运行时 `dlopen` 系统 libcurl；代理、重定向、SSRF 校验（`--cloud-public-only`）都在这层。
3. **平台与编码**：133 处 `_WIN32`、9 处 `__APPLE__`、9 处 `__ANDROID__`；Windows GBK/CP_UTF8 路径、POSIX `utimensat`、macOS `_NSGetExecutablePath`。
4. **闭源原生库**：`live2d_renderer.cpp` 动态加载 `Live2DCubismCore.dll`。任何目标语言都必须保留 FFI/动态加载，无法"纯语言"重写。
5. **Android 进程内后端**：`.so` + JNI + 平台 HTTP 桥。换成 Rust 可保留（NDK 支持好），换成 Go/Node 会明显更重。
6. **FTXUI TUI**（6,690 行）：目标语言没有 1:1 组件库，重写等于重做交互与视觉。
7. **第三方库全部 vendored、无包管理器**：nlohmann/json、cpp-httplib（仅测试）、Catch2、miniz、CLI11、FTXUI，共 6 个，许可证为 MIT/BSL/Apache/BSD。供应链简单，但升级靠手工 re-fetch。

### 3.5 平台覆盖与 CI

| 平台 | 构建 | 测试 | 备注 |
| --- | --- | --- | --- |
| Windows (MSVC) | 官方主通道 | 599 例全量 | 3 个测试 TU 仅 Windows |
| Linux (g++/clang) | 官方 | 排除 3 个 TU | `test_cfg_store` / `test_p4_aa` / `test_p3b_domain_tools` 因 Win32 API 被排除 |
| macOS (clang) | 官方（CI 为 informational） | 同上 | 需 libiconv、重签名 |
| Android (NDK) | `android_build.sh` | 无设备级自动化 | 仅 64 位 ABI |
| 网页版 | 复用 backend + 静态托管 | 冒烟 | 无独立后端 |

`native-ci.yml` 只跑 `ctest` + `curl` 冒烟；**没有 ASan/UBSan、没有 fuzz、没有 clang-tidy/cppcheck**（全仓 0 命中）。这是当前 C++ 体系最大的"廉价可改进项"。

### 3.6 为什么当年选 C++ 是合理的

- 一个 2–4 MB 级的可执行文件即可覆盖 Win/Linux/macOS，不需要用户装运行时；
- Android 用 `.so` 在进程内起服务，避免了 CPython/Chaquopy 的体积与启动问题（代码里明确记录了"去 Chaquopy"的迁移）；
- 与 Flutter 的边界是 HTTP，前端可独立演进；
- 已用 38 份 golden JSON + 599 例测试把行为冻结下来。

### 3.7 C++ 侧风险

| 风险 | 证据 | 影响 |
| --- | --- | --- |
| 内存/生命周期缺陷 | 历史提交修过悬垂引用、`httpd` use-after-free | 崩溃/安全问题 |
| 无 sanitizer/静态分析 | CI 0 命中 | 缺陷发现晚 |
| 平台分支多 | 133 处 `_WIN32` | 三平台行为漂移 |
| 构建门槛 | MSVC + CMake + Ninja + NDK，无包管理器 | 新人上手慢 |
| 人才池 | C++20 + 网络/跨平台 | 招聘与交接成本 |
| 文档与代码漂移 | 部分 UI 文案仍写"Python 运行时" | 误导维护者 |

---

## 4. Python 依赖解剖

### 4.1 规模与分类

**总计 9,043 行 / 34 文件**：

| 类别 | 行数 | 文件 | 是否随产品分发 | 是否在发布必经路径 |
| --- | --- | --- | --- | --- |
| 发布编排 + 打包 | 1,940 | `build_release.py`(1,341)、`run_dev.py`(150)、`packaging/*.py`(424)、`aa_scan_entry.py`(25) | 否 | **是**（唯一发布入口） |
| Unity 资产管线 | 2,676 | `tools/resource_scan/*`(2,551)、`packaging/export_*.py`(125) | 产物是；代码否 | 是（生成资源扩展包时） |
| 测试 / 契约 / 冒烟 | 3,320 | `native/tests/**/*.py`、`tools/record_golden.py` | 否 | 否（`native-ci` 不跑） |
| MCP stdio 桥 | 855 | `tools/mcp_bridge/*` | 否 | 否（HTTP `/api/mcp` 是正式通道） |
| 代码生成 | 181 | `tools/gen_field_rules.py`、`gen_field_help.py` | 产物已入库 | 否（手动执行） |
| 示例插件 | 71 | `examples/plugins/service_demo/service.py` | 示例 | 否 |

### 4.2 运行时依赖：0

- `native/server`、`native/cli`、`native/tui`、`native/gateway` 的源码中**没有任何 `system("python")`、`exec` 或嵌入解释器**；N-API/CPython 全部不存在。
- 分发目录 `build/release/backend_dist/` 只有 3 个 exe，没有任何 `python*.dll` / `_internal/`。
- Android 明确"无独立后端进程、无 CPython"（`.so` + JNI）。
- README 也把这句话写死了：**`aa_scan` 是当前唯一保留的 Python 组件（独立工具，与后端进程无关）**。

**"Python 明天消失"影响面：**

| 能力 | 影响 |
| --- | --- |
| 桌面 GUI / CLI / TUI / Android / 网页版 | 无影响 |
| 核心 JSON 编辑、配置表、模组、剧情 | 无影响 |
| 发布出包（5 个平台） | **停摆**（`build_release.py` 是唯一编排器） |
| 资源扫描 / AA 索引 / 基底表 | **降级**：已有产物可读；重新扫描不可用 |
| 资源扩展包（背景/立绘/解码包） | **停摆**（`export_*.py`） |
| 开发便利（`run_dev.py`） | 降级为手动 `native/build.cmd` + `flutter run` |
| 黑盒/契约/golden 脚本 | 停摆（但 CI 本来不跑） |
| MCP stdio 桥 | 停摆（HTTP `/api/mcp` 仍可用） |
| 字段帮助/规则生成 | 停摆（产物已入库，暂时不影响构建） |

### 4.3 唯一随包 Python：`aa_scan`

- 由 PyInstaller onefile 冻结 `tools/resource_scan`，支持 `index` / `base-tables` / `decoded-pack`。
- 安装器 `setup.iss` 以 `skipifsourcedoesntexist` 方式带上；构建失败只打印警告并降级为"本次发行不带 `aa_scan`"，**不阻塞主链路**。
- C++ 后端**从不解析 Unity bundle**，只消费 `aa_index.json` / `base_data/*.json` / `decoded pack` 的 JSON 契约。这是当初能删掉 Python 后端的关键设计。

### 4.4 资产管线才是 Python 的真正护城河

`tools/resource_scan` 不是"薄脚本"，它包含：

- `unityfs_res.py`（687 行）：UnityFS/SerializedFile 解析、bundle 依赖 BFS、path_id 定位；
- `decoded_export.py`（653 行）：UnityPy + PIL + `fmod_toolkit`，纹理转 WebP、FSB 音频转 WAV、简繁/英文表过滤、指纹；
- `base_tables.py` / `aa_index.py` / `selfcheck.py`：46+ 张配置表的识别、清洗、索引、产物自检；
- `ARTIFACT_FORMAT.md`：冻结的产物契约（int64 path_id、norm_key、原子落盘、partial 语义）。

即使把语言换掉，**UnityPy 的等价物仍然要重写**（C# 的 AssetStudio/AssetRipper 是另一套生态）。这就是"去 Python"最贵的部分。

### 4.5 Python 侧风险与技术债（本次审计新发现）

| # | 问题 | 证据 | 影响 |
| --- | --- | --- | --- |
| 1 | **依赖未锁定** | 无 `requirements.txt` / `pyproject.toml`；CI 直接 `pip install pyinstaller unitypy` | UnityPy 升级可能悄悄改变产物；构建不可复现 |
| 2 | **生成器断链** | `semantic_db_data.cpp` 头注释要求"从 `backend/editor/core/data_dicts.py` 重新生成"，该文件已随 Python 后端删除 | 39.8 KB 的效果词典快照**无法按文档再生**（可从 git 历史恢复，见建议） |
| 3 | **生成器输入未入库** | `tools/gen_field_*.py` 读取 `参考资料/.../catalog-schema.json`，而 `参考资料/` 在 `.gitignore` | 换机/CI 无法重放字段规则生成 |
| 4 | **UX 泄漏** | `aa_routes.cpp` 报错让用户执行 `py -m resource_scan index ...`；`settings_page.dart` 仍写"Python 运行时" | 没装 Python 的用户被指到死路；文案与架构不符 |
| 5 | **知识以注释形式存在** | 381 处注释/文档引用已删除的 `api.py`、`cloud_sync.py` 等行号 | 事实规范只在 git 历史里，交接风险 |
| 6 | **静默降级** | `aa_scan` 构建失败仅警告 | 发行包可能缺资源扫描能力，用户侧无告警 |
| 7 | **测试不在 CI** | `native-ci.yml` 只跑 ctest + curl；2.8k 行 Python 冒烟未接入 | 契约回归依赖人工 |

---

## 5. 边界判断：耦合深，但接缝干净

| 判断项 | 结论 |
| --- | --- |
| 前端是否依赖 C++/Python 的二进制接口 | **否**。`frontend/lib` 无 `dart:ffi`、无动态库加载；只有 2 个 `MethodChannel`（外观、Android 后端启动） |
| 前后端契约 | **HTTP + Token**，168 条路由，38 份 golden JSON 可直接当验收基线 |
| 后端内部接缝 | `server`（核心）/ `cli` / `tui` / `gateway` 是 4 个可独立替换的 HTTP 参与者 |
| 数据接缝 | `schema.json`、`dicts.json`、`aa_index.json`、`base_data/*.json` 均为稳定 JSON |
| 资产接缝 | C++ 不解析 bundle，只读 Python 产物 → 资产工具可独立替换 |
| 结论 | **重构不需要"大爆炸"**；可以按 server / CLI / TUI / gateway / 工具链分块替换 |

这也是为什么"只换 Python"比"换 C++"便宜一个数量级：Python 全在边界外，C++ 在边界内。

---

## 6. 重构代价模型

### 6.1 估算假设

- 1 人日 = 1 名熟悉目标栈的工程师 1 天，含本模块自测，不含项目管理。
- 1 人月 = 21 人日。
- 参考基线：有源代码可对照的 1:1 移植，250–450 行/人日；测试重写 150–250 行/人日；跨平台验收不按行数估。
- 区间为 ±40%。不含新功能、不含视觉改版、不含产品需求变更。
- "本仓库日历"单独给出，因为本仓库已经证明可以用 AI 多代理并行把日历压到远低于人力当量的水平（见 6.5）。

### 6.2 C++ 替换（目标：Rust 为例）

| # | 模块 | 行数 | 乐观 | 中性 | 悲观 | 难点 |
| --- | --- | --- | --- | --- | --- | --- |
| A | `server/services` 业务层 | 32,745 | 85 | 120 | 170 | 云驱动、文件流转、语义规则 |
| B | `server` 基础设施 | 4,969 | 15 | 22 | 32 | 手写 HTTP、连接池、job、锁 |
| C | `sa_core` | 3,751 | 14 | 20 | 30 | WinHTTP/libcurl 双栈、GBK、哈希 |
| D | CLI | 4,954 | 12 | 18 | 26 | REPL、颜色、命令兼容 |
| E | TUI | 6,690 | 16 | 24 | 36 | FTXUI 无同构替代 |
| F | gateway | 3,078 | 8 | 12 | 18 | 账号/会话/代理池 |
| G | Android JNI/.so | 587 | 5 | 8 | 12 | NDK、JNI、平台 HTTP |
| H | 测试（599 例） | 19,714 | 28 | 42 | 60 | 行为等价，不是翻译 |
| I | 构建/发布/签名（5 平台） | — | 14 | 22 | 34 | Inno/deb/AppImage/DMG/PKG |
| J | 联调/回归/平台验收 | — | 18 | 30 | 45 | 真机、代理、IME、云账号 |
| | **合计** | **56.8k 生产** | **215** | **318** | **463** | **10.2 / 15.1 / 22.0 人月** |

**只替换 server+core+gateway（保留 CLI/TUI）**：约 A+B+C+F + 对应测试/集成 ≈ **8–12 人月**（仅服务层）；加上测试、发布与验收约 **12–16 人月**。这是最现实的分阶段方案。

### 6.3 Python 移除

| # | 模块 | 行数 | 乐观 | 中性 | 悲观 | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| K | 发布编排 + 打包 | 1,940 | 8 | 13 | 20 | Go/Node/CMake+PowerShell 重写 |
| L | Unity 资产管线 | 2,676 | 70 | 110 | 160 | **UnityPy + PIL + fmod_toolkit 的等价物** |
| M | 测试/契约/冒烟 | 3,320 | 8 | 12 | 18 | 可改 Go/C++ runner 或保留 stdlib Python |
| N | MCP stdio 桥 | 855 | 2 | 4 | 6 | 协议简单 |
| O | 代码生成 | 181 | 1 | 2 | 3 | 输入需先入库 |
| P | CI / 文档 | — | 4 | 7 | 11 | 3 个 OS 的 job |
| | **合计（全量）** | **9,043** | **93** | **148** | **218** | **4.4 / 7.0 / 10.4 人月** |
| | **仅 K+M+N+O+P（保留 `aa_scan`）** | 6,296 | **23** | **38** | **58** | **1.1 / 1.8 / 2.8 人月** |

**结论：Python 的 90% 成本在 L（资产管线）。** 如果接受 `aa_scan` 作为唯一且预编译的 Python 孤岛，去 Python 化只要约 1.8 人月。

### 6.4 组合

| 场景 | 人月（中性） | 说明 |
| --- | --- | --- |
| 只去 Python，保留 `aa_scan` | **1.8** | 性价比最高 |
| 去 Python 全量 | **7.0** | 需要重写 Unity 资产解析 |
| C++ 后端 → Rust + 保留 Python 工具 | **12–16** | server+core+gateway+测试+发布 |
| C++ 全量 → Rust + 去 Python 全量 | **17–22** | 两个都动 |
| 前后端统一 Dart | **20–28** | 不建议，见 6.6 |

### 6.5 历史校准：这个团队已经做过一次 Python → C++ 重写

| 事实 | 数据 |
| --- | --- |
| 首个 C++ 后端提交 | 2026-09-07 19:58 |
| 删除整个 Python 后端 | 2026-09-11 19:24（**96 小时**） |
| 同期 `native/server|core|cli|tui` 净增 | **28,119 行** |
| 被删除的 Python 后端 | **46,204 行** |
| 当前 C++ 自有代码 | 76,488 行（此后约 7 周持续加固） |

这说明两件事：

1. **在本仓库的 AI 多代理并行工作流下，1:1 移植的日历成本远低于传统人月模型**。如果现在再做一次 C++→Rust，且沿用"先冻结契约、再分波并行、golden 兜底"的方法，日历上 **4–8 周可出可运行版本，2–4 个月达到可发布质量**。
2. **但这不是常规团队预算**。那次迁移的前提是：Python 源码在手、逐行可对照、行为有 38 份 golden JSON 冻结、多个代理并行、orchestrator 统一收口。换成 C++→Rust，仍然有 C++ 源码和测试作规范，条件接近；换成"凭记忆重写"则完全不成立。

**代价的三个口径（建议同时写进预算）：**

| 口径 | C++ 全量 → Rust | Python 全量移除 |
| --- | --- | --- |
| 人力当量（常规团队） | 10–22 人月 | 4.4–10.4 人月 |
| 本仓库 AI 并行日历 | 2–4 个月到可发布 | 1–2 个月 |
| 质量尾部（回归/平台/边缘） | 额外 1–2 个月 | 额外 2–4 周 |

### 6.6 方案对比

| 方案 | 一次性成本 | 日历 | 风险 | 收益 | 结论 |
| --- | --- | --- | --- | --- | --- |
| **A. 维持现状 + 加固** | 0.5–1 人月 | 2–4 周 | 低 | 稳定性↑，为将来降本 10–20% | **推荐** |
| **B1. 去 Python 构建链，保留预编译 `aa_scan`** | **1.5–2.5 人月** | 3–5 周 | 低 | 开发/发布不再依赖 Python 环境 | **推荐** |
| B2. 去 Python 全量（自研资产解析） | 4.4–10.4 人月 | 2–3 个月 | 中高 | 单语言工具链 | 仅在硬性要求下 |
| C1. C++ 后端 → Rust（server+core+gateway，含测试/发布） | 9–16 人月 | 4–5 个月 | 高 | 内存安全、生态、招人 | 有强诉求才做 |
| C2. C++ 全量 → Rust | 10–22 人月 | 4–6 个月 | 很高 | 同上 | 不推荐现在做 |
| D. C++ → Go | 9–15 人月 | 4–6 个月 | 很高 | 上手快 | 不推荐（TUI/Android/Live2D 反而更难） |
| E. 前后端统一 Dart | 20–28 人月 | 8–12 个月 | 极高 | 单语言 | 不推荐（Dart 服务端/原生能力弱） |
| F. 前后端统一 TS/Node | 12–18 人月 | 4–6 个月 | 高 | 与 Web 生态一致 | 不推荐（分发体积/启动/Android 变差） |

**为什么"统一到 Dart"最贵：** 后端要重做手写 HTTP、TLS、S3 分片、7 家云驱动、Live2D FFI、Android JNI，还要把 56.8k 行 C++ 的并发/文件语义搬进 Dart isolate；同时失去 2–4 MB 单文件分发。收益只有"少一门语言"。

---

## 7. 风险登记

| 风险 | 概率 | 影响 | 触发信号 | 缓解 |
| --- | --- | --- | --- | --- |
| C++ 内存安全缺陷进入生产 | 中 | 高 | 崩溃率、fuzz 命中、CVE | ASan/UBSan CI、fuzz、静态分析、代码评审 |
| 重写期间功能冻结导致产品落后 | 高 | 中 | 竞品迭代速度 | 分阶段替换，不做大爆炸 |
| 重写后行为漂移（168 路由 × 5 平台） | 高 | 高 | golden 差异、用户回归 | 以 38 份 golden JSON + 599 例为验收闸门 |
| UnityPy 升级导致资产产物变化 | 中 | 中 | 产物哈希变化 | 锁定版本、产物哈希入 lock |
| `aa_scan` 缺失但无告警 | 中 | 中 | 安装包缺文件 | 构建时硬校验 + 启动时能力探测 |
| Android 形态在重写后退化 | 中 | 高 | `.so` 体积/启动/JNI 崩溃 | 保留 `.so` 方案，先做 PoC |
| Live2D 闭源 DLL 无法跨语言 | 高 | 中 | 渲染功能缺失 | 保留 FFI；或在目标语言里做动态加载 |
| 构建/签名链路重做踩坑 | 高 | 中 | 5 平台产物失败 | 先跑通一个平台，再复制 |
| 维护者只熟悉单一语言 | 中 | 高 | 招聘周期 | 文档化 + 结对 + 先做 B1 降低门槛 |
| 文档与代码继续漂移 | 高 | 低 | 新人文案误解 | 每次架构变更同步 `CONVENTIONS.md` 与 UI 文案 |

---

## 8. 建议路线

### 8.1 总原则

1. **保留 C++ 后端**。它是当前产品的交付优势（单文件、无运行时、Android 进程内），不是负债。
2. **把 Python 收敛成"一个可替换的工具"**，而不是"发布必经的第二种语言"。
3. **不要为了"少一门语言"而重写**；只为"可验证的收益"（安全、发布可复现、合规）付费。
4. **任何重写都先冻结契约**：168 路由 + 39 golden + 599 例测试是现成的验收网。

### 8.2 P0：两周内可做（约 0.2–0.3 人月，收益最高）

1. **锁定 Python 环境**：新增 `tools/requirements.txt`（`unitypy`、`pillow`、`fmod_toolkit`、`pyinstaller` 固定版本），CI 用固定镜像；产物记录哈希。
2. **`aa_scan` 产物化**：每个平台预编译一次，哈希写入 `packaging/ci_assets.lock.json`；发布不再现场 `pip install`。
3. **修 UX 断头路**：`aa_routes.cpp` 的错误信息优先指向 `aa_scan.exe`，其次才是 `py -m resource_scan`；删除 `settings_page.dart` 里"Python 运行时"的过期文案。
4. **恢复可再生性**：从 git 历史恢复 `backend/editor/core/data_dicts.py`（1,992 行）到 `tools/`，让 `semantic_db_data.cpp` 可重新生成；或明确把它标记为"冻结快照"。
5. **生成器输入入库**：把 `catalog-schema.json` 等 `gen_field_*` 的输入纳入仓库（或明确 CI 不跑并记录）。

### 8.3 P1：一个月内（约 0.5–1 人月）

6. **发布脚本去 Python**：`build_release.py` → Go/Node/CMake+PowerShell 薄层；目标是把 3 个 OS 的 release job 从 `pip install` 里解放出来。`run_dev.py` 同理（或保留为可选便利脚本）。
7. **测试补盲**：把 POSIX 排除的 3 个 TU（`test_cfg_store`、`test_p4_aa`、`test_p3b_domain_tools`）改成平台无关；至少让 Linux/macOS 覆盖到配置写路径。
8. **把 Python 冒烟接进 CI**（可选）：`smoke_cli/tui/web/upload` + `selftest_blackbox.py` 是现成的黑盒验收，接进 `native-ci` 比重写便宜。

### 8.4 P2：两个月内（约 0.5–1 人月，安全加固）

9. **ASan/UBSan + fuzz**：优先 `httpd`（multipart、Range、chunked）、zip 解包、路径沙箱、云 URL 校验。
10. **静态分析**：clang-tidy/cppcheck 进 CI（先只报告不阻塞），逐步清零。
11. **编译器告警**：MSVC `/W4`、GCC/Clang `-Werror` 分模块推进。

### 8.5 P3：仅在硬性诉求下（C++ → Rust）

12. **范围**：先 server + core + gateway；CLI/TUI/gateway 都是 HTTP 客户端，可后置或保留。
13. **顺序**：冻结契约 → 用 Rust 重写 `core`（HTTP/JSON/路径/哈希）→ 逐个 service → 用 39 golden 做差分 → 最后切发布。
14. **不建议**同时重写 TUI（FTXUI 等价物成本高）和 Android JNI。

### 8.6 触发重写的条件（写进决策记录）

- 出现**反复无法修复**的内存安全漏洞，且 ASan/fuzz 仍无法收敛；
- C++ 维护者少于 1 人且**招聘持续失败**（连续 2 个季度）；
- 产品要求**浏览器内 WASM 后端**（此时 C++ 也可编译 WASM，但文件/网络能力受限，需重新评估）；
- 要并入 **Unity/C# 资产工具生态**（此时 C# 可能比 Rust 更合适，因为 AssetStudio/AssetRipper 生态在 C#）。

### 8.7 明确不建议做的事

| 不做 | 原因 |
| --- | --- |
| 把后端逻辑搬进 Flutter/Dart | 破坏 HTTP 边界，Android/桌面/网页三形态都会变重 |
| 为了"统一语言"重写 C++ | 15 人月换来的主要是"少一门语言"，不是产品能力 |
| 重写 Unity 资产管线 | 90% 成本在 UnityPy 等价物，收益极低 |
| 保留 Python 作为运行时依赖 | 没必要；现在已经是 0 运行时 |
| 在无 golden 的情况下重写 | 会丢失唯一可靠的行为规范 |

---

## 9. 附：复核命令与关键文件

### 9.1 复核命令（PowerShell）

```powershell
# 自有 C++ 规模（排除 third_party / build）
$f = Get-ChildItem native -Recurse -File -Include *.cpp,*.h |
     Where-Object { $_.FullName -notmatch '\\(build|third_party)\\' }
($f | ForEach-Object { (Get-Content $_.FullName | Measure-Object -Line).Lines } |
  Measure-Object -Sum).Sum

# Python 规模（git 跟踪）
git ls-files '*.py' | ForEach-Object {
  (Get-Content $_ | Measure-Object -Line).Lines
} | Measure-Object -Sum

# 路由数
(Select-String -Path (Get-ChildItem native/server -Recurse -Include *.cpp).FullName `
  -Pattern '\br\.(get|post|put|del|options)\s*\(\s*R?"' -AllMatches).Matches.Count

# Catch2 用例/断言
$t = (Get-ChildItem native/tests -Recurse -Include *.cpp).FullName
(Select-String -Path $t -Pattern 'TEST_CASE\s*\(' -AllMatches).Matches.Count
(Select-String -Path $t -Pattern '\b(CHECK|REQUIRE)\w*\s*\(' -AllMatches).Matches.Count

# 平台分支
$s = (Get-ChildItem native -Recurse -Include *.cpp,*.h |
      Where-Object { $_.FullName -notmatch '\\(build|third_party)\\' }).FullName
(Select-String -Path $s -Pattern '_WIN32' -AllMatches).Matches.Count
```

### 9.2 关键文件索引

| 关注点 | 文件 |
| --- | --- |
| 路由总线 | `native/server/api_router.cpp` |
| HTTP 传输 | `native/server/httpd.cpp` |
| 出站 HTTP/TLS | `native/core/http_client.cpp` |
| 配置写/历史/锁 | `native/server/cfg_store.cpp`、`cfg_cache.cpp`、`revision_manager.cpp` |
| 云同步 7 驱动 | `native/server/services/cloud_sync.cpp` |
| 文件流转/S3 | `native/server/services/file_transfer.cpp` |
| 语义/校验 | `native/server/services/semantic_*.cpp` |
| Live2D | `native/server/live2d_renderer.cpp` |
| TUI | `native/tui/p8_*.cpp`、`native/tui/tui/*` |
| Android JNI | `native/android/jni_bridge.cpp`、`http_jni_bridge.cpp` |
| 发布编排 | `build_release.py` |
| 资产管线 | `tools/resource_scan/*`、`packaging/export_*.py` |
| 产物契约 | `tools/resource_scan/ARTIFACT_FORMAT.md` |
| 测试契约 | `native/tests/contract/`、`native/CONVENTIONS.md` |

### 9.3 一句话总结

**C++ 的依赖是"结构性"的，重构等于重建；Python 的依赖是"工具性"的，重构只是换工具。**
当前最划算的动作不是重写，而是：**锁定 Python、预编译 `aa_scan`、修好过期文案、给 C++ 加 sanitizer/fuzz**。这四件事合计不到 1 人月，能消掉大部分"依赖焦虑"，同时把真正的重写选项留到有硬性诉求时再启动。

