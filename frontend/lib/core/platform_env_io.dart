import 'dart:io';

/// 当前是否 Windows（Web 上恒 false）。
bool get isWindowsPlatform => Platform.isWindows;

/// 当前是否 Android（Web 上恒 false——web 的“移动浏览器”不算 Android）。
bool get isAndroidPlatform => Platform.isAndroid;

/// 读取环境变量（Web 上恒 null）。
String? envValue(String name) => Platform.environment[name];
