// native/android: sa_core::http transport for Android (W4-4, Plan B).
//
// Drives Kotlin com.studentage.editor.BackendHttp (java.net.HttpURLConnection)
// through cached static method IDs. The seven W4-3 handover contracts, mapped
// in this file + BackendHttp.kt:
//   (a) custom verbs PROPFIND/MKCOL   -> kt setVerb() reflection; a blocked
//       reflection surfaces as UnsupportedOperationException -> Other with an
//       explicit message (hide-API long-term risk, W4-6 real-device watch).
//   (b) request_stream chunk pacing,
//       early abort -> Error::None + partial body   -> the read loop below
//       hands every Java-side InputStream.read() return straight to on_chunk;
//       false => close + return what was delivered, error None.
//   (c) error categories Timeout / Connection / Tls / BadInput  -> classify
//       on the thrown exception's class name (services phrase the Chinese
//       user text off these).
//   (d) status >= 400 is NOT an error -> Kotlin reads errorStream; the C++
//       side only ever sets error on a thrown transport exception.
//   (e) follow redirects -> Kotlin instanceFollowRedirects=true.
//   (f) system CAs + thread safety -> platform trust store via
//       HttpURLConnection; per-request state only, worker threads attach
//       themselves (AttachCurrentThreadAsDaemon), matching the 64-slot httpd.
//   (g) binary request bodies with embedded NUL -> bodies cross JNI as
//       byte[] with setFixedLengthStreamingMode, never as a C string.
#include <cctype>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <android/log.h>
#include <jni.h>

#include "sa_core/http_client.h"
#include "sa_core/utf8.h"

namespace sa {
namespace android_http {
namespace {

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "StudentAgeBackend", __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, "StudentAgeBackend", __VA_ARGS__)

JavaVM* g_vm = nullptr;
jclass g_cls = nullptr;  // global ref: com/studentage/editor/BackendHttp
jmethodID g_open = nullptr;     // (String,String,String[],byte[],int,int):Long
jmethodID g_status = nullptr;   // (Long):Int
jmethodID g_headers = nullptr;  // (Long):String[]
jmethodID g_read = nullptr;     // (Long,byte[]):Int
jmethodID g_close = nullptr;    // (Long):Void

std::once_flag g_warn_once;

// Attach-if-needed JNIEnv holder (contract f: transport callers are C++
// threads — the httpd worker pool — not Java threads).
struct JniEnv {
    JNIEnv* env = nullptr;
    bool attached_here = false;
    bool ok() const { return env != nullptr; }
    JniEnv() {
        if (!g_vm) return;
        if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK)
            return;
        JavaVMAttachArgs args;
        args.version = JNI_VERSION_1_6;
        args.name = const_cast<char*>("sa-http");
        args.group = nullptr;
        if (g_vm->AttachCurrentThread(&env, &args) == JNI_OK) {
            attached_here = true;
        } else {
            env = nullptr;
        }
    }
    ~JniEnv() {
        if (attached_here && g_vm) {
            if (env && env->ExceptionCheck()) env->ExceptionClear();
            g_vm->DetachCurrentThread();
        }
    }
};

std::string jstring_to_utf8(JNIEnv* env, jstring s) {
    if (!s) return {};
    // UTF-16 path, not GetStringUTFChars: the latter returns Modified UTF-8 in
    // which astral code points are CESU-8 surrogate pairs (invalid UTF-8).
    const jchar* c = env->GetStringChars(s, nullptr);
    if (!c) return {};
    std::string out = sa_core::utf16_to_utf8(reinterpret_cast<const char16_t*>(c),
                                             env->GetStringLength(s));
    env->ReleaseStringChars(s, c);
    return out;
}

// Outbound jstring via NewString(UTF-16), never NewStringUTF: the latter
// expects Modified UTF-8, and a 4-byte UTF-8 sequence (emoji, CJK Ext-B in an
// unencoded WebDAV URL or header value) is illegal input for it — some ART
// versions mangle the string, others raise. Invalid bytes decode as U+FFFD.
jstring new_jstring(JNIEnv* env, const std::string& utf8) {
    std::vector<jchar> u16;
    u16.reserve(utf8.size());
    size_t i = 0;
    const size_t n = utf8.size();
    auto push_cp = [&](uint32_t cp) {
        if (cp >= 0x10000) {
            cp -= 0x10000;
            u16.push_back(static_cast<jchar>(0xD800 | (cp >> 10)));
            u16.push_back(static_cast<jchar>(0xDC00 | (cp & 0x3FF)));
        } else {
            u16.push_back(static_cast<jchar>(cp));
        }
    };
    while (i < n) {
        unsigned char c = static_cast<unsigned char>(utf8[i]);
        uint32_t cp = 0xFFFD;
        size_t len = 1;
        if (c < 0x80) {
            cp = c;
        } else if ((c & 0xE0) == 0xC0 && i + 1 < n &&
                   (static_cast<unsigned char>(utf8[i + 1]) & 0xC0) == 0x80) {
            cp = ((c & 0x1Fu) << 6) | (utf8[i + 1] & 0x3Fu);
            len = 2;
        } else if ((c & 0xF0) == 0xE0 && i + 2 < n &&
                   (static_cast<unsigned char>(utf8[i + 1]) & 0xC0) == 0x80 &&
                   (static_cast<unsigned char>(utf8[i + 2]) & 0xC0) == 0x80) {
            cp = ((c & 0x0Fu) << 12) | ((utf8[i + 1] & 0x3Fu) << 6) | (utf8[i + 2] & 0x3Fu);
            len = 3;
        } else if ((c & 0xF8) == 0xF0 && i + 3 < n &&
                   (static_cast<unsigned char>(utf8[i + 1]) & 0xC0) == 0x80 &&
                   (static_cast<unsigned char>(utf8[i + 2]) & 0xC0) == 0x80 &&
                   (static_cast<unsigned char>(utf8[i + 3]) & 0xC0) == 0x80) {
            cp = ((c & 0x07u) << 18) | ((utf8[i + 1] & 0x3Fu) << 12) |
                 ((utf8[i + 2] & 0x3Fu) << 6) | (utf8[i + 3] & 0x3Fu);
            len = 4;
        }
        push_cp(cp);
        i += len;
    }
    return env->NewString(u16.data(), static_cast<jsize>(u16.size()));
}

// Consume any pending exception: classify it + build "Class: message".
// Returns Error::None when nothing is pending.
sa_core::http::Response::Error take_exception(JNIEnv* env, std::string* msg) {
    using Err = sa_core::http::Response::Error;
    jthrowable ex = env->ExceptionOccurred();
    if (!ex) return Err::None;
    env->ExceptionClear();

    std::string cls, detail;
    jclass exCls = env->GetObjectClass(ex);
    jclass classCls = env->FindClass("java/lang/Class");
    jmethodID getName = classCls
        ? env->GetMethodID(classCls, "getName", "()Ljava/lang/String;")
        : nullptr;
    if (getName) {
        auto name = (jstring)env->CallObjectMethod(exCls, getName);
        cls = jstring_to_utf8(env, name);
        if (name) env->DeleteLocalRef(name);
    } else {
        // GetMethodID failure leaves a pending NoSuchMethodError; left set it
        // would poison every later JNI call on this thread.
        env->ExceptionClear();
    }
    env->DeleteLocalRef(exCls);
    if (classCls) env->DeleteLocalRef(classCls);

    jclass ex_cls2 = env->GetObjectClass(ex);
    jmethodID get_msg = env->GetMethodID(ex_cls2, "getMessage",
                                         "()Ljava/lang/String;");
    env->DeleteLocalRef(ex_cls2);
    if (get_msg) {
        auto m = (jstring)env->CallObjectMethod(ex, get_msg);
        detail = jstring_to_utf8(env, m);
        if (m) env->DeleteLocalRef(m);
    } else {
        env->ExceptionClear();
    }
    env->DeleteLocalRef(ex);
    if (cls.empty()) {
        *msg = "unknown Java exception";
        return Err::Other;
    }

    auto has = [&](const char* needle) {
        return cls.find(needle) != std::string::npos;
    };
    // Contract (c) — mirrors the WinHTTP/curl switches' categories.
    Err kind;
    if (has("java.net.SocketTimeoutException")) {
        kind = Err::Timeout;
    } else if (has("javax.net.ssl.SSLException") ||
               has("java.security.cert.CertificateException")) {
        kind = Err::Tls;
    } else if (has("java.net.UnknownHostException") ||
               has("java.net.ConnectException") ||
               has("java.net.SocketException") ||
               has("java.net.NoRouteToHostException")) {
        kind = Err::Connection;
    } else if (has("java.net.MalformedURLException") ||
               has("java.net.URISyntaxException") ||
               has("java.net.ProtocolException") ||
               has("java.lang.IllegalArgumentException")) {
        kind = Err::BadInput;
    } else {
        // Contract (a) degradation lands here (UnsupportedOperationException
        // from the reflection hack) carrying Kotlin's explicit message.
        kind = Err::Other;
    }
    *msg = cls + (detail.empty() ? "" : ": " + detail);
    return kind;
}

}  // namespace

bool install(JNIEnv* env, JavaVM* vm) {
    g_vm = vm;
    if (!env || !vm) return false;
    if (g_cls) return true;  // idempotent
    jclass local = env->FindClass("com/studentage/editor/BackendHttp");
    if (!local) {
        env->ExceptionClear();
        LOGW("BackendHttp class not found — outbound HTTP disabled");
        return false;
    }
    g_cls = (jclass)env->NewGlobalRef(local);
    env->DeleteLocalRef(local);
    g_open = env->GetStaticMethodID(
        g_cls, "httpOpen",
        "(Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;[BII)J");
    g_status = env->GetStaticMethodID(g_cls, "httpStatus", "(J)I");
    g_headers = env->GetStaticMethodID(g_cls, "httpHeaders",
                                       "(J)[Ljava/lang/String;");
    g_read = env->GetStaticMethodID(g_cls, "httpRead", "(J[B)I");
    g_close = env->GetStaticMethodID(g_cls, "httpClose", "(J)V");
    if (env->ExceptionCheck() || !g_open || !g_status || !g_headers || !g_read ||
        !g_close) {
        env->ExceptionClear();
        env->DeleteGlobalRef(g_cls);  // never leak the ref on a failed install
        g_cls = nullptr;
        LOGW("BackendHttp method IDs missing — outbound HTTP disabled");
        return false;
    }
    LOGI("JNI HTTP bridge installed (Plan B: HttpURLConnection)");
    return true;
}

namespace detail {

sa_core::http::Response do_request(const sa_core::http::Request& req,
                                   const sa_core::http::ChunkHandler* on_chunk) {
    using Resp = sa_core::http::Response;
    Resp resp;
    auto fail = [](const Resp::Error kind, const std::string& msg) {
        Resp r;
        r.error = kind;
        r.error_message = msg;
        return r;
    };
    if (!g_cls) {
        return fail(Resp::Error::Other,
                    "Android HTTP bridge 未初始化（nativeStart 之前不接受外呼）");
    }

    JniEnv j;
    if (!j.ok()) return fail(Resp::Error::Other, "JNI AttachCurrentThread 失败");
    JNIEnv* env = j.env;

    const std::string method = req.method.empty() ? "GET" : req.method;
    const int ms = static_cast<int>(
        std::llround(std::max(0.5, req.timeout_seconds) * 1000.0));

    jstring jurl = new_jstring(env, req.url);
    jstring jmethod = new_jstring(env, method);
    if (env->ExceptionCheck()) {
        std::string em;
        take_exception(env, &em);
        return fail(Resp::Error::BadInput, "URL/method 含非法字符: " + em);
    }

    // Headers, in order; the WinHTTP default Accept when the caller gave
    // none (parity with the other two transports).
    std::vector<std::string> lines;
    bool has_accept = false;
    for (const auto& kv : req.headers) {
        std::string lower;
        for (char c : kv.first) lower.push_back((char)std::tolower((unsigned char)c));
        if (lower == "accept") has_accept = true;
        lines.push_back(kv.first + ": " + kv.second);
    }
    if (!has_accept) lines.push_back("Accept: */*");
    jclass str_cls = env->FindClass("java/lang/String");
    jobjectArray jheaders =
        env->NewObjectArray((jsize)lines.size(), str_cls, nullptr);
    for (size_t i = 0; i < lines.size(); ++i) {
        jstring s = new_jstring(env, lines[i]);
        env->SetObjectArrayElement(jheaders, (jsize)i, s);
        env->DeleteLocalRef(s);
    }
    if (str_cls) env->DeleteLocalRef(str_cls);
    if (env->ExceptionCheck()) {
        std::string em;
        take_exception(env, &em);
        return fail(Resp::Error::BadInput, "header 含非法字符: " + em);
    }

    // Contract (g): binary-safe body via byte[]. Empty POSTs still send a
    // zero-length body so Content-Length: 0 goes on the wire, matching
    // WinHTTP/curl; every other empty-body verb sends no body at all.
    jbyteArray jbody = nullptr;
    if (!req.body.empty() || method == "POST") {
        jbody = env->NewByteArray((jsize)req.body.size());
        if (jbody == nullptr) {
            // Allocation failed (OutOfMemoryError pending): Clear it so the
            // subsequent CallStaticLongMethod does not run with a pending throw.
            env->ExceptionClear();
            return fail(Resp::Error::Other, "Android JNI: 分配请求体字节数组失败");
        }
        if (!req.body.empty()) {
            env->SetByteArrayRegion(jbody, 0, (jsize)req.body.size(),
                                    (const jbyte*)req.body.data());
            if (env->ExceptionCheck()) {
                std::string em2;
                take_exception(env, &em2);
                env->DeleteLocalRef(jbody);
                return fail(Resp::Error::Other, "Android JNI: 写入请求体失败: " + em2);
            }
        }
    }

    std::string em;
    Resp::Error kind;
    jlong handle = env->CallStaticLongMethod(g_cls, g_open, jurl, jmethod,
                                             jheaders, jbody, (jint)ms, (jint)ms);
    if ((kind = take_exception(env, &em)) != Resp::Error::None) {
        return fail(kind, "Android HttpURLConnection: " + em);
    }

    auto close_handle = [&] {
        env->CallStaticVoidMethod(g_cls, g_close, handle);
        env->ExceptionClear();
    };

    // Status + headers parse before the first body chunk fires (both other
    // transports order it the same way; the SSE callers rely on it).
    jint status = env->CallStaticIntMethod(g_cls, g_status, handle);
    if ((kind = take_exception(env, &em)) != Resp::Error::None) {
        close_handle();
        return fail(kind, "Android HttpURLConnection: " + em);
    }
    resp.status = (int)status;  // contract (d): >= 400 stays a success below

    auto jhs = (jobjectArray)env->CallStaticObjectMethod(g_cls, g_headers,
                                                         handle);
    if ((kind = take_exception(env, &em)) != Resp::Error::None) {
        close_handle();
        return fail(kind, "Android HttpURLConnection: " + em);
    }
    if (jhs) {
        const jsize n = env->GetArrayLength(jhs);
        for (jsize i = 0; i + 1 < n; i += 2) {
            auto k = (jstring)env->GetObjectArrayElement(jhs, i);
            auto v = (jstring)env->GetObjectArrayElement(jhs, i + 1);
            resp.headers.emplace_back(jstring_to_utf8(env, k),
                                      jstring_to_utf8(env, v));
            env->DeleteLocalRef(k);
            env->DeleteLocalRef(v);
        }
        env->DeleteLocalRef(jhs);
    }

    // Contract (b): chunk loop. Each Java InputStream.read(buf) return is
    // delivered verbatim to on_chunk (network pacing preserved); false =>
    // stop, keep the partial body, Error stays None (SSE early-abort).
    constexpr jsize kChunk = 65536;
    jbyteArray jbuf = env->NewByteArray(kChunk);
    std::vector<char> scratch((size_t)kChunk);
    for (;;) {
        jint n = env->CallStaticIntMethod(g_cls, g_read, handle, jbuf);
        if ((kind = take_exception(env, &em)) != Resp::Error::None) {
            env->DeleteLocalRef(jbuf);
            close_handle();
            return fail(kind, "Android HttpURLConnection read: " + em);
        }
        if (n < 0) break;      // EOF
        if (n == 0) continue;  // defensive: Kotlin's blocking read never returns 0
        env->GetByteArrayRegion(jbuf, 0, n, (jbyte*)scratch.data());
        resp.body.append(scratch.data(), (size_t)n);
        if (on_chunk && *on_chunk &&
            !(*on_chunk)(std::string_view(scratch.data(), (size_t)n))) {
            break;  // early abort: contract (b) — NOT an error
        }
    }
    env->DeleteLocalRef(jbuf);
    close_handle();

    std::call_once(g_warn_once, [] { LOGI("JNI HTTP transport active"); });
    return resp;
}

}  // namespace detail
}  // namespace android_http
}  // namespace sa

// The sa_core::http entry points the Android build links in place of the
// core/http_client.cpp stub (SA_ANDROID_HTTP_BRIDGE, see that file).
namespace sa_core {
namespace http {

Response request(const Request& req) {
    return sa::android_http::detail::do_request(req, nullptr);
}

Response request_stream(const Request& req, const ChunkHandler& on_chunk) {
    return sa::android_http::detail::do_request(req, &on_chunk);
}

}  // namespace http
}  // namespace sa_core
