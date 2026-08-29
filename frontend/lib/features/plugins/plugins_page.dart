import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/plugin_state.dart';

/// 插件管理页：列表 / 启用（高危确认）/ 停用 / 卸载 / 安装 zip / 重载。
/// 不自带 Scaffold：既嵌入侧栏 SidePaneView，也嵌入移动端 MobileSubPage。
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key, required this.pluginState});

  final PluginState pluginState;

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  bool _busy = false;

  PluginState get _ps => widget.pluginState;

  // ---------------- 操作 ----------------

  /// 启用：每次都先弹高危确认框（不做"不再提示"），确认后带 risk_ack:true 调用。
  Future<void> _enable(PluginSummary p) async {
    final ok = await _confirmEnable(p);
    if (ok != true || !mounted) return;
    try {
      await _ps.enable(p.id);
    } catch (e) {
      if (mounted) _showError('启用失败：$e');
    }
  }

  Future<void> _disable(PluginSummary p) async {
    try {
      await _ps.disable(p.id);
    } catch (e) {
      if (mounted) _showError('停用失败：$e');
    }
  }

  Future<void> _uninstall(PluginSummary p) async {
    if (p.enabled) {
      _showInfo('该插件处于启用状态，请先停用后再卸载');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('卸载插件'),
        content: Text('确定卸载插件「${p.name}」吗？卸载后插件目录与数据将被删除。'),
        actions: [
          fluent.Button(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          fluent.FilledButton(
            style: const fluent.ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(Colors.red),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _ps.uninstall(p.id);
      if (mounted) _showInfo('插件已卸载');
    } catch (e) {
      if (mounted) _showError('卸载失败：$e');
    }
  }

  /// 选择本地 zip 安装：先拷贝到应用可写临时目录，再按路径提交后端
  /// （对齐资源包导入流程，绕过 base64 与体积上限）。
  Future<void> _install() async {
    if (_busy) return;
    const typeGroup = XTypeGroup(label: '插件包', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final tmpDir = await Directory.systemTemp.createTemp('plugin_import_');
      final dest = '${tmpDir.path}${Platform.pathSeparator}${file.name}';
      await File(file.path).copy(dest);
      await _ps.installZip(dest, file.name);
      if (mounted) _showInfo('插件安装成功');
    } catch (e) {
      if (mounted) _showError('安装失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _ps.reloadAll();
      if (mounted) _showInfo('已重新加载全部插件');
    } catch (e) {
      if (mounted) _showError('重载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 高危启用确认框：名称/版本/作者/描述 + 红色警示块，确认按钮为危险红「仍要启用」。
  Future<bool> _confirmEnable(PluginSummary p) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => fluent.ContentDialog(
            title: const Text('启用插件'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name,
                    style: TextStyle(
                        fontSize: 14, color: palette.textHigh, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  '版本 v${p.version.isEmpty ? '?' : p.version} · 作者：${p.author.isEmpty ? '未知' : p.author}',
                  style: TextStyle(fontSize: 11, color: palette.textHint),
                ),
                if (p.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(p.description,
                      style: TextStyle(fontSize: 12, color: palette.textSecondary, height: 1.5)),
                ],
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: palette.tintDanger,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: palette.statusDanger),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(FluentIcons.warning_24_regular,
                          size: 16, color: palette.statusDanger),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '该插件为第三方 Python 代码，启用后将以与编辑器相同的用户权限在本机运行，'
                          '可读写文件、访问网络。请仅启用来自可信来源的插件。',
                          style: TextStyle(
                              fontSize: 12, color: palette.statusDanger, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              fluent.FilledButton(
                style: const fluent.ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(Colors.red),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('仍要启用'),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ---------------- 提示 ----------------

  void _showError(String msg) {
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
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(msg),
        severity: fluent.InfoBarSeverity.info,
      ),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(onRefresh: _refresh, onInstall: _install),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: ListenableBuilder(
            listenable: _ps,
            builder: (context, _) => _buildBody(),
          ),
        ),
        Divider(height: 1, color: palette.border),
        Container(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: fluent.Button(
                  onPressed: _busy ? null : _reload,
                  child: const Text('重载插件'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: fluent.FilledButton(
                  onPressed: _busy ? null : _install,
                  child: const Text('安装插件'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _refresh() => _ps.refresh();

  Widget _buildBody() {
    if (_ps.loading && _ps.plugins.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_ps.plugins.isEmpty) {
      final err = _ps.error;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.puzzle_piece_24_regular,
                size: 32, color: palette.textFaint),
            const SizedBox(height: 10),
            Text('暂无插件，点击安装或查看插件指南',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textHint, fontSize: 13, height: 1.6)),
            if (err != null) ...[
              const SizedBox(height: 8),
              Text(err,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.textMuted, fontSize: 11)),
              const SizedBox(height: 8),
              fluent.Button(onPressed: _refresh, child: const Text('重试')),
            ],
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final p in _ps.plugins) ...[
          _pluginCard(p),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _pluginCard(PluginSummary p) {
    final loadFailed = p.enabled && !p.loaded;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: loadFailed ? palette.statusWarn : palette.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.puzzle_piece_24_regular,
                  size: 18, color: palette.accentLight),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.name.isEmpty ? p.id : p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14, color: palette.textHigh, fontWeight: FontWeight.w600),
                ),
              ),
              fluent.ToggleSwitch(
                checked: p.enabled,
                onChanged: (v) => v ? _enable(p) : _disable(p),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (p.version.isNotEmpty) 'v${p.version}',
              if (p.author.isNotEmpty) '作者：${p.author}',
              p.id,
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: palette.textHint),
          ),
          if (p.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(p.description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: palette.textMuted, height: 1.5)),
          ],
          if (loadFailed) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: palette.tintWarn,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: palette.statusWarn),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(FluentIcons.warning_24_regular, size: 14, color: palette.statusWarn),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      p.error.isNotEmpty ? '加载失败：${p.error}' : '已启用但未加载成功，请查看后端日志或尝试重载',
                      style: TextStyle(fontSize: 11, color: palette.statusWarn, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ] else if (p.error.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('⚠ ${p.error}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: palette.statusDanger)),
          ],
          if (p.riskAckAt.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('已确认于 ${p.riskAckAt}',
                style: TextStyle(fontSize: 10, color: palette.textFaint)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Text(p.loaded ? '已加载' : (p.enabled ? '未加载' : '未启用'),
                  style: TextStyle(
                      fontSize: 11,
                      color: p.enabled && !p.loaded
                          ? palette.statusWarn
                          : palette.textHint)),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _uninstall(p),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(FluentIcons.delete_24_regular,
                      size: 18, color: palette.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onRefresh, required this.onInstall});
  final VoidCallback onRefresh;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text('插件',
              style: TextStyle(
                  fontSize: 12, color: palette.textSecondary, fontWeight: FontWeight.w600)),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onInstall,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(FluentIcons.folder_zip_24_regular,
                    size: 15, color: palette.textMuted),
              ),
            ),
          ),
          const SizedBox(width: 4),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRefresh,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(FluentIcons.arrow_sync_24_regular,
                    size: 15, color: palette.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
