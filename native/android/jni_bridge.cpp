// native/android: the JNI surface the Flutter app talks to (W4-4 — replaces
// the Chaquopy `Python.start + editor.server.start_server(...)` boot).
//
// Contract with MainActivity.kt:
//   nativeStart(port, dataRoot, packsRoot, bundledZip) -> Int
//       Starts sa::run_server on a dedicated C++ thread with the exact
//       desktop boot semantics (CONVENTIONS 11 env injection + bundled-zip
//       extraction live in run.cpp now, shared with Windows/POSIX). Blocks
//       until the socket is bound and returns the ACTUAL bound port — the
//       --write-port semantics translated to a return value (task brief W3).
//       Returns 0 on bind failure. Idempotent: while the server is up the
//       current port is returned without touching anything (the Kotlin
//       onResume re-entry path).
//   nativeStop()
//       request_exit() + join (the server loop prints the same
//       "API server listening ..."/"stopped" lines into logcat-absorbed
//       stdout as desktop).
#include <atomic>
#include <condition_variable>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include <android/log.h>
#include <jni.h>

#include "http_jni_bridge.h"
#include "sa_core/utf8.h"
#include "server/run.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "StudentAgeBackend", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "StudentAgeBackend", __VA_ARGS__)

namespace {

JavaVM* g_jvm = nullptr;
std::thread g_server_thread;
std::mutex g_start_mu;      // serializes start/stop
std::atomic<int> g_port{0};

std::string to_jstring_utf(JNIEnv* env, jstring s) {
    if (!s) return {};
    // GetStringChars yields full UTF-16; GetStringUTFChars would yield Modified
    // UTF-8 (CESU-8) where astral code points (CJK Ext-B, emoji) are 6 invalid
    // bytes. Convert via the UTF-16 path so paths/roots stay valid UTF-8.
    const jchar* c = env->GetStringChars(s, nullptr);
    if (!c) return {};
    std::string out = sa_core::utf16_to_utf8(reinterpret_cast<const char16_t*>(c),
                                             env->GetStringLength(s));
    env->ReleaseStringChars(s, c);
    return out;
}

}  // namespace

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
    g_jvm = vm;
    return JNI_VERSION_1_6;
}

JNIEXPORT jint JNICALL
Java_com_studentage_editor_MainActivity_nativeStart(JNIEnv* env, jobject /*thiz*/,
                                                    jint port, jstring dataRoot,
                                                    jstring packsRoot,
                                                    jstring bundledZip) {
    // C++ exceptions must never unwind across the JNI boundary (UB in the JVM,
    // typically abort): std::thread/make_shared/string ops here can throw.
    try {
        std::lock_guard<std::mutex> lk(g_start_mu);
        if (int live = g_port.load()) return live;  // Activity recreation

        // Cache BackendHttp NOW: this call runs on the Kotlin "backend" thread —
        // a Java thread whose classloader sees app classes (a C++ worker thread's
        // FindClass would only see the system loader). Failure is non-fatal:
        // inbound HTTP still works, outbound answers a clear Other error.
        if (!sa::android_http::install(env, g_jvm)) {
            LOGE("HTTP bridge install failed — outbound HTTP disabled");
        }

        auto cfg = std::make_shared<sa::ServerConfig>();
        cfg->port = port;
        cfg->data_root = to_jstring_utf(env, dataRoot);
        cfg->packs_root = to_jstring_utf(env, packsRoot);
        cfg->bundled_zip = to_jstring_utf(env, bundledZip);

        // Heap wait-state: the server thread outlives this function on success,
        // so the lambda must not reference nativeStart's stack.
        struct Waiter {
            std::mutex mu;
            std::condition_variable cv;
            int bound = 0;
            bool finished = false;
        };
        auto w = std::make_shared<Waiter>();
        cfg->on_ready = [w](int p) {
            {
                std::lock_guard<std::mutex> wl(w->mu);
                w->bound = p;
            }
            w->cv.notify_all();
        };
        g_server_thread = std::thread([cfg, w] {
            const int rc = sa::run_server(*cfg);
            {
                std::lock_guard<std::mutex> wl(w->mu);
                w->finished = true;
            }
            w->cv.notify_all();
            if (rc != 0) LOGE("run_server exited early (rc=%d)", rc);
        });

        // Wait for the bind (or an early give-up: bad port — run_server is
        // non-throwing so only bind failure ends it pre-ready). Bundled-zip
        // extraction runs inside run_server BEFORE the bind and may legitimately
        // take tens of seconds on device; no timeout here (Kotlin calls this off
        // the main thread).
        {
            std::unique_lock<std::mutex> wl(w->mu);
            w->cv.wait(wl, [&] { return w->bound != 0 || w->finished; });
        }
        if (w->bound > 0) {
            g_port.store(w->bound);
            LOGI("backend started on 127.0.0.1:%d", w->bound);
            return w->bound;
        }
        if (g_server_thread.joinable()) g_server_thread.join();
        LOGE("backend failed to bind on port %d", (int)port);
        return 0;
    } catch (const std::exception& e) {
        LOGE("nativeStart threw: %s", e.what());
        return 0;
    } catch (...) {
        LOGE("nativeStart threw: unknown");
        return 0;
    }
}

JNIEXPORT void JNICALL
Java_com_studentage_editor_MainActivity_nativeStop(JNIEnv* /*env*/,
                                                  jobject /*thiz*/) {
    try {
        std::lock_guard<std::mutex> lk(g_start_mu);
        sa::request_exit();
        if (g_server_thread.joinable()) g_server_thread.join();
        g_port.store(0);
        LOGI("backend stopped");
    } catch (const std::exception& e) {
        LOGE("nativeStop threw: %s", e.what());
    } catch (...) {
        LOGE("nativeStop threw: unknown");
    }
}

}  // extern "C"
