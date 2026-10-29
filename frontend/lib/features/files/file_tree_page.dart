import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/mobile_widgets.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../editor/editor_controller.dart';
import '../../core/app_theme.dart';
import '../../core/editor_leave_guard.dart';

/// 文件树侧边栏：浏览当前模组目录，点击打开文档。
///
/// 移动端（宽度 <720 或横屏手机）走「逐级浏览」：只列当前目录，点文件夹进入，
/// 顶部返回上级；桌面端保持 deep=1 平铺（侧栏需要一眼看到全部文件）。
class FileTreePage extends StatefulWidget {
  const FileTreePage({super.key, required this.state, required this.controller});
  final AppState state;
  final EditorController controller;
  @override
  State<FileTreePage> createState() => _FileTreePageState();
}

class _FileTreePageState extends State<FileTreePage> {
  List<FsEntry> _entries = [];
  bool _loading = false;
  bool _didInit = false;
  bool? _lastMobile;

  /// 移动端当前目录（相对 mod 根，空串=根目录）。
  String _currentPath = '';

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _showSearch = false;

  @override
  void initState() {
    super.initState();
    // 先对齐当前模组缓存，避免启动后首个无关通知误触发重复加载
    _lastModRoot = widget.state.modRoot;
    _lastModName = widget.state.modName;
    widget.state.addListener(_onState);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mob = isMobileWidth(context);
    if (!_didInit) {
      _didInit = true;
      _lastMobile = mob;
      // initState 不能读 MediaQuery，首屏加载放到这里。
      _load();
      return;
    }
    // 旋转/改窗口宽度：桌面切到移动时留在平铺列表没有意义，清空目录重载。
    if (_lastMobile != mob) {
      _lastMobile = mob;
      _currentPath = '';
      _query = '';
      _showSearch = false;
      _searchCtrl.clear();
      _load();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onState() {
    // 只关注模组切换；AA 状态等其它通知不应触发文件树全量重载
    final modRoot = widget.state.modRoot;
    final modName = widget.state.modName;
    if (modRoot != _lastModRoot || modName != _lastModName) {
      _lastModRoot = modRoot;
      _lastModName = modName;
      _currentPath = '';
      _query = '';
      _showSearch = false;
      _searchCtrl.clear();
      if (mounted) _load();
    }
  }

  String _lastModRoot = '';
  String _lastModName = '';

  Future<void> _load({bool refresh = false}) async {
    if (widget.state.modRoot.isEmpty) {
      if (mounted) setState(() => _entries = []);
      return;
    }
    final mob = isMobileWidth(context);
    if (!refresh && mounted) setState(() => _loading = true);
    try {
      // 移动端逐级浏览（deep=0）；桌面 deep=1 平铺（Cfgs/zh-cn/*.json）。
      final r = await ApiClient.instance.get('/api/tools/list', query: {
        'scope': 'mod',
        'path': mob ? _currentPath : '',
        'deep': mob ? '0' : '1',
      });
      if (!mounted) return;
      setState(() => _entries = (r['entries'] as List)
          .map((e) => FsEntry.fromJson(e as Map<String, dynamic>))
          .toList());
    } catch (_) {
      if (mounted) setState(() => _entries = []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(FsEntry e) async {
    final path = _fullPath(e.name);
    final lower = path.toLowerCase();
    if (lower.endsWith('.json') && lower.startsWith('cfgs/zh-cn/')) {
      final cfgName = path.split('/').last.replaceAll('.json', '');
      await openDocGuarded(
        context,
        widget.controller,
        OpenDoc.cfg(cfgName: cfgName),
      );
    } else {
      await openDocGuarded(
        context,
        widget.controller,
        OpenDoc.file(path: path, title: path),
      );
    }
  }

  String _fullPath(String name) {
    if (_currentPath.isEmpty) return name;
    return '$_currentPath/$name';
  }

  void _openDir(FsEntry e) {
    setState(() {
      _currentPath = _fullPath(e.name);
      _query = '';
      _showSearch = false;
    });
    _searchCtrl.clear();
    MobileHaptic.lightImpact();
    _load();
  }

  void _goUp() {
    if (_currentPath.isEmpty) return;
    final i = _currentPath.lastIndexOf('/');
    setState(() {
      _currentPath = i < 0 ? '' : _currentPath.substring(0, i);
      _query = '';
      _showSearch = false;
    });
    _searchCtrl.clear();
    MobileHaptic.lightImpact();
    _load();
  }

  void _goRoot() {
    if (_currentPath.isEmpty) return;
    setState(() {
      _currentPath = '';
      _query = '';
      _showSearch = false;
    });
    _searchCtrl.clear();
    _load();
  }

  List<FsEntry> _visibleEntries(bool mob) {
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? List<FsEntry>.of(_entries)
        : _entries
            .where((e) => e.name.toLowerCase().contains(q))
            .toList();
    // 移动端把目录排前面，文件按名称排；桌面保持服务端顺序。
    if (mob) {
      list.sort((a, b) {
        if (a.type != b.type) return a.type == 'dir' ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    }
    return list;
  }

  /// 按扩展名选择文件图标（图片/音频用专用图标，其余用文档图标）。
  static IconData _fileIcon(String name) {
    final i = name.lastIndexOf('.');
    final ext = i < 0 ? '' : name.substring(i + 1).toLowerCase();
    if (const {'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'}.contains(ext)) {
      return FluentIcons.image_24_regular;
    }
    if (const {'wav', 'ogg', 'mp3', 'flac', 'm4a'}.contains(ext)) {
      return FluentIcons.music_note_2_24_regular;
    }
    return FluentIcons.document_24_regular;
  }

  static String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final mob = isMobileWidth(context);
    if (widget.state.modRoot.isEmpty) {
      return Center(
          child: Text('请先在「模组」中选择一个模组',
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.textHint, fontSize: 12)));
    }
    final visible = _visibleEntries(mob);
    return Column(
      children: [
        Container(
          height: mob ? 48 : 38,
          padding: EdgeInsets.symmetric(
              horizontal: mob ? AppSpace.xs : AppSpace.m),
          child: Row(
            children: [
              if (mob && _currentPath.isNotEmpty)
                _headerIcon(
                  FluentIcons.arrow_left_24_regular,
                  '返回上级',
                  _goUp,
                  mob: mob,
                ),
              Icon(FluentIcons.folder_24_regular,
                  size: 14, color: palette.textMuted),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: GestureDetector(
                  onTap: mob && _currentPath.isNotEmpty ? _goRoot : null,
                  child: Text(
                    mob
                        ? (_currentPath.isEmpty
                            ? widget.state.modName
                            : _currentPath)
                        : widget.state.modName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 12, color: palette.textSecondary),
                  ),
                ),
              ),
              if (mob)
                _headerIcon(
                  _showSearch
                      ? FluentIcons.dismiss_24_regular
                      : FluentIcons.search_24_regular,
                  _showSearch ? '关闭搜索' : '搜索文件',
                  () => setState(() => _showSearch = !_showSearch),
                  mob: mob,
                ),
              _headerIcon(
                FluentIcons.arrow_sync_24_regular,
                '刷新',
                () => _load(refresh: true),
                mob: mob,
              ),
            ],
          ),
        ),
        if (mob && _showSearch)
          Padding(
            padding: const EdgeInsets.only(
                left: AppSpace.m, right: AppSpace.m, bottom: AppSpace.s),
            child: MobileTextField(
              controller: _searchCtrl,
              hintText: '搜索文件…',
              autoFocus: true,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: _loading
              ? const Center(
                  child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : visible.isEmpty
                  ? _emptyState(mob)
                  : Builder(builder: (context) {
                      final list = ListView.builder(
                        padding:
                            const EdgeInsets.symmetric(vertical: AppSpace.xs),
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: visible.length,
                        itemBuilder: (context, i) =>
                            _buildRow(visible[i], mob),
                      );
                      if (!mob) return list;
                      return RefreshIndicator(
                        onRefresh: () => _load(refresh: true),
                        child: list,
                      );
                    }),
        ),
      ],
    );
  }

  Widget _headerIcon(
    IconData icon,
    String tip,
    VoidCallback onTap, {
    required bool mob,
  }) {
    return Semantics(
      button: true,
      label: tip,
      child: Tooltip(
        message: tip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: mob ? 44 : 32,
            height: mob ? 44 : 32,
            child: Center(
              child: Icon(icon, size: 14, color: palette.textMuted),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(FsEntry e, bool mob) {
    final isDir = e.type == 'dir';
    final canTap = !isDir || mob;
    final name = e.name.split('/').last;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: canTap
            ? () {
                MobileHaptic.lightImpact();
                if (isDir) {
                  _openDir(e);
                } else {
                  _open(e);
                }
              }
            : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: mob ? 48 : 0),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: mob ? 10 : 6,
            ),
            child: Row(
              children: [
                Icon(
                  isDir ? FluentIcons.folder_24_regular : _fileIcon(name),
                  size: 15,
                  color: isDir ? palette.textSecondary : palette.textHint,
                ),
                const SizedBox(width: AppSpace.s),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: mob ? 14 : 12.5,
                        color: palette.textPrimary,
                        fontWeight:
                            isDir ? FontWeight.w600 : FontWeight.w400),
                  ),
                ),
                if (mob) ...[
                  const SizedBox(width: AppSpace.s),
                  if (isDir)
                    Icon(FluentIcons.chevron_right_24_regular,
                        size: 16, color: palette.textFaint)
                  else
                    Text(
                      _sizeLabel(e.size),
                      style: TextStyle(
                          fontSize: 10.5, color: palette.textHint),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState(bool mob) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FluentIcons.folder_24_regular,
              size: 40, color: palette.textFaint),
          const SizedBox(height: AppSpace.s10),
          Text(
            _query.isNotEmpty
                ? '没有匹配的文件'
                : (_currentPath.isEmpty ? '暂无文件' : '此文件夹为空'),
            style: TextStyle(fontSize: 12.5, color: palette.textHint),
          ),
          const SizedBox(height: AppSpace.s10),
          TextButton(
            onPressed: () => _load(refresh: true),
            child: const Text('刷新'),
          ),
        ],
      ),
    );
  }
}
