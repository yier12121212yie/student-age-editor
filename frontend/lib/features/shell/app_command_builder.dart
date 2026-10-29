// A2 命令面板 / 全局快捷键的数据来源：**现场**从现有目录生成命令，
// 不维护第二份功能清单（见 plan/ux_roadmap_r2.md A2）。
//
// 数据源与各入口一一对应：
// - 常用动作 → [ShellState.selectPane]（左侧栏面板）与 [ShellState.toggleAi]；
// - 界面模式 → [UiMode] + `mode_picker` 的图标/说明；
// - 编辑页面 → `pages_catalog` 的 [visibleEditorPages] + [pageIconFor]；
// - 功能     → `workshop_features` 的 [kWorkshopFeatures]；
// - 模组     → [AppState.mods]。
//
// 壳相关的落地（导演壳的功能视图、移动壳的子页等）走 [AppCommandHost]；
// 未登记时不生成对应命令，避免出现点了没反应的死条目。
library;

import 'package:flutter/widgets.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_command.dart';
import '../../core/app_feedback.dart';
import '../../core/error_text.dart';
import '../../core/editor_leave_guard.dart';
import '../../core/mode_picker.dart';
import '../../core/models.dart';
import '../../core/ui_mode.dart';
import '../editor/editor_controller.dart';
import '../pages/pages_catalog.dart';
import '../pages/workshop_features.dart';
import 'shell_state.dart';

/// 组装当前壳可执行的完整命令清单。
///
/// [includePaneActions] 为 false 时（导演壳 / 手机宽度）不生成左侧栏面板类
/// 动作——那些壳没有侧栏，生成了也点不到；导演壳改由 `host.extraActions`
/// 提供自己的常用动作。
///
/// [saveCurrent] 为 app 层现取「当前可保存对象」的解析器（活动工作台的
/// SaveHandle 优先）；为 null（没有任何可保存对象）时不生成「保存当前」。
List<AppCommand> buildAppCommands({
  required AppState state,
  required ShellState shell,
  required UiMode uiMode,
  required AppCommandHost host,
  required Future<void> Function(UiMode mode) setUiMode,
  required bool includePaneActions,
  Future<bool> Function()? saveCurrent,
}) {
  final out = <AppCommand>[];

  // ---------------- 常用动作 ----------------
  if (includePaneActions) {
    const panes = <(SidePane, String, String, IconData)>[
      (SidePane.settings, '打开设置', '偏好 外观 简易模式 模型 ai 设置',
          FluentIcons.settings_24_regular),
      (SidePane.mods, '打开模组管理', '新建 切换 导入 导出 mod 模组',
          FluentIcons.apps_24_regular),
      (SidePane.pages, '打开编辑页面列表', '页面 目录 page',
          FluentIcons.grid_24_regular),
      (SidePane.files, '打开文件树', '文件 目录 文本编辑 file',
          FluentIcons.folder_24_regular),
      (SidePane.resources, '打开资源面板', '贴图 音频 立绘 素材 资源',
          FluentIcons.image_24_regular),
      (SidePane.plugins, '打开插件面板', '插件 扩展 动态面板 plugin',
          FluentIcons.puzzle_piece_24_regular),
      (SidePane.cloud, '打开云同步', '云同步 备份 webdav openlist',
          FluentIcons.cloud_24_regular),
      (SidePane.bugfix, '打开扫描修复', '配置 体检 修复 扫描 bugfix',
          FluentIcons.wrench_24_regular),
    ];
    for (final (pane, label, keywords, icon) in panes) {
      out.add(AppCommand(
        id: 'action:pane-${pane.name}',
        label: label,
        description: '在左侧栏打开该面板',
        keywords: keywords,
        category: AppCommandCategory.action,
        icon: icon,
        run: (context) async => shell.selectPane(pane),
      ));
    }
    out.add(AppCommand(
      id: 'action:ai',
      label: shell.aiOpen ? '收起 AI 助手' : '打开 AI 助手',
      description: '停靠 / 收起右侧 AI 面板',
      keywords: 'ai 助手 对话 模型 assistant',
      category: AppCommandCategory.action,
      icon: FluentIcons.bot_24_regular,
      run: (context) async => shell.toggleAi(),
    ));
  }

  // 剧情库检索：壳登记优先（壳自己知道检索页在哪），否则退回左侧栏的
  // 检索面板（创作/经典壳都有）——统一走 `shell.openSearch`。
  if (host.openSearch != null || includePaneActions) {
    out.add(AppCommand(
      id: 'action:search',
      label: '剧情库检索',
      description: '原版事件与台词全文检索',
      keywords: '搜索 检索 剧情 台词 事件 search',
      category: AppCommandCategory.action,
      icon: FluentIcons.search_24_regular,
      run: (context) async => shell.openSearch(),
    ));
  }

  if (saveCurrent != null) {
    out.add(AppCommand(
      id: 'action:save',
      label: '保存当前',
      description: '保存当前工作台的修改（Ctrl+S）',
      keywords: '保存 存盘 save',
      category: AppCommandCategory.action,
      icon: FluentIcons.save_24_regular,
      run: (context) async {
        final ok = await saveCurrent();
        if (!ok && context.mounted) {
          AppFeedback.info(context, '当前界面没有可保存的内容');
        }
      },
    ));
  }

  out.addAll(host.extraActions);

  // ---------------- 界面模式 ----------------
  for (final m in UiMode.values) {
    final current = m == uiMode;
    out.add(AppCommand(
      id: 'mode:${m.prefsValue}',
      label: current ? '界面模式：${m.label}（当前）' : '界面模式：${m.label}',
      description: uiModeDescription(m),
      keywords: '布局 模式 风格 mode ${m.label}',
      category: AppCommandCategory.mode,
      icon: uiModeIcon(m),
      run: (context) async {
        if (!current) await setUiMode(m);
      },
    ));
  }

  // ---------------- 编辑页面（pages_catalog） ----------------
  for (final p in visibleEditorPages) {
    out.add(AppCommand(
      id: 'page:${p.id}',
      label: p.title,
      description: p.description,
      keywords: p.cfgNames.join(' '),
      category: AppCommandCategory.page,
      icon: pageIconFor(p.id),
      run: (context) async {
        final open = host.openPage;
        if (open != null) {
          open(p.id);
          return;
        }
        await openDocGuarded(
          context,
          shell.controller,
          OpenDoc.page(pageId: p.id, title: p.title),
        );
      },
    ));
  }

  // ---------------- 功能（workshop_features，导演壳专属） ----------------
  final openFeature = host.openFeature;
  if (openFeature != null) {
    for (final f in kWorkshopFeatures) {
      if (!f.native || f.isLibrary) continue;
      out.add(AppCommand(
        id: 'feature:${f.id}',
        label: f.label,
        description: f.description,
        keywords: '${f.group} ${f.tables.join(' ')}',
        category: AppCommandCategory.feature,
        icon: FluentIcons.apps_list_24_regular,
        run: (context) async => openFeature(f.id),
      ));
    }
  }

  // ---------------- 模组 ----------------
  for (final m in state.mods) {
    final current = m.name == state.modName;
    out.add(AppCommand(
      id: 'mod:${m.name}',
      label: current ? '${m.displayName}（当前模组）' : m.displayName,
      description: '切换到模组 ${m.name}',
      keywords: '${m.name} 切换模组 mod switch',
      category: AppCommandCategory.mod,
      icon: FluentIcons.apps_24_regular,
      run: (context) async {
        if (current) return;
        final select = host.selectMod;
        if (select != null) {
          await select(m.name);
          return;
        }
        await defaultSelectMod(context, state, m.name);
      },
    ));
  }

  return out;
}

/// 默认的模组切换（不含壳的善后逻辑）：先跑离开守卫，再 POST 切换并同步
/// 本地状态。导演壳用自己的 [AppCommandHost.selectMod] 覆盖（它会额外刷新
/// 素材映射）。
Future<void> defaultSelectMod(
  BuildContext context,
  AppState state,
  String name,
) async {
  if (name.trim().isEmpty || name == state.modName) return;
  if (!await state.runLeaveGuards()) return;
  try {
    final r = await ApiClient.instance.post(
      '/api/mods/select',
      body: {'name': name},
    );
    final m = (r['mod'] as Map).cast<String, dynamic>();
    state.setMod(m['name'] as String, m['root'] as String);
    if (!context.mounted) return;
    AppFeedback.success(context, '已切换到模组「${state.currentModDisplayName}」');
  } catch (e) {
    if (!context.mounted) return;
    AppFeedback.error(
      context,
      '切换模组失败：${humanizeErrorMessage(e)}',
      detail: e.toString(),
    );
  }
}
