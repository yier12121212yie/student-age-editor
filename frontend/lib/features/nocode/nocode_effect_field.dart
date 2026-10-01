import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/app_theme.dart';
import '../editor/field_meta.dart';
import '../editor/field_utils.dart';
import 'effect_block_editor.dart';

/// 无代码模式下的效果/条件/指令字段：**内联积木编辑器**，零文本输入。
///
/// 三个编辑面（经典 schema 编辑器、剧情图内联卡片、剧情图 Inspector）共用
/// 本组件，保证"开启无代码模式后没有地方能手输代码"的目标在任一入口都成立。
///
/// 数据安全边界：
/// - 文本能拆成积木 → 行卡片编辑，行变更即时写回（防抖在积木编辑器内）；
/// - 文本拆不动（后端不可达 / 非码内容）→ 只读展示原文，绝不覆写；
/// - 任何情况下都不提供文本输入框，逃生口是"关闭无代码模式"。
class NoCodeEffectField extends StatelessWidget {
  const NoCodeEffectField({
    super.key,
    required this.value,
    required this.type,
    required this.cfg,
    required this.fieldKey,
    required this.onChanged,
    this.mode,
    this.gameDicts = const {},
    this.onDisableNoCode,
    this.dense = false,
  });

  /// 字段当前值（1D/2D Array 的 JSON 值）。
  final dynamic value;

  /// schema 类型：1D Array / 2D Array。
  final String type;

  /// 所属配置表（决定积木 mode 的 cfg 限定分支）。
  final String cfg;

  /// 字段 key（用于 ValueKey 与 mode 推断）。
  final String fieldKey;

  final ValueChanged<dynamic> onChanged;

  /// 显式指定补全目录 mode；缺省按 [effectSuggestMode] 推断，仍为空时按 effect。
  final String? mode;

  final Map<String, dynamic> gameDicts;

  /// 逃生口：关闭无代码模式以便手动编辑（null = 不显示该入口，如内联卡片）。
  final VoidCallback? onDisableNoCode;

  /// 紧凑形态（剧情图内联卡片约 200px 宽）：隐藏脚注与逃生口。
  final bool dense;

  String get _mode {
    final m = mode;
    if (m != null && m.isNotEmpty) return m;
    return effectSuggestMode(cfg, fieldKey) ?? 'effect';
  }

  /// 1D 码字段（screenEffect）：一句话只能一个屏幕效果。
  bool get _singleRow => type == '1D Array';

  @override
  Widget build(BuildContext context) {
    final text = ValueCodec.encode(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        EffectBlockEditor(
          key: ValueKey('nocode-blocks-$cfg-$fieldKey-$type'),
          initialText: text,
          mode: _mode,
          gameDicts: gameDicts,
          singleRow: _singleRow,
          embedded: true,
          onResult: (out) {
            if (out == null) return;
            onChanged(ValueCodec.decode(out, type));
          },
        ),
        if (!dense && onDisableNoCode != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: fluent.Button(
                onPressed: onDisableNoCode,
                child: const Text('关闭无代码模式以手动编辑',
                    style: TextStyle(fontSize: 10)),
              ),
            ),
          ),
      ],
    );
  }
}
