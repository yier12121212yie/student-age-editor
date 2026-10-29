/// 运行时异常兜底：把「灰块 / 空白」换成人话，并留下可反馈的线索。
///
/// Flutter 的默认行为在 release 里就是一块灰底（build 期异常）或干脆什么都不
/// 画（回调/异步异常只进控制台）。Web 上用户既看不到控制台，也不知道该刷新
/// 还是等——这里统一接管三类出口：
///
/// - `ErrorWidget.builder`：某个子树 build 失败时就地渲染错误卡片，不会整页
///   白屏（其余部分照常可用）；
/// - `FlutterError.onError`：记录最近一次框架异常（仍调用原处理器，保留控制台
///   输出与 debug 红屏）；
/// - `PlatformDispatcher.onError`：异步/引擎层未捕获异常，同样记录后放行。
///
/// JS 层的 `error` / `unhandledrejection` 在 `core/web_errors.dart` 采集。
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'design_tokens.dart';
import 'editor_font.dart';
import 'web_diag.dart';
import 'web_errors.dart';

/// 在 `runApp` 之前调用一次（`main.dart`）。重复调用是安全的。
void installErrorHandlers() {
  installWebErrorCapture();

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    markWebDiag('err', summarizeErrorText(details.exceptionAsString()));
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    markWebDiag('err', summarizeErrorText(error.toString()));
    // false = 继续走引擎的默认处理（release 也会打印到控制台）。
    return false;
  };

  ErrorWidget.builder = (details) {
    final summary = summarizeErrorText(details.exceptionAsString());
    markWebDiag('err', summary);
    return RenderErrorView(summary: summary);
  };
}

/// 把异常压成一行：诊断只留「哪类错、第一句」，堆栈交给控制台。
String summarizeErrorText(String raw, {int maxChars = 200}) {
  final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= maxChars) return flat;
  return '${flat.substring(0, maxChars)}…';
}

/// build 失败时就地替换该子树的错误卡片。
///
/// 刻意只用最基础的组件（不依赖 MaterialApp/Navigator/MediaQuery），因为错误
/// 可能就发生在这些祖先里；颜色仍走 `palette`，跟随当前明暗外观。
class RenderErrorView extends StatelessWidget {
  const RenderErrorView({super.key, required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final hint = kIsWeb
        ? '这块界面没能画出来，其余部分通常仍可继续使用。\n'
            '细节已写入控制台（window.__editorDiag.err）；'
            '也可以在「设置 → 诊断」里复制诊断信息反馈给开发者。'
        : '这块界面没能画出来，其余部分通常仍可继续使用。\n'
            '请重启应用；若反复出现，请把下面的信息反馈给开发者。';
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: p.bg,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '界面渲染出错',
                    style: TextStyle(
                      fontSize: AppText.heading,
                      fontWeight: FontWeight.w600,
                      color: p.textHigh,
                      fontFamily: kEditorCjkFamily,
                    ),
                  ),
                  const SizedBox(height: AppSpace.s),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: AppText.body,
                      height: 1.6,
                      color: p.textBody,
                      fontFamily: kEditorCjkFamily,
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.s10, vertical: AppSpace.s),
                    decoration: BoxDecoration(
                      color: p.bgDeep,
                      borderRadius: BorderRadius.circular(AppRadius.m),
                      border: Border.all(color: p.border),
                    ),
                    child: Text(
                      summary.isEmpty ? '（无异常信息）' : summary,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.small,
                        height: 1.5,
                        color: p.textMuted,
                        fontFamily: kEditorCjkFamily,
                      ),
                    ),
                  ),
                  if (kIsWeb) ...[
                    const SizedBox(height: AppSpace.m),
                    const _ReloadButton(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘按钮：不依赖 Material/InkWell（错误可能就出在 Material 祖先上）。
class _ReloadButton extends StatefulWidget {
  const _ReloadButton();

  @override
  State<_ReloadButton> createState() => _ReloadButtonState();
}

class _ReloadButtonState extends State<_ReloadButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: reloadWebPage,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.m, vertical: AppSpace.s),
          decoration: BoxDecoration(
            color: _hover ? p.hover : p.card,
            borderRadius: BorderRadius.circular(AppRadius.m),
            border: Border.all(color: _hover ? p.borderHover : p.border),
          ),
          child: Text(
            '重新加载页面',
            style: TextStyle(
              fontSize: AppText.body,
              color: p.textHigh,
              fontFamily: kEditorCjkFamily,
            ),
          ),
        ),
      ),
    );
  }
}
