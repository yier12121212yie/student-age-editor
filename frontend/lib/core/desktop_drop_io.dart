/// 桌面端原生拖放：`desktop_drop` → 字节 → 与「导入本地…」同一回调。
library;

import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'web_drop.dart';

class DesktopDropRegion extends StatelessWidget {
  const DesktopDropRegion({
    super.key,
    required this.onFiles,
    required this.child,
  });

  final DropHandler onFiles;
  final Widget child;

  Future<void> _onDragDone(DropDoneDetails details) async {
    if (details.files.isEmpty) return;
    final out = <DroppedFile>[];
    for (final item in details.files) {
      // 目录整体拖入不做递归导入（与 Web 一致：只接文件）。
      if (item is DropItemDirectory) continue;
      try {
        final bytes = await item.readAsBytes();
        if (bytes.isEmpty) continue;
        final name = item.name.isNotEmpty
            ? item.name
            : item.path.split(RegExp(r'[\\/]')).last;
        if (name.isEmpty) continue;
        out.add((name: name, bytes: bytes));
      } catch (e) {
        debugPrint('[drop] 读取拖入文件失败（${item.path}）：$e');
      }
    }
    if (out.isEmpty) return;
    await onFiles(out);
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (details) {
        // desktop_drop 的回调是同步的；异步读取在内部展开，错误各自吞掉。
        unawaited(_onDragDone(details));
      },
      child: child,
    );
  }
}
