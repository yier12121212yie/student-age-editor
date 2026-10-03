import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:file_selector/file_selector.dart';
import 'dart:convert';

import '../../core/api_client.dart';
import '../../core/file_save.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../../core/zip_staging.dart';
import '../editor/editor_controller.dart';
import '../../core/app_theme.dart';

/// 创意工坊 AppID，与 native 的 sa_core::steam_paths::kGameAppid 同源。
const String _kWorkshopAppid = '1991040';

/// 模组侧边栏：列表 + 新建/删除/选择。
class ModsPage extends StatefulWidget {
  const ModsPage({super.key, required this.state, required this.controller});
  final AppState state;
  final EditorController controller;
  @override
  State<ModsPage> createState() => _ModsPageState();
}

class _ModsPageState extends State<ModsPage> {
  Future<void> _select(ModInfo mod) async {
    try {
      final r = await ApiClient.instance.post('/api/mods/select', body: {'name': mod.name});
      widget.state.setMod(
          (r['mod'] as Map)['name'] as String, (r['mod'] as Map)['root'] as String);
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _create() async {
    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => fluent.ContentDialog(
          title: const Text('创建新模组'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text('必填：创建后显示在模组列表的名称，建议简洁明了',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ),
              const SizedBox(height: 4),
              fluent.TextBox(controller: titleCtrl, placeholder: '模组标题'),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('可选：一句话描述模组内容与玩法，便于日后区分不同模组',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ),
              const SizedBox(height: 4),
              fluent.TextBox(controller: descCtrl, placeholder: '模组简介（可选）', maxLines: 3),
            ],
          ),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            fluent.FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  final r = await ApiClient.instance.post('/api/mods/create',
                      body: {'title': titleCtrl.text, 'desc': descCtrl.text});
                  final m = (r['mod'] as Map).cast<String, dynamic>();
                  widget.state.setMod(m['name'] as String, m['root'] as String);
                  await _refresh();
                } catch (e) {
                  if (mounted) _showError(e.toString());
                }
              },
              child: const Text('创建'),
            ),
          ],
        ),
      );
    } finally {
      // 对话框关闭即释放，无论以取消还是创建路径退出。
      titleCtrl.dispose();
      descCtrl.dispose();
    }
  }

  /// 上传本地模组 zip 导入为工作区新模组（桌面=本机路径，web=base64 上传）。
  Future<void> _importMod() async {
    const typeGroup = XTypeGroup(label: '模组包', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    StagedZip? staged;
    try {
      staged = await stageZipForInstall(
        file,
        const ZipStageOptions(
          pathEndpoint: '/api/mods/import_path',
          uploadEndpoint: '/api/mods/import_upload',
          tempPrefix: 'mod_import_',
        ),
      );
      final r = await ApiClient.instance.post(staged.endpoint,
          body: staged.body, timeout: const Duration(minutes: 30));
      final map = r is Map ? r.cast<String, dynamic>() : <String, dynamic>{};
      final mod = map['mod'];
      if (mod is Map) {
        final m = mod.cast<String, dynamic>();
        widget.state.setMod(m['name'] as String, m['root'] as String);
      }
      await _refresh();
      if (mounted) {
        fluent.displayInfoBar(
            context,
            builder: (ctx, close) => const fluent.InfoBar(
                title: Text('导入成功'),
                content: Text('模组已导入并选中'),
                severity: fluent.InfoBarSeverity.success));
      }
    } catch (e) {
      if (mounted) _showError('导入失败：$e');
    } finally {
      try {
        await staged?.cleanup();
      } catch (_) {}
    }
  }

  /// 把当前选中的模组打包成 zip 下载（web 走浏览器下载，桌面弹保存位置）。
  Future<void> _exportCurrent() async {
    final name = widget.state.modName;
    if (name.isEmpty) {
      if (mounted) _showError('请先选择要导出的模组');
      return;
    }
    try {
      final r =
          await ApiClient.instance.post('/api/mods/export',
              body: {'name': name}, timeout: const Duration(minutes: 30));
      final map = r is Map ? r.cast<String, dynamic>() : <String, dynamic>{};
      final enc = (map['data_base64'] ?? '').toString();
      final filename = (map['filename'] ?? '$name.zip').toString();
      if (enc.isEmpty) {
        if (mounted) _showError('导出失败：后端返回空数据');
        return;
      }
      final saved = await saveBytesToFile(
          filename: filename,
          bytes: base64Decode(enc),
          mimeType: 'application/zip');
      if (mounted && saved != null) {
        fluent.displayInfoBar(
            context,
            builder: (ctx, close) => fluent.InfoBar(
                title: const Text('导出完成'),
                content: Text('已保存 $filename'),
                severity: fluent.InfoBarSeverity.success));
      }
    } catch (e) {
      if (mounted) _showError('导出失败：$e');
    }
  }

  Future<void> _delete(ModInfo mod) async {
    if (_isWorkshop(mod)) {
      if (!mounted) return;
      fluent.displayInfoBar(context,
          builder: (ctx, close) => const fluent.InfoBar(
              title: Text('无法删除'),
              content: Text('创意工坊订阅内容请在 Steam 客户端取消订阅，不能直接删除'),
              severity: fluent.InfoBarSeverity.error));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('删除模组'),
        content: Text('确定删除模组「${mod.name}」吗？此操作不可恢复。'),
        actions: [
          fluent.Button(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          fluent.FilledButton(
            style: fluent.ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(palette.danger),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiClient.instance.post('/api/mods/delete', body: {'name': mod.name});
      if (widget.state.modName == mod.name) {
        widget.state.setMod('', '');
      }
      await _refresh();
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  bool _isWorkshop(ModInfo mod) {
    // 后端返回的路径分隔符约定为正斜杠；这里再归一一次反斜杠，兼容历史数据。
    final p = mod.root.replaceAll('\\', '/').toLowerCase();
    return p.contains('/steamapps/workshop/content/$_kWorkshopAppid');
  }

  Future<void> _refresh() async {
    final r = await ApiClient.instance.get('/api/mods');
    if (!mounted) return;
    // 列表变更经 setMods 广播给所有依赖 state.mods 的面板
    // （如云同步的 Mod 下拉），否则它们要等下一次无关通知才刷新。
    widget.state.setMods((r['mods'] as List)
        .map((e) => ModInfo.fromJson(e as Map<String, dynamic>))
        .toList());
  }

  void _showError(String msg) {
    fluent.displayInfoBar(context, builder: (ctx, close) =>
        fluent.InfoBar(title: Text('操作失败'), content: Text(msg), severity: fluent.InfoBarSeverity.error));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(
          onRefresh: _refresh,
          onCreate: _create,
          onImport: _importMod,
          onExport: _exportCurrent,
        ),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.state,
            builder: (context, _) {
              if (widget.state.mods.isEmpty) {
                return Center(
                    child: Text('暂无模组\n点击右上角 + 新建',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: palette.textHint, fontSize: 12)));
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: widget.state.mods.length,
                separatorBuilder: (_, _) => Divider(height: 1, color: palette.panel),
                itemBuilder: (context, i) {
                  final mod = widget.state.mods[i];
                  final selected = mod.name == widget.state.modName;
                  return MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => _select(mod),
                      child: Container(
                        color: selected ? palette.hover : Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Icon(FluentIcons.box_24_regular, size: 16, color: palette.textSecondary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      mod.manifestTitle.isNotEmpty
                                          ? mod.manifestTitle
                                          : mod.name,
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: selected ? palette.textHigh : palette.textPrimary,
                                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                                  if (mod.manifestTitle.isNotEmpty)
                                    Text(mod.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 11, color: palette.textHint)),
                                  Text('${mod.cfgFiles.length} 个配置表',
                                      style: TextStyle(fontSize: 11, color: palette.textHint)),
                                ],
                              ),
                            ),
                            if (selected && !_isWorkshop(mod))
                              GestureDetector(
                                onTap: () => _delete(mod),
                                child: Icon(FluentIcons.delete_24_regular,
                                    size: 15, color: palette.textMuted),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.onRefresh,
    required this.onCreate,
    required this.onImport,
    required this.onExport,
  });
  final VoidCallback onRefresh;
  final VoidCallback onCreate;
  final VoidCallback onImport;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final mob = isMobileWidth(context);
    return Container(
      height: mob ? 44 : 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text('模组',
              style: TextStyle(fontSize: 12, color: palette.textSecondary, fontWeight: FontWeight.w600)),
          const Spacer(),
          _HeaderIcon(
            icon: FluentIcons.arrow_download_24_regular,
            tip: '导入模组 zip',
            onTap: onImport,
            mob: mob,
          ),
          const SizedBox(width: 4),
          _HeaderIcon(
            icon: FluentIcons.arrow_upload_24_regular,
            tip: '导出当前模组 zip',
            onTap: onExport,
            mob: mob,
          ),
          const SizedBox(width: 4),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRefresh,
              child: SizedBox(
                width: mob ? 44 : 32,
                height: mob ? 44 : 32,
                child: Center(
                  child: Icon(FluentIcons.arrow_sync_24_regular, size: 15, color: palette.textMuted),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onCreate,
              child: SizedBox(
                width: mob ? 44 : 32,
                height: mob ? 44 : 32,
                child: Center(
                  child: Icon(FluentIcons.add_24_regular, size: 16, color: palette.textMuted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 模组页头部的小动作按钮（导入/导出共用；refresh/add 是历史内联写法，保持原样）。
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.icon,
    required this.tip,
    required this.onTap,
    required this.mob,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final bool mob;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: mob ? 44 : 32,
            height: mob ? 44 : 32,
            child: Center(
              child: Icon(icon, size: 15, color: palette.textMuted),
            ),
          ),
        ),
      ),
    );
  }
}
