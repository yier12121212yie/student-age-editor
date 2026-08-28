import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../editor/editor_controller.dart';

/// 文件树侧边栏：浏览当前模组目录，点击打开文档。
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

  @override
  void initState() {
    super.initState();
    // 先对齐当前模组缓存，避免启动后首个无关通知误触发重复加载
    _lastModRoot = widget.state.modRoot;
    _lastModName = widget.state.modName;
    widget.state.addListener(_onState);
    _load();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    // 只关注模组切换；AA 状态等其它通知不应触发文件树全量重载
    final modRoot = widget.state.modRoot;
    final modName = widget.state.modName;
    if (modRoot != _lastModRoot || modName != _lastModName) {
      _lastModRoot = modRoot;
      _lastModName = modName;
      if (mounted) _load();
    }
  }

  String _lastModRoot = '';
  String _lastModName = '';

  Future<void> _load() async {
    if (widget.state.modRoot.isEmpty) {
      setState(() => _entries = []);
      return;
    }
    setState(() => _loading = true);
    try {
      // deep=1：递归列出子目录条目（Cfgs/zh-cn/*.json），否则只能看到根目录一级
      final r = await ApiClient.instance
          .get('/api/tools/list', query: {'scope': 'mod', 'path': '', 'deep': '1'});
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

  void _open(FsEntry e) {
    final lower = e.name.toLowerCase();
    if (lower.endsWith('.json') && lower.startsWith('cfgs/zh-cn/')) {
      final cfgName = e.name.split('/').last.replaceAll('.json', '');
      widget.controller.open(OpenDoc.cfg(cfgName: cfgName));
    } else {
      widget.controller.open(OpenDoc.file(path: e.name, title: e.name));
    }
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

  @override
  Widget build(BuildContext context) {
    final mob = isMobileWidth(context);
    if (widget.state.modRoot.isEmpty) {
      return const Center(
          child: Text('请先在「模组」中选择一个模组',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF6E6E76), fontSize: 12)));
    }
    return Column(
      children: [
        Container(
          height: mob ? 44 : 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Icon(FluentIcons.folder_24_regular, size: 14, color: Color(0xFF8B8B93)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.state.modName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9B9BA3))),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _load,
                    child: Padding(
                        padding: EdgeInsets.all(mob ? 12 : 0),
                        child: const Icon(FluentIcons.arrow_sync_24_regular,
                            size: 14, color: Color(0xFF8B8B93)))),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2E)),
        Expanded(
          child: _loading
              ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _entries.length,
                  itemBuilder: (context, i) {
                    final e = _entries[i];
                    final isDir = e.type == 'dir';
                    final name = e.name.split('/').last;
                    return MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: isDir ? null : () => _open(e),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                isDir
                                    ? FluentIcons.folder_24_regular
                                    : _fileIcon(name),
                                size: 15,
                                color: isDir ? const Color(0xFF9B9BA3) : const Color(0xFF6E6E76),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        color: const Color(0xFFD4D4D8),
                                        fontWeight: isDir ? FontWeight.w600 : FontWeight.w400)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
