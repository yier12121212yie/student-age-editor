// `java.util.Properties` must be imported rather than fully qualified: inside a
// build script `java` resolves to the Gradle JavaPluginExtension, so
// `java.util.Properties()` fails to compile ("Unresolved reference 'util'").
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // W4-4: Chaquopy removed — the backend is the native libbackend_shared.so
    // (jniLibs/, built by native/android/android_build.sh; MainActivity.kt
    // System.loadLibrary + nativeStart).
}

// 正式签名用的 keystore 不入库（.gitignore: *.keystore / key.properties）。
// 凭证只来自 keystore/key.properties（gitignored，CI 由 secrets 注入）。
// 安全批次 A：删除 "studentage2024"/"studentage" 硬编码兜底 —— 密码写进
// 源码等于把签名权公开（历史泄露的 key 必须轮换，见 SECURITY_AUDIT_REPORT）。
// 这些 val 必须留在脚本顶层：`android {}` 是 lambda，写在其内部的局部变量
// 对下方 afterEvaluate 的签名守卫不可见（Kotlin DSL 会报 Unresolved
// reference 'hasReleaseSigning'）。
val keystoreDir = file("${project.projectDir}/../keystore")
val releaseKeystore = File(keystoreDir, "release.keystore")
val keyProps = Properties().apply {
    val f = File(keystoreDir, "key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseSigning = releaseKeystore.exists() &&
    !keyProps.getProperty("storePassword").isNullOrBlank() &&
    !keyProps.getProperty("keyAlias").isNullOrBlank() &&
    !keyProps.getProperty("keyPassword").isNullOrBlank()

android {
    namespace = "com.studentage.editor"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.studentage.editor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 注意：ABI 过滤不在这里（defaultConfig.ndk.abiFilters 会同时作用于
        // 所有 buildType，且与 buildType 级取并集、无法再按类型收缩），
        // 统一放到下方 buildTypes 内按 release/debug 分别声明。
    }

    // 签名材料与 hasReleaseSigning 见脚本顶层（afterEvaluate 守卫也要用）。
    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = keyProps.getProperty("storePassword")!!
                keyAlias = keyProps.getProperty("keyAlias")!!
                keyPassword = keyProps.getProperty("keyPassword")!!
            }
        }
    }

    buildTypes {
        debug {
            ndk {
                // 调试通道：真机 + 模拟器并用，保留 arm64-v8a 与 x86_64 双 ABI
                // （libbackend_shared.so 两档均有，见 native/android/android_build.sh）。
                abiFilters += listOf("arm64-v8a", "x86_64")
            }
        }
        release {
            ndk {
                // 体积收紧：x86_64 只服务模拟器，release 不再打包
                // （未 strip 的 x86_64 .so 约 74MB），只留 arm64-v8a 覆盖现网设备；
                // armeabi-v7a/x86 无 native 后端，维持排除。
                abiFilters += listOf("arm64-v8a")
            }
            // 无正式签名材料时配置期仍需占位 signingConfig（debug），否则
            // assembleDebug 都无法通过配置阶段；真正的阻断在下方任务级守卫：
            // 任何产出 release 工件的任务执行前直接抛异常，绝不静默产出
            // debug 签名的 release 包。
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

// 任务级签名守卫（安全批次 A）：release 工件任务执行前强校验 keystore 与
// key.properties 三件套齐全，缺失即中断并给出修复指引。
afterEvaluate {
    tasks.matching { task ->
        val n = task.name
        n == "assembleRelease" || n == "bundleRelease" ||
            n.startsWith("packageRelease") || n.startsWith("assembleRelease")
    }.configureEach {
        doFirst {
            if (!hasReleaseSigning) {
                throw GradleException(
                    "[signing] 缺少正式签名材料：frontend/android/keystore/ 下需要 " +
                    "release.keystore 与完整的 key.properties（storePassword/keyAlias/" +
                    "keyPassword）。release 产物禁止使用 debug 签名；本地调试请用 " +
                    "assembleDebug，正式发布由 CI secrets 注入 keystore。"
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
