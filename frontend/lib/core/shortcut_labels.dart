/// 快捷键提示文案的平台适配。
///
/// 仓库里 `Shortcuts` 同时注册了 Ctrl 与 Meta（见 app_shortcuts.dart），但
/// 界面提示此前一律写死 `Ctrl+S`——Web 端在 macOS 上是 ⌘，照抄 Ctrl 会让
/// 用户以为提示失效。这里集中一处换算，提示与真实按键才一致。
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

/// 是否 Apple 平台（macOS / iOS / iPadOS 浏览器）。
///
/// Web 上 [defaultTargetPlatform] 由浏览器 UA 推断，mac 用户拿到 macOS，
/// 因此同一份代码在 Mac 浏览器里也会显示 ⌘。
bool get isApplePlatform =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// 修饰键显示名：`⌘` 或 `Ctrl`。
String get modKeyLabel => isApplePlatform ? '⌘' : 'Ctrl';

/// 组合键提示：`Ctrl+S` / `⌘S`。
String shortcutLabel(String key) => '$modKeyLabel+$key';

/// 保存快捷键提示。
String get saveShortcutLabel => shortcutLabel('S');

/// 撤销 / 重做提示（工具提示用，带括号文案）。
String get undoTooltipLabel => '撤销 (${shortcutLabel('Z')})';

String get redoTooltipLabel => '重做 (${shortcutLabel('Y')})';
