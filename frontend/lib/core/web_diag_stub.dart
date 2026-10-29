/// 非 Web：没有浏览器控制台可写，但诊断页仍需要一份进程内快照。
library;

final Map<String, String> _entries = <String, String>{};

void markWebDiag(String key, String value) {
  _entries[key] = value;
}

/// 桌面端的启动/渲染阶段快照（与 Web 的 `window.__editorDiag` 同形）。
Map<String, String> webDiagEntries() => Map<String, String>.unmodifiable(_entries);
