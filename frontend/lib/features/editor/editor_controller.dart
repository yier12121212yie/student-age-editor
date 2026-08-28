import 'package:flutter/foundation.dart';

/// 打开的文档：cfg 表、任意文本文件、编辑页面或事件场景预览。
class OpenDoc {
  OpenDoc.cfg({required this.cfgName})
      : kind = 'cfg',
        path = '',
        pageId = '',
        eventId = '',
        title = cfgName;
  OpenDoc.file({required this.path, required this.title})
      : kind = 'file',
        cfgName = '',
        pageId = '',
        eventId = '';
  OpenDoc.page({required this.pageId, required this.title})
      : kind = 'page',
        cfgName = '',
        path = '',
        eventId = '';
  OpenDoc.preview({required this.eventId})
      : kind = 'preview',
        cfgName = '',
        path = '',
        pageId = '',
        title = '预览 #$eventId';

  final String kind; // cfg | file | page | preview
  final String cfgName;
  final String path;
  final String pageId;
  /// preview 文档的事件 ID（EvtCfg 条目）。
  final String eventId;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is OpenDoc &&
      other.kind == kind &&
      other.cfgName == cfgName &&
      other.path == path &&
      other.pageId == pageId &&
      other.eventId == eventId;
  @override
  int get hashCode => Object.hash(kind, cfgName, path, pageId, eventId);
}

/// 编辑区标签管理。
class EditorController extends ChangeNotifier {
  final List<OpenDoc> docs = [];
  int currentIndex = -1;

  void open(OpenDoc doc) {
    final idx = docs.indexOf(doc);
    if (idx >= 0) {
      currentIndex = idx;
    } else {
      docs.add(doc);
      currentIndex = docs.length - 1;
    }
    notifyListeners();
  }

  void close(int index) {
    if (index < 0 || index >= docs.length) return;
    docs.removeAt(index);
    if (docs.isEmpty) {
      currentIndex = -1;
    } else {
      currentIndex = index.clamp(0, docs.length - 1);
    }
    notifyListeners();
  }

  OpenDoc? get current => currentIndex >= 0 && currentIndex < docs.length ? docs[currentIndex] : null;
}
