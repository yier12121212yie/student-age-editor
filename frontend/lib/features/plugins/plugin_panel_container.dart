import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../resources/asset_explorer_panel.dart';

/// Main feature panel container for asset and Live2D viewers.
class PluginPanelContainer extends StatefulWidget {
  const PluginPanelContainer({super.key});

  @override
  State<PluginPanelContainer> createState() => _PluginPanelContainerState();
}

class _PluginPanelContainerState extends State<PluginPanelContainer> {
  int _selectedTab = 0;
  /// 声明了 service 的插件行内 service_status（{ok,url,name,checked}，
  /// 见 PLUGIN_GUIDE §5）。GET /api/plugins 只读缓存、不触网。
  List<Map<String, dynamic>> _services = const [];
  bool _loading = true;
  bool _bannerDismissed = false;

  final List<Map<String, String>> _tabs = [
    {'label': '资源浏览器', 'value': 'asset'},
    {'label': 'Live2D 预览', 'value': 'live2d'},
  ];

  @override
  void initState() {
    super.initState();
    _checkServiceStatus();
  }

  Future<void> _checkServiceStatus() async {
    try {
      final res = await ApiClient.instance.get('/api/plugins');
      final list = res is Map ? (res['plugins'] as List? ?? const []) : const [];
      setState(() {
        _services = [
          for (final e in list)
            if (e is Map && e['service'] != null)
              Map<String, dynamic>.from(
                  e['service_status'] as Map? ?? const <String, dynamic>{}),
        ];
        _loading = false;
      });
    } catch (e) {
      print('[PluginPanel] Service check failed: $e');
      setState(() => _loading = false);
    }
  }

  /// 声明了 service 但最近一次刷新未通过：ok=false，或 checked=false（尚无结论）。
  bool get _serviceDown => _services.any((s) => s['ok'] != true);

  List<Map<String, dynamic>> get _downServices =>
      [for (final s in _services) if (s['ok'] != true) s];

  Widget _buildOfflineBanner() {
    final detail = _downServices
        .map((s) {
          final name = s['name'] as String? ?? '';
          final url = s['url'] as String? ?? '';
          if (name.isEmpty) return url;
          return url.isEmpty ? name : '$name（$url）';
        })
        .where((t) => t.isNotEmpty)
        .join('、');
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.orange.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.shade400),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orange),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '插件服务未就绪',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.orange.shade900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail.isEmpty ? '未检测到已声明的服务插件' : detail,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange.shade700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '服务进程需手动启动；状态未刷新时请重载插件（PLUGIN_GUIDE §5）',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.orange.shade700,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _bannerDismissed = true),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final offline = _serviceDown && !_bannerDismissed;

    return Row(
      children: [
        // 60px 图标 Tab 栏
        SizedBox(
          width: 60,
          child: Column(
            children: _tabs.asMap().entries.map((entry) {
              final index = entry.key;
              final tab = entry.value;
              final isSelected = _selectedTab == index;

              return InkWell(
                key: ValueKey(tab['value']),
                onTap: () => setState(() => _selectedTab = index),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  color: isSelected
                      ? AppTheme.palette.hover
                      : Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(FluentIcons.apps_24_regular, size: 20),
                      const SizedBox(height: 4),
                      Text(
                        tab['label'] ?? '',
                        style: const TextStyle(fontSize: 10),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        // 选中内容
        Expanded(
          child: Column(
            children: [
              const SizedBox(height: 8),
              if (offline) _buildOfflineBanner(),
              Expanded(
                child: _selectedTab == 0
                    ? const AssetExplorerPanel()
                    : _buildLive2DPreviewPanel(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLive2DPreviewPanel() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            FluentIcons.person_24_regular,
            size: 64,
            color: Colors.grey,
          ),
          const SizedBox(height: 16),
          const Text(
            'Live2D 预览面板',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          const Text(
            '离线渲染和实时动画预览',
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          fluent.Button(
            child: const Text('查看模型列表'),
            onPressed: () {
              // TODO: Navigate to model list page
            },
          ),
        ],
      ),
    );
  }
}
