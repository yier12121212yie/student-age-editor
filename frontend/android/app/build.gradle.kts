plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // W4-4: Chaquopy removed — the backend is the native libbackend_shared.so
    // (jniLibs/, built by native/android/android_build.sh; MainActivity.kt
    // System.loadLibrary + nativeStart).
}

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

    ndk {
        // libbackend_shared.so 只交叉编译这两个 ABI（arm64 覆盖现网设备，
        // x86_64 供模拟器）；armeabi-v7a/x86 无 native 后端，保持排除。
        abiFilters += listOf("arm64-v8a", "x86_64")
    }
    }

    // 正式签名用的 keystore 不入库（.gitignore: *.keystore），CI 上不存在。
    // 本地放好 frontend/android/keystore/release.keystore 即自动启用正式签名；
    // 缺失时回落到 debug 签名（与 Alpha-v0.5 的出厂行为一致），保证 release 通道能出包。
    val releaseKeystore = file("${project.projectDir}/../keystore/release.keystore")

    signingConfigs {
        if (releaseKeystore.exists()) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = "studentage2024"
                keyAlias = "studentage"
                keyPassword = "studentage2024"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseKeystore.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
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
