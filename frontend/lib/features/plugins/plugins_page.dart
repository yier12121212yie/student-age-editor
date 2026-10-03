import 'package:flutter/material.dart';

import '../extensions/extensions_page.dart';
import '../../core/plugin_state.dart';

/// 插件面（侧栏 / 模态）——3A 起与资源包合并为统一的「扩展」页：一个列表
/// 同时管理插件与资源包，支持多选启用。保留原类名以免改动全部调用点。
class PluginsPage extends StatelessWidget {
  const PluginsPage({super.key, required this.pluginState});

  final PluginState pluginState;

  @override
  Widget build(BuildContext context) {
    return ExtensionsPage(pluginState: pluginState);
  }
}
