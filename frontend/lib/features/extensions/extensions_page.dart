import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/plugin_state.dart';
import '../../core/zip_staging.dart';
import '../../core/app_dialogs.dart';

/// 统一的「扩展」管理页（3A）：资源包 + 插件合并为一个列表，多选启用。
///
/// 数据来自 `GET /api/extensions`：`{enabled:[...], extensions:[...]}`。插件
/// 默认启用、资源包 opt-in；启用/停用统一走 `POST /api/extensions/active`
/// 的 `{"ids":[...]}`（2A）。安装统一落插件根（1A），资源包也可经既有的
/// `/api/resource_packs` 安装（兼容）。
///
/// 不自带 Scaffold：既嵌入侧栏 / 模态，也嵌入移动端 MobileSubPage（调用方
/// 负责 Scaffold/AppBar），与既有 PluginsPage 的约定一致。
class ExtensionsPage extends StatefulWidget {
  const ExtensionsPage({super.key, this.pluginState});

  /// 可选：启用/停用插件后刷新全局插件状态（侧栏面板、AI 工具等据此更新）。
  final PluginState? pluginState;

  @override
  State<ExtensionsPage> createState() => _ExtensionsPageState();
}

class _ExtensionsPageState extends State<ExtensionsPage> {
  List<Map<String, dynamic>> _exts = [];
  Set<String> _enabled = {};
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await ApiClient.instance.get('/api/extensions');
      if (!mounted) return;
      final exts = ((r is Map ? r['extensions'] : null) as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final enabled = ((r is Map ? r['enabled'] : null) as List? ?? const [])
          .whereType<String>()
          .toSet();
      setState(() {
        _exts = exts;
        _enabled = enabled;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 切换一个扩展的启用态：把完整启用集提交给 `/api/extensions/active`。
  Future<void> _toggle(String id, bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = {..._enabled};
    if (on) {
      next.add(id);
    } else {
      next.remove(id);
    }
    try {
      final r = await ApiClient.instance.post(
        '/api/extensions/active',
        body: {'ids': next.toList()},
      );
      if (!mounted) return;
      final enabled = ((r is Map ? r['enabled'] : null) as List? ?? const [])
          .whereType<String>()
          .toSet();
      setState(() {
        _enabled = enabled;
        for (final e in _exts) {
          if (e['id'] == id) e['enabled'] = enabled.contains(id);
        }
      });
      await widget.pluginState?.refresh();
    } catch (e) {
      if (mounted) _showError(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 选择本地 zip 安装：桌面=临时目录路径，web=base64 上传。
  Future<void> _install() async {
    if (_busy) return;
    const typeGroup = XTypeGroup(label: '扩展包', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    setState(() => _busy = true);
    StagedZip? staged;
    try {
      staged = await stageZipForInstall(
        file,
        const ZipStageOptions(
          pathEndpoint: '/api/extensions/install_path',
          uploadEndpoint: '/api/extensions/install_upload',
          tempPrefix: 'extension_import_',
        ),
      );
      final r = await ApiClient.instance.post(staged.endpoint, body: staged.body);
      if (r is Map && r['ok'] == false) {
        _showError((r['error'] ?? '安装失败').toString());
        return;
      }
      _showInfo('扩展安装成功');
      await widget.pluginState?.refresh();
    } catch (e) {
      if (mounted) _showError('安装失败：$e');
    } finally {
      try {
        await staged?.cleanup();
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _uninstall(Map<String, dynamic> e) async {
    final id = (e['id'] as String?) ?? '';
    if (id.isEmpty) return;
    final name = (e['name'] as String?) ?? id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('卸载扩展'),
        content: Text('确定卸载扩展「$name」吗？扩展目录或资源包将被删除。'),
        actions: [
          fluent.Button(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          fluent.FilledButton(
            style: fluent.ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(palette.danger),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ApiClient.instance.delete('/api/extensions/${Uri.encodeComponent(id)}');
      if (mounted) _showInfo('已卸载');
      await widget.pluginState?.refresh();
    } catch (e) {
      if (mounted) _showError('卸载失败：$e');
    } finally {
      await _load();
    }
  }

  Future<void> _reload() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ApiClient.instance.post('/api/extensions/reload');
      if (mounted) _showInfo('已重新加载全部扩展');
      await widget.pluginState?.refresh();
    } catch (e) {
      if (mounted) _showError('重载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: const Text('操作失败'),
        content: Text(msg),
        severity: fluent.InfoBarSeverity.error,
      ),
    );
  }

  void _showInfo(String msg) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(msg),
        severity: fluent.InfoBarSeverity.info,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(),
        Divider(height: 1, color: palette.border),
        Expanded(child: _body()),
        Divider(height: 1, color: palette.border),
        Container(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: fluent.Button(
                  onPressed: _busy ? null : _reload,
                  child: const Text('重载'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: fluent.FilledButton(
                  onPressed: _busy ? null : _install,
                  child: const Text('安装扩展'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(
            '扩展',
            style: TextStyle(
              fontSize: 12,
              color: palette.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          _iconButton(FluentIcons.folder_zip_24_regular, _busy ? null : _install, '安装扩展'),
          const SizedBox(width: 4),
          _iconButton(FluentIcons.arrow_sync_24_regular, _busy ? null : _reload, '重载'),
        ],
      ),
    );
  }

  Widget _iconButton(IconData icon, VoidCallback? onTap, String tooltip) {
    return fluent.Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 15, color: palette.textMuted),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading && _exts.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null && _exts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FluentIcons.error_circle_24_regular, color: palette.statusDanger, size: 32),
              const SizedBox(height: 10),
              Text('加载失败: $_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.textSecondary, fontSize: 13)),
              const SizedBox(height: 12),
              fluent.Button(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_exts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.puzzle_piece_24_regular, size: 32, color: palette.textFaint),
            const SizedBox(height: 10),
            Text('暂无扩展，点击安装资源包或插件',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textHint, fontSize: 13, height: 1.6)),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.surface),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(FluentIcons.info_24_regular, size: 16, color: accentColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '扩展包含插件（界面面板 / AI 工具）与资源包（官方配置表、解码图包）。可同时启用多个；资源包用于无游戏环境的设备。',
                  style: TextStyle(fontSize: 12, color: palette.textSecondary, height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final e in _exts) ...[
          _card(e),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _card(Map<String, dynamic> e) {
    final id = (e['id'] as String?) ?? '';
    final name = (e['name'] as String?) ?? id;
    final enabled = _enabled.contains(id) || e['enabled'] == true;
    final kind = (e['kind'] as String?) ?? 'extension';
    final source = (e['source'] as String?) ?? '';
    final isPlugin = source == 'plugins';
    final resources = (e['resources'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: enabled ? palette.accentDeep : palette.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPlugin ? FluentIcons.puzzle_piece_24_regular : FluentIcons.folder_zip_24_regular,
                size: 18,
                color: palette.accentLight,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name.isEmpty ? id : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14, color: palette.textHigh, fontWeight: FontWeight.w600),
                ),
              ),
              _kindBadge(kind, resources),
              const SizedBox(width: 8),
              fluent.ToggleSwitch(
                checked: enabled,
                onChanged: _busy ? null : (v) => _toggle(id, v),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [
              if ((e['version'] as String?)?.isNotEmpty ?? false) 'v${e['version']}',
              if ((e['author'] as String?)?.isNotEmpty ?? false) '作者：${e['author']}',
              id,
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: palette.textHint),
          ),
          if ((e['description'] as String?)?.isNotEmpty ?? false) ...[
            const SizedBox(height: 4),
            Text(e['description'] as String,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: palette.textMuted, height: 1.5)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Text(enabled ? '已启用' : '未启用',
                  style: TextStyle(
                      fontSize: 11,
                      color: enabled ? palette.accentLighter : palette.textHint)),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _uninstall(e),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(FluentIcons.delete_24_regular, size: 18, color: palette.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kindBadge(String kind, Map<String, dynamic> resources) {
    final labels = <String>[
      if (kind == 'resource') '资源包' else '插件',
      if (resources['aa'] == true) 'AA',
      if (resources['base'] == true) 'base',
      if (resources['cfgs'] == true) 'Cfgs',
      if (resources['tex'] == true) '图',
      if (resources['aud'] == true) '音',
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border),
      ),
      child: Text(labels.join(' · '),
          style: TextStyle(fontSize: 10, color: palette.textSecondary)),
    );
  }
}
