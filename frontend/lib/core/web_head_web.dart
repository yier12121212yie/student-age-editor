/// Web：守住 `<title>` 与 `theme-color`（原因见 web_head.dart）。
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// 与 index.html / manifest 保持一致的浏览器 UI 配色（浅 / 深）。
const String _lightBg = '#F5F5F8';
const String _darkBg = '#1b1b2e';
const String _lightMedia = '(prefers-color-scheme: light)';
const String _darkMedia = '(prefers-color-scheme: dark)';

String Function()? _computeTitle;
web.MutationObserver? _observer;

void setWebDocumentTitle(String title) {
  if (web.document.title == title) return;
  web.document.title = title;
}

/// 绑定标题来源并开始守护 `<head>`；重复调用只替换回调。
void bindWebHead(String Function() computeTitle) {
  _computeTitle = computeTitle;
  final head = web.document.head;
  if (head == null) return;
  _observer ??= web.MutationObserver(
    ((JSArray<web.MutationRecord> _, web.MutationObserver _) => _enforce()).toJS,
  )..observe(
      head,
      web.MutationObserverInit(
        childList: true,
        subtree: true,
        characterData: true,
      ),
    );
  _enforce();
}

void unbindWebHead() {
  _observer?.disconnect();
  _observer = null;
  _computeTitle = null;
}

/// 一把梭：改回标题 + 清理非 media 的 theme-color。
///
/// 自身写 DOM 也会触发 observer，但下一轮检查时已无可改动项（标题一致、
/// 只剩带 media 的一对），不会自激。
void _enforce() {
  final want = _computeTitle?.call() ?? '';
  if (want.isNotEmpty) setWebDocumentTitle(want);
  _enforceThemeColor();
}

void _enforceThemeColor() {
  final head = web.document.head;
  if (head == null) return;
  final metas = head.querySelectorAll('meta[name="theme-color"]');
  final stale = <web.Element>[];
  final medias = <String>{};
  for (var i = 0; i < metas.length; i++) {
    final node = metas.item(i);
    if (node == null) continue;
    final el = node as web.Element;
    final media = el.getAttribute('media') ?? '';
    if (media.isEmpty) {
      stale.add(el); // 引擎注入的 #0078d4
      continue;
    }
    medias.add(media);
  }
  for (final el in stale) {
    el.remove();
  }
  if (!medias.contains(_lightMedia)) _appendThemeColor(_lightMedia, _lightBg);
  if (!medias.contains(_darkMedia)) _appendThemeColor(_darkMedia, _darkBg);
}

void _appendThemeColor(String media, String color) {
  final head = web.document.head;
  if (head == null) return;
  final meta = web.document.createElement('meta') as web.HTMLMetaElement;
  meta.name = 'theme-color';
  meta.content = color;
  meta.setAttribute('media', media);
  head.append(meta);
}
