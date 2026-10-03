import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../extensions/extensions_page.dart';

/// 资源包管理入口——3A 起展示统一的「扩展」页（插件 + 资源包合并）。
/// 保留原类名与 `state` 构造参数以免改动调用点；安装/启用/删除都在统一页内。
class PackManagerPage extends StatelessWidget {
  const PackManagerPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: palette.bgDeep2,
      appBar: AppBar(
        backgroundColor: palette.bg,
        elevation: 0,
        leading: BackButton(color: palette.textHigh),
        title: Text('扩展', style: TextStyle(fontSize: 16, color: palette.textHigh)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(FluentIcons.puzzle_piece_24_regular, color: palette.textSecondary),
          ),
        ],
      ),
      body: const SafeArea(child: ExtensionsPage()),
    );
  }
}
