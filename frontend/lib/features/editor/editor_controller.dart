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

  /// 有未保存修改的 cfg 文档（阶段 2b）：由挂载的 SchemaEditorView 经
  /// markDirty 上报，页签关闭/切换前据此弹确认，防静默丢改动。
  final Set<OpenDoc> _dirtyDocs = {};
  bool isDirty(OpenDoc doc) => _dirtyDocs.contains(doc);
  void markDirty(OpenDoc doc, bool dirty) {
    final changed = dirty ? _dirtyDocs.add(doc) : _dirtyDocs.remove(doc);
    if (changed) notifyListeners();
  }

  /// 每次 open() 递增的序号。带底部导航的壳（MobileShell）据此区分
  /// 「新打开/重新激活文档」（需要切到编辑 tab）与普通状态变化
  /// （dirty、close 等——不应劫持用户当前所在的 tab）。
  int openSeq = 0;

  void open(OpenDoc doc) {
    openSeq++;
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
    final doc = docs[index];
    docs.removeAt(index);
    _dirtyDocs.remove(doc);
    if (docs.isEmpty) {
      currentIndex = -1;
    } else {
      currentIndex = index.clamp(0, docs.length - 1);
    }
    notifyListeners();
  }

  /// 按文档对象关闭（阶段 2b）：页签回调持有的是 doc，按下标关要在
  /// 点击瞬间回找下标——列表在 build 之后发生变化时按下标会关错页签。
  void closeDoc(OpenDoc doc) {
    final i = docs.indexOf(doc);
    if (i >= 0) close(i);
  }

  OpenDoc? get current => currentIndex >= 0 && currentIndex < docs.length ? docs[currentIndex] : null;
}
