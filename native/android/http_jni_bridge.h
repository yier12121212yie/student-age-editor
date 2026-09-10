// native/android: the W4-4 Plan-B outbound-HTTP bridge (JNI -> Kotlin
// BackendHttp -> HttpURLConnection), providing sa_core::http::request /
// request_stream on Android (the __ANDROID__ stub in
// core/http_client.cpp steps aside under SA_ANDROID_HTTP_BRIDGE).
//
// Lifecycle: jni_bridge.cpp's nativeStart() runs ON A JAVA THREAD (the
// Kotlin "backend" thread). That is the one moment FindClass can see the app
// classloader, so the BackendHttp class + method IDs are cached there.
// Later requests arrive on C++ std::thread workers (httpd slots) which
// AttachCurrentThreadAsDaemon on demand.
#pragma once

#include <jni.h>

namespace sa {
namespace android_http {

// Cache JavaVM + com/studentage/editor/BackendHttp and its static method
// IDs. Returns false (no throw) when anything is missing; requests then
// answer a clear Other error. Idempotent.
bool install(JNIEnv* env, JavaVM* vm);

}  // namespace android_http
}  // namespace sa
