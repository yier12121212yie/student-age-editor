import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import 'bg_visuals.dart';

/// 背景展示：全部 BgCfg 背景的网格画廊（对齐「人物资源库」的立绘网格）。
///
/// 数据源 `GET /api/preview/meta` 的 `bgKeys`/`bgs`（[BgVisualCache]），缩略图
/// 走 `/api/aa/preview`（[BgThumb] → [TexThumb]）——活动资源包未命中时由后端
/// 「背景图片资源扩展」（本地目录 / 对象存储 URL）回退，因此无游戏环境也能看。
class BgGalleryPanel extends StatefulWidget {
  const BgGalleryPanel({super.key});

  @override
  State<BgGalleryPanel> createState() => _BgGalleryPanelState();
}

class _BgGalleryPanelState extends State<BgGalleryPanel> {
  List<BgVisual> _items = const [];
  bool _loading = true;
  String _error = '';
  String _filter = '';

  /// 扫描/轮询态（纯视觉），只重建顶栏图标与空态按钮。
  final ValueNotifier<bool> _scanning = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scanning.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final items = await BgVisualCache.instance.load(force: force);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 扫描游戏资源并轮询直到完成，随后强制重拉元数据（服务器侧有指纹缓存）。
  Future<void> _scan() async {
    if (_scanning.value) return;
    _scanning.value = true;
    try {
      var status = await ApiClient.instance
          .post('/api/aa/scan')
          .then((r) => r['status'] as String? ?? 'scanning');
      for (var i = 0; i < 300; i++) {
        if (status != 'scanning') break;
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        status = (await ApiClient.instance.get('/api/aa/status'))['status']
                as String? ??
            'idle';
      }
      if (mounted) await _load(force: true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) _scanning.value = false;
    }
  }

  List<BgVisual> get _filtered {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items
        .where((b) =>
            b.name.toLowerCase().contains(q) ||
            b.key.toLowerCase().contains(q) ||
            b.id.toLowerCase().contains(q))
        .toList();
  }

  void _showPreview(BgVisual b) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final w = size.width < 640 ? size.width - 48 : 900.0;
        return AlertDialog(
          title: Text(
            b.name.isEmpty ? b.key : b.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: w,
            height: w * 9 / 16,
            child: BgThumb(
              keyName: b.key,
              fit: BoxFit.contain,
              borderRadius: BorderRadius.circular(AppRadius.s),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Widget _iconButton(IconData icon, VoidCallback? onTap, String tooltip,
      {bool spinning = false}) {
    return fluent.Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: spinning
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(icon, size: 16, color: palette.textMuted),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Icon(FluentIcons.image_24_regular, size: 15, color: accentColor),
          const SizedBox(width: 8),
          Text(
            '背景展示',
            style: TextStyle(
              fontSize: 12.5,
              color: palette.textHigh,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text('共 ${_items.length} 张',
              style: TextStyle(fontSize: 11, color: palette.textHint)),
          const Spacer(),
          SizedBox(
            width: 200,
            child: fluent.TextBox(
              placeholder: '搜索名称 / key / ID',
              prefix: const Icon(FluentIcons.search_24_regular, size: 13),
              style: const TextStyle(fontSize: 12),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          const SizedBox(width: 6),
          ListenableBuilder(
            listenable: _scanning,
            builder: (context, _) => _iconButton(
              FluentIcons.arrow_sync_24_regular,
              _scanning.value ? null : _scan,
              '重新扫描游戏资源',
              spinning: _scanning.value,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.image_24_regular,
                size: 40, color: palette.iconDisabled),
            const SizedBox(height: 12),
            Text(
              _error.isNotEmpty
                  ? '加载失败：$_error'
                  : '暂无背景\n可在 BgCfg 背景表配置 url，或安装「背景图片资源扩展包」',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12.5, color: palette.textSecondary, height: 1.6),
            ),
            const SizedBox(height: 14),
            ListenableBuilder(
              listenable: _scanning,
              builder: (context, _) => fluent.FilledButton(
                onPressed: _scanning.value ? null : _scan,
                child: Text(_scanning.value ? '扫描中…' : '扫描游戏资源'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(List<BgVisual> list) {
    if (list.isEmpty) {
      return Center(
        child: Text('没有匹配的背景',
            style: TextStyle(fontSize: 12, color: palette.textHint)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 16 / 9,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) => _tile(list[i]),
    );
  }

  Widget _tile(BgVisual b) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _showPreview(b),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.m),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                color: palette.panel,
                child: BgThumb(keyName: b.key, fit: BoxFit.cover),
              ),
              // 底部渐变 + 名称/key，避免亮色背景上看不清文字。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        palette.bgDeep2.withValues(alpha: 0.82),
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        b.name.isEmpty ? b.key : b.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${b.key}  ·  ID ${b.id}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: _loading
              ? const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : _items.isEmpty
                  ? _buildEmpty()
                  : _buildGrid(_filtered),
        ),
      ],
    );
  }
}
