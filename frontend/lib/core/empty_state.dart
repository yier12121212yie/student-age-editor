/// 统一「空态」文案块。
///
/// 迁移前全仓 10+ 处各写 `Center(child: Text('没有匹配的 X', style:
/// TextStyle(fontSize: 12, color: palette.textHint)))`——字号、灰度与
/// 是否居中各不相同。这里统一为「居中 + AppText.body + textHint」，
/// 需要图标或紧凑内边距时用参数微调。
library;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'design_tokens.dart';

class EmptyState extends StatelessWidget {
  const EmptyState(this.message, {super.key, this.icon, this.dense = false});

  /// 主文案（单行短句，如「没有匹配的人物」）。
  final String message;

  /// 可选前置图标。
  final IconData? icon;

  /// 紧凑模式：内边距 12（默认 16），供窄面板/列表内嵌使用。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(dense ? AppSpace.m : AppSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 22, color: palette.iconDisabled),
              const SizedBox(height: AppSpace.s),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: AppText.body, color: palette.textHint),
            ),
          ],
        ),
      ),
    );
  }
}
