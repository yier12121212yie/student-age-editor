plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Chaquopy：在应用内嵌 CPython，运行本地 API 后端（editor.server）
    id("com.chaquo.python")
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
        // Chaquopy 需要；arm64 覆盖现网设备，x86_64 供模拟器。
        // 配合 gradle.properties 中 disable-abi-filtering=true：
        // Flutter 插件默认会把全部 ABI（含 Python 3.12 不支持的 armeabi-v7a/x86）
        // 强制写入 defaultConfig，导致 Chaquopy 配置期校验失败，故关闭其注入。
        abiFilters += listOf("arm64-v8a", "x86_64")
    }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

chaquopy {
    defaultConfig {
        // 与桌面后端同为 Python 3.12；buildPython 取 PATH 上的同版本解释器
        version = "3.12"
        pip {
            // UnityPy 的原生依赖（Chaquopy 官方仓库提供 Android 轮子）
            install("brotli")
            install("lz4")
            install("Pillow")
            // 纯 Python 依赖（tpk_ar 仅为 UnityPy 打包期依赖，运行时不需要）
            install("fsspec")
            install("attrs")
        }
    }
}
