// A2 全局命令：命令面板（Ctrl+K）与全局快捷键共用的命令模型。
//
// 设计约束（见 plan/ux_roadmap_r2.md A2）：
// - **不新建第二份功能清单**——命令由现有目录现场生成（`pages_catalog` 的
//   `editorPages`、`workshop_features` 的 `kWorkshopFeatures`、`UiMode`、
//   `AppState.mods`），本文件只描述「一条命令」的形状；
// - 快捷键挂在壳之上（`FluentApp.builder`），因此命令的落地回调由**当前壳**
//   登记（[AppCommandHost]）：壳没登记的入口自动隐藏，不产生「点了没反应」
//   的死条目。
library;

import 'package:flutter/widgets.dart';

/// 命令分组：决定命令面板里的分区标题与排序。
enum AppCommandCategory {
  action('动作'),
  mode('界面模式'),
  page('编辑页面'),
  feature('功能'),
  mod('模组');

  const AppCommandCategory(this.label);

  final String label;
}

/// 一条全局命令。`run` 在命令面板 / 快捷键的宿主 context（位于 Navigator 与
/// Overlay 之下）内执行，因此可直接用 `showDialog` / `displayInfoBar`。
class AppCommand {
  const AppCommand({
    required this.id,
    required this.label,
    required this.category,
    required this.run,
    this.description = '',
    this.keywords = '',
    this.icon,
  });

  /// 稳定标识，形如 `page:person` / `mod:MyMod`，供去重与测试断言。
  final String id;

  final String label;

  /// 副标题（一句话说明）。
  final String description;

  /// 额外匹配词（表名、别名、分组名等），参与模糊搜索。
  final String keywords;

  final AppCommandCategory category;

  final IconData? icon;

  final Future<void> Function(BuildContext context) run;

  /// 模糊搜索的单一匹配串。
  String get searchText => '$label $description $keywords';
}

/// 当前壳登记的「命令落地」回调集合。
///
/// 未登记（或字段为 null）时不生成对应命令——命令面板只展示当前壳真的能
/// 执行的动作。所有字段都可选：[AppCommandHost] 的默认实例即「什么都不登记」。
class AppCommandHost {
  const AppCommandHost({
    this.openPage,
    this.openFeature,
    this.openSearch,
    this.selectMod,
    this.save,
    this.extraActions = const <AppCommand>[],
  });

  /// 在当前壳里打开某个编辑页面（`editorPages` 的 id）。
  final void Function(String pageId)? openPage;

  /// 在当前壳里打开某个功能（`kWorkshopFeatures` 的 id）。
  final void Function(String featureId)? openFeature;

  /// 打开「剧情库检索」。
  final VoidCallback? openSearch;

  /// 切换模组（壳可带上自己的善后，如刷新素材映射）。
  final Future<void> Function(String modName)? selectMod;

  /// 保存当前（依赖 A3 工作台保存条控制器）。
  final Future<void> Function()? save;

  /// 壳自有的常用动作（导演壳的「主页 / 云同步 / 素材库」等）。
  final List<AppCommand> extraActions;

  /// 是否什么都没登记（等价于默认实例）。
  bool get isEmpty =>
      openPage == null &&
      openFeature == null &&
      openSearch == null &&
      selectMod == null &&
      save == null &&
      extraActions.isEmpty;
}
