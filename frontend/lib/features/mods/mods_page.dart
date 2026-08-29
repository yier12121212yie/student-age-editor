import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../editor/editor_controller.dart';
import '../../core/app_theme.dart';

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
    final p = mod.root.replaceAll('\\', '/').toLowerCase();
    return p.contains('/steamapps/workshop/content/1991040');
  }

  Future<void> _refresh() async {
    final r = await ApiClient.instance.get('/api/mods');
    if (!mounted) return;
    setState(() {
      widget.state.mods = (r['mods'] as List)
          .map((e) => ModInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    });
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
  const _Header({required this.onRefresh, required this.onCreate});
  final VoidCallback onRefresh;
  final VoidCallback onCreate;

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
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRefresh,
                child: Padding(
                    padding: EdgeInsets.all(mob ? 12 : 0),
                    child: Icon(FluentIcons.arrow_sync_24_regular,
                        size: 15, color: palette.textMuted))),
          ),
          const SizedBox(width: 4),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCreate,
                child: Padding(
                    padding: EdgeInsets.all(mob ? 12 : 0),
                    child: Icon(FluentIcons.add_24_regular,
                        size: 16, color: palette.textMuted))),
          ),
        ],
      ),
    );
  }
}
