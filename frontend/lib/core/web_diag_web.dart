/// Web：把启动/渲染状态写到 `window.__editorDiag`（F12 控制台可读）。
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('__editorDiag')
external set _diagRoot(JSObject value);

JSObject? _root;

/// Dart 侧副本：`window.__editorDiag` 只能从 JS 读，设置页「复制诊断信息」
/// 需要在 Dart 里直接拿到同一份内容，免去 interop 反射。
final Map<String, String> _entries = <String, String>{};

void markWebDiag(String key, String value) {
  _entries[key] = value;
  final root = _root ??= JSObject();
  root.setProperty(key.toJS, value.toJS);
  _diagRoot = root;
}

/// 当前诊断快照（只读副本）。
Map<String, String> webDiagEntries() => Map<String, String>.unmodifiable(_entries);
