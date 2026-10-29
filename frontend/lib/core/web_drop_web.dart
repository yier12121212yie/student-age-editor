/// Web：把「拖文件到窗口」变成一次资源导入。
///
/// 两层作用：
/// 1. **防事故**：浏览器默认会直接打开被拖入的文件（整页跳走）。这里在
///    dragover / drop 上一律 preventDefault，页面不会被替换。
/// 2. **顺手导入**：读成字节后交给 Dart 侧（与「导入本地…」共用同一条上传/
///    引用链路，见 features/resources/local_import.dart）。
///
/// 覆盖层用原生 DOM 画：拖拽过程中 Flutter 收不到 HTML5 拖放事件，用 Dart
/// 重建一整套覆盖层反而要额外维护两套状态，收益不高。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'web_diag.dart';

/// 拖入的文件（只有文件名与字节；浏览器拿不到路径）。
typedef DroppedFile = ({String name, Uint8List bytes});

/// 收到一批拖入文件时的回调。
typedef DropHandler = Future<void> Function(List<DroppedFile> files);

class WebFileDrop {
  WebFileDrop._({required this._onFiles}) {
    web.window.addEventListener('dragenter', _onDragEnterJs);
    web.window.addEventListener('dragover', _onDragOverJs);
    web.window.addEventListener('dragleave', _onDragLeaveJs);
    web.window.addEventListener('drop', _onDropJs);
    // Ctrl+V 粘贴截图：只在「当前不在文本输入里」时接管（见 _onPaste）。
    web.document.addEventListener('paste', _onPasteJs);
  }

  static WebFileDrop? _instance;

  /// 幂等安装；重复调用返回同一实例。
  static WebFileDrop? install({required DropHandler onFiles}) =>
      _instance ??= WebFileDrop._(onFiles: onFiles);
  static void uninstall() {
    final inst = _instance;
    if (inst == null) return;
    _instance = null;
    web.window.removeEventListener('dragenter', inst._onDragEnterJs);
    web.window.removeEventListener('dragover', inst._onDragOverJs);
    web.window.removeEventListener('dragleave', inst._onDragLeaveJs);
    web.window.removeEventListener('drop', inst._onDropJs);
    web.document.removeEventListener('paste', inst._onPasteJs);
    inst._hideOverlay();
    inst._overlay?.remove();
  }

  late final JSFunction _onDragEnterJs = _onDragEnter.toJS;
  late final JSFunction _onDragOverJs = _onDragOver.toJS;
  late final JSFunction _onDragLeaveJs = _onDragLeave.toJS;
  late final JSFunction _onDropJs = _onDrop.toJS;
  late final JSFunction _onPasteJs = _onPaste.toJS;

  final DropHandler _onFiles;
  web.HTMLDivElement? _overlay;
  int _depth = 0;
  bool _busy = false;

  void dispose() => uninstall();

  // ---------------------------------------------------------------- 拖拽事件

  bool _hasFiles(web.Event event) {
    final dt = (event as web.DragEvent).dataTransfer;
    if (dt == null) return false;
    for (final type in dt.types.toDart) {
      if (type.toDart == 'Files') return true;
    }
    return false;
  }

  void _onDragEnter(web.Event event) {
    if (!_hasFiles(event)) return;
    event.preventDefault();
    _depth++;
    _showOverlay();
  }

  void _onDragOver(web.Event event) {
    if (!_hasFiles(event)) return;
    // 不 preventDefault 就不会触发 drop，浏览器还会接管这次拖放。
    event.preventDefault();
    (event as web.DragEvent).dataTransfer?.dropEffect = 'copy';
    _showOverlay();
  }

  void _onDragLeave(web.Event event) {
    // 不判 _hasFiles：部分浏览器在 dragleave 时已清空 dataTransfer.types，
    // 判了就会漏减深度，覆盖层再也关不掉。非文件拖拽时 _depth 恒为 0，
    // 这里的 max(0, …) 与 _hideOverlay 都是空操作。
    _depth = math.max(0, _depth - 1);
    if (_depth == 0) _hideOverlay();
  }

  void _onDrop(web.Event event) {
    if (!_hasFiles(event)) return;
    event.preventDefault();
    _depth = 0;
    _hideOverlay();
    final dt = (event as web.DragEvent).dataTransfer;
    final files = dt?.files;
    if (files == null || files.length == 0 || _busy) return;
    markWebDiag('intake', 'drop files=${files.length}');
    unawaited(_deliver(files));
  }

  /// Ctrl+V：剪贴板里带文件（截图、复制的图片文件）时按「导入」处理。
  ///
  /// 两条安全边界：
  /// - **正在编辑文本时不接管**（Flutter 的输入法宿主是 `<input>/<textarea>`），
  ///   否则用户往单元格里粘字会被抢走；
  /// - 剪贴板没有文件时什么都不做（普通文本粘贴完全不受影响）。
  void _onPaste(web.Event event) {
    final cb = (event as web.ClipboardEvent).clipboardData;
    final files = cb?.files;
    if (files == null || files.length == 0 || _busy) return;
    if (_isEditingText()) return;
    markWebDiag('intake', 'paste files=${files.length}');
    unawaited(_deliver(files));
  }

  bool _isEditingText() {
    final el = web.document.activeElement;
    if (el == null) return false;
    final tag = el.tagName.toUpperCase();
    if (tag == 'INPUT' || tag == 'TEXTAREA') return true;
    return (el as web.HTMLElement).isContentEditable;
  }

  Future<void> _deliver(web.FileList files) async {
    _busy = true;
    try {
      final out = <DroppedFile>[];
      for (var i = 0; i < files.length; i++) {
        final f = files.item(i);
        if (f == null) continue;
        final buffer = await f.arrayBuffer().toDart;
        out.add((name: f.name, bytes: buffer.toDart.asUint8List()));
      }
      if (out.isEmpty) return;
      await _onFiles(out);
    } catch (e) {
      debugPrint('[drop] 读取拖入文件失败：$e');
    } finally {
      _busy = false;
    }
  }

  // ---------------------------------------------------------------- 覆盖层

  void _showOverlay() {
    final el = _overlay ??= _createOverlay();
    if (el.style.display != 'flex') el.style.display = 'flex';
  }

  void _hideOverlay() {
    final el = _overlay;
    if (el != null && el.style.display != 'none') el.style.display = 'none';
  }

  web.HTMLDivElement _createOverlay() {
    final el = web.document.createElement('div') as web.HTMLDivElement;
    el.id = '__editor_drop_overlay';
    el.style.cssText = [
      'position:fixed',
      'inset:0',
      'display:none',
      'align-items:center',
      'justify-content:center',
      'flex-direction:column',
      'gap:10px',
      'z-index:2147483000',
      'pointer-events:none',
      'background:rgba(27,27,46,0.72)',
      "font-family:'Microsoft YaHei','PingFang SC',sans-serif",
      'color:#fff',
      'text-align:center',
      'padding:24px',
      'box-sizing:border-box',
    ].join(';');
    final title = web.document.createElement('div');
    title.textContent = '松开以导入到当前模组';
    title.setAttribute(
        'style', 'font-size:20px;letter-spacing:1px;font-weight:600');
    final sub = web.document.createElement('div');
    sub.textContent = '支持图片 / 音频 / 视频；其它类型请用「导入本地…」';
    sub.setAttribute('style', 'font-size:13px;opacity:.78;max-width:420px');
    el.append(title);
    el.append(sub);
    web.document.body?.append(el);
    return el;
  }
}
