package com.studentage.editor

import android.util.Log
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
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

    /// Android 上没有桌面版的 backend.exe 子进程，改为在应用内嵌的
    /// CPython（Chaquopy）里直接运行 editor.server.start_server()，
    /// 前端仍通过 http://127.0.0.1:8765 访问，架构与桌面版一致。
    private fun ensureBackend() {
        thread(name = "python-backend") {
            try {
                if (!Python.isStarted()) {
                    Python.start(AndroidPlatform(applicationContext))
                }
                if (pingBackend()) return@thread // Activity 重建时后端仍在跑
                val py = Python.getInstance()
                // start_server(port, on_ready, data_root, packs_root, bundled_zip)；
                // 内置资源包由后端解压到 packs_root/bundled 供无游戏的 Android 使用。
                val bundledZip = copyBundledAsset()
                val dataRoot = "${filesDir.absolutePath}/data"
                val packsRoot = "${filesDir.absolutePath}/resource_packs"
                val result = py.getModule("editor.server")
                    .callAttr("start_server", backendPort, null, dataRoot, packsRoot, bundledZip)
                val port = result.asList()[1].toInt()
                Log.i(TAG, "backend started on 127.0.0.1:$port")
            } catch (e: Exception) {
                Log.e(TAG, "backend failed to start", e)
            }
        }
    }

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

    private companion object {
        const val TAG = "StudentAgeBackend"
    }
}
