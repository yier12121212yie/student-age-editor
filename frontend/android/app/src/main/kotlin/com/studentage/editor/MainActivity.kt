package com.studentage.editor

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    /// 与 frontend/lib/core/backend_launcher.dart 保持一致
    private val backendPort = 8765
    private val bundledAssetPath = "bundled/resource_pack.zip"
    private val bundledZipName = "bundled_resource_pack.zip"

    override fun onResume() {
        super.onResume()
        ensureBackend()
    }

    /// W4-4：Android 后端从 Chaquopy 内嵌 CPython 换成 native C++
    /// （libbackend_shared.so，JNI 线程里跑与桌面完全同一套 sa::run_server）。
    /// 前端仍按 http://127.0.0.1:8765 访问，dart 侧协议不变
    /// （backend_launcher.dart 轮询 /api/ping 等就绪）。
    private fun ensureBackend() {
        thread(name = "native-backend") {
            try {
                // Activity 重建时后端线程还活着：nativeStart 幂等，但先探一下省一次跳转。
                if (pingBackend()) return@thread
                val bundledZip = copyBundledAsset()
                val dataRoot = "${filesDir.absolutePath}/data"
                val packsRoot = "${filesDir.absolutePath}/resource_packs"
                val port = nativeStart(backendPort, dataRoot, packsRoot, bundledZip)
                if (port == 0) {
                    Log.e(TAG, "backend failed to start (bind port $backendPort)")
                    return@thread
                }
                Log.i(TAG, "backend started on 127.0.0.1:$port")
            } catch (e: Exception) {
                Log.e(TAG, "backend failed to start", e)
            }
        }
    }

    /// 起服务（对齐桌面 --write-port 语义：返回实际绑定端口，0=失败）。
    private external fun nativeStart(
        port: Int,
        dataRoot: String,
        packsRoot: String,
        bundledZip: String,
    ): Int

    /// 停服（正常发行路径不调用——进程随 app 结束；保留对称能力与测试钩子）。
    private external fun nativeStop()

    /// 把 assets/bundled/resource_pack.zip 流式拷贝到 filesDir/bundled_resource_pack.zip。
    /// 返回解出后的绝对路径；APK 未内置时返回空字符串（后端按无内置资源运行）。
    private fun copyBundledAsset(): String {
        val target = File(filesDir, bundledZipName)
        try {
            // openFd 只能处理未压缩的 asset，可拿到原始长度做“非同尺寸才覆盖”；
            // Gradle 构建的 APK assets 默认未压缩，走此路径最省。
            val afd = assets.openFd(bundledAssetPath)
            try {
                if (target.exists() && target.length() == afd.length) {
                    return target.absolutePath
                }
                afd.createInputStream().use { input ->
                    FileOutputStream(target).use { out -> input.copyTo(out, 64 * 1024) }
                }
                Log.i(TAG, "内置资源包已解出: ${target.absolutePath} (${target.length() / 1048576} MB)")
                return target.absolutePath
            } finally {
                afd.close()
            }
        } catch (_: FileNotFoundException) {
            Log.i(TAG, "APK 未内置资源包（assets/$bundledAssetPath 不存在），后端将无内置资源")
            return ""
        } catch (_: IOException) {
            // asset 被压缩存储时 openFd 不可用，退化为流式拷贝（仅在缺失时写一次）
            if (target.exists() && target.length() > 0L) {
                return target.absolutePath
            }
            try {
                assets.open(bundledAssetPath).use { input ->
                    FileOutputStream(target).use { out -> input.copyTo(out, 64 * 1024) }
                }
                Log.i(TAG, "内置资源包已解出(流式): ${target.absolutePath} (${target.length() / 1048576} MB)")
            } catch (_: FileNotFoundException) {
                Log.i(TAG, "APK 未内置资源包（assets/$bundledAssetPath 不存在），后端将无内置资源")
                return ""
            } catch (e: Exception) {
                Log.w(TAG, "拷贝内置资源包失败", e)
                return ""
            }
        } catch (e: Exception) {
            Log.w(TAG, "拷贝内置资源包失败", e)
            return ""
        }
        return if (target.exists()) target.absolutePath else ""
    }

    private fun pingBackend(): Boolean = try {
        val conn = URL("http://127.0.0.1:$backendPort/api/ping").openConnection()
            as HttpURLConnection
        conn.connectTimeout = 500
        conn.readTimeout = 500
        val ok = conn.responseCode == 200
        conn.disconnect()
        ok
    } catch (_: Exception) {
        false
    }

    companion object {
        const val TAG = "StudentAgeBackend"

        init {
            // 依赖注入的 jniLibs/<abi>/libbackend_shared.so（native/android/
            // android_build.sh 产物；CI 与本地构建同路径）。
            System.loadLibrary("backend_shared")
        }
    }
}
