/// Web 版平台环境：无操作系统、无环境变量，全部给出「无」语义。
bool get isWindowsPlatform => false;

bool get isAndroidPlatform => false;

String? envValue(String name) => null;

/// Web 上由 `webEnvironmentSummary()` 提供浏览器环境，这里为空串。
String desktopEnvironmentSummary() => '';
