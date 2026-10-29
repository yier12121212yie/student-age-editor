import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:file_selector/file_selector.dart';
import 'dart:convert';

import '../../core/api_client.dart';
import '../../core/blob_put.dart' show downloadUrlNative;
import '../../core/error_text.dart';
import '../../core/file_save.dart';
import '../../core/long_task_progress.dart';
import '../../core/mod_staged_export.dart';
import '../../core/mod_staged_import.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../../core/zip_staging.dart';
import '../editor/editor_controller.dart';
import '../../core/app_theme.dart';
import '../../core/app_dialogs.dart';
import '../../core/mobile_widgets.dart';
import '../auth/deployment_caps.dart';
import 'workshop_publish_dialog.dart';

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
        builder: (ctx) => AppContentDialog(
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

  /// 上传本地模组 zip 导入为工作区新模组。
  ///
  /// 分三条通道：
  /// - 桌面/Android：本机路径直发 `import_path`（zip_staging io 实现）；
  /// - 网页小包：base64 `import_upload`（既有行为）；
  /// - 网页大包（>48MiB，典型是带贴图/配乐资源的模组）：走 `/api/v1/files`
  ///   直传落盘 + `import_staged`。base64 通道受网关 `max_body_bytes`
  ///   （默认 256 MiB）与浏览器内存双重压制，资源包一旦超阈值必失败，
  ///   这正是「模组里有资源就无法导入自托管」的根因。
  Future<void> _importMod() async {
    const typeGroup = XTypeGroup(label: '模组包', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    if (kIsWeb && await file.length() > StagedModImport.directUploadThresholdBytes) {
      try {
        await _importModStaged(file);
        return;
      } on ApiException catch (e) {
        // 服务器没配 COS 文件流转（upload/request/complete 的 500）：回退
        // 旧 base64 通道，让小包照常可用，大包拿到服务端明确的上限报错。
        final notConfigured = e.statusCode == 500 &&
            e.message.toLowerCase().contains('file transfer not configured');
        if (!notConfigured) rethrow;
      }
    }
    await _importModViaZip(file);
  }

  /// 既有 zip 通道：桌面 = 本机路径端点，web = base64 上传端点。
  Future<void> _importModViaZip(XFile file) async {
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
      await _applyImportResult(map);
    } catch (e) {
      if (mounted) _showError('导入失败：${humanizeErrorMessage(e)}');
    } finally {
      try {
        await staged?.cleanup();
      } catch (_) {}
    }
  }

  /// 自托管大模组包：直传对象存储 -> 服务器落盘 -> import_staged，
  /// 全程带进度对话框。抛出的异常由 [._importMod] 决定回退或展示。
  Future<void> _importModStaged(XFile file) async {
    final ctl = showLongTaskProgress(context,
        title: '导入模组包', initialLabel: '申请直传');
    try {
      final map = await StagedModImport.run(
        file,
        onStage: (label, frac) => ctl.update(label, frac),
        isCancelled: () => ctl.isCancelled,
      );
      ctl.finish('导入完成');
      await ctl.closed;
      if (ctl.isCancelled) return; // 已取消：丢弃在途结果
      await _applyImportResult(map);
    } on LongTaskCancelled {
      await ctl.closed; // 用户主动取消：静默，不弹错误
    } catch (e) {
      ctl.fail('导入失败');
      await ctl.closed;
      if (ctl.isCancelled) return;
      rethrow;
    } finally {
      ctl.dispose();
    }
  }

  /// 导入成功后的统一收尾：选中模组、刷新列表、提示。
  Future<void> _applyImportResult(Map<String, dynamic> map) async {
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
  }

  /// 把当前选中的模组打包成 zip 下载（web 走服务端拼包 + 直链，桌面弹保存位置）。
  ///
  /// 网页版优先 `/api/mods/export_staged`：服务端把本地盘文件与 COS 引用资源
  /// 流式拼成 zip（产物登记进文件流转），浏览器经预签名直链带进度下载；带资源
  /// 的大模组走 base64 导出必爆。未配置对象存储时回退旧 base64 通道（小模组）。
  Future<void> _exportCurrent() async {
    final name = widget.state.modName;
    if (name.isEmpty) {
      if (mounted) _showError('请先选择要导出的模组');
      return;
    }
    if (kIsWeb) {
      try {
        await _exportStaged(name);
        return;
      } on ApiException catch (e) {
        final notConfigured = e.statusCode == 500 &&
            e.message.toLowerCase().contains('file transfer not configured');
        if (!notConfigured) {
          if (mounted) _showError('导出失败：${humanizeErrorMessage(e)}');
          return;
        }
        // 未配置对象存储：回退 base64 通道，让小模组照常导出。
      }
    }
    await _exportViaBase64(name);
  }

  /// 服务端拼包导出（web）：打包 -> 等待预热 -> 直链带进度下载 -> 保存。
  Future<void> _exportStaged(String name) async {
    final ctl = showLongTaskProgress(context,
        title: '导出模组包', initialLabel: '服务端打包');
    try {
      final out = await StagedModExport.run(
        name,
        onStage: (label, frac) => ctl.update(label, frac),
        isCancelled: () => ctl.isCancelled,
      );
      ctl.finish('保存中');
      await ctl.closed;
      if (ctl.isCancelled) return; // 已取消：丢弃在途结果
      final saved = out.bytes != null
          ? await saveBytesToFile(
              filename: out.filename,
              bytes: out.bytes!,
              mimeType: 'application/zip')
          : await _saveByNativeDownload(out.url, out.filename);
      if (mounted && saved != null) {
        fluent.displayInfoBar(
            context,
            builder: (ctx, close) => fluent.InfoBar(
                title: const Text('导出完成'),
                content: Text('已保存 ${out.filename}'),
                severity: fluent.InfoBarSeverity.success));
      }
    } on LongTaskCancelled {
      await ctl.closed; // 用户主动取消：静默
    } catch (e) {
      ctl.fail('导出失败');
      await ctl.closed;
      if (ctl.isCancelled) return;
      rethrow;
    } finally {
      ctl.dispose();
    }
  }

  /// 对象存储/CDN 未放行 CORS 时，走浏览器原生下载（不读字节、必然不触发跨域）。
  Future<String?> _saveByNativeDownload(String url, String filename) async {
    await downloadUrlNative(url, filename: filename);
    return filename;
  }

  /// 旧 base64 导出通道（桌面；web 未配对象存储时的小模组回退）。
  Future<void> _exportViaBase64(String name) async {
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
      if (mounted) _showError('导出失败：${humanizeErrorMessage(e)}');
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
      builder: (ctx) => AppContentDialog(
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

  void _publishWorkshop() {
    if (!DeploymentCaps.steamWorkshopAvailable) {
      if (mounted) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => const fluent.InfoBar(
            title: Text('Steam 创意工坊不可用'),
            content: Text('自托管部署运行在服务器上，没有 Steam 客户端。'
                '请在桌面版本机发布，或下载模组 zip 后手动上传。'),
            severity: fluent.InfoBarSeverity.warning,
          ),
        );
      }
      return;
    }
    final name = widget.state.modName;
    if (name.isEmpty) {
      if (mounted) _showError('请先选择要发布的模组');
      return;
    }
    final curMod = widget.state.mods.firstWhere(
      (m) => m.name == name,
      orElse: () => ModInfo(
        name: name,
        root: '',
        cfgFiles: const [],
        hasManifest: false,
        manifestTitle: '',
      ),
    );
    WorkshopPublishDialog.show(
      context,
      modName: name,
      initialTitle: curMod.manifestTitle.isNotEmpty ? curMod.manifestTitle : name,
      initialDesc: '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final mob = isMobileWidth(context);
    return Column(
      children: [
        _Header(
          onRefresh: _refresh,
          onCreate: _create,
          onImport: _importMod,
          onExport: _exportCurrent,
          onPublishWorkshop: _publishWorkshop,
          publishWorkshopAvailable: DeploymentCaps.steamWorkshopAvailable,
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
              final list = ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                physics: mob
                    ? const AlwaysScrollableScrollPhysics()
                    : null,
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
                                  Row(
                                    children: [
                                      Text(
                                          mod.manifestTitle.isNotEmpty
                                              ? mod.manifestTitle
                                              : mod.name,
                                          style: TextStyle(
                                              fontSize: 13,
                                              color: selected ? palette.textHigh : palette.textPrimary,
                                              fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                                      if (_isWorkshop(mod)) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.blue.withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(3),
                                          ),
                                          child: const Text('Steam 工坊',
                                              style: TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ],
                                  ),
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
                              Tooltip(
                                message: '删除模组',
                                child: InkWell(
                                  onTap: () {
                                    MobileHaptic.mediumImpact();
                                    _delete(mod);
                                  },
                                  borderRadius: BorderRadius.circular(AppRadius.m),
                                  child: SizedBox(
                                    width: mob ? 44 : 24,
                                    height: mob ? 44 : 24,
                                    child: Center(
                                      child: Icon(
                                          FluentIcons.delete_24_regular,
                                          size: 15,
                                          color: palette.textMuted),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
              return mob
                  ? RefreshIndicator(onRefresh: _refresh, child: list)
                  : list;
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
    required this.onPublishWorkshop,
    required this.publishWorkshopAvailable,
  });
  final VoidCallback onRefresh;
  final VoidCallback onCreate;
  final VoidCallback onImport;
  final VoidCallback onExport;
  final VoidCallback onPublishWorkshop;
  final bool publishWorkshopAvailable;

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
            icon: FluentIcons.cloud_sync_24_regular,
            tip: publishWorkshopAvailable
                ? '发布到 Steam 创意工坊'
                : '自托管部署没有 Steam 客户端，无法发布到创意工坊',
            onTap: onPublishWorkshop,
            mob: mob,
            enabled: publishWorkshopAvailable,
          ),
          const SizedBox(width: 4),
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
    this.enabled = true,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final bool mob;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: MouseRegion(
        cursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.forbidden,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: mob ? 44 : 32,
            height: mob ? 44 : 32,
            child: Center(
              child: Icon(
                icon,
                size: 15,
                color: enabled ? palette.textMuted : palette.textHint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// 直传导入/导出的进度对话框已提升为公共件 core/long_task_progress.dart（C5），
// 带「取消」按钮，四个长任务场景复用。
