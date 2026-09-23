import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/api_client.dart';

/// Asset Explorer Panel - Resource browser for Live2D characters, CGs, and audio assets.
///
/// 数据源（后端 native C++，见 native/server/services/assets_routes.cpp）：
///   * GET /api/assets/catalog?q=&kind=&tags=&limit=&offset=
///       -> {status, total, matched, returned, truncated, counts,
///           resources_by_kind:{sprite:[...],texture:[...],audio:[...]}}
///       行 = {key, original_name, kind, width, height, sha24, tags}
///   * GET /api/assets/tags  -> {status, total, tags:[...], counts:{tag:n}}
///   * POST /api/aa/scan     -> 重读 tools/resource_scan 产物（后端不解析 bundle）
///   * POST /api/aa/preview  -> {kind, mime, data(base64)}；需预解码包，否则 422
///
/// 过滤/分页一律在服务端做：目录可能有数万条，客户端筛选既不准（只筛已拉到的
/// 那一页）又浪费内存。旧的 /plugin/assets/* 路径属于已退役的 Python 插件服务，
/// 后端已无该路由。
class AssetExplorerPanel extends StatefulWidget {
  const AssetExplorerPanel({super.key});

  @override
  State<AssetExplorerPanel> createState() => _AssetExplorerPanelState();
}

class _AssetExplorerPanelState extends State<AssetExplorerPanel> {
  /// 服务端一次最多返回的条数（后端 limit 上限 5000，这里取更保守的值）。
  static const int _pageLimit = 500;

  bool _isLoading = true;
  bool _isScanning = false;
  String? _error;

  /// 最近一次 catalog 响应里的行（服务端已过滤 + 分页）。
  List<Map<String, dynamic>> _rows = [];
  int _total = 0;
  int _matched = 0;
  bool _truncated = false;

  /// 标签云（全量口径）与当前选中的标签。
  List<String> _allTags = [];
  final Set<String> _selectedTags = {};

  String _searchQuery = '';
  String _selectedKind = 'all';
  int _selectedTabIndex = 0;
  Map<String, dynamic>? _scanResult;

  /// 搜索防抖：目录可能有数万条，逐键请求既慢又无意义。
  Timer? _debounce;

  /// 请求序号：慢响应回来时若已有更新的请求发出，直接丢弃（防乱序覆盖）。
  int _reqSeq = 0;

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
    _loadTags();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadTags() async {
    try {
      final res = await ApiClient.instance.get('/api/assets/tags');
      if (!mounted) return;
      final tags = res is Map ? res['tags'] : null;
      setState(() {
        _allTags = tags is List
            ? tags.map((e) => e.toString()).toList(growable: false)
            : const <String>[];
      });
    } catch (_) {
      // 标签是增强项：拉不到就让标签栏不显示，不阻塞目录。
      if (mounted) setState(() => _allTags = const <String>[]);
    }
  }

  Future<void> _loadCatalog() async {
    final seq = ++_reqSeq;
    final query = <String, String>{
      'limit': _pageLimit.toString(),
      if (_searchQuery.isNotEmpty) 'q': _searchQuery,
      if (_selectedKind != 'all') 'kind': _selectedKind,
      if (_selectedTags.isNotEmpty) 'tags': _selectedTags.join(','),
    };
    try {
      final res = await ApiClient.instance.get('/api/assets/catalog', query: query);
      if (!mounted || seq != _reqSeq) return;
      final rows = <Map<String, dynamic>>[];
      if (res is Map) {
        final byKind = res['resources_by_kind'];
        if (byKind is Map) {
          for (final entry in byKind.entries) {
            final list = entry.value;
            if (list is! List) continue;
            for (final item in list) {
              if (item is Map) {
                final row = Map<String, dynamic>.from(item);
                row['kind'] = item['kind'] ?? entry.key;
                rows.add(row);
              }
            }
          }
        }
      }
      setState(() {
        _rows = rows;
        _total = res is Map ? ((res['total'] as num?)?.toInt() ?? rows.length) : rows.length;
        _matched =
            res is Map ? ((res['matched'] as num?)?.toInt() ?? rows.length) : rows.length;
        _truncated = res is Map && res['truncated'] == true;
        _error = null;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _rows = <Map<String, dynamic>>[];
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _scanBundles() async {
    setState(() => _isScanning = true);
    try {
      // 后端不解析 bundle：这里只是让它重读 tools/resource_scan 的产物。
      final res = await ApiClient.instance.post('/api/aa/scan');
      if (!mounted) return;
      setState(() {
        _scanResult = res is Map ? Map<String, dynamic>.from(res) : null;
      });
      await _loadCatalog();
      await _loadTags();
      if (!mounted) return;
      final status = _scanResult?['status'] ?? 'unknown';
      await _showInfoDialog('重新读取资源索引', '状态：$status');
    } catch (e) {
      if (!mounted) return;
      await _showInfoDialog('重新读取资源索引失败', _detailOf(e));
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  /// 后端的错误信封里 detail 往往带可执行的修复指引（如 aa_index 的生成命令），
  /// 优先展示它，其次才是状态码。
  String _detailOf(Object e) {
    if (e is ApiException) return e.message;
    return e.toString();
  }

  Future<void> _showInfoDialog(String title, String message) {
    if (!mounted) return Future<void>.value();
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
        ],
      ),
    );
  }

  void _onSearchChanged(String v) {
    _searchQuery = v.trim().toLowerCase();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      _loadCatalog();
    });
  }

  void _selectKind(String kind) {
    if (_selectedKind == kind) return;
    setState(() => _selectedKind = kind);
    _loadCatalog();
  }

  void toggleTagSelection(String tag) {
    setState(() {
      if (!_selectedTags.remove(tag)) _selectedTags.add(tag);
    });
    _loadCatalog();
  }

  void _clearTags() {
    if (_selectedTags.isEmpty) return;
    setState(_selectedTags.clear);
    _loadCatalog();
  }

  Widget _buildEmptyView() {
    final message = _error ?? '暂无资源数据';
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(FluentIcons.folder_open_24_regular, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w500, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            '资源目录来自游戏 aa_index.json（tools/resource_scan 产物）',
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          fluent.Button(
            onPressed: _isScanning ? null : _scanBundles,
            child: const Text('重新读取资源索引'),
          ),
        ],
      ),
    );
  }

  /// 后端返回的 tags 是 JSON 数组（运行时类型 List<dynamic>），不能直接
  /// 硬转成 List&lt;String&gt;——那会在真数据上抛 TypeError。
  static List<String> _tagsOf(Map<String, dynamic> asset) {
    final raw = asset['tags'];
    if (raw is List) return raw.map((e) => e.toString()).toList(growable: false);
    return const <String>[];
  }

  Widget _buildResourceCard(Map<String, dynamic> asset) {
    final kind = asset['kind']?.toString() ?? 'texture';
    final name = asset['original_name']?.toString() ?? asset['key']?.toString() ?? '';
    final width = (asset['width'] as num?)?.toInt() ?? 0;
    final height = (asset['height'] as num?)?.toInt() ?? 0;
    final tags = _tagsOf(asset);

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
        icon = FluentIcons.music_note_2_24_regular;
        iconColor = const Color(0xFFF25460); // Red for audio
        break;
      default:
        icon = FluentIcons.attach_24_regular;
        iconColor = Colors.grey;
    }

    return fluent.Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: InkWell(
          onTap: () => _showAssetPreview(asset),
          borderRadius: BorderRadius.circular(8),
          hoverColor: Theme.of(context).brightness == Brightness.light
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
                      name,
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
              // 显示前 3 个标签
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final tag in tags.take(3))
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6C5CE7).withAlpha(100),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          tag,
                          style: const TextStyle(fontSize: 9, color: Colors.white),
                        ),
                      ),
                    if (tags.length > 3)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          '+${tags.length - 3}',
                          style: TextStyle(fontSize: 9, color: Colors.grey[600]),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showAssetPreview(Map<String, dynamic> asset) {
    final name = asset['original_name']?.toString() ?? asset['key']?.toString() ?? '';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(name),
        content: SizedBox(
          width: 480,
          height: 360,
          child: FutureBuilder<List<int>>(
            future: _loadAssetImage(asset),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return SingleChildScrollView(
                  child: Text('加载失败：${snapshot.error}'),
                );
              }
              final bytes = snapshot.data ?? const <int>[];
              if (bytes.isEmpty) return const Center(child: Text('无预览数据'));
              return Image.memory(Uint8List.fromList(bytes), fit: BoxFit.contain);
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// POST /api/aa/preview：只有预解码包里的资源能出图，游戏索引里的键回 422
  /// （C++ 侧不解码 bundle，ARTIFACT_FORMAT §8.7 边界）。
  Future<List<int>> _loadAssetImage(Map<String, dynamic> asset) async {
    final kind = asset['kind']?.toString() ?? '';
    final key = asset['key']?.toString() ?? asset['original_name']?.toString() ?? '';
    final previewKind = kind == 'audio' ? 'aud' : 'tex';
    try {
      final res = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': previewKind, 'key': key});
      final data = res is Map ? res['data'] : null;
      if (data is String && data.isNotEmpty) return base64Decode(data);
      return const <int>[];
    } on ApiException catch (e) {
      if (e.statusCode == 422) {
        throw '该资源需要预解码包才能预览（后端不解码 bundle）';
      }
      throw e.message;
    }
  }

  Widget _buildTagBar() {
    if (_allTags.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 45,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '标签过滤',
                  style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: _selectedTags.isEmpty ? null : _clearTags,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _selectedTags.isEmpty
                                ? Colors.transparent
                                : const Color(0xFF6C5CE7).withAlpha(30),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _selectedTags.isEmpty
                                  ? Colors.transparent
                                  : const Color(0xFF6C5CE7).withAlpha(150),
                            ),
                          ),
                          child: Text(
                            '清除选择',
                            style: TextStyle(
                              fontSize: 10,
                              color: _selectedTags.isEmpty
                                  ? Colors.grey[600]
                                  : const Color(0xFF6C5CE7),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      for (final tag in _allTags.take(20))
                        GestureDetector(
                          onTap: () => toggleTagSelection(tag),
                          child: Container(
                            margin: const EdgeInsets.only(right: 4),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: _selectedTags.contains(tag)
                                  ? const Color(0xFF6C5CE7).withAlpha(200)
                                  : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: _selectedTags.contains(tag)
                                    ? const Color(0xFF6C5CE7).withAlpha(150)
                                    : Colors.grey.shade300,
                                width: 1,
                              ),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontSize: 9.5,
                                color: _selectedTags.contains(tag)
                                    ? Colors.white
                                    : Colors.grey[700],
                                fontWeight: _selectedTags.contains(tag)
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildCountLine() {
    final shown = _rows.length;
    final text = _truncated
        ? '共 $_total 条，匹配 $_matched 条，显示前 $shown 条（请用搜索或标签缩小范围）'
        : '共 $_total 条，显示 $shown 条';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Text(text, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header toolbar
        SegmentedButton<int>(
          segments: const [
            ButtonSegment<int>(
              value: 0,
              label: Text('库'),
              icon: Icon(FluentIcons.collections_24_regular),
            ),
            ButtonSegment<int>(
              value: 1,
              label: Text('扫描'),
              icon: Icon(FluentIcons.arrow_download_24_regular),
            ),
          ],
          selected: {_selectedTabIndex},
          onSelectionChanged: (Set<int> newSelection) {
            setState(() => _selectedTabIndex = newSelection.first);
          },
        ),
        const Divider(),

        if (_selectedTabIndex == 0)
          // Browse mode：这一支自身必须是外层 Column 的 flex 子项——它内部有
          // Expanded(GridView)，作为普通子项会拿到无界高度约束并触发
          // RenderFlex 断言（non-zero flex but unbounded constraints）。
          Expanded(
            child: Column(
              children: [
                // Search and filter bar
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            hintText: '搜索资源...',
                            prefixIcon: Icon(FluentIcons.search_24_regular),
                            isDense: true,
                          ),
                          onChanged: _onSearchChanged,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 120,
                        child: DropdownButton<String>(
                          value: _selectedKind,
                          isExpanded: true,
                          hint: const Text('类型'),
                          items: _kindOptions
                              .map((opt) => DropdownMenuItem<String>(
                                    value: opt['value'],
                                    child: Text(opt['label']!),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) _selectKind(v);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      fluent.Button(
                        onPressed: _isScanning ? null : _scanBundles,
                        child: const Text('重新读取索引'),
                      ),
                    ],
                  ),
                ),

                // 智能标签过滤器（横向滚动）
                _buildTagBar(),

                _buildCountLine(),

                // Results grid
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _rows.isEmpty
                          ? _buildEmptyView()
                          : GridView.builder(
                              padding: const EdgeInsets.all(8),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                childAspectRatio: 1.5,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                              itemCount: _rows.length,
                              itemBuilder: (context, index) =>
                                  _buildResourceCard(_rows[index]),
                            ),
                ),
              ],
            ),
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
                          '索引读取结果',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        Text('状态：${_scanResult!['status'] ?? '-'}'),
                        Text('资源总数：$_total'),
                        Text('标签数：${_allTags.length}'),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text('错误：$_error'),
                        ],
                      ],
                    ),
                  ),
          ),
      ],
    );
  }
}
