/// 小号状态徽标（pill）：tint 底 + 单色文字的小标签。
///
/// 迁移前积木库与无代码积木行各持一份逐字相同的私有 `_Badge`
/// （h6/v1、r3、描边、9.5pt），导演视图另有不带描边的「N选」变体；
/// 此处收敛为单一实现。[bordered] 控制描边（默认与积木库一致）。
library;

import 'package:flutter/material.dart';

import 'design_tokens.dart';

class StatusPill extends StatelessWidget {
  const StatusPill(
    this.text, {
    super.key,
    required this.bg,
    required this.fg,
    this.bordered = true,
  });

  final String text;

  /// 填充底色（一般取 `palette.tint*`）。
  final Color bg;

  /// 文字/描边色（一般取 `palette.status*` 或 `palette.warning`）。
  final Color fg;

  final bool bordered;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.s6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.xxs),
        border: bordered ? Border.all(color: fg) : null,
      ),
      child: Text(text, style: TextStyle(fontSize: AppText.tiny, color: fg)),
    );
  }
}
