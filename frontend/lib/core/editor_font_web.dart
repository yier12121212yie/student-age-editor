// Web：把随包内置的中文字体注册进 CanvasKit。
//
// 字体文件在 pubspec 里按普通 asset 声明（不进 FontManifest），因此不会在引擎
// 启动时被无条件下载；这里用 rootBundle 读入后交给 FontLoader。
//
// 加载**不阻塞 runApp**（见 main.dart）：注册完成后引擎会发 'fontsChange'
// 系统消息，框架随即重排所有文本（RenderParagraph 监听 systemFonts），
// 晚到的字体不会留下豆腐块。首屏是否已让位由 index.html 的加载屏决定：
// 它等到 `window.__editorFontReady === true`（或超时）后才移除覆盖层。
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 与 app.dart 里主题 fontFamily 共用的族名。
const String kEditorCjkFamily = 'EditorCJK';

const String _asset = 'assets/fonts/EditorCJK.ttf';

/// 除了主题字体，还把同一份字体注册到代码里显式写死的族名上。
///
/// Web 上 `Consolas` / `monospace` 并不存在（CanvasKit 也没有系统字体映射），
/// 这些样式里的中文同样会掉进引擎 fallback 切片。把内置字体同时挂到这两个
/// 族名上，代码查看器/JSON 预览里的中文也能正常显示（拉丁字形由 Noto Sans
/// 承担，和原本回退 Roboto 的观感差别很小）。
const List<String> _families = <String>[
  kEditorCjkFamily,
  'Consolas',
  'monospace',
];

/// 通知 index.html 的加载屏「字体已就位，可以让位了」。
@JS('__editorFontReady')
external set _fontReadyFlag(bool value);

Future<void>? _loading;

/// 加载内置中文字体；重复调用返回同一个 Future。
///
/// 失败只记录日志（退回引擎的 fallback 切片，界面可能出现部分豆腐块），
/// 不阻断启动。
Future<void> ensureEditorCjkFont() => _loading ??= _load();

Future<void> _load() async {
  final sw = Stopwatch()..start();
  try {
    final data = await rootBundle.load(_asset);
    final bytes = Future<ByteData>.value(data);
    for (final family in _families) {
      await (FontLoader(family)..addFont(bytes)).load();
    }
    debugPrint('[font] 内置中文字体已注册（${data.lengthInBytes ~/ 1024} KB, '
        '${sw.elapsedMilliseconds} ms, families=${_families.join(",")}）');
  } catch (e) {
    debugPrint('[font] 内置中文字体加载失败，回退引擎 fallback：$e');
  } finally {
    // 成功/失败都放行：加载屏还会等 2.5s 超时兜底，但没必要让用户多等。
    _fontReadyFlag = true;
  }
}
