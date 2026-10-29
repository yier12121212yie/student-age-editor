/// 非桌面平台：拖放由 `web_drop` 处理，这里只做透明包装。
library;

import 'package:flutter/widgets.dart';

import 'web_drop.dart';

/// 见 desktop_drop_io.dart 的同名组件。
class DesktopDropRegion extends StatelessWidget {
  const DesktopDropRegion({
    super.key,
    required this.onFiles,
    required this.child,
  });

  final DropHandler onFiles;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
