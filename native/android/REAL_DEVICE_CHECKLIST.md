# Android 真机回归清单（W4-6）

背景：W4-4 把 Android 后端从 Chaquopy 内嵌 CPython 换成 native `libbackend_shared.so`
+ JNI（`MainActivity.kt` `System.loadLibrary("backend_shared")` + `nativeStart`）。
JNI 桥的七条 HTTP 语义契约已在代码级实现并注释（`native/android/http_jni_bridge.cpp`
与 `frontend/android/app/src/main/kotlin/com/studentage/editor/BackendHttp.kt`），
但**本机无 emulator / adb 设备**，全部真机级证据悬置。此清单是补验脚本。

## 构建产物（本地已验证）

```
bash native/android/android_build.sh          # NDK r28，两 ABI → jniLibs/<abi>/libbackend_shared.so
cd frontend && flutter build apk --debug      # 140MB，APK 内含 lib/{arm64-v8a,x86_64}/libbackend_shared.so
```
APK 已核不含 CPython/chaquopy 痕迹（构建后 `unzip -l app-debug.apk | grep -E "chaquopy|libpython"` 应为空）。

## 真机步骤（每步给「期望」作为判据）

| # | 操作 | 期望 |
|---|---|---|
| 1 | `adb install -r app-debug.apk`，启动 app | 无崩溃；`adb logcat -s StudentAgeBackend` 出现 `backend started on 127.0.0.1:8765` |
| 2 | 看首启日志 | `nativeStart(8765, filesDir/data, filesDir/resource_packs, <bundledZip>)` 返回非 0 端口；bundled zip 首次解压（较慢）后 `/api/aa/scan` → `{"status":"ready"}` |
| 3 | 杀进程重开 | 第二启 `packs_root/bundled/.bundled_version` md5 命中 → **跳过解压**（首启快） |
| 4 | 前端连通 | GUI 正常加载模组列表（`backend_launcher.dart` 轮询 `127.0.0.1:8765/api/ping`） |
| 5 | WebDAV 同步（PROPFIND/MKCOL） | 配置 WebDAV 驱动后能列目录/建目录——验证契约(a)：`BackendHttp.setVerb` 反射改 `method` 字段是否被 hide-API 拦截。**若失败，logcat 会现 `UnsupportedOperationException: Android HttpURLConnection 拒绝自定义动词`**（已知长期风险） |
| 6 | AI 对话流式（SSE） | DashScope/MiniMax 流式返回逐段上屏、提前停止不报错——验证契约(b)：`request_stream` 分块 + 早停回 `Error::None` |
| 7 | 断网/错 key 的错误文案 | 中文错误分类正确（超时/连接失败/TLS/入参）——验证契约(c) 异常类名映射；≥400 走 errorStream 不报错（契约 d） |
| 8 | 302 重定向端点 | 自动跟随（契约 e） |
| 9 | 含 NUL 的二进制请求体 | 上传类接口不截断（契约 g，byte[] + fixed-length streaming） |
| 10 | 长时运行 | 64 槽 httpd 下多线程外呼不崩（契约 f，`AttachCurrentThreadAsDaemon`） |

## 关键风险点

- **契约 (a) 反射改 `method`**：Android hide-API 名单随版本变动，是唯一可能静默失效的一条。
  真机若第 5 步失败，替代方案：降级为仅 GET/POST/PUT/DELETE（放弃 WebDAV 的自定义动词），
  或改用 OkHttp（需新增依赖）。
- **assets 解析**：Android 无 exe-dir 上溯语义，资源必须走显式 root 参数
  （`nativeStart` 的 dataRoot/packsRoot/bundledZip）；若 `libbackend_shared.so` 内
  `sa_core::assets` 落回 walk-up 会在移动端找不到文件——真机第 2 步会暴露。
- **ABI**：仅 arm64-v8a/x86_64（`build.gradle.kts` abiFilters）；32 位设备不支持。

## 无设备时的替代证据（已做）

- NDK 交叉编译两 ABI 成功（.so 81.8MB/77.5MB，gradle strip 后 ~4MB）。
- APK 构建成功且 .so 就位、无 CPython。
- 七契约的代码级证据在 `http_jni_bridge.cpp` 头部注释逐条对应，Kotlin 侧
  `BackendHttp.kt` 头部亦列同一清单；C++/Kotlin 方法签名一致性由 JNI 契约
  （`httpOpen/httpStatus/httpHeaders/httpRead/httpClose` + `nativeStart/nativeStop`）固定。
