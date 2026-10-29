# 本地服务图片加载速度优化方案 (Implementation Plan)

> **目标**：全面消除本地服务（C++ 后端 `backend`）与客户端（Flutter 前端桌面/移动端/Web）之间图片加载的协议传输、编解码、磁盘 I/O 以及并发连接瓶颈，大幅提升画廊（AssetPicker/BgGallery）、立绘/头像（RoleVisuals/TexThumb）、剧情预览（EventPreview）以及资源管理器（ResourcesPage）的图片首屏加载与滚动吞吐速度。

---

## 1. 现状与瓶颈分析 (Root Cause Analysis)

经过对 `native/server`（C++ 后端）与 `frontend/lib`（Flutter 前端）全链路代码的系统调研，当前本地图片加载存在以下四大核心性能瓶颈：

```
【当前全链路开销】
本地磁盘文件 (WebP/PNG/AVIF)
    │
    ▼ [磁盘 I/O] 每次请求均无缓存重读磁盘
`DecodedPack::read_file` (C++ std::string 内存分配)
    │
    ▼ [膨胀 +33%] C++ `b64_encode` 将二进制编码为 Base64 ASCII
`aa_routes.cpp` (生成数 MB 的 Base64 std::string)
    │
    ▼ [二次复制与转义] `nlohmann::json` + `sa_core::py_dumps`
`httpd.cpp` (序列化出包含巨幅 Base64 的庞大 JSON 报文)
    │
    ▼ [网络传输] HTTP POST /api/aa/preview 响应（Cache-Control: no-store，不可缓存）
Loopback TCP Socket (127.0.0.1)
    │
    ▼ [Dart 堆解析] `jsonDecode` 解析多兆字节 JSON 报文
Flutter/Dart `ApiClient.post`
    │
    ▼ [Isolate 线程切换与数据拷贝] `compute(_base64DecodeIsolate, data)`
后台 Isolate 解码 Base64 -> 拷贝回主 Isolate 生成 Uint8List
    │
    ▼ [渲染引擎解码]
Flutter `Image.memory` -> GPU 纹理上传
```

### 瓶颈 1：Base64 膨胀与双端频繁编解码（最大的 CPU 与内存浪费）
- **现象**：所有组件（`image_asset_picker.dart`、`event_preview_view.dart`、`asset_explorer_panel.dart`、`resources_page.dart`）均通过 `POST /api/aa/preview` 请求图片。
- **代价**：
  1. **体积增加 33%~37%**：一张 500 KB 的 WebP 背景图编码后达 670 KB，2 MB 原图编码后接近 2.7 MB。
  2. **后端四重内存分配与拷贝**：磁盘文件 buffer $\rightarrow$ base64 string $\rightarrow$ JSON 对象 $\rightarrow$ HTTP 响应 string。
  3. **前端高 CPU 与 Isolate 开销**：Dart 必须先将 JSON 字符串完整解码，提取超大 Base64 字符串，再跨 Isolate 发送执行 `base64Decode`。在连续滚动或打开画廊时，引发明显的 GC 停顿与掉帧。

### 瓶颈 2：HTTP 语义倒退，缺少缓存与协商（ETag / 304 Not Modified）
- **现象**：`httpd.cpp` 默认对所有请求输出 `Cache-Control: no-store`，且仅提供 `POST /api/aa/preview`。
- **代价**：
  1. HTTP POST 语义规范中不支持浏览器标准缓存。
  2. 没有 `ETag` 与 `If-None-Match` 支持，即使本地磁盘文件分毫未改，每次请求依然重复传输全部字节。
  3. Web 模式下无法直接通过 `<img>` 标签或 `Image.network` 走浏览器原生高速缓存与 GPU 解码。

### 瓶颈 3：后端无内存字节缓存，重复磁盘 I/O
- **现象**：每次请求到达，`DecodedPack::read_file` 均直接调用 `sa_core::paths::read_bytes(path)` 从磁盘读取。
- **代价**：在画廊来回滚动、切换对白或重复打开预览时，即使同一张立绘被反复使用，后端依然重复打满磁盘读 IOPS。

### 瓶颈 4：客户端并发连接池受限（Dart 默认仅 6 并发）
- **现象**：`ApiClient.instance.client` 采用默认 `http.Client()`，底层在桌面/移动端采用 `dart:io` 的 `HttpClient`，其 `maxConnectionsPerHost` 默认限制为 **6**！
- **代价**：当画廊网格一屏显示 30~50 个瓦片时，40 多张图片被阻塞在 Dart 网络队列中，排队以 6 个一组串行拉取，造成严重的瀑布流等待延迟。

---

## 2. 优化方案设计 (Proposed Architecture)

```
【优化后的高速流转链路】
                       ┌──────────────────────────────┐
                       │  C++ 内存 LRU 缓存 (0ms I/O)  │
                       └──────────────▲───────────────┘
                                      │ (命中)
[客户端请求]                          │
GET /api/aa/raw?kind=tex&key=... ──▶ 后端快速路径
If-None-Match: "etag"                 │ (未命中)
                                      ▼
                           读取本地磁盘 (WebP/PNG/AVIF)
                                      │
               ┌──────────────────────┴──────────────────────┐
               │                                             │
      (ETag 一致: 304)                              (首次/已更新: 200)
    HTTP 304 Not Modified                    Resp::BytesTyped (零 Base64, 零 JSON)
    0 字节 Payload, 瞬时响应                   直发原始二进制流, 附带 ETag + Cache-Control
               │                                             │
               └──────────────────────┬──────────────────────┘
                                      │
                                      ▼
                        客户端 (Flutter / Web)
                ┌─────────────────────────────────────┐
                │ 1. 32 队列高并发连接池 (突破 6 并发限制) │
                │ 2. 直接获取 Uint8List (零 Isolate 损耗)│
                │ 3. 兼容降级 (自动回退旧版 POST)      │
                └─────────────────────────────────────┘
```

### 模块 A：后端直发二进制 GET 接口与 ETag 协商 (`native/server`)
1. **新增二进制流 GET 路由**：
   - 路径：`GET /api/aa/raw?kind=tex&key=<key>` 与 `GET /api/aa/tex?key=<key>`。
   - 行为：
     - 查询成功时：调用 `Resp::BytesTyped(200, std::move(bytes), mime)`，直接以纯二进制字节流输出，无需任何 Base64 编码或 JSON 包装。
     - 若命中外部对象存储（COS）：自动返回 `302 Found`（附带 `Location: <url>`），HTTP 客户端自动跳转拉取，无需客户端单独适配。
     - 标头支持：附带 `ETag: "<size_hex>-<mtime_hex>"` 和 `Cache-Control: public, max-age=86400`。
2. **`httpd.cpp` 支持 ETag 与 If-None-Match 协商**：
   - `Req` 新增 `if_none_match_header` 解析。
   - `Resp` 新增 `etag` 字段及 `Resp::NotModified(etag, cache_control)` 构造方法。
   - 当客户端携带 `If-None-Match` 且与资源 ETag 一致时，直接返回 `304 Not Modified`（响应体 0 字节）。
3. **保持 100% 向后兼容**：
   - `POST /api/aa/preview` 原样保留，且同样接入后端内存缓存，确保原有测试集与下游消费方零风险。

### 模块 B：后端线程安全图片 LRU 内存缓存 (`ImageBytesCache`)
1. **结构设计**：
   - 在 `aa.cpp` 中引入紧凑的 LRU 缓存单例：
     ```cpp
     struct ImageCacheEntry {
         std::string data;
         std::string mime;
         std::string etag;
         long long mtime_ns = 0;
         long long size = 0;
     };
     ```
   - 默认容量上限：`64 MB`（可按需要上调至 128 MB）。
2. **失效与刷新策略**：
   - 命中时校验 `statInfo.mtime_ns` 和 `statInfo.size`，若磁盘文件被外部编辑或替换，自动使缓存失效并重新读取。
   - 缓存命中时，耗时从磁盘 I/O 的数毫秒下降至微秒级（$<0.1\text{ms}$）。

### 模块 C：前端并发连接数解禁 (`frontend/lib/core/api_client.dart`)
1. **解除 6 连接限制**：
   - 在桌面端（Windows/macOS/Linux）与移动端（Android/iOS），配置 `ApiClient` 的底层 `HttpClient`：
     ```dart
     HttpClient()
       ..maxConnectionsPerHost = 32
       ..idleTimeout = const Duration(seconds: 30);
     ```
   - 并发加载画廊多张缩略图时，吞吐速度成倍提升，彻底消除排队等待。
2. **新增 `getRawBytes` 高速方法**：
   - 针对二进制流资源直接返回 `Uint8List`，免去任何 `utf8.decode` 与 `json.decode`。

### 模块 D：前端 `TexBytesCache` 双通道升级 (`image_asset_picker.dart`)
1. **优先走二进制高速通道**：
   - `TexBytesCache._fetch` 优先发起 `GET /api/aa/raw?kind=tex&key=...`。
   - 直接获得图片文件的原始二进制字节流，**彻底跳过 `compute(_base64DecodeIsolate)`**。
2. **优雅降级与测试兼容**：
   - 若遇到 404/405 或桩服务（如单元测试中的 `MockClient` 仅 Mock 了 `/api/aa/preview`），无缝降级回退执行原有的 `POST /api/aa/preview`。

---

## 3. 具体修改细节 (Proposed Changes)

### Component 1: `native/server` (后端 C++ 路由与 HTTPD 优化)

#### [MODIFY] `native/server/httpd.h`
- 在 `Req` 结构体中添加 `std::string if_none_match_header;`。
- 在 `Resp` 结构体中添加 `std::string etag;`，增加静态辅助方法 `static Resp NotModified(std::string etag = {}, std::string cache_control = {});`。

#### [MODIFY] `native/server/httpd.cpp`
- 在请求头部解析循环中识别 `if-none-match` 并写入 `req.if_none_match_header`。
- 在 `write_response` 中，若 `resp.etag` 非空，输出 `ETag: <etag>\r\n`。
- 若 `status == 304`，输出状态行 `304 Not Modified`，`Content-Length: 0`，不输出包体。

#### [MODIFY] `native/server/services/aa.h` 与 `native/server/services/aa.cpp`
- 实现线程安全的 `ImageBytesCache`（LRU 替换，容量上限 64MB）。
- 提供统一的 `fetch_tex_raw(const std::string& key, const std::string& if_none_match)` 方法，统一处理本地立绘、背景、模组资源与对象存储 URL。
- `POST /api/aa/preview` 内部也复用该缓存，加速旧接口。

#### [MODIFY] `native/server/services/aa_routes.cpp`
- 注册 `GET /api/aa/raw` 与 `GET /api/aa/tex`：
  - 处理 `kind=tex`（以及 `kind=aud`、`kind=txt`）的二进制直发。
  - 支持 ETag 协商与 304 快速响应。
  - 支持 COS URL 的 `302 Found` 自动重定向。

---

### Component 2: `frontend/lib` (前端 HTTP 并发与直发通道对接)

#### [MODIFY] `frontend/lib/core/api_client.dart`
- 引入 `dart:io` 的平台定制连接池（桌面/移动端 `maxConnectionsPerHost = 32`），Web 模式保持平台默认。
- 在 `ApiClient` 添加 `Future<http.Response> getRaw(String path, {Map<String, String>? query, Map<String, String>? headers})`。

#### [MODIFY] `frontend/lib/features/resources/image_asset_picker.dart`
- 在 `TexBytesCache._fetch` 中，优先通过 `ApiClient.instance.getRaw('/api/aa/raw', query: {'kind': 'tex', 'key': key})` 获取二进制字节。
- 遇 200 直接构建 `TexSource.bytes(resp.bodyBytes)`，跳过 Isolate Base64 解码。
- 遇 404/405 等非就绪状态自动降级为旧版 `POST /api/aa/preview`。

#### [MODIFY] `frontend/lib/features/resources/asset_explorer_panel.dart` 与 `resources_page.dart`
- 同样对接二进制通道，避免全量大图在预览弹窗时产生 Base64 解码卡顿。

---

## 4. 预期收益与量化指标 (Expected Performance Gains)

| 指标维度 | 优化前 | 优化后 | 收益预估 |
|---|---|---|---|
| **网络传输体积** (以 20 张背景图为例) | ~3.0 MB (Base64 JSON) | ~2.2 MB (Raw WebP) | **体积减少 ~27%** |
| **客户端 CPU / 内存开销** | 需主/子 Isolate 间字符串拷贝与 `base64Decode` | 0 字符串分配，直接使用 `bodyBytes` | **减少 100% 解码 CPU 开销** |
| **画廊并发加载能力** | 仅 6 个并发连接，其余排队 | 32 个并发连接并行流水线请求 | **并发吞吐提升 3~5 倍** |
| **重复浏览响应时延 (热缓存)** | 再次读取磁盘文件 + 重新 Base64 | 304 响应 (0 字节) 或 后端内存缓存 (<0.1ms) | **时延降低 90%+** |

---

## 5. 验证方案 (Verification Plan)

### 自动化测试 (Automated Tests)
1. **C++ 后端 Catch2 测试**：
   - 运行 `.\native\build\bin\sa_tests.exe "[aa]"`，确保既有 AA 索引、预览与立绘测试 100% 通过。
   - 新增 `test_aa_raw_binary` 测试用例：
     - 测试 `GET /api/aa/raw?kind=tex&key=...` 返回 200 与二进制字节流（`Content-Type: image/...`）。
     - 测试带 `If-None-Match` 返回 `304 Not Modified`。
     - 测试未知 key 返回 404。
2. **Flutter 单元与 Widget 测试**：
   - 运行 `flutter test test/image_asset_picker_test.dart`，验证瞬时重试、画廊渲染、降级容错均正常。
   - 新增针对 `TexBytesCache` 直读通道与 ETag 逻辑的单测。

### 手动交互验证 (Manual Verification)
1. 启动本地开发模式：`python run_dev.py -d windows`。
2. 打开「资源库」/「背景画廊」面板：
   - 观察滚动画廊时缩略图的加载流畅度与首屏出图速度。
   - 检查开发者工具/控制台中的请求日志，确认状态码为 200 (二进制) 或 304。
3. 打开「人物立绘」与「剧情舞台」预览，验证立绘与背景图显示正常，无丢图、闪烁或尺寸异常。

---

## 6. 用户评审关注项 (User Review Required)

> [!IMPORTANT]
> 1. **默认保持 100% 向后兼容**：既有的 `POST /api/aa/preview` 不作破坏性改动，所有旧工具与测试用例继续正常运行。
> 2. **内存上限控制**：后端 C++ 图片内存 LRU 缓存上限预设为 **64 MB**，对于桌面端常驻占用极低；若有特殊内存受限场景，可通过环境变量 `EDITOR_IMAGE_CACHE_MB` 自由微调。
