/// 无代码模式的「只选不敲」引用/ID 字段。
///
/// 与 [NoCodeEffectField]（码字段 → 内联积木）互补：本组件覆盖
/// `reference` / `visual` 形态——只读展示现值 + 一个选择入口，**不出现任何
/// 可输入的代码/ID 文本框**。宿主把选择动作（实体面板 / ID 浏览对话框）
/// 包进 [onPick]；没有候选通道时给只读提示与「关闭无代码模式」逃生口，
/// 绝不放文本输入框。
library;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/app_theme.dart';

/// 单行/多行的只读引用字段。`value` 是已编码的可读 ID 串（逗号/分号分隔）。
class NoCodeRefField extends StatelessWidget {
  const NoCodeRefField({
    super.key,
    required this.value,
    required this.pickLabel,
    this.onPick,
    this.preview,
    this.emptyText = '（未设置）',
    this.onDisableNoCode,
    this.maxLines = 1,
    this.compact = false,
  });

  /// 当前值的可读文本（如 `1001, 1002`）。
  final String value;

  /// 选择按钮文案，如「选人物…」。
  final String pickLabel;

  /// 选择动作：由宿主执行挑选 + 写回；null = 该字段没有候选通道。
  final Future<void> Function()? onPick;

  /// 可选：现值前的自定义预览（如背景缩略图）。
  final Widget? preview;

  final String emptyText;

  /// 逃生口：关闭无代码模式以便手动编辑。
  final VoidCallback? onDisableNoCode;

  final int maxLines;

  /// 紧凑形态（表格单元格内）：按钮缩成一个「选…」，不铺死路提示。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = value.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (preview != null) ...[preview!, const SizedBox(width: 6)],
            Expanded(
              child: Text(
                text.isEmpty ? emptyText : text,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 10.5 : 12,
                  color: text.isEmpty ? palette.textHint : palette.textBody,
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (compact)
              MouseRegion(
                cursor: onPick == null
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onPick,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: palette.panel,
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                      border: Border.all(color: palette.border),
                    ),
                    child: Text(
                      '选…',
                      style: TextStyle(
                        fontSize: 10,
                        color:
                            onPick == null ? palette.textHint : palette.textBody,
                      ),
                    ),
                  ),
                ),
              )
            else
              fluent.Button(
                onPressed: onPick == null ? null : () => onPick!(),
                child: Text(pickLabel, style: const TextStyle(fontSize: 11)),
              ),
          ],
        ),
        if (!compact && onPick == null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '该字段没有可选候选；如需手写请关闭无代码模式。',
                    style: TextStyle(fontSize: 10, color: palette.textHint),
                  ),
                ),
                if (onDisableNoCode != null)
                  fluent.Button(
                    onPressed: onDisableNoCode,
                    child: const Text('关闭无代码模式',
                        style: TextStyle(fontSize: 10)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
