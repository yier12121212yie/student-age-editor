import 'package:flutter/foundation.dart';

/// 模组信息（来自后端 /api/mods）。
class ModInfo {
  ModInfo({required this.name, required this.root, required this.cfgFiles,
      required this.hasManifest, required this.manifestTitle});
  final String name;
  final String root;
  final List<String> cfgFiles;
  final bool hasManifest;
  final String manifestTitle;

  factory ModInfo.fromJson(Map<String, dynamic> json) => ModInfo(
        name: json['name'] as String? ?? '',
        root: json['root'] as String? ?? '',
        cfgFiles: (json['cfg_files'] as List?)?.cast<String>() ?? [],
        hasManifest: json['has_manifest'] as bool? ?? false,
        manifestTitle: json['manifest_title'] as String? ?? '',
      );
}

/// 目录条目（文件树 / AI 工具）。
class FsEntry {
  FsEntry({required this.name, required this.type, required this.size});
  final String name;
  final String type; // dir | file
  final int size;

  factory FsEntry.fromJson(Map<String, dynamic> json) => FsEntry(
        name: json['name'] as String? ?? '',
        type: json['type'] as String? ?? 'file',
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

/// 全局应用状态。
class AppState extends ChangeNotifier {
  String workspaceRoot = '';
  String modRoot = '';
  String modName = '';
  List<ModInfo> mods = [];
  String aaStatus = 'idle';
  Map<String, dynamic> gameSchema = {};
  Map<String, dynamic> keyMaps = {};
  Map<String, dynamic> gameDicts = {};

  bool backendOnline = false;
  String backendError = '';

  void setAaStatus(String value) {
    if (aaStatus == value) return; // 值未变化不通知，避免轮询期间触发全量重建
    aaStatus = value;
    notifyListeners();
  }

  Future<void> refreshState() async {
    notifyListeners();
  }

  void setMod(String name, String root) {
    modName = name;
    modRoot = root;
    notifyListeners();
  }
}
