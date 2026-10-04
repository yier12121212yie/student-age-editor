import 'dart:async';
import 'dart:convert';
// Uint8List 随 foundation 一并导出（compute 入口返回字节列表）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/responsive.dart';
import 'local_import.dart' show importLocalAssets;

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
  bool _isImporting = false;
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

  /// 预览字节缓存（资源键 → future）：参照 image_asset_picker 的
  /// TexBytesCache/_PreviewPane 样板——future 只创建一次，对话框反复 rebuild
  /// 复用同一实例，不再每次重建都重发 /api/aa/preview、重解码 base64。
  /// 键 = previewKind + 分隔符 + 资源 key（音频/图片可能共用键名）。
  final Map<String, Future<Uint8List>> _previewFutures =
      <String, Future<Uint8List>>{};

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
    // 面板销毁后缓存的 future 不再有意义：清掉，避免跨实例误复用。
    _previewFutures.clear();
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
      // 刷新（重读索引）后产物可能已变：清空预览缓存，重新打开预览会重新拉取。
      _previewFutures.clear();
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

  /// 从本地电脑导入资源到当前模组。
  ///
  /// 类型跟着当前筛选走：筛「音频」→ `kind: 'audio'` 且让后端顺手登记
  /// AudioCfg（`register_audio: true`）；其余（全部/立绘/背景）→ `'image'`。
  /// 目录仍由后端按扩展名推断，前端不传 `dir`。
  Future<void> _importLocal() async {
    if (_isImporting) return;
    setState(() => _isImporting = true);
    try {
      final audio = _selectedKind == 'audio';
      final saved = await importLocalAssets(
        context,
        kind: audio ? 'audio' : 'image',
        registerAudio: audio,
      );
      if (!mounted || saved.isEmpty) return;
      // 新文件可能改动了索引产物与标签：清预览缓存并重拉目录。
      _previewFutures.clear();
      await _loadCatalog();
      await _loadTags();
    } finally {
      if (mounted) setState(() => _isImporting = false);
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
          Icon(FluentIcons.folder_open_24_regular, size: 64, color: palette.textSecondary),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w500, color: palette.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            '资源目录来自游戏 aa_index.json（tools/resource_scan 产物）',
            style: TextStyle(fontSize: 14, color: palette.textSecondary),
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
        iconColor = palette.catSprite;
        break;
      case 'texture':
        icon = FluentIcons.image_24_regular;
        iconColor = palette.catTexture;
        break;
      case 'audio':
        icon = FluentIcons.music_note_2_24_regular;
        iconColor = palette.catAudio;
        break;
      default:
        icon = FluentIcons.attach_24_regular;
        iconColor = palette.textSecondary;
    }

    return fluent.Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: InkWell(
          onTap: () => _showAssetPreview(asset),
          borderRadius: BorderRadius.circular(8),
          hoverColor:
              palette.isLight ? palette.checkerA : palette.overlayWeak,
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
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      kind.toUpperCase(),
                      style: TextStyle(fontSize: 10, color: palette.textSecondary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (width > 0 && height > 0)
                Text(
                  '$width × $height px',
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
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
                          color: accentColor.withAlpha(100),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          tag,
                          style: TextStyle(fontSize: 9, color: palette.onAccent),
                        ),
                      ),
                    if (tags.length > 3)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          '+${tags.length - 3}',
                          style: TextStyle(fontSize: 9, color: palette.textSecondary),
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
    // 样板做法（image_asset_picker 的 _PreviewPane/TexBytesCache）：future 在进入
    // build 之前从缓存取出（同 key 只创建一次），由对话框内容 State 持有。
    // 旧写法在 dialog builder 里直接调 _loadAssetImage → 每次 rebuild 重发请求
    // + 重解码。
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(name),
        content: SizedBox(
          width: 480,
          height: 360,
          child: _AssetPreviewBody(future: _previewFutureFor(asset)),
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

  /// 预览字节的按 key 缓存入口：目录行里资源键唯一（sha24 随目录刷新），同 key
  /// 重复打开预览复用同一 future，不再重发 /api/aa/preview、不再重解码。
  /// 失败的 future 会移出缓存（重开可重试），错误仍会送达已挂载的 FutureBuilder。
  Future<Uint8List> _previewFutureFor(Map<String, dynamic> asset) {
    final kind = asset['kind']?.toString() ?? '';
    final key = asset['key']?.toString() ?? asset['original_name']?.toString() ?? '';
    final previewKind = kind == 'audio' ? 'aud' : 'tex';
    if (key.isEmpty) return Future<Uint8List>.value(_emptyPreviewBytes);
    // previewKind 前缀防音频/图片共用键名串数据。
    final cacheKey = '$previewKind|$key';
    final cached = _previewFutures[cacheKey];
    if (cached != null) return cached;
    final f = _loadAssetImage(previewKind, key);
    _previewFutures[cacheKey] = f;
    // 失败移出缓存以便重开重试；这里只是旁路监听，错误仍送达 FutureBuilder。
    f.then<void>((_) {}, onError: (_) {
      if (_previewFutures[cacheKey] == f) _previewFutures.remove(cacheKey);
    });
    return f;
  }

  /// POST /api/aa/preview：只有预解码包里的资源能出图，游戏索引里的键回 422
  /// （C++ 侧不解码 bundle，ARTIFACT_FORMAT §8.7 边界）。
  /// base64→字节移到 compute（后台 isolate）：预览图常见数 MB，同步解码会卡
  /// 对话框首帧——参照样板的「解码重活出主 isolate」。
  Future<Uint8List> _loadAssetImage(String previewKind, String key) async {
    try {
      final res = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': previewKind, 'key': key});
      final data = res is Map ? res['data'] : null;
      if (data is String && data.isNotEmpty) {
        return await compute(_decodePreviewBase64, data);
      }
      return _emptyPreviewBytes;
    } on ApiException catch (e) {
      if (e.statusCode == 422) {
        throw '该资源需要预解码包才能预览（后端不解码 bundle）';
      }
      throw e.message;
    }
  }

  /// 搜索 + 类型筛选 + 导入/重扫操作条。
  ///
  /// 桌面单行：搜索自适应 + 120 宽类型下拉 + 两个文字按钮。手机上这四件套
  /// 的固定最小宽（约 430）超过屏宽会 RenderFlex 溢出，故窄屏改为两行：
  /// 搜索独占一行，类型下拉与两个按钮一行；下拉用 Expanded 吸收剩余宽度，
  /// 保证 320 宽机型也不溢出。
  Widget _buildFilterBar() {
    final mobile = isMobileWidth(context);

    final searchField = TextField(
      decoration: const InputDecoration(
        hintText: '搜索资源...',
        prefixIcon: Icon(FluentIcons.search_24_regular),
        isDense: true,
      ),
      onChanged: _onSearchChanged,
    );

    final kindDropdown = DropdownButton<String>(
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
    );

    final importButton = fluent.Button(
      onPressed: (_isImporting || _isScanning) ? null : _importLocal,
      child: Text(_isImporting ? '导入中…' : '导入本地…'),
    );

    final scanButton = fluent.Button(
      onPressed: _isScanning ? null : _scanBundles,
      child: const Text('重新读取索引'),
    );

    return Padding(
      padding: const EdgeInsets.all(8),
      child: !mobile
          ? Row(
              children: [
                Expanded(child: searchField),
                const SizedBox(width: 8),
                SizedBox(width: 120, child: kindDropdown),
                const SizedBox(width: 8),
                importButton,
                const SizedBox(width: 8),
                scanButton,
              ],
            )
          : Column(
              children: [
                searchField,
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: kindDropdown),
                    const SizedBox(width: 8),
                    importButton,
                    const SizedBox(width: 8),
                    scanButton,
                  ],
                ),
              ],
            ),
    );
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
                  style: TextStyle(fontSize: 10, color: palette.textSecondary),
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
                                : accentColor.withAlpha(30),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _selectedTags.isEmpty
                                  ? Colors.transparent
                                  : accentColor.withAlpha(150),
                            ),
                          ),
                          child: Text(
                            '清除选择',
                            style: TextStyle(
                              fontSize: 10,
                              color: _selectedTags.isEmpty
                                  ? palette.textSecondary
                                  : accentColor,
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
                                  ? accentColor.withAlpha(200)
                                  : palette.checkerA,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: _selectedTags.contains(tag)
                                    ? accentColor.withAlpha(150)
                                    : palette.border,
                                width: 1,
                              ),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontSize: 9.5,
                                color: _selectedTags.contains(tag)
                                    ? palette.onAccent
                                    : palette.textMuted,
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
      child: Text(text, style: TextStyle(fontSize: 11, color: palette.textSecondary)),
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
                _buildFilterBar(),

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

/// compute 入口必须是顶层/静态函数（不能捕获 State 闭包）：base64 → 字节。
Uint8List _decodePreviewBase64(String base64Data) => base64Decode(base64Data);

/// 空预览的共享占位（data 缺失/键为空时用），避免每次分配新列表。
final Uint8List _emptyPreviewBytes = Uint8List(0);

/// 预览对话框内容：future 存进 State（initState 一次），照搬 image_asset_picker
/// 的 _PreviewPane 样板——build 期间不再新建 future，FutureBuilder 不会
/// 每次 rebuild 重新订阅、进而重发请求/重解码。
class _AssetPreviewBody extends StatefulWidget {
  const _AssetPreviewBody({required this.future});

  final Future<Uint8List> future;

  @override
  State<_AssetPreviewBody> createState() => _AssetPreviewBodyState();
}

class _AssetPreviewBodyState extends State<_AssetPreviewBody> {
  late final Future<Uint8List> _future = widget.future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return SingleChildScrollView(
            child: Text('加载失败：${snapshot.error}'),
          );
        }
        final bytes = snapshot.data ?? _emptyPreviewBytes;
        if (bytes.isEmpty) return const Center(child: Text('无预览数据'));
        // 按显示宽 × DPR 限解码尺寸：1080p 原图全尺寸解码位图 ≈8MB/张。
        return LayoutBuilder(
          builder: (context, box) {
            final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
            final px = (box.maxWidth.isFinite ? box.maxWidth : 512.0) * dpr;
            final w = px.ceil();
            return Image.memory(
              bytes,
              fit: BoxFit.contain,
              cacheWidth: w < 64 ? 64 : (w > 4096 ? 4096 : w),
            );
          },
        );
      },
    );
  }
}
