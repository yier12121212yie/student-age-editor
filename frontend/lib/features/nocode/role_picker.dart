/// 无代码模式的人物浏览面板（兼容入口）。
///
/// 实现已并入通用实体选择器 [showEntityPicker]（kind=roles）：立绘卡片网格 +
/// 服务端搜索 + 单/多选 + kind=role 使用度上报。本文件保留原先的 API 形状
/// （[RoleEntry] / [loadRoles] / [showRolePickerDialog]），调用点与测试不必改。
library;

import 'package:flutter/material.dart';

import 'entity_picker.dart';

export 'entity_picker.dart' show RoleEntry, loadRoles;

/// 打开人物浏览面板；确认返回所选 id（按点选顺序），取消返回 null。
/// [multi]=true 多选（累加高亮），false 单击即选中并返回。
Future<List<String>?> showRolePickerDialog(
  BuildContext context, {
  bool multi = true,
  String title = '选择人物',
  Set<String> exclude = const {},
}) {
  return showEntityPicker(
    context,
    kind: EntityKind.roles,
    multi: multi,
    title: title,
    exclude: exclude,
  );
}
