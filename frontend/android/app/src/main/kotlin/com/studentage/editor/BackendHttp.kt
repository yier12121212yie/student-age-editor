package com.studentage.editor

import java.io.IOException
import java.io.InputStream
import java.lang.reflect.Field
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * W4-4（去 Chaquopy）：C++ 后端的外呼 HTTP 桥。
 *
 * native 的 libbackend_shared.so 里 sa_core::http::request / request_stream
 * 经 JNI 调到这里（native/android/http_jni_bridge.cpp），用平台
 * HttpURLConnection 完成出站请求。方法名/签名是 JNI 契约，勿改。
 *
 * 语义契约对齐（W4-3 交底七条）：
 *  - (a) PROPFIND/MKCOL：HttpURLConnection.setRequestMethod 白名单外时反射改
 *    method 字段（Android libcore 的 java.net.HttpURLConnection 声明了该字段，
 *    WebDAV 库多年沿用的标准手法）。反射被 hide-API 拦截时抛
 *    UnsupportedOperationException（C++ 侧归 Other + 明确文案）——长期风险，
 *    W4-6 真机回归观察点。
 *  - (b) 流式分块由 C++ 侧逐次调 httpRead 驱动（网络节奏保持）；提前停止时
 *    C++ 直接关连接并带回部分体，不视为错误。
 *  - (c) 错误分类靠异常类名（SocketTimeout / SSL / UnknownHost|Connect|Socket /
 *    Malformed|Protocol）映射，C++ 侧完成。
 *  - (d) >=400 不是错误：读 errorStream 正常返回。
 *  - (e) instanceFollowRedirects = true。
 *  - (f) 系统 CA（平台网络栈）；每次请求独立连接对象，多线程安全。
 *  - (g) 请求体以 ByteArray 传输（fixed-length streaming），可含 NUL 二进制。
 */
object BackendHttp {
    private class Holder(val conn: HttpURLConnection, val stream: InputStream?)

    private val conns = ConcurrentHashMap<Long, Holder>()
    private val seq = AtomicLong(1)

    /** headers 为 "Name: value" 数组；body 为 null 表示无请求体（含方法非 POST 的空体）。 */
    @JvmStatic
    @Throws(IOException::class)
    fun httpOpen(
        url: String, method: String, headers: Array<String>,
        body: ByteArray?, connectMs: Int, readMs: Int,
    ): Long {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.instanceFollowRedirects = true
        conn.connectTimeout = connectMs
        conn.readTimeout = readMs
        conn.useCaches = false
        setVerb(conn, method)
        for (h in headers) {
            val i = h.indexOf(':')
            if (i > 0) {
                conn.addRequestProperty(h.substring(0, i).trim(), h.substring(i + 1).trim())
            }
        }
        try {
            if (body != null) {
                conn.doOutput = true
                conn.setFixedLengthStreamingMode(body.size)
                conn.connect()
                conn.outputStream.use { it.write(body) }
            }
            // (d)：>=400 不抛错，读 errorStream（getInputStream 在 >=400 会抛）。
            val code = conn.responseCode
            val stream = if (code >= 400) conn.errorStream else conn.inputStream
            val handle = seq.getAndIncrement()
            conns[handle] = Holder(conn, stream)
            return handle
        } catch (e: IOException) {
            try { conn.disconnect() } catch (_: Throwable) {}
            throw e
        }
    }

    @JvmStatic
    fun httpStatus(handle: Long): Int =
        conns[handle]?.conn?.responseCode ?: throw IOException("backend http handle vanished")

    /** 返回扁平的 [name, value, name, value, ...]（无名状态行被略过）。 */
    @JvmStatic
    fun httpHeaders(handle: Long): Array<String> {
        val holder = conns[handle] ?: return emptyArray()
        val out = ArrayList<String>()
        for ((k, v) in holder.conn.headerFields) {
            if (k == null) continue
            for (s in v) {
                out.add(k)
                out.add(s)
            }
        }
        return out.toTypedArray()
    }

    /** 阻塞读入 buf，返回字节数或 -1（EOF）。0 不会出现（buf 非空 + 阻塞流）。 */
    @JvmStatic
    @Throws(IOException::class)
    fun httpRead(handle: Long, buf: ByteArray): Int {
        val holder = conns[handle] ?: return -1
        val s = holder.stream ?: return -1
        return s.read(buf)
    }

    @JvmStatic
    fun httpClose(handle: Long) {
        val holder = conns.remove(handle) ?: return
        try { holder.stream?.close() } catch (_: Throwable) {}
        try { holder.conn.disconnect() } catch (_: Throwable) {}
    }

    /** (a) 自定义动词：先走白名单 setter，被拒时反射改字段。 */
    private fun setVerb(conn: HttpURLConnection, method: String) {
        try {
            conn.requestMethod = method
            return
        } catch (_: java.net.ProtocolException) {
            // fall through to reflection
        }
        try {
            val f = findMethodField(conn.javaClass)
            f.isAccessible = true
            f.set(conn, method)
        } catch (t: Throwable) {
            try { conn.disconnect() } catch (_: Throwable) {}
            throw UnsupportedOperationException(
                "Android HttpURLConnection 拒绝自定义动词 '$method'" +
                    "（反射失败: ${t.javaClass.name}: ${t.message}）",
            )
        }
    }

    /** 从实现类向上找 protected String method（Android 基类 java.net.HttpURLConnection 声明）。 */
    private fun findMethodField(c: Class<*>): Field {
        var k: Class<*>? = c
        while (k != null) {
            try {
                return k.getDeclaredField("method")
            } catch (_: NoSuchFieldException) {
                k = k.superclass
            }
        }
        throw NoSuchFieldException("HttpURLConnection.method not found on $c")
    }
}
