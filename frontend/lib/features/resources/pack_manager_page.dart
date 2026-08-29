import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/app_theme.dart';

/// 资源包管理页：列出 / 激活 / 删除 / 导入内置游戏资源包。
/// 资源包内含官方配置表、base_data 与预解码图包，是无游戏环境（Android）
/// 使用剧情库 / 事件预览 / 资源浏览的数据来源。
class PackManagerPage extends StatefulWidget {
  const PackManagerPage({super.key, required this.state});

  final AppState state;

  @override
  State<PackManagerPage> createState() => _PackManagerPageState();
}

class _PackManagerPageState extends State<PackManagerPage> {
  Map<String, dynamic>? _meta; // {active, packs: [...]}
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final r = await ApiClient.instance.get('/api/resource_packs');
      if (!mounted) return;
      setState(() {
        _meta = r is Map ? Map<String, dynamic>.from(r) : null;
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

  Future<void> _activate(String id) async {
    try {
      await ApiClient.instance.post('/api/resource_packs/active', body: {'id': id});
      if (mounted) _refresh();
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('删除资源包'),
        content: Text('确定删除资源包「$id」吗？'),
        actions: [
          fluent.Button(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          fluent.FilledButton(
            style: const fluent.ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(Colors.red),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiClient.instance.delete('/api/resource_packs/$id');
      if (mounted) _refresh();
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  /// 选择本地 zip 导入：先拷贝到应用可写临时目录，再按路径提交后端
  /// （绕过 base64 与 500MB 体积上限）。
  Future<void> _import() async {
    const typeGroup = XTypeGroup(label: 'zip', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    try {
      final tmpDir = await Directory.systemTemp.createTemp('pack_import_');
      final dest = '${tmpDir.path}${Platform.pathSeparator}${file.name}';
      await File(file.path).copy(dest);
      final r = await ApiClient.instance
          .post('/api/resource_packs/import_path', body: {'path': dest});
      if (!mounted) return;
      if (r is Map && r['ok'] == false) {
        _showError((r['error'] ?? '导入失败').toString());
        return;
      }
      _showInfo('资源包导入成功');
      _refresh();
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: palette.tintDanger,
      ),
    );
  }

  void _showInfo(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: palette.panel),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: palette.bgDeep2,
      appBar: AppBar(
        backgroundColor: palette.bg,
        elevation: 0,
        leading: BackButton(color: palette.textHigh),
        title: Text('资源包管理', style: TextStyle(fontSize: 16, color: palette.textHigh)),
        actions: [
          IconButton(
            icon: Icon(FluentIcons.folder_zip_24_regular, color: palette.textSecondary),
            onPressed: _import,
            tooltip: '导入资源包',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(FluentIcons.error_circle_24_regular, color: Colors.redAccent, size: 32),
              const SizedBox(height: 10),
              Text('加载失败: $_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.textSecondary, fontSize: 13)),
              const SizedBox(height: 12),
              fluent.Button(onPressed: _refresh, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final active = (_meta?['active'] as String?) ?? '';
    final packs = ((_meta?['packs'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
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
              Icon(FluentIcons.info_24_regular, size: 16, color: Color(0xFF6C5CE7)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '资源包内置游戏的官方配置表与解码图包。无游戏环境的设备（如 Android）可借此使用剧情库、事件预览与资源浏览。',
                  style: TextStyle(fontSize: 12, color: palette.textSecondary, height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (packs.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Text('未安装任何资源包\n点击右上角导入',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textHint, fontSize: 13, height: 1.6)),
          )
        else
          for (final p in packs) ...[
            _packCard(p, active),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _packCard(Map<String, dynamic> p, String active) {
    final id = (p['id'] as String?) ?? '';
    final isActive = id == active;
    final files = (p['files'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: isActive ? const Color(0xFF4A3DB8) : palette.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.folder_zip_24_regular, size: 18, color: palette.accentLight),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  (p['name'] as String?) ?? id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14, color: palette.textHigh, fontWeight: FontWeight.w600),
                ),
              ),
              if (isActive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C5CE7).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF4A3DB8)),
                  ),
                  child: Text('激活中',
                      style: TextStyle(fontSize: 11, color: palette.accentLighter)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [
              if ((p['version'] as String?)?.isNotEmpty ?? false) 'v${p['version']}',
              '$files 个文件',
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: palette.textHint),
          ),
          if ((p['description'] as String?)?.isNotEmpty ?? false) ...[
            const SizedBox(height: 4),
            Text(p['description'] as String,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: palette.textMuted)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              if (!isActive)
                fluent.FilledButton(
                  style: const fluent.ButtonStyle(
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                  ),
                  onPressed: () => _activate(id),
                  child: const Text('激活', style: TextStyle(fontSize: 12)),
                )
              else
                Text('当前启用中',
                    style: TextStyle(fontSize: 11, color: palette.textHint)),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _delete(id),
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(FluentIcons.delete_24_regular, size: 18, color: palette.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}