/// 无代码模式的逃生口：关闭共享开关并给出失败反馈。
///
/// 无代码模式开启后，代码/ID 字段一律不给文本输入框（见 field_meta 的
/// [NoCodeShape]）。当某字段既没有候选也没有浏览/试听入口时，用户唯一的出路
/// 就是关掉这个共享开关——本文件把那一步（写穿后端 + 失败提示）收在一处，
/// 三个编辑面共用，避免各写一份对话框。
library;

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';

import '../../core/no_code_mode.dart';

/// 关闭无代码模式（写穿 editor_env.json）；写穿失败时提示并说明已回滚。
Future<void> exitNoCodeMode(BuildContext context) async {
  final ok = await persistNoCodeMode(false);
  if (ok || !context.mounted) return;
  await fluent.showDialog<void>(
    context: context,
    builder: (ctx) => fluent.ContentDialog(
      title: const Text('关闭失败'),
      content: const Text('无法写穿后端共享设置，开关已回滚。请确认后端在线后重试。'),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
