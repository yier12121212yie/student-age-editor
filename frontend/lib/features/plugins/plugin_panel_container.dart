import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
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
  Map<String, dynamic>? _pluginStatus;
  bool _loading = true;

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
      // Check if asset extractor service is running
      final res = await ApiClient.instance.get('/plugin/assets/plugin.json');
      setState(() {
        _pluginStatus = res;
        _loading = false;
      });
    } catch (e) {
      print('[PluginPanel] Service check failed: $e');
      setState(() {
        _pluginStatus = {'status': 'offline'};
        _loading = false;
      });
    }
  }

  Widget _buildOfflineBanner() {
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
                  '服务未启动',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.orange.shade900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '请运行 python3 native/server/services/asset_extractor.py --port 39251',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange.shade700,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () {},
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

    final offline = _pluginStatus == null || _pluginStatus!['status'] == 'offline';

    return Column(
      children: [
        // Tab bar
        fluent.NavigationView(
          paneDisplayMode: fluent.NavigationPaneDisplayMode.compact,
          paneTitle: const Text('插件面板'),
          paneContent: SizedBox(
            width: 60,
            child: Column(
              children: _tabs.asMap().entries.map((entry) {
                final index = entry.key;
                final tab = entry.value;
                final isSelected = _selectedTab == index;
                
                return fluent.Button(
                  key: ValueKey(tab['value']),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(FluentIcons.app_branding_24_regular, size: 20),
                        SizedBox(height: 4),
                        Text(
                          '',
                          style: TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  onPressed: () => setState(() => _selectedTab = index),
                  selected: isSelected,
                );
              }).toList(),
            ),
          ),
          content: Column(
            children: [
              // Content header
              const SizedBox(height: 8),
              if (offline) _buildOfflineBanner(),
              
              // Selected content
              Expanded(
                child: _selectedTab == 0
                    ? AssetExplorerPanel()
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
            FluentIcons.face_24_regular,
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
