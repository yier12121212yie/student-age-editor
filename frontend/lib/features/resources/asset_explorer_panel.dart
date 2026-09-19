import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/api_client.dart';
import '../../core/app_theme.dart';

/// Asset Explorer Panel - Resource browser for Live2D characters, CGs, and audio assets.
class AssetExplorerPanel extends StatefulWidget {
  const AssetExplorerPanel({super.key});

  @override
  State<AssetExplorerPanel> createState() => _AssetExplorerPanelState();
}

class _AssetExplorerPanelState extends State<AssetExplorerPanel> {
  bool _isLoading = true;
  bool _isScanning = false;
  Map<String, dynamic>? _scanResult;
  List<Map<String, dynamic>> _searchResults = [];
  String _searchQuery = '';
  String _selectedKind = 'all';
  int _selectedTabIndex = 0;
  
  final List<Map<String, String>> _kindOptions = [
    {'label': '全部', 'value': 'all'},
    {'label': '立绘/角色', 'value': 'sprite'},
    {'label': '背景/CG', 'value': 'texture'},
    {'label': '音频', 'value': 'audio'},
  ];

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    try {
      final res = await ApiClient.instance.get('/plugin/assets/catalog');
      if (res.containsKey('resources_by_kind')) {
        final kindMap = res['resources_by_kind'] as Map<String, dynamic>;
        final allAssets = <Map<String, dynamic>>[];
        
        kindMap.forEach((kind, assets) {
          if (assets is List) {
            for (final asset in assets) {
              asset['kind'] = kind;
              allAssets.add(asset);
            }
          }
        });
        
        setState(() {
          _searchResults = allAssets;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('[AssetExplorer] Failed to load catalog: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _scanBundles() async {
    setState(() => _isScanning = true);
    
    try {
      final res = await ApiClient.instance.get(
        '/plugin/assets/scan?force=true',
      );
      
      setState(() {
        _scanResult = res;
        _isLoading = false;
      });
      
      // Reload catalog after scan
      await _loadCatalog();
      
      if (mounted) {
        fluent.dialog.Dialogbox.basic(
          title: const Text('扫描完成'),
          content: Text('发现 ${_scanResult?['bundles_found'] ?? 0} 个 bundle，提取 ${_scanResult?['assets_extracted'] ?? 0} 个资源'),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(fluent.dialog.Context.getDialogContext!),
              child: const Text('确定'),
            ),
          ],
        );
      }
    } catch (e) {
      print('[AssetExplorer] Scan failed: $e');
      setState(() => _isScanning = false);
      
      if (mounted) {
        fluent.dialog.Dialogbox.basic(
          title: const Text('扫描失败'),
          content: Text('错误：${e.toString()}'),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(fluent.dialog.Context.getDialogContext!),
              child: const Text('关闭'),
            ),
          ],
        );
      }
    }
  }

  void _filterResources(String query) {
    setState(() {
      _searchQuery = query.toLowerCase();
      _applyFilters();
    });
  }

  void _applyFilters() {
    setState(() {
      _searchResults = _searchResults.where((asset) {
        // Kind filter
        if (_selectedKind != 'all' && asset['kind'] != _selectedKind) {
          return false;
        }
        
        // Search query filter
        if (_searchQuery.isNotEmpty) {
          final searchable = '${asset['original_name']} ${(asset['tags'] as List).join(' ')}'.toLowerCase();
          return searchable.contains(_searchQuery);
        }
        
        return true;
      }).toList();
    });
  }

  void _selectKind(String kind) {
    setState(() {
      _selectedKind = kind;
      _applyFilters();
    });
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            FluentIcons.folder_open_24_regular,
            size: 64,
            color: Colors.grey,
          ),
          const SizedBox(height: 16),
          const Text(
            '暂无资源数据',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            '点击「扫描游戏包」按钮开始提取资源',
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          fluent.Button(
            child: const Text('扫描游戏包'),
            onPressed: _isScanning ? null : _scanBundles,
            loading: _isScanning,
          ),
        ],
      ),
    );
  }

  Widget _buildResourceCard(Map<String, dynamic> asset) {
    final kind = asset['kind'] as String;
    final sha24 = asset['sha24'] as String;
    final name = asset['original_name'] as String;
    final width = asset['width'] ?? 0;
    final height = asset['height'] ?? 0;
    final tags = asset['tags'] as List<dynamic>;
    
    IconData icon;
    Color iconColor;
    
    switch (kind) {
      case 'sprite':
        icon = FluentIcons.person_24_regular;
        iconColor = const Color(0xFF0078D4); // Blue for character
        break;
      case 'texture':
        icon = FluentIcons.image_24_regular;
        iconColor = const Color(0xFF00B294); // Teal for background
        break;
      case 'audio':
        icon = FluentIcons.music_note_24_regular;
        iconColor = const Color(0xFFF25460); // Red for audio
        break;
      default:
        icon = FluentIcons.attachment_24_regular;
        iconColor = Colors.grey;
    }
    
    return fluent.Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: InkWell(
          onTap: () => _showAssetPreview(asset),
          borderRadius: BorderRadius.circular(8),
          hoverColor: Theme.of(context).brightness == brightMode.light
              ? Colors.grey.shade100
              : Colors.white.withOpacity(0.05),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: iconColor, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name.substring(0, min(name.indexOf('_'), 15)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: iconColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      kind.toUpperCase(),
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (width > 0 && height > 0)
                Text(
                  '$width × $height px',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              if (tags.isNotEmpty)
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: tags.map((tag) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        tag,
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAssetPreview(Map<String, dynamic> asset) {
    showDialog(
      context: context,
      builder: (context) => fluent.dialog.Dialogbox(
        title: Text(asset['original_name'] as String),
        content: FutureBuilder(
          future: _loadAssetImage(asset),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Text('加载失败：${snapshot.error}');
            }
            return Image.memory(
              snapshot.data as List<int>,
              fit: BoxFit.contain,
            );
          },
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<List<int>> _loadAssetImage(Map<String, dynamic> asset) async {
    // TODO: Implement actual image fetching from backend
    // For now, return placeholder
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header toolbar
        fluent.SegmentedButton<int>(
          segments: const [
            fluent.ButtonSegment<int>(
              value: 0,
              label: Text('库'),
              icon: Icon(FluentIcons.collection_24_regular),
            ),
            fluent.ButtonSegment<int>(
              value: 1,
              label: Text('扫描'),
              icon: Icon(FluentIcons.download_24_regular),
            ),
          ],
          selected: {_selectedTabIndex},
          onSelectionChanged: (Set<int> newSelection) {
            setState(() => _selectedTabIndex = newSelection.first);
          },
        ),
        const Divider(),
        
        if (_selectedTabIndex == 0)
          // Browse mode
          Column(
            children: [
              // Search and filter bar
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: fluent.TextField(
                        hint: '搜索资源...',
                        prefix: const Icon(FluentIcons.search_24_regular),
                        onChanged: _filterResources,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 120,
                      child: fluent.ComboBox<String>.readOnly(
                        hint: '类型',
                        items: _kindOptions.map((opt) => 
                          fluent.ComboBoxItem<String>(
                            value: opt['value'],
                            child: Text(opt['label']),
                          )
                        ).toList(),
                        selected: _selectedKind,
                        onChanged: _selectKind,
                      ),
                    ),
                  ],
                ),
              ),
              
              // Results grid
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _searchResults.isEmpty
                        ? _buildEmptyView()
                        : GridView.builder(
                            padding: const EdgeInsets.all(8),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              childAspectRatio: 1.5,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: _searchResults.length,
                            itemBuilder: (context, index) {
                              return _buildResourceCard(_searchResults[index]);
                            },
                          ),
              ),
            ],
          ),
        
        if (_selectedTabIndex == 1)
          // Scan mode
          Expanded(
            child: _scanResult == null
                ? _buildEmptyView()
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '扫描结果',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        Text('扫描时间：${DateTime.now().toIso8601String()}'),
                        Text('发现 Bundle: ${_scanResult!['bundles_found']} 个'),
                        Text('提取资源：${_scanResult!['assets_extracted']} 个'),
                        if ((_scanResult!['errors'] as List).isNotEmpty) ...[
                          const SizedBox(height: 16),
                          const Text(
                            '错误列表:',
                            style: TextStyle(fontWeight: FontWeight.w500),
                          ),
                          ...(_scanResult!['errors'] as List).map((e) => Text(e)).toList(),
                        ],
                      ],
                    ),
                  ),
          ),
      ],
    );
  }
}
