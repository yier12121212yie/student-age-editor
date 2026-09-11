import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 容错字符串取值：非字符串（数字/布尔/对象）转字符串，null/缺失归 ''。
/// 后端 or_raw 会原样透传 manifest 值，`"version": 2` 之类不能抛异常。
String _jsonStr(Object? v) => v == null ? '' : (v is String ? v : v.toString());

/// uiPanels 中必须为字符串的字段；refresh 时统一归一化，
/// 避免 activity_bar/mobile_shell 在 build 期做无保护的 `as String?`。
const List<String> _panelStringKeys = [
  'plugin_id',
  'panel_id',
  'title',
  'icon',
  'description',
];

Map<String, dynamic> _normPanel(Map e) {
  final m = Map<String, dynamic>.from(e);
  for (final k in _panelStringKeys) {
    if (m.containsKey(k)) m[k] = _jsonStr(m[k]);
  }
  return m;
}

/// 插件条目（来自 GET /api/plugins）。
class PluginSummary {
  PluginSummary({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.entry,
    required this.enabled,
    required this.loaded,
    required this.error,
    required this.riskAckAt,
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String entry;
  final bool enabled;
  final bool loaded;
  final String error;
  /// 用户上次确认高危启用的时间（ISO 字符串，空表示未确认过）。
  final String riskAckAt;

  /// 容错解析：任何字段缺失/类型不符都不抛异常。
  factory PluginSummary.fromJson(Map<String, dynamic> json) => PluginSummary(
        id: _jsonStr(json['id']),
        name: _jsonStr(json['name']),
        version: _jsonStr(json['version']),
        author: _jsonStr(json['author']),
        description: _jsonStr(json['description']),
        entry: _jsonStr(json['entry']),
        enabled: json['enabled'] == true,
        loaded: json['loaded'] == true,
        error: _jsonStr(json['error']),
        riskAckAt: _jsonStr(json['risk_ack_at']),
      );
}

/// 插件系统全局状态：插件列表 + 已启用插件声明的 UI 面板。
/// 由 app.dart 创建并下传（对齐 AppState 模式）。
class PluginState extends ChangeNotifier {
  List<PluginSummary> plugins = [];
  /// /api/plugins/ui 返回的面板声明：
  /// [{plugin_id, panel_id, title, icon, description}]
  List<Map<String, dynamic>> uiPanels = [];
  bool loading = false;
  /// 最近一次 refresh 的错误信息（成功后清空）；UI 可据此展示重试。
  String? error;

  /// 并行拉取插件列表与面板声明；失败置错误态不抛出（对齐其他 refresh 容错风格）。
  Future<void> refresh() async {
    loading = true;
    notifyListeners();
    try {
      final rs = await Future.wait<dynamic>([
        ApiClient.instance.get('/api/plugins'),
        ApiClient.instance.get('/api/plugins/ui'),
      ]);
      final list = rs[0] is Map ? (rs[0]['plugins'] as List? ?? const []) : const [];
      plugins = [
        for (final e in list)
          if (e is Map) PluginSummary.fromJson(Map<String, dynamic>.from(e)),
      ];
      final panels = rs[1] is Map ? (rs[1]['panels'] as List? ?? const []) : const [];
      uiPanels = [
        for (final e in panels)
          if (e is Map) _normPanel(e),
      ];
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 卸载插件。声明型插件常开，若需「停用」请直接卸载（enable/disable 后端恒 410）。
  Future<dynamic> uninstall(String id) async {
    try {
      return await ApiClient.instance.delete('/api/plugins/$id');
    } finally {
      await refresh();
    }
  }

  /// 从本地 zip 安装：path 为已拷贝到可写临时目录的文件路径（对齐资源包导入流程）。
  Future<dynamic> installZip(String path, String filename) async {
    try {
      return await ApiClient.instance
          .post('/api/plugins/install_path', body: {'path': path, 'filename': filename});
    } finally {
      await refresh();
    }
  }

  /// 重新加载全部插件。
  Future<dynamic> reloadAll() async {
    try {
      return await ApiClient.instance.post('/api/plugins/reload');
    } finally {
      await refresh();
    }
  }
}
